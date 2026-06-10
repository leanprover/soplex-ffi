/*
 * Lean-callable bridge: unpacks Lean ByteArray / FloatArray inputs, calls
 * into `lean_soplex.cpp`, and packages the result as a Lean ADT.
 *
 * Integer index arrays are passed as ByteArrays of int32 entries
 * (matching `lean-csdp`); floating-point arrays as FloatArrays;
 * rationals in the packed numerator/denominator wire format described
 * at `RatBufReader` below, decoded with `mpz_import`.
 *
 * Compiled as C++ because Lean's runtime headers and SoPlex's headers both
 * need a C++ translation unit somewhere; making the bridge itself C++
 * keeps the entire FFI in one language.
 */

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <fstream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <tuple>
#include <vector>

#include <lean/lean.h>
#include <gmp.h>
#ifndef NDEBUG
#define NDEBUG
#endif
#include <soplex.h>

#include "lean_soplex.h"

using namespace soplex;

/*
 * Same glibc-compatibility shim as in `lean-csdp`: Lean's bundled clang on
 * Linux still references `__libc_csu_init` / `__libc_csu_fini` from the
 * CRT, but glibc 2.34+ removed them. Provide weak fallbacks that walk
 * `.init_array` / `.fini_array` so global constructors (and SoPlex has
 * many) run correctly.
 */
#if defined(__linux__) && defined(__GLIBC__)
extern "C" {
typedef void (*csu_init_fn)(int, char **, char **);
typedef void (*csu_fini_fn)(void);

extern csu_init_fn __init_array_start[] __attribute__((weak, visibility("hidden")));
extern csu_init_fn __init_array_end[]   __attribute__((weak, visibility("hidden")));
extern csu_fini_fn __fini_array_start[] __attribute__((weak, visibility("hidden")));
extern csu_fini_fn __fini_array_end[]   __attribute__((weak, visibility("hidden")));

__attribute__((weak)) void __libc_csu_init(int argc, char **argv, char **envp) {
  for (size_t i = 0; &__init_array_start[i] != __init_array_end; ++i) {
    __init_array_start[i](argc, argv, envp);
  }
}

__attribute__((weak)) void __libc_csu_fini(void) {
  size_t i = (size_t)(__fini_array_end - __fini_array_start);
  while (i-- > 0) __fini_array_start[i]();
}
} // extern "C"
#endif

static inline const int32_t *byte_array_as_i32(b_lean_obj_arg arr) {
  return reinterpret_cast<const int32_t *>(lean_sarray_cptr(arr));
}

static inline const double *float_array_const_ptr(b_lean_obj_arg arr) {
  return lean_float_array_cptr(arr);
}

/*
 * RAII redirection of SoPlex's `spxout` to an in-memory buffer.
 *
 * When `enabled` is true, the constructor allocates an `ostringstream`
 * and points every verbosity level's stream at it; the destructor
 * restores the original stream pointers. When `enabled` is false the
 * helper is a complete no-op: no allocation, no setStream calls, and
 * `str()` returns an empty string.
 *
 * Designed for use around any SoPlex call site that wants to capture
 * solver output. The reference to `SoPlex` is non-owning; the solver
 * must outlive this object. `SPxOut` stores raw, non-owning
 * `std::ostream*` pointers, so the saved streams (typically the
 * process-default `cout`/`cerr`) must outlive both the solver and
 * this capture — true by default; only a custom caller-installed
 * stream could violate it.
 */
class LogCapture {
 public:
  LogCapture(soplex::SoPlex &solver, bool enabled)
      : solver_(solver), enabled_(enabled) {
    if (!enabled_) return;
    oss_.reset(new std::ostringstream());
    for (int v = 0; v < kNumVerbLevels; ++v) {
      auto verb = static_cast<soplex::SPxOut::Verbosity>(v);
      saved_[v] = &solver_.spxout.getStream(verb);
      solver_.spxout.setStream(verb, *oss_);
    }
  }
  // Vendored `SPxOut::setStream` is non-throwing (a single pointer
  // assignment), so restoration is safe to run during stack unwinding.
  ~LogCapture() noexcept {
    if (!enabled_) return;
    for (int v = 0; v < kNumVerbLevels; ++v) {
      auto verb = static_cast<soplex::SPxOut::Verbosity>(v);
      solver_.spxout.setStream(verb, *saved_[v]);
    }
  }
  LogCapture(const LogCapture &) = delete;
  LogCapture &operator=(const LogCapture &) = delete;

  std::string str() const {
    return enabled_ ? oss_->str() : std::string{};
  }

 private:
  // SoPlex's `Verbosity` enum is documented as a contiguous range
  // `VERB_ERROR == 0` .. `VERB_INFO3 == 5`; see `soplex/spxout.h`.
  static_assert(static_cast<int>(soplex::SPxOut::VERB_ERROR) == 0,
                "SPxOut::VERB_ERROR must be 0");
  static_assert(static_cast<int>(soplex::SPxOut::VERB_INFO3) == 5,
                "SPxOut::VERB_INFO3 must be 5 (six contiguous verbosity levels)");
  static constexpr int kNumVerbLevels = static_cast<int>(soplex::SPxOut::VERB_INFO3) + 1;

  soplex::SoPlex &solver_;
  bool enabled_;
  std::unique_ptr<std::ostringstream> oss_;
  std::ostream *saved_[kNumVerbLevels] = {};
};

class Mpq {
 public:
  mpq_t q;

  Mpq() { mpq_init(q); }
  Mpq(const Mpq &) = delete;
  Mpq &operator=(const Mpq &) = delete;
  Mpq(Mpq &&other) noexcept {
    mpq_init(q);
    mpq_swap(q, other.q);
  }
  Mpq &operator=(Mpq &&other) noexcept {
    if (this != &other) mpq_swap(q, other.q);
    return *this;
  }
  ~Mpq() { mpq_clear(q); }
};

static void init_mpq_vector(std::vector<Mpq> &xs, size_t n) {
  xs.clear();
  xs.reserve(n);
  for (size_t i = 0; i < n; ++i) xs.emplace_back();
}

/* RAII raw `mpq_t` array for SoPlex's rational getters; the destructor
 * clears every entry, covering the failure / throw paths too. */
class MpqArray {
 public:
  explicit MpqArray(size_t n) : p_(new mpq_t[n]), n_(n) {
    for (size_t i = 0; i < n_; ++i) mpq_init(p_[i]);
  }
  ~MpqArray() {
    for (size_t i = 0; i < n_; ++i) mpq_clear(p_[i]);
  }
  MpqArray(const MpqArray &) = delete;
  MpqArray &operator=(const MpqArray &) = delete;

  mpq_t *data() { return p_.get(); }
  const mpq_t &operator[](size_t i) const { return p_[i]; }

 private:
  std::unique_ptr<mpq_t[]> p_;
  size_t n_;
};

// The limb-walking conversions below assume GMP's limbs are 64-bit
// with no nail bits, true on every platform this package targets
// (Linux x86_64/aarch64, macOS arm64, Windows x86_64 via MinGW).
static_assert(sizeof(mp_limb_t) == sizeof(uint64_t),
              "packed-rational marshalling assumes 64-bit GMP limbs");
static_assert(GMP_NUMB_BITS == 64,
              "packed-rational marshalling assumes nail-free 64-bit GMP limbs");

/*
 * Build a Lean `Nat` holding |z|, straight from GMP's limbs: the top
 * limb seeds the value and each further limb is folded in with
 * shift-and-add through the Lean runtime's bignum ops. Single-limb
 * values (the common case) take the `lean_uint64_to_nat` fast path.
 * Allocation-free apart from the Lean objects themselves, hence
 * non-throwing — important for the Lean-object construction phases
 * below, which rely on not unwinding mid-build.
 */
static lean_object *mk_nat_from_mpz_abs(const mpz_t z) {
  size_t nlimbs = mpz_size(z);
  if (nlimbs == 0) return lean_box(0);
  lean_object *n = lean_uint64_to_nat(static_cast<uint64_t>(mpz_getlimbn(z, nlimbs - 1)));
  if (nlimbs == 1) return n;
  lean_object *shift = lean_box(64);
  for (size_t i = nlimbs - 1; i-- > 0;) {
    lean_object *shifted = lean_nat_shiftl(n, shift);
    lean_dec(n);
    lean_object *limb = lean_uint64_to_nat(static_cast<uint64_t>(mpz_getlimbn(z, i)));
    n = lean_nat_add(shifted, limb);
    lean_dec(shifted);
    lean_dec(limb);
  }
  return n;
}

static lean_object *mk_int_from_mpz(const mpz_t z) {
  lean_object *nat = mk_nat_from_mpz_abs(z);
  lean_object *pos = lean_nat_to_int(nat); // consumes `nat`
  if (mpz_sgn(z) >= 0) return pos;
  lean_object *neg = lean_int_neg(pos);
  lean_dec(pos);
  return neg;
}

/*
 * Build a Lean `Rat` from a canonical `mpq_t`.
 *
 * PRECONDITION: `q` is canonical (positive denominator, gcd 1) — the
 * Lean `Rat` type carries reducedness as an invariant, so handing it a
 * non-canonical value would be unsound. Every producer in this file
 * guarantees this: inputs decode from Lean `Rat`s (canonical by
 * construction), GMP arithmetic preserves canonicity, and SoPlex
 * getter results are canonicalized in `fetch` / `mk_rat_from_mpq_canon`.
 */
static lean_object *mk_rat_from_mpq(const mpq_t q) {
  lean_object *r = lean_alloc_ctor(0, 4, 0);
  lean_ctor_set(r, 0, mk_int_from_mpz(mpq_numref(q)));
  lean_ctor_set(r, 1, mk_nat_from_mpz_abs(mpq_denref(q)));
  lean_ctor_set(r, 2, lean_box(0));
  lean_ctor_set(r, 3, lean_box(0));
  return r;
}

/* Canonicalizing variant for values whose canonicity we don't control
 * (SoPlex objective values, file-reader output). */
static lean_object *mk_rat_from_mpq_canon(const mpq_t q) {
  Mpq z;
  mpq_set(z.q, q);
  mpq_canonicalize(z.q);
  return mk_rat_from_mpq(z.q);
}

/*
 * Build a Lean `Rat` from an IEEE-754 double via `mpq_set_d`. The result
 * is the *exact* rational represented by the double's binary fraction,
 * e.g. `0.1` becomes `7205759403792794 / 2^56`, not `1/10`. Used by
 * `lean_soplex_solve_float` to surface SoPlex's `Real` primal values
 * losslessly as rationals — never as a verifier-grade certificate.
 */
static lean_object *mk_rat_from_double(double d) {
  Mpq q;
  mpq_set_d(q.q, d);
  mpq_canonicalize(q.q);
  return mk_rat_from_mpq(q.q);
}

/*
 * Sequential reader for the packed-rational wire format produced by
 * `pushRatLE` in `SoplexFFI/Basic.lean`. One record per rational:
 *
 *   u8  sign      1 = negative numerator, 0 otherwise
 *   u32 numLen    little-endian byte count of |num|
 *   ..  num       |num| base-256, least significant byte first,
 *                 no trailing zero byte; numLen = 0 <=> num = 0
 *   u32 denLen    same encoding; denLen = 0 <=> den = 1
 *   ..  den
 *
 * Records are canonical by construction on the Lean side (`Rat`
 * carries reducedness proofs), so no gcd pass happens here; only
 * structural validity (in-bounds reads, nonzero denominator) is
 * checked.
 */
class RatBufReader {
 public:
  explicit RatBufReader(b_lean_obj_arg buf)
      : p_(lean_sarray_cptr(buf)), end_(p_ + lean_sarray_size(buf)) {}

  void read_mpq(mpq_t q) {
    uint8_t sign = read_u8();
    if (sign > 1) throw std::runtime_error("malformed rational buffer (sign byte)");
    read_mpz(mpq_numref(q));
    uint32_t denLen = read_u32();
    if (denLen > 0) {
      read_mpz_bytes(mpq_denref(q), denLen);
      if (mpz_sgn(mpq_denref(q)) == 0) {
        throw std::runtime_error("malformed rational buffer (zero denominator)");
      }
    }
    if (sign) mpz_neg(mpq_numref(q), mpq_numref(q));
  }

  void expect_end() const {
    if (p_ != end_) throw std::runtime_error("malformed rational buffer (trailing bytes)");
  }

 private:
  uint8_t read_u8() {
    need(1);
    return *p_++;
  }
  uint32_t read_u32() {
    need(4);
    uint32_t v = static_cast<uint32_t>(p_[0]) | (static_cast<uint32_t>(p_[1]) << 8) |
                 (static_cast<uint32_t>(p_[2]) << 16) | (static_cast<uint32_t>(p_[3]) << 24);
    p_ += 4;
    return v;
  }
  void read_mpz(mpz_t z) { read_mpz_bytes(z, read_u32()); }
  void read_mpz_bytes(mpz_t z, uint32_t len) {
    if (len == 0) {
      mpz_set_ui(z, 0);
      return;
    }
    need(len);
    mpz_import(z, len, /*order=*/-1, /*size=*/1, /*endian=*/0, /*nails=*/0, p_);
    p_ += len;
  }
  void need(size_t n) const {
    if (static_cast<size_t>(end_ - p_) < n) {
      throw std::runtime_error("malformed rational buffer (truncated)");
    }
  }

  const uint8_t *p_;
  const uint8_t *end_;
};

/* Decode a buffer of exactly `count` packed rationals. */
static std::vector<Mpq> decode_rat_array(b_lean_obj_arg buf, size_t count) {
  RatBufReader reader(buf);
  std::vector<Mpq> out;
  init_mpq_vector(out, count);
  for (size_t i = 0; i < count; ++i) reader.read_mpq(out[i].q);
  reader.expect_end();
  return out;
}

/* Decode a buffer holding a single packed rational (`objOffset`). */
static Mpq decode_rat(b_lean_obj_arg buf) {
  RatBufReader reader(buf);
  Mpq q;
  reader.read_mpq(q.q);
  reader.expect_end();
  return q;
}

/*
 * All problem data, decoded from the Lean buffers exactly once. The
 * bound vectors always have full row / column length; entries whose
 * mask bit is 0 decode as zero and are never read. Keeping the decoded
 * `Mpq`s here lets the certificate-extraction paths
 * (`bound_combination_sign`, `compute_at_y`) reuse them instead of
 * re-parsing.
 */
struct DecodedProblem {
  int numVars;
  int numConstraints;
  size_t nnz;
  const int32_t *aRows;
  const int32_t *aCols;
  const uint8_t *rowLoMask;
  const uint8_t *rowHiMask;
  const uint8_t *colLoMask;
  const uint8_t *colHiMask;
  std::vector<Mpq> c;
  std::vector<Mpq> aVals;
  std::vector<Mpq> rowLo;
  std::vector<Mpq> rowHi;
  std::vector<Mpq> colLo;
  std::vector<Mpq> colHi;
};

static const uint8_t *mask_ptr(b_lean_obj_arg mask, size_t expected, const char *what) {
  if (lean_sarray_size(mask) != expected) {
    throw std::runtime_error(std::string("bound mask has wrong length: ") + what);
  }
  return lean_sarray_cptr(mask);
}

static DecodedProblem decode_problem(
    uint32_t numVars_u, uint32_t numConstraints_u,
    b_lean_obj_arg c_buf,
    b_lean_obj_arg a_rows_arr, b_lean_obj_arg a_cols_arr, b_lean_obj_arg a_vals_buf,
    b_lean_obj_arg rowLoMask, b_lean_obj_arg rowLo,
    b_lean_obj_arg rowHiMask, b_lean_obj_arg rowHi,
    b_lean_obj_arg colLoMask, b_lean_obj_arg colLo,
    b_lean_obj_arg colHiMask, b_lean_obj_arg colHi) {
  DecodedProblem dp;
  dp.numVars = static_cast<int>(numVars_u);
  dp.numConstraints = static_cast<int>(numConstraints_u);
  if (lean_sarray_size(a_rows_arr) % sizeof(int32_t) != 0 ||
      lean_sarray_size(a_cols_arr) != lean_sarray_size(a_rows_arr)) {
    throw std::runtime_error("malformed sparse index buffers");
  }
  dp.nnz = lean_sarray_size(a_rows_arr) / sizeof(int32_t);
  dp.aRows = byte_array_as_i32(a_rows_arr);
  dp.aCols = byte_array_as_i32(a_cols_arr);
  size_t m = static_cast<size_t>(dp.numConstraints);
  size_t n = static_cast<size_t>(dp.numVars);
  dp.rowLoMask = mask_ptr(rowLoMask, m, "rowLo");
  dp.rowHiMask = mask_ptr(rowHiMask, m, "rowHi");
  dp.colLoMask = mask_ptr(colLoMask, n, "colLo");
  dp.colHiMask = mask_ptr(colHiMask, n, "colHi");
  dp.c = decode_rat_array(c_buf, n);
  dp.aVals = decode_rat_array(a_vals_buf, dp.nnz);
  dp.rowLo = decode_rat_array(rowLo, m);
  dp.rowHi = decode_rat_array(rowHi, m);
  dp.colLo = decode_rat_array(colLo, n);
  dp.colHi = decode_rat_array(colHi, n);
  return dp;
}

static void add_rational_col(SoPlex &solver, const LPColRational &col) {
  solver.addColRational(col);
}

static void add_rational_col(SPxLPRational &lp, const LPColRational &col) {
  lp.addCol(col);
}

static void add_rational_row(SoPlex &solver, const LPRowRational &row) {
  solver.addRowRational(row);
}

static void add_rational_row(SPxLPRational &lp, const LPRowRational &row) {
  lp.addRow(row);
}

template <typename Lp>
static void build_rational_lp(Lp &lp, const DecodedProblem &dp) {
  std::vector<std::vector<int>> rowIdx(dp.numConstraints);
  std::vector<std::vector<size_t>> rowValIdx(dp.numConstraints);
  for (size_t k = 0; k < dp.nnz; ++k) {
    int r = dp.aRows[k];
    int col = dp.aCols[k];
    if (r < 0 || r >= dp.numConstraints || col < 0 || col >= dp.numVars) {
      throw std::runtime_error("sparse index out of range");
    }
    rowIdx[r].push_back(col);
    rowValIdx[r].push_back(k);
  }

  DSVectorRational emptyCol(0);
  for (int j = 0; j < dp.numVars; ++j) {
    Rational obj(dp.c[j].q);
    Rational lo = dp.colLoMask[j] ? Rational(dp.colLo[j].q) : -Rational(infinity);
    Rational hi = dp.colHiMask[j] ? Rational(dp.colHi[j].q) : Rational(infinity);
    add_rational_col(lp, LPColRational(obj, emptyCol, hi, lo));
  }

  for (int i = 0; i < dp.numConstraints; ++i) {
    Rational lo = dp.rowLoMask[i] ? Rational(dp.rowLo[i].q) : -Rational(infinity);
    Rational hi = dp.rowHiMask[i] ? Rational(dp.rowHi[i].q) : Rational(infinity);
    DSVectorRational vals(static_cast<int>(rowIdx[i].size()));
    for (size_t t = 0; t < rowIdx[i].size(); ++t) {
      vals.add(rowIdx[i][t], Rational(dp.aVals[rowValIdx[i][t]].q));
    }
    add_rational_row(lp, LPRowRational(lo, vals, hi));
  }
}

static void build_real_lp(SoPlex &solver, const DecodedProblem &dp) {
  DSVector emptyCol(0);
  for (int j = 0; j < dp.numVars; ++j) {
    double lo = dp.colLoMask[j] ? mpq_get_d(dp.colLo[j].q) : -infinity;
    double hi = dp.colHiMask[j] ? mpq_get_d(dp.colHi[j].q) : infinity;
    solver.addColReal(LPCol(mpq_get_d(dp.c[j].q), emptyCol, hi, lo));
  }

  std::vector<DSVector> rows(dp.numConstraints);
  for (size_t k = 0; k < dp.nnz; ++k) {
    int r = dp.aRows[k];
    int col = dp.aCols[k];
    if (r < 0 || r >= dp.numConstraints || col < 0 || col >= dp.numVars) {
      throw std::runtime_error("sparse index out of range");
    }
    rows[r].add(col, mpq_get_d(dp.aVals[k].q));
  }

  for (int i = 0; i < dp.numConstraints; ++i) {
    double lo = dp.rowLoMask[i] ? mpq_get_d(dp.rowLo[i].q) : -infinity;
    double hi = dp.rowHiMask[i] ? mpq_get_d(dp.rowHi[i].q) : infinity;
    solver.addRowReal(LPRow(lo, rows[i], hi));
  }
}

static lean_object *mk_array_from_mpqs(const std::vector<Mpq> &xs) {
  lean_object *a = lean_alloc_array(xs.size(), xs.size());
  lean_array_set_size(a, xs.size());
  for (size_t i = 0; i < xs.size(); ++i) {
    lean_array_cptr(a)[i] = mk_rat_from_mpq(xs[i].q);
  }
  return a;
}

static lean_object *mk_none() {
  return lean_box(0);
}

static lean_object *mk_some(lean_object *x) {
  lean_object *o = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(o, 0, x);
  return o;
}

/* Takes ownership of the four (already-built) Lean arrays. */
static lean_object *mk_dual_bundle(
    lean_object *rowLower, lean_object *rowUpper,
    lean_object *colLower, lean_object *colUpper) {
  lean_object *d = lean_alloc_ctor(0, 4, 0);
  lean_ctor_set(d, 0, rowLower);
  lean_ctor_set(d, 1, rowUpper);
  lean_ctor_set(d, 2, colLower);
  lean_ctor_set(d, 3, colUpper);
  return d;
}

static lean_object *mk_certificate(
    lean_object *primalOpt, lean_object *dualOpt, lean_object *rayOpt) {
  lean_object *c = lean_alloc_ctor(0, 3, 0);
  lean_ctor_set(c, 0, primalOpt);
  lean_ctor_set(c, 1, dualOpt);
  lean_ctor_set(c, 2, rayOpt);
  return c;
}

static lean_object *mk_solution(
    uint8_t status, lean_object *objectiveOpt, lean_object *cert,
    const std::string &log) {
  // Solution m n layout (m, n are type-level parameters, erased at
  // runtime). Lean packs scalars at the end:
  //   boxed 0 = objective      : Option Rat
  //   boxed 1 = certificate    : Certificate m n
  //   boxed 2 = log            : String
  //   scalar  = status         : SolveStatus (uint8)
  lean_object *s = lean_alloc_ctor(0, 3, sizeof(uint8_t));
  lean_ctor_set(s, 0, objectiveOpt);
  lean_ctor_set(s, 1, cert);
  lean_ctor_set(s, 2, lean_mk_string(log.c_str()));
  lean_ctor_set_uint8(s, sizeof(void *) * 3, status);
  return s;
}

static lean_object *mk_except_ok(lean_object *x) {
  lean_object *r = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(r, 0, x);
  return r;
}

static lean_object *mk_except_error(const std::string &msg) {
  lean_object *r = lean_alloc_ctor(0, 1, 0);
  lean_ctor_set(r, 0, lean_mk_string(msg.c_str()));
  return r;
}

/* Shared literal `(0 : Rat)`; callers `lean_inc` per use. */
static lean_object *mk_rat_zero() {
  lean_object *r = lean_alloc_ctor(0, 4, 0);
  lean_ctor_set(r, 0, lean_box(0)); // num = 0
  lean_ctor_set(r, 1, lean_box(1)); // den = 1
  lean_ctor_set(r, 2, lean_box(0));
  lean_ctor_set(r, 3, lean_box(0));
  return r;
}

/*
 * Split a signed multiplier vector into nonnegative (lower, upper)
 * components by sign, building the two Lean arrays directly — no
 * intermediate `std::vector<Mpq>` copies. Zero entries share a single
 * `(0 : Rat)` object.
 */
static void mk_split_pos_arrays(const std::vector<Mpq> &signedVals,
                                lean_object **lowerOut, lean_object **upperOut) {
  size_t n = signedVals.size();
  lean_object *lower = lean_alloc_array(n, n);
  lean_object *upper = lean_alloc_array(n, n);
  lean_object *zero = mk_rat_zero();
  Mpq tmp;
  for (size_t i = 0; i < n; ++i) {
    int sign = mpq_sgn(signedVals[i].q);
    lean_object *lo;
    lean_object *hi;
    if (sign > 0) {
      lo = mk_rat_from_mpq(signedVals[i].q);
      lean_inc(zero);
      hi = zero;
    } else if (sign < 0) {
      mpq_neg(tmp.q, signedVals[i].q);
      hi = mk_rat_from_mpq(tmp.q);
      lean_inc(zero);
      lo = zero;
    } else {
      lean_inc(zero);
      lean_inc(zero);
      lo = zero;
      hi = zero;
    }
    lean_array_cptr(lower)[i] = lo;
    lean_array_cptr(upper)[i] = hi;
  }
  lean_dec(zero);
  *lowerOut = lower;
  *upperOut = upper;
}

// Mask-aware Farkas routing: send a signed Farkas multiplier vector into
// the (lower, upper) slots of `DualBundle`, consulting the bound mask so
// one-sided rows always populate the slot that actually has a bound.
// Builds the Lean arrays directly, like `mk_split_pos_arrays`.
//
// Why not just split by sign (`mk_split_pos_arrays`)? SoPlex's `getDualFarkasRational`
// returns POSITIVE multipliers for one-sided constraints regardless of
// which bound side they refer to (positive both for `Ax ≤ hi` and
// `Ax ≥ lo` infeasibilities). For ranged constraints (both bounds
// present), the sign indicates the binding side: positive→lower,
// negative→upper. Pure sign-based routing breaks the one-sided-upper
// case (positive multipliers wrongly land in `rowLower`, where the
// `DualBundle` contract requires zero).
//
// The verifier (`LP/Verify/Bool.lean`) requires:
//   * `lower[i] = 0` if row `i` has no lower bound, and similarly for
//     upper;
//   * all multipliers `≥ 0`.
// Both invariants are preserved here by routing to the present side and
// taking the absolute value.
static void mk_farkas_arrays(
    const std::vector<Mpq> &signedY,
    const uint8_t *loMask, const uint8_t *hiMask,
    lean_object **lowerOut, lean_object **upperOut) {
  size_t n = signedY.size();
  lean_object *lower = lean_alloc_array(n, n);
  lean_object *upper = lean_alloc_array(n, n);
  lean_object *zero = mk_rat_zero();
  Mpq tmp;
  for (size_t i = 0; i < n; ++i) {
    int sign = mpq_sgn(signedY[i].q);
    bool hasLo = loMask[i];
    bool hasHi = hiMask[i];
    lean_object *lo = nullptr;
    lean_object *hi = nullptr;
    if (sign != 0 && hasLo && hasHi) {
      // Ranged: SoPlex's signed convention is positive→lower, negative→upper.
      if (sign > 0) {
        lo = mk_rat_from_mpq(signedY[i].q);
      } else {
        mpq_neg(tmp.q, signedY[i].q);
        hi = mk_rat_from_mpq(tmp.q);
      }
    } else if (sign != 0 && hasLo) {
      // One-sided lower: take the magnitude into rowLower.
      if (sign > 0) {
        lo = mk_rat_from_mpq(signedY[i].q);
      } else {
        mpq_neg(tmp.q, signedY[i].q);
        lo = mk_rat_from_mpq(tmp.q);
      }
    } else if (sign != 0 && hasHi) {
      // One-sided upper: take the magnitude into rowUpper.
      if (sign > 0) {
        hi = mk_rat_from_mpq(signedY[i].q);
      } else {
        mpq_neg(tmp.q, signedY[i].q);
        hi = mk_rat_from_mpq(tmp.q);
      }
    }
    // Free row (no bounds) or zero multiplier: both slots stay zero.
    if (lo == nullptr) {
      lean_inc(zero);
      lo = zero;
    }
    if (hi == nullptr) {
      lean_inc(zero);
      hi = zero;
    }
    lean_array_cptr(lower)[i] = lo;
    lean_array_cptr(upper)[i] = hi;
  }
  lean_dec(zero);
  *lowerOut = lower;
  *upperOut = upper;
}

static void negate_all(std::vector<Mpq> &xs) {
  for (auto &x : xs) mpq_neg(x.q, x.q);
}

static void compute_at_y(
    size_t numVars, const int32_t *rows, const int32_t *cols,
    const std::vector<Mpq> &vals, const std::vector<Mpq> &y,
    std::vector<Mpq> &out) {
  init_mpq_vector(out, numVars);
  mpq_t tmp;
  mpq_init(tmp);
  for (size_t k = 0; k < vals.size(); ++k) {
    mpq_mul(tmp, vals[k].q, y[rows[k]].q);
    mpq_add(out[cols[k]].q, out[cols[k]].q, tmp);
  }
  mpq_clear(tmp);
}

/* Bounds come straight from `dp`'s decoded vectors — no re-parsing. */
static int bound_combination_sign(
    const std::vector<Mpq> &rowSigned, const std::vector<Mpq> &colSigned,
    const DecodedProblem &dp) {
  Mpq acc;
  mpq_t tmp;
  mpq_init(tmp);
  auto add_bound = [&](const Mpq &signedVal, bool lower, const Mpq &bound) {
    if ((lower && mpq_sgn(signedVal.q) <= 0) || (!lower && mpq_sgn(signedVal.q) >= 0)) return;
    mpq_mul(tmp, signedVal.q, bound.q);
    if (!lower) mpq_neg(tmp, tmp);
    mpq_add(acc.q, acc.q, tmp);
  };
  for (size_t i = 0; i < rowSigned.size(); ++i) {
    if (dp.rowLoMask[i]) add_bound(rowSigned[i], true, dp.rowLo[i]);
    if (dp.rowHiMask[i]) add_bound(rowSigned[i], false, dp.rowHi[i]);
  }
  for (size_t j = 0; j < colSigned.size(); ++j) {
    if (dp.colLoMask[j]) add_bound(colSigned[j], true, dp.colLo[j]);
    if (dp.colHiMask[j]) add_bound(colSigned[j], false, dp.colHi[j]);
  }
  int s = mpq_sgn(acc.q);
  mpq_clear(tmp);
  return s;
}

extern "C" LEAN_EXPORT uint32_t lean_soplex_version_ffi(void) {
  return static_cast<uint32_t>(lean_soplex_version());
}

extern "C" LEAN_EXPORT uint32_t lean_soplex_exception_check_ffi(void) {
  return static_cast<uint32_t>(lean_soplex_exception_check());
}

extern "C" LEAN_EXPORT lean_obj_res lean_soplex_solve_exact(
    b_lean_obj_arg /*m*/, b_lean_obj_arg /*n*/,
    uint32_t numVars_u, uint32_t numConstraints_u,
    uint8_t simplex,
    uint8_t hasTimeLimit, double timeLimit,
    uint8_t hasIterLimit, uint32_t iterLimit,
    uint8_t verbose, uint32_t randomSeed,
    uint8_t precisionBoost, uint8_t presolve,
    b_lean_obj_arg c_arr, b_lean_obj_arg objOffset,
    b_lean_obj_arg a_rows_arr, b_lean_obj_arg a_cols_arr, b_lean_obj_arg a_vals_arr,
    b_lean_obj_arg rowLoMask, b_lean_obj_arg rowLo,
    b_lean_obj_arg rowHiMask, b_lean_obj_arg rowHi,
    b_lean_obj_arg colLoMask, b_lean_obj_arg colLo,
    b_lean_obj_arg colHiMask, b_lean_obj_arg colHi) noexcept {
  try {
    const DecodedProblem input = decode_problem(
        numVars_u, numConstraints_u, c_arr, a_rows_arr, a_cols_arr, a_vals_arr,
        rowLoMask, rowLo, rowHiMask, rowHi, colLoMask, colLo, colHiMask, colHi);

    SoPlex solver;
    // Constructed before any parameter / LP-build call so the whole
    // solveExact lifecycle (param-setting warnings, LP construction,
    // optimize, result extraction) writes into the captured buffer
    // when verbose. Non-verbose path is a no-op.
    LogCapture logCap(solver, verbose != 0);
    solver.setIntParam(SoPlex::OBJSENSE, SoPlex::OBJSENSE_MINIMIZE);
    solver.setIntParam(SoPlex::SOLVEMODE, SoPlex::SOLVEMODE_RATIONAL);
    solver.setIntParam(SoPlex::SYNCMODE, SoPlex::SYNCMODE_AUTO);
    solver.setIntParam(SoPlex::READMODE, SoPlex::READMODE_RATIONAL);
    solver.setIntParam(SoPlex::CHECKMODE, SoPlex::CHECKMODE_RATIONAL);
    // SoPlex's documented exact-solver settings require zero rational
    // feasibility/optimality tolerances. Otherwise the rational getters may
    // return tolerance-feasible duals rather than verifier-grade certificates.
    solver.setRealParam(SoPlex::FEASTOL, 0.0);
    solver.setRealParam(SoPlex::OPTTOL, 0.0);
    // SoPlex 8.0.2 only enables this knob in MPFR builds. The local
    // static build used by this package is Boost/GMP-only, where setting
    // it to true is rejected by the parameter layer and can leave the
    // solver inconsistent. False is always safe; true keeps SoPlex's
    // build-time default.
    if (!precisionBoost) solver.setBoolParam(SoPlex::PRECISION_BOOSTING, false);
    solver.setIntParam(SoPlex::SIMPLIFIER, presolve ? SoPlex::SIMPLIFIER_INTERNAL : SoPlex::SIMPLIFIER_OFF);
    solver.setIntParam(SoPlex::VERBOSITY, verbose ? SoPlex::VERBOSITY_NORMAL : SoPlex::VERBOSITY_ERROR);
    solver.setRandomSeed(randomSeed);
    if (hasTimeLimit) solver.setRealParam(SoPlex::TIMELIMIT, timeLimit);
    if (hasIterLimit) solver.setIntParam(SoPlex::ITERLIMIT, static_cast<int>(iterLimit));
    if (simplex == 0) solver.setIntParam(SoPlex::ALGORITHM, SoPlex::ALGORITHM_PRIMAL);
    if (simplex == 1) solver.setIntParam(SoPlex::ALGORITHM, SoPlex::ALGORITHM_DUAL);

    build_rational_lp(solver, input);

    SPxSolver::Status st = solver.optimize();
    uint8_t status = 5; // numericFailure
    lean_object *objective = mk_none();
    lean_object *primal = mk_none();
    lean_object *dual = mk_none();
    lean_object *ray = mk_none();

    auto fetch = [&](size_t n, auto getter, const char *what) {
      MpqArray raw(n);
      bool ok = (solver.*getter)(raw.data(), static_cast<int>(n));
      if (!ok) throw std::runtime_error(std::string("SoPlex failed to return ") + what);
      std::vector<Mpq> xs;
      init_mpq_vector(xs, n);
      for (size_t i = 0; i < n; ++i) {
        mpq_set(xs[i].q, raw[i]);
        mpq_canonicalize(xs[i].q);
      }
      return xs;
    };

    switch (st) {
      case SPxSolver::OPTIMAL:
      case SPxSolver::OPTIMAL_UNSCALED_VIOLATIONS: {
        status = 0;
        // Throwing work (SoPlex getters, GMP) first; Lean allocation
        // only once everything is in hand, so a failed fetch cannot
        // leak partially built Lean objects.
        // SoPlex's objective is `c·x`; the reported objective must
        // include the constant `objOffset` (`Solution.objective`'s
        // contract in lp-core), so add it here in exact arithmetic.
        // GMP's mpq functions require canonical operands, and SoPlex's
        // value is not guaranteed canonical, so canonicalize first.
        Rational soplexObj = solver.objValueRational();
        Mpq objVal;
        mpq_set(objVal.q, soplexObj.backend().data());
        mpq_canonicalize(objVal.q);
        Mpq off = decode_rat(objOffset);
        mpq_add(objVal.q, objVal.q, off.q);
        std::vector<Mpq> x = fetch(input.numVars,
          static_cast<bool (SoPlex::*)(mpq_t *, const int)>(&SoPlex::getPrimalRational),
          "primal solution");
        std::vector<Mpq> y = fetch(input.numConstraints,
          static_cast<bool (SoPlex::*)(mpq_t *, const int)>(&SoPlex::getDualRational),
          "dual solution");
        std::vector<Mpq> z = fetch(input.numVars,
          static_cast<bool (SoPlex::*)(mpq_t *, const int)>(&SoPlex::getRedCostRational),
          "reduced costs");
        objective = mk_some(mk_rat_from_mpq(objVal.q));
        primal = mk_some(mk_array_from_mpqs(x));
        lean_object *rowLower, *rowUpper, *colLower, *colUpper;
        mk_split_pos_arrays(y, &rowLower, &rowUpper);
        mk_split_pos_arrays(z, &colLower, &colUpper);
        dual = mk_some(mk_dual_bundle(rowLower, rowUpper, colLower, colUpper));
        break;
      }
      case SPxSolver::INFEASIBLE: {
        status = 1;
        std::vector<Mpq> y = fetch(input.numConstraints,
          static_cast<bool (SoPlex::*)(mpq_t *, const int)>(&SoPlex::getDualFarkasRational),
          "dual Farkas vector");
        std::vector<Mpq> aty;
        compute_at_y(input.numVars, input.aRows, input.aCols, input.aVals, y, aty);
        for (auto &v : aty) mpq_neg(v.q, v.q);
        if (bound_combination_sign(y, aty, input) < 0) {
          negate_all(y);
          negate_all(aty);
        }
        lean_object *rowLower, *rowUpper, *colLower, *colUpper;
        mk_farkas_arrays(y, input.rowLoMask, input.rowHiMask, &rowLower, &rowUpper);
        mk_farkas_arrays(aty, input.colLoMask, input.colHiMask, &colLower, &colUpper);
        dual = mk_some(mk_dual_bundle(rowLower, rowUpper, colLower, colUpper));
        break;
      }
      case SPxSolver::UNBOUNDED: {
        status = 2;
        std::vector<Mpq> x = fetch(input.numVars,
          static_cast<bool (SoPlex::*)(mpq_t *, const int)>(&SoPlex::getPrimalRational),
          "primal base point");
        std::vector<Mpq> r = fetch(input.numVars,
          static_cast<bool (SoPlex::*)(mpq_t *, const int)>(&SoPlex::getPrimalRayRational),
          "primal ray");
        primal = mk_some(mk_array_from_mpqs(x));
        ray = mk_some(mk_array_from_mpqs(r));
        break;
      }
      case SPxSolver::ABORT_TIME:
        status = 3;
        break;
      case SPxSolver::ABORT_ITER:
        status = 4;
        break;
      case SPxSolver::ABORT_VALUE:
      case SPxSolver::SINGULAR:
      case SPxSolver::NO_RATIOTESTER:
      case SPxSolver::REGULAR:
        status = 5;
        break;
      default:
        status = 7;
        break;
    }

    const std::string log = logCap.str();
    lean_object *cert = mk_certificate(primal, dual, ray);
    lean_object *sol = mk_solution(status, objective, cert, log);
    return mk_except_ok(sol);
  } catch (const std::exception &e) {
    return mk_except_error(e.what());
  } catch (...) {
    return mk_except_error("unknown C++ exception");
  }
}


/*
 * Build a `some : Float → Option Float` Lean value. `Option` is a
 * universe-polymorphic inductive, so its data argument is always
 * passed as a boxed `lean_object *` — the `some` constructor has one
 * object field, never a scalar Float slot. We therefore box the
 * double with `lean_box_float` before storing.
 */
static lean_object *mk_some_float(double d) {
  lean_object *o = lean_alloc_ctor(1, 1, 0);
  lean_ctor_set(o, 0, lean_box_float(d));
  return o;
}

/*
 * Build a Lean `FloatSolution` value. The declaration is
 *   structure FloatSolution where
 *     status      : SolveStatus       -- enum, 1 scalar byte
 *     primalAsRat : Option (Array Rat)
 *     objective   : Option Float
 *     log         : String
 * Lean places object fields first (in declaration order), then scalars.
 * So the ctor has 3 object slots followed by 1 byte of scalar data.
 */
static lean_object *mk_float_solution(
    uint8_t status, lean_object *primalOpt, lean_object *objectiveOpt,
    const std::string &log) {
  lean_object *s = lean_alloc_ctor(0, 3, sizeof(uint8_t));
  lean_ctor_set(s, 0, primalOpt);
  lean_ctor_set(s, 1, objectiveOpt);
  lean_ctor_set(s, 2, lean_mk_string(log.c_str()));
  lean_ctor_set_uint8(s, sizeof(void *) * 3, status);
  return s;
}

/*
 * Float-mode solve. Mirrors `lean_soplex_solve_exact` structurally but
 * builds the LP via `addColReal` / `addRowReal` and runs SoPlex in its
 * default floating-point mode. The returned `primalAsRat` is the exact
 * rational representation of each IEEE-754 double SoPlex produced
 * (via `mpq_set_d`), not a decimal rational and not a verifier-grade
 * certificate.
 *
 * Marshalling helpers (`Mpq`, `mk_rat_from_mpq`, `mk_array_from_mpqs`,
 * `mk_some` / `mk_none`, `mk_except_*`, `decode_problem`,
 * `byte_array_*`) are shared with `lean_soplex_solve_exact` above.
 */
extern "C" LEAN_EXPORT lean_obj_res lean_soplex_solve_float(
    b_lean_obj_arg /*n*/,
    uint32_t numVars_u, uint32_t numConstraints_u,
    uint8_t simplex,
    uint8_t hasTimeLimit, double timeLimit,
    uint8_t hasIterLimit, uint32_t iterLimit,
    uint8_t verbose, uint32_t randomSeed,
    uint8_t presolve,
    b_lean_obj_arg c_arr, b_lean_obj_arg objOffset,
    b_lean_obj_arg a_rows_arr, b_lean_obj_arg a_cols_arr, b_lean_obj_arg a_vals_arr,
    b_lean_obj_arg rowLoMask, b_lean_obj_arg rowLo,
    b_lean_obj_arg rowHiMask, b_lean_obj_arg rowHi,
    b_lean_obj_arg colLoMask, b_lean_obj_arg colLo,
    b_lean_obj_arg colHiMask, b_lean_obj_arg colHi) noexcept {
  try {
    const DecodedProblem input = decode_problem(
        numVars_u, numConstraints_u, c_arr, a_rows_arr, a_cols_arr, a_vals_arr,
        rowLoMask, rowLo, rowHiMask, rowHi, colLoMask, colLo, colHiMask, colHi);

    SoPlex solver;
    LogCapture logCap(solver, verbose != 0);
    solver.setIntParam(SoPlex::OBJSENSE, SoPlex::OBJSENSE_MINIMIZE);
    solver.setIntParam(SoPlex::SIMPLIFIER,
        presolve ? SoPlex::SIMPLIFIER_INTERNAL : SoPlex::SIMPLIFIER_OFF);
    solver.setIntParam(SoPlex::VERBOSITY,
        verbose ? SoPlex::VERBOSITY_NORMAL : SoPlex::VERBOSITY_ERROR);
    solver.setRandomSeed(randomSeed);
    if (hasTimeLimit) solver.setRealParam(SoPlex::TIMELIMIT, timeLimit);
    if (hasIterLimit) solver.setIntParam(SoPlex::ITERLIMIT, static_cast<int>(iterLimit));
    if (simplex == 0) solver.setIntParam(SoPlex::ALGORITHM, SoPlex::ALGORITHM_PRIMAL);
    if (simplex == 1) solver.setIntParam(SoPlex::ALGORITHM, SoPlex::ALGORITHM_DUAL);

    build_real_lp(solver, input);

    SPxSolver::Status st = solver.optimize();
    uint8_t status = 5; // numericFailure
    lean_object *primal = mk_none();
    lean_object *objective = mk_none();

    switch (st) {
      case SPxSolver::OPTIMAL:
      case SPxSolver::OPTIMAL_UNSCALED_VIOLATIONS: {
        status = 0;
        std::vector<double> x(input.numVars);
        if (!solver.getPrimalReal(x.data(), input.numVars)) {
          throw std::runtime_error("SoPlex failed to return primal solution");
        }
        lean_object *arr = lean_alloc_array(input.numVars, input.numVars);
        lean_array_set_size(arr, input.numVars);
        for (int j = 0; j < input.numVars; ++j) {
          lean_array_cptr(arr)[j] = mk_rat_from_double(x[j]);
        }
        primal = mk_some(arr);
        // As in the exact path, the reported objective includes
        // `objOffset`; the offset is converted to double via GMP.
        Mpq off = decode_rat(objOffset);
        objective = mk_some_float(solver.objValueReal() + mpq_get_d(off.q));
        break;
      }
      case SPxSolver::INFEASIBLE:
        status = 1;
        break;
      case SPxSolver::UNBOUNDED:
        status = 2;
        break;
      case SPxSolver::ABORT_TIME:
        status = 3;
        break;
      case SPxSolver::ABORT_ITER:
        status = 4;
        break;
      case SPxSolver::ABORT_VALUE:
      case SPxSolver::SINGULAR:
      case SPxSolver::NO_RATIOTESTER:
      case SPxSolver::REGULAR:
        status = 5;
        break;
      default:
        status = 7;
        break;
    }

    const std::string log = logCap.str();
    return mk_except_ok(mk_float_solution(status, primal, objective, log));
  } catch (const std::exception &e) {
    return mk_except_error(e.what());
  } catch (...) {
    return mk_except_error("unknown C++ exception");
  }
}

/*
 * FFI-check toy LP solve. Inputs:
 *   c          : FloatArray of length numVars
 *   b          : FloatArray of length numConstraints
 *   a_rows     : ByteArray of int32 of length a_nnz
 *   a_cols     : ByteArray of int32 of length a_nnz
 *   a_vals     : FloatArray of length a_nnz
 *
 * Returns a Lean structure
 *   { primal : FloatArray
 *     ret    : UInt32           -- 0 ok, 1 infeas, 2 unbounded, ~0 error
 *     obj    : Float }
 *
 * `ret = (uint32_t)-1` (i.e. 0xFFFFFFFF) is reserved for any FFI-layer or
 * SoPlex error that didn't terminate normally.
 */
extern "C" LEAN_EXPORT lean_obj_res lean_soplex_ffi_check_solve_ffi(
    b_lean_obj_arg c_arr,
    b_lean_obj_arg b_arr,
    b_lean_obj_arg a_rows,
    b_lean_obj_arg a_cols,
    b_lean_obj_arg a_vals) {
  const int32_t numVars = static_cast<int32_t>(lean_sarray_size(c_arr));
  const int32_t numConstraints = static_cast<int32_t>(lean_sarray_size(b_arr));
  const int32_t a_nnz = static_cast<int32_t>(lean_sarray_size(a_rows) / sizeof(int32_t));

  lean_object *primal_out =
      lean_alloc_sarray(sizeof(double), static_cast<size_t>(numVars),
                        static_cast<size_t>(numVars));
  double *primal_ptr = reinterpret_cast<double *>(lean_sarray_cptr(primal_out));
  double objval = 0.0;

  int rc = lean_soplex_ffi_check_solve(
      numVars, numConstraints,
      float_array_const_ptr(c_arr),
      float_array_const_ptr(b_arr),
      a_nnz,
      byte_array_as_i32(a_rows),
      byte_array_as_i32(a_cols),
      float_array_const_ptr(a_vals),
      primal_ptr,
      &objval);

  /*
   * Layout for `LP.FFICheckResult`:
   *   primal : FloatArray   -- object field
   *   ret    : UInt32       -- scalar field
   *   obj    : Float        -- scalar field
   *
   * Lean places object fields first (declaration order), then scalar
   * fields ordered by descending alignment requirement. With one
   * object slot (`primal`) and two scalars, the scalar region starts
   * at byte offset `sizeof(void*) * 1`. Within the scalar region,
   * `Float` (align 8) precedes `UInt32` (align 4).
   */
  lean_object *result =
      lean_alloc_ctor(0, /*num_objs=*/1, /*scalar_bytes=*/sizeof(double) + sizeof(uint32_t));
  lean_ctor_set(result, 0, primal_out);
  lean_ctor_set_float(result, sizeof(void *), objval);
  lean_ctor_set_uint32(result, sizeof(void *) + sizeof(double), static_cast<uint32_t>(rc));
  return result;
}

// ---------------------------------------------------------------------------
// MPS / LP file I/O.
//
// We use SoPlex's `SPxLPBase<Rational>` (a.k.a. `SPxLPRational`) directly
// rather than going through the top-level `SoPlex::readFile` / `writeFile`
// surface. Two reasons:
//
//  * Explicit format control. `SoPlex::readFile` dispatches on the
//    `READMODE` parameter (REAL vs RATIONAL precision), and
//    `writeFile`/`writeFileLPBase` dispatches LP vs MPS purely by the
//    `.lp` / `.mps` filename suffix. We want the caller's choice of
//    `readMps` / `readLp` / `writeMps` / `writeLp` to be honoured
//    regardless of file extension.
//  * `SPxLPBase<Rational>::readLPF` / `readMPS` / `writeLPF` / `writeMPS`
//    are the natural format-specific entry points and they operate
//    directly on the rational LP we want.
//
// Round-trip note: ranged rows survive MPS round-trip (RANGES section)
// but `writeLPF` expands a ranged row into two non-ranged rows. That's a
// SoPlex format-conversion property, not a bridge property; we don't
// paper over it.
// ---------------------------------------------------------------------------

using SPxLPRat = SPxLPBase<Rational>;

static lean_object *mk_nat_from_int(int n) {
  return lean_unsigned_to_nat(static_cast<unsigned>(n));
}

static lean_object *mk_fin_from_int(int n) {
  return mk_nat_from_int(n);
}

static lean_object *mk_prod2(lean_object *a, lean_object *b) {
  lean_object *p = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(p, 0, a);
  lean_ctor_set(p, 1, b);
  return p;
}

static bool is_neg_infinity(const Rational &r) {
  return r <= Rational(-infinity);
}

static bool is_pos_infinity(const Rational &r) {
  return r >= Rational(infinity);
}

// Pull a SoPlex `Rational` out as a canonical `mpq`. SoPlex's readers
// produce canonical values in practice, but canonicity is load-bearing
// for the Lean `Rat` invariant, so normalise defensively here (file
// I/O is not a hot path).
static Mpq rational_to_mpq(const Rational &r) {
  Mpq q;
  mpq_set(q.q, r.backend().data());
  mpq_canonicalize(q.q);
  return q;
}

// Build an `Option Rat` Lean object; `q` is ignored when absent.
static lean_object *mk_opt_rat(const Mpq &q, bool present) {
  return present ? mk_some(mk_rat_from_mpq(q.q)) : mk_none();
}

// Construct a `LP.Problem` Lean object.
//
// `Problem m n` is a structure with the following fields in
// declaration order; Lean lays out a structure as a single anonymous
// constructor with one argument slot per field. `m` and `n` are
// type-level naturals, erased at runtime:
//
//   c              : Vector Rat n         (runtime: Array Rat)
//   objOffset      : Rat
//   a              : Array (Fin m × Fin n × Rat)
//   rowBounds      : Vector (Option Rat × Option Rat) m   (Array layout)
//   colBounds      : Vector (Option Rat × Option Rat) n   (Array layout)
static lean_object *mk_problem(
    lean_object *c, lean_object *objOffset,
    lean_object *a, lean_object *rowBounds, lean_object *colBounds) {
  lean_object *p = lean_alloc_ctor(0, 5, 0);
  lean_ctor_set(p, 0, c);
  lean_ctor_set(p, 1, objOffset);
  lean_ctor_set(p, 2, a);
  lean_ctor_set(p, 3, rowBounds);
  lean_ctor_set(p, 4, colBounds);
  return p;
}

// Walk an `SPxLPBase<Rational>` (already filled by `readLPF` / `readMPS`)
// into our canonical `Problem` shape.
//
// SoPlex stores LPs internally in maximisation form, but `obj(j)`
// returns the coefficient *as the file wrote it* regardless of sense
// (it negates twice — once because storage is in max form, once because
// the user-facing sense maps it back). Our `Problem` is always
// interpreted as a minimisation problem (sense lives in `Options`), so
// if the file said `Maximize` we must negate every objective coefficient
// and the offset by hand. We do NOT call `lp.changeSense(MINIMIZE)` —
// it would also flip the internal storage and re-apply on the next
// `obj()` call, undoing exactly the change we want.
//
// Exception-safety note: every Rational is copied out to a canonical
// `Mpq` in a first pass (this is where GMP work and std::vector
// allocation, the throw-prone half, happen). Only once all values are
// in hand do we allocate Lean constructors; `mk_rat_from_mpq` is
// allocation-free apart from the Lean objects themselves, so from that
// point on we never throw and partially built Lean objects cannot leak.
static lean_object *problem_from_lp(SPxLPRat &lp) {
  const bool isMax = (lp.spxSense() == SPxLPRat::MAXIMIZE);
  const int nVars = lp.nCols();
  const int nCons = lp.nRows();

  // Phase 1 — pull every Rational out as a canonical Mpq. Throws stay
  // in this phase, before any Lean allocation has happened.
  auto signedRat = [&](const Rational &r) -> Mpq {
    return isMax ? rational_to_mpq(-r) : rational_to_mpq(r);
  };
  // Absent bounds keep a default (zero) Mpq that is never read.
  auto optRat = [&](const Rational &r, bool present) -> Mpq {
    return present ? rational_to_mpq(r) : Mpq();
  };

  Mpq offset = signedRat(lp.objOffset());
  std::vector<Mpq> cVals;
  cVals.reserve(nVars);
  for (int j = 0; j < nVars; ++j) cVals.push_back(signedRat(lp.obj(j)));

  std::vector<std::pair<Mpq, Mpq>> colBounds;
  std::vector<std::pair<bool, bool>> colBoundPresent(nVars);
  colBounds.reserve(nVars);
  for (int j = 0; j < nVars; ++j) {
    const Rational &lo = lp.lower(j);
    const Rational &hi = lp.upper(j);
    colBoundPresent[j] = {!is_neg_infinity(lo), !is_pos_infinity(hi)};
    colBounds.emplace_back(optRat(lo, colBoundPresent[j].first),
                           optRat(hi, colBoundPresent[j].second));
  }

  std::vector<std::pair<Mpq, Mpq>> rowBounds;
  std::vector<std::pair<bool, bool>> rowBoundPresent(nCons);
  rowBounds.reserve(nCons);
  std::vector<std::tuple<int, int, Mpq>> entries;
  for (int i = 0; i < nCons; ++i) {
    const Rational &lhs = lp.lhs(i);
    const Rational &rhs = lp.rhs(i);
    rowBoundPresent[i] = {!is_neg_infinity(lhs), !is_pos_infinity(rhs)};
    rowBounds.emplace_back(optRat(lhs, rowBoundPresent[i].first),
                           optRat(rhs, rowBoundPresent[i].second));
    const SVectorRational &row = lp.rowVector(i);
    for (int k = 0; k < row.size(); ++k) {
      entries.emplace_back(i, row.index(k), rational_to_mpq(row.value(k)));
    }
  }

  // Phase 2 — pure Lean allocations. lean_alloc_* terminate on OOM
  // rather than throwing, and `mk_rat_from_mpq` is non-throwing, so
  // partial-allocation leaks are ruled out.
  lean_object *cArr = lean_alloc_array(static_cast<size_t>(nVars), static_cast<size_t>(nVars));
  for (int j = 0; j < nVars; ++j) {
    lean_array_cptr(cArr)[j] = mk_rat_from_mpq(cVals[j].q);
  }

  lean_object *colB = lean_alloc_array(static_cast<size_t>(nVars), static_cast<size_t>(nVars));
  for (int j = 0; j < nVars; ++j) {
    lean_object *lo = mk_opt_rat(colBounds[j].first, colBoundPresent[j].first);
    lean_object *hi = mk_opt_rat(colBounds[j].second, colBoundPresent[j].second);
    lean_array_cptr(colB)[j] = mk_prod2(lo, hi);
  }

  lean_object *rowB = lean_alloc_array(static_cast<size_t>(nCons), static_cast<size_t>(nCons));
  for (int i = 0; i < nCons; ++i) {
    lean_object *lo = mk_opt_rat(rowBounds[i].first, rowBoundPresent[i].first);
    lean_object *hi = mk_opt_rat(rowBounds[i].second, rowBoundPresent[i].second);
    lean_array_cptr(rowB)[i] = mk_prod2(lo, hi);
  }

  const size_t nnz = entries.size();
  lean_object *aArr = lean_alloc_array(nnz, nnz);
  for (size_t k = 0; k < nnz; ++k) {
    const auto &e = entries[k];
    lean_object *triple = mk_prod2(
        mk_fin_from_int(std::get<0>(e)),
        mk_prod2(mk_fin_from_int(std::get<1>(e)),
                 mk_rat_from_mpq(std::get<2>(e).q)));
    lean_array_cptr(aArr)[k] = triple;
  }

  lean_object *prob = mk_problem(
      cArr, mk_rat_from_mpq(offset.q),
      aArr, rowB, colB);
  // Wrap in `Σ m, Σ n, Problem m n` so `readMpsImpl` / `readLpImpl`
  // can return the dimensions as type-level witnesses.
  //   inner = Sigma.mk nVars prob   (n is the outer Nat in the type
  //                                  `Σ n, Problem m n`)
  //   outer = Sigma.mk nCons inner
  lean_object *inner = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(inner, 0, mk_nat_from_int(nVars));
  lean_ctor_set(inner, 1, prob);
  lean_object *outer = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(outer, 0, mk_nat_from_int(nCons));
  lean_ctor_set(outer, 1, inner);
  return outer;
}

enum class LpFormat { LP, MPS };

static lean_obj_res read_lp_file(b_lean_obj_arg path_obj, LpFormat fmt) noexcept {
  try {
    const char *path = lean_string_cstr(path_obj);
    std::ifstream in(path);
    if (!in) {
      return mk_except_error(std::string("cannot open file for read: ") + path);
    }
    SPxLPRat lp;
    // SoPlex's reader/writer emit warnings via `SPX_MSG_WARNING((*spxout),
    // ...)` which dereferences `spxout`. The default `SPxLPBase` ctor
    // leaves `spxout` as `nullptr` (the `SoPlex` class normally wires
    // its own SPxOut into the LP it owns), so standalone construction
    // segfaults on the first warning. Give it a local sink; verbosity
    // is set to ERROR so nothing actually prints unless the format
    // parser is shouting about a real problem.
    SPxOut spxout;
    spxout.setVerbosity(SPxOut::VERB_ERROR);
    lp.setOutstream(spxout);
    NameSet rowNames;
    NameSet colNames;
    DIdxSet intVars;
    const bool ok = (fmt == LpFormat::MPS)
        ? lp.readMPS(in, &rowNames, &colNames, &intVars)
        : lp.readLPF(in, &rowNames, &colNames, &intVars);
    if (!ok) {
      return mk_except_error(std::string("SoPlex failed to parse ")
                             + (fmt == LpFormat::MPS ? "MPS" : "LP")
                             + " file: " + path);
    }
    // Integer-marked variables would relax silently to continuous,
    // changing the problem's meaning. Reject them; `Problem` has no
    // integrality field, so we cannot faithfully represent them.
    if (intVars.size() > 0) {
      return mk_except_error(
          std::string("integer variables are not supported (file: ") + path + ")");
    }
    return mk_except_ok(problem_from_lp(lp));
  } catch (const std::exception &e) {
    return mk_except_error(e.what());
  } catch (...) {
    return mk_except_error("unknown C++ exception");
  }
}

// Build an `SPxLPBase<Rational>` from the flat Problem marshalling and
// stream it out via `writeMPS` / `writeLPF`. Mirrors `lean_soplex_solve_exact`'s
// LP-construction path (same `addColRational` / `addRowRational` shape,
// same handling of optional bound masks) but does not call `optimize`.
static lean_obj_res write_lp_file(
    b_lean_obj_arg path_obj,
    uint32_t numVars_u, uint32_t numConstraints_u,
    b_lean_obj_arg c_arr, b_lean_obj_arg objOffset_buf,
    b_lean_obj_arg a_rows_arr, b_lean_obj_arg a_cols_arr, b_lean_obj_arg a_vals_arr,
    b_lean_obj_arg rowLoMask, b_lean_obj_arg rowLo,
    b_lean_obj_arg rowHiMask, b_lean_obj_arg rowHi,
    b_lean_obj_arg colLoMask, b_lean_obj_arg colLo,
    b_lean_obj_arg colHiMask, b_lean_obj_arg colHi,
    LpFormat fmt) noexcept {
  try {
    const char *path = lean_string_cstr(path_obj);
    const DecodedProblem input = decode_problem(
        numVars_u, numConstraints_u, c_arr, a_rows_arr, a_cols_arr, a_vals_arr,
        rowLoMask, rowLo, rowHiMask, rowHi, colLoMask, colLo, colHiMask, colHi);

    SPxLPRat lp;
    // See `read_lp_file` for why this `SPxOut` is necessary.
    SPxOut spxout;
    spxout.setVerbosity(SPxOut::VERB_ERROR);
    lp.setOutstream(spxout);
    lp.changeSense(SPxLPRat::MINIMIZE);

    build_rational_lp(lp, input);

    // SoPlex's `writeLPF` and `writeMPS` for `Rational` do not emit
    // `objOffset` (LP format has no syntax for it; MPS *can* express it
    // via an RHS row against the N-row, which SoPlex reads but does not
    // write). Silently dropping a nonzero offset on write would produce
    // a file whose round-trip is mathematically wrong, so reject up
    // front. Callers can rewrite the offset into an explicit auxiliary
    // variable if they really need it on disk.
    Mpq off = decode_rat(objOffset_buf);
    if (mpq_sgn(off.q) != 0) {
      return mk_except_error(
          "nonzero objOffset is not supported by SoPlex's MPS / LP writers; "
          "rewrite as an auxiliary variable before writing");
    }

    std::ofstream out(path);
    if (!out) {
      return mk_except_error(std::string("cannot open file for write: ") + path);
    }
    if (fmt == LpFormat::MPS) {
      lp.writeMPS(out, nullptr, nullptr, nullptr, /*writeZeroObjective=*/true);
    } else {
      lp.writeLPF(out, nullptr, nullptr, nullptr, /*writeZeroObjective=*/true);
    }
    if (!out) {
      return mk_except_error(std::string("error writing file: ") + path);
    }
    return mk_except_ok(lean_box(0));
  } catch (const std::exception &e) {
    return mk_except_error(e.what());
  } catch (...) {
    return mk_except_error("unknown C++ exception");
  }
}

extern "C" LEAN_EXPORT lean_obj_res lean_soplex_read_mps_ffi(b_lean_obj_arg path_obj) noexcept {
  return read_lp_file(path_obj, LpFormat::MPS);
}

extern "C" LEAN_EXPORT lean_obj_res lean_soplex_read_lp_ffi(b_lean_obj_arg path_obj) noexcept {
  return read_lp_file(path_obj, LpFormat::LP);
}

extern "C" LEAN_EXPORT lean_obj_res lean_soplex_write_mps_ffi(
    b_lean_obj_arg path_obj,
    uint32_t numVars_u, uint32_t numConstraints_u,
    b_lean_obj_arg c_arr, b_lean_obj_arg objOffset_buf,
    b_lean_obj_arg a_rows_arr, b_lean_obj_arg a_cols_arr, b_lean_obj_arg a_vals_arr,
    b_lean_obj_arg rowLoMask, b_lean_obj_arg rowLo,
    b_lean_obj_arg rowHiMask, b_lean_obj_arg rowHi,
    b_lean_obj_arg colLoMask, b_lean_obj_arg colLo,
    b_lean_obj_arg colHiMask, b_lean_obj_arg colHi) noexcept {
  return write_lp_file(path_obj, numVars_u, numConstraints_u, c_arr, objOffset_buf,
                       a_rows_arr, a_cols_arr, a_vals_arr,
                       rowLoMask, rowLo, rowHiMask, rowHi,
                       colLoMask, colLo, colHiMask, colHi, LpFormat::MPS);
}

extern "C" LEAN_EXPORT lean_obj_res lean_soplex_write_lp_ffi(
    b_lean_obj_arg path_obj,
    uint32_t numVars_u, uint32_t numConstraints_u,
    b_lean_obj_arg c_arr, b_lean_obj_arg objOffset_buf,
    b_lean_obj_arg a_rows_arr, b_lean_obj_arg a_cols_arr, b_lean_obj_arg a_vals_arr,
    b_lean_obj_arg rowLoMask, b_lean_obj_arg rowLo,
    b_lean_obj_arg rowHiMask, b_lean_obj_arg rowHi,
    b_lean_obj_arg colLoMask, b_lean_obj_arg colLo,
    b_lean_obj_arg colHiMask, b_lean_obj_arg colHi) noexcept {
  return write_lp_file(path_obj, numVars_u, numConstraints_u, c_arr, objOffset_buf,
                       a_rows_arr, a_cols_arr, a_vals_arr,
                       rowLoMask, rowLo, rowHiMask, rowHi,
                       colLoMask, colLo, colHiMask, colHi, LpFormat::LP);
}
