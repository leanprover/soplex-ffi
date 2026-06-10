/-
  FFI surface for `SoplexFFI`.

  This file exposes the SoPlex-backed entry points:

  * `version` — returns SoPlex's compile-time version macro. Exists to
    confirm the FFI is linked and the SoPlex headers used at build time
    match the runtime.

  * `ffiCheckSolve` — solves a small equality-constrained LP in
    floating-point mode. Used as the cross-platform CI build verifier
    (see `Main.lean`); it exercises SoPlex's constructors, parameter
    setting, column / row builders, the solver loop, and result
    extraction in a single call.

  * `solveExact`, `solveFloat`, and MPS / LP file I/O — the direct
    SoPlex-backed solver API.
-/
module

public import LPCore.Validate
public import Lean

@[expose] public section

initialize
  try
    let olean ← Lean.findOLean `SoplexFFI.Basic
    let some leanLibDir := olean.parent
      | throw <| IO.userError s!"could not determine Lean library directory from {olean}"
    let mut dir := leanLibDir
    let mut libDir? := none
    for _ in [0:20] do
      if dir.fileName == some "lean" then
        libDir? := dir.parent
        break
      else
        match dir.parent with
        | some parent => dir := parent
        | none => pure ()
    let some libDir := libDir?
      | throw <| IO.userError s!"could not determine native library directory from {leanLibDir}"
    let libNames :=
      if System.Platform.isOSX then #["libsoplexffi.dylib"]
      else if System.Platform.isWindows then #["soplexffi.dll", "libsoplexffi.dll"]
      else #["libsoplexffi.so"]
    let mut loaded := false
    let mut lastError := ""
    for libName in libNames do
      try
        Lean.loadDynlib (libDir / libName)
        loaded := true
        break
      catch e =>
        lastError := toString e
    unless loaded do
      throw <| IO.userError s!"could not load SoPlex FFI native library from {libDir}: {lastError}"
  catch _ =>
    pure ()

namespace LP

/-- SoPlex's compile-time `SOPLEX_VERSION` macro, e.g. `802` for v8.0.2. -/
@[extern "lean_soplex_version_ffi"]
opaque versionImpl : Unit → UInt32

/-- SoPlex's compile-time `SOPLEX_VERSION` macro, e.g. `802` for v8.0.2. -/
def version : UInt32 := versionImpl ()

/-- Cross-stdlib ABI self-test: throws a `std::runtime_error` in C++,
    catches via the `std::exception` base, verifies `what()` survives.
    Returns `0` on success.

    Exposed as a `Unit → UInt32` function rather than a `UInt32` value
    so the call is deferred to invocation time. A bare `def : UInt32 :=
    exceptionCheckImpl ()` would be evaluated at module load — i.e.
    inside `lean` while it elaborates any module that imports this one,
    which would crash the compiler if the throw/catch ABI is broken,
    rather than surfacing as a clean executable-level failure.

    Run from `Main.lean` on every non-macOS platform as a cross-stdlib
    ABI canary; see the Linux / Windows branches of `soplexRuntimeLinkArgs`
    in `lakefile.lean` for the link-time arrangements this validates. -/
@[extern "lean_soplex_exception_check_ffi"]
opaque exceptionCheck : Unit → UInt32

/-- Result of `ffiCheckSolve`. `ret` follows the FFI layer convention:
    `0` = optimal, `1` = infeasible, `2` = unbounded, anything else is an
    FFI / SoPlex error. -/
structure FFICheckResult where
  /-- Primal solution (length = `numVars`). Meaningful iff `ret = 0`. -/
  primal : FloatArray
  /-- Return code; see structure docstring. -/
  ret    : UInt32
  /-- Objective value; meaningful iff `ret = 0`. -/
  obj    : Float
deriving Inhabited

@[extern "lean_soplex_ffi_check_solve_ffi"]
opaque ffiCheckSolveImpl
    (c : @& FloatArray) (b : @& FloatArray)
    (aRows : @& ByteArray) (aCols : @& ByteArray) (aVals : @& FloatArray) :
    FFICheckResult

/-- Pack a `UInt32` little-endian onto a `ByteArray`. -/
@[inline] def pushU32LE (bs : ByteArray) (u : UInt32) : ByteArray :=
  bs.push (u &&& 0xff).toUInt8
    |>.push ((u >>> 8) &&& 0xff).toUInt8
    |>.push ((u >>> 16) &&& 0xff).toUInt8
    |>.push ((u >>> 24) &&& 0xff).toUInt8

/-- Marshalling helper: flatten sparse indices into the little-endian
    `ByteArray` the bridge expects. Not intended as public API. -/
def packUInt32Array (xs : Array UInt32) : ByteArray := Id.run do
  let mut bs := ByteArray.empty
  for x in xs do bs := pushU32LE bs x
  return bs

/-- Marshalling helper: repack an `Array Float` as the unboxed
    `FloatArray` the `ffiCheckSolve` ABI takes. -/
def floatArrayOfArray (xs : Array Float) : FloatArray := Id.run do
  let mut a := FloatArray.empty
  for x in xs do a := a.push x
  return a

/-! ## Packed-rational wire format.

  Rationals cross the FFI as a flat `ByteArray`, one record per value:

  ```
  u8  sign      1 = negative numerator, 0 otherwise
  u32 numLen    little-endian byte count of |num|
  ..  num       |num| as `numLen` base-256 digits, least significant
                first, no trailing zero byte; `numLen = 0` ⇔ `num = 0`
  u32 denLen    same encoding for the denominator;
                `denLen = 0` ⇔ `den = 1` (the common integer case)
  ..  den
  ```

  The C++ bridge reads each record with `mpz_import`. Like the
  decimal-string encoding it replaces, this format is independent of
  Lean's small-vs-boxed integer representation, but it avoids decimal
  formatting here and GMP decimal parsing on the C++ side. Records are
  canonical by construction (`Rat` carries reducedness proofs), so the
  bridge performs no gcd on input. -/

/-- Byte count of `n`'s minimal little-endian base-256 encoding
    (`0` for `n = 0`). -/
@[inline] def natLEByteLen (n : Nat) : Nat :=
  if n == 0 then 0 else n.log2 / 8 + 1

/-- Append exactly `len` little-endian base-256 digits of `n`,
    extracting 64-bit chunks so the per-byte cost stays low for
    multi-limb numerators. -/
def pushNatLE (bs : ByteArray) (n : Nat) (len : Nat) : ByteArray := Id.run do
  let mut bs := bs
  let mut n := n
  let mut remaining := len
  while remaining > 0 do
    let mut chunk := n.toUInt64
    let take := min remaining 8
    for _ in [0:take] do
      bs := bs.push chunk.toUInt8
      chunk := chunk >>> 8
    n := n >>> 64
    remaining := remaining - take
  return bs

/-- Append a `u32` length prefix followed by `n`'s little-endian
    digits. -/
def pushNatField (bs : ByteArray) (n : Nat) : ByteArray :=
  let len := natLEByteLen n
  pushNatLE (pushU32LE bs (UInt32.ofNat len)) n len

/-- Append one packed-rational record (see the wire-format note
    above). -/
def pushRatLE (bs : ByteArray) (q : Rat) : ByteArray :=
  let bs := bs.push (if q.num < 0 then (1 : UInt8) else 0)
  let bs := pushNatField bs q.num.natAbs
  if q.den == 1 then pushU32LE bs 0 else pushNatField bs q.den

/-- Rough capacity hint per packed rational: sign + two `u32` lengths
    + one 64-bit limb. Buffers grow past this as needed. -/
def ratRecordSizeHint : Nat := 17

/-- Pack a single rational (used for `objOffset`). -/
def packRat (q : Rat) : ByteArray :=
  pushRatLE (ByteArray.emptyWithCapacity ratRecordSizeHint) q

/-- Boundary check: a `Nat` must fit the bridge's 32-bit slots. -/
def checkedU32 (field : String) (n : Nat) :
    Except ProblemError UInt32 :=
  if n ≤ ffiMaxInt then
    pure (UInt32.ofNat n)
  else
    throw (.tooLarge field ffiMaxInt n)

/-- Boundary check: the iteration limit must fit the bridge's 32-bit
    slot (`OptionError`-flavoured variant of `checkedU32`). -/
def checkedIterLimit (n : Nat) : Except OptionError UInt32 :=
  if n ≤ ffiMaxInt then
    pure (UInt32.ofNat n)
  else
    throw (.iterLimitTooLarge ffiMaxInt n)

/-- Translate `Options.iterLimit` into the bridge's `(hasLimit, limit)`
    pair convention (`0` when unlimited). -/
def ffiIterLimit (opts : Options) : Except SolveError UInt32 :=
  match opts.iterLimit with
  | none => pure 0
  | some n => checkedIterLimit n |>.mapError SolveError.invalidOptions

/-- Flat marshalling of a `Problem`'s sparse / bound data into the
    ByteArray form the C++ bridge expects (packed rationals for all
    values, presence masks for optional bounds). Shared between
    `solveExact`, `writeMps`, and `writeLp`. -/
structure ProblemFlat where
  numVars        : UInt32
  numConstraints : UInt32
  c              : ByteArray
  objOffset      : ByteArray
  aRows          : ByteArray
  aCols          : ByteArray
  aVals          : ByteArray
  rowLoMask      : ByteArray
  rowLo          : ByteArray
  rowHiMask      : ByteArray
  rowHi          : ByteArray
  colLoMask      : ByteArray
  colLo          : ByteArray
  colHiMask      : ByteArray
  colHi          : ByteArray

def problemFlatten {m n : Nat} (p : Problem m n) :
    Except ProblemError ProblemFlat := do
  let numVars ← checkedU32 "numVars" n
  let numConstraints ← checkedU32 "numConstraints" m
  -- Sparse entries carry `Fin m` / `Fin n` indices, so once `m` and `n`
  -- pass `checkedU32` every index fits a `UInt32` with no further
  -- per-entry checks.
  let nnz := p.a.size
  let mut aRows := ByteArray.emptyWithCapacity (4 * nnz)
  let mut aCols := ByteArray.emptyWithCapacity (4 * nnz)
  let mut aVals := ByteArray.emptyWithCapacity (ratRecordSizeHint * nnz)
  for (i, j, v) in p.a do
    aRows := pushU32LE aRows (UInt32.ofNat i.val)
    aCols := pushU32LE aCols (UInt32.ofNat j.val)
    aVals := pushRatLE aVals v
  let mut c := ByteArray.emptyWithCapacity (ratRecordSizeHint * n)
  for x in p.c do
    c := pushRatLE c x
  -- Bound buffers always contain one record per index; absent bounds
  -- encode as `0` and are skipped via the mask.
  let mut rowLoMask := ByteArray.emptyWithCapacity m
  let mut rowHiMask := ByteArray.emptyWithCapacity m
  let mut rowLo := ByteArray.emptyWithCapacity (ratRecordSizeHint * m)
  let mut rowHi := ByteArray.emptyWithCapacity (ratRecordSizeHint * m)
  for (lo, hi) in p.rowBounds do
    rowLoMask := rowLoMask.push (if lo.isSome then 1 else 0)
    rowLo := pushRatLE rowLo (lo.getD 0)
    rowHiMask := rowHiMask.push (if hi.isSome then 1 else 0)
    rowHi := pushRatLE rowHi (hi.getD 0)
  let mut colLoMask := ByteArray.emptyWithCapacity n
  let mut colHiMask := ByteArray.emptyWithCapacity n
  let mut colLo := ByteArray.emptyWithCapacity (ratRecordSizeHint * n)
  let mut colHi := ByteArray.emptyWithCapacity (ratRecordSizeHint * n)
  for (lo, hi) in p.colBounds do
    colLoMask := colLoMask.push (if lo.isSome then 1 else 0)
    colLo := pushRatLE colLo (lo.getD 0)
    colHiMask := colHiMask.push (if hi.isSome then 1 else 0)
    colHi := pushRatLE colHi (hi.getD 0)
  pure {
    numVars, numConstraints, c, aRows, aCols, aVals
    objOffset := packRat p.objOffset
    rowLoMask, rowLo, rowHiMask, rowHi
    colLoMask, colLo, colHiMask, colHi }

/-- C++ bridge for exact solve. `{m n : Nat}` are implicit so the
    Lean caller passes them positionally to the FFI as `lean_object*`;
    the C++ side declares matching `b_lean_obj_arg /*m*/, /*n*/` slots
    but ignores their values (they are erased at compile time as far
    as the C++ logic is concerned). Tried phrasing the return as
    `Solution numConstraints.toNat numVars.toNat` to drop the
    implicits; the call site then needs a `UInt32.ofNat n |>.toNat = n`
    coercion proof that adds more friction than the saved arg-slots
    are worth. -/
@[extern "lean_soplex_solve_exact"]
opaque solveExactFlat {m n : Nat}
    (numVars numConstraints : UInt32)
    (simplex : UInt8)
    (hasTimeLimit : Bool) (timeLimit : Float)
    (hasIterLimit : Bool) (iterLimit : UInt32)
    (verbose : Bool) (randomSeed : UInt32)
    (precisionBoost presolve : Bool)
    (c : @& ByteArray) (objOffset : @& ByteArray)
    (aRows aCols aVals : @& ByteArray)
    (rowLoMask rowLo : @& ByteArray)
    (rowHiMask rowHi : @& ByteArray)
    (colLoMask colLo : @& ByteArray)
    (colHiMask colHi : @& ByteArray) :
    Except String (Solution m n)

def solveErrorFromBridge (e : String) : SolveError :=
  .bridge e

def mapObjectiveForSense {m n : Nat} (sense : ObjSense)
    (s : Solution m n) : Solution m n :=
  match sense with
  | .minimize => s
  | .maximize => { s with objective := s.objective.map Neg.neg }

def simplexTag : Simplex → UInt8
  | .primal => 0
  | .dual => 1
  | .auto => 2

/-- Exact rational solve through SoPlex. The bridge receives rationals
    in the packed numerator/denominator wire format described above,
    deliberately avoiding any dependence on Lean's small-vs-boxed integer
    representation across the C++ ABI. For `.maximize`, the LP sent to
    SoPlex is the verifier's minimization canonicalization; the reported
    objective is flipped back into the caller's original sense. -/
opaque solveExact {m n : Nat} (opts : Options) (p : Problem m n) :
    Except SolveError (Solution m n) := do
  let opts ← validateOptions opts |>.mapError SolveError.invalidOptions
  let iterLimit ← ffiIterLimit opts
  let p ← validate p |>.mapError SolveError.invalidProblem
  let f ← problemFlatten (canonicalize opts.sense p) |>.mapError SolveError.invalidProblem
  -- The LP crossing the FFI is always the minimization canonicalization
  -- (`canonicalize` above); the bridge has no objective-sense parameter.
  let sol ← solveExactFlat
    f.numVars f.numConstraints
    (simplexTag opts.simplex)
    opts.timeLimit.isSome (opts.timeLimit.getD 0.0)
    opts.iterLimit.isSome iterLimit
    opts.verbose opts.randomSeed opts.precisionBoost opts.presolve
    f.c f.objOffset
    f.aRows f.aCols f.aVals
    f.rowLoMask f.rowLo
    f.rowHiMask f.rowHi
    f.colLoMask f.colLo
    f.colHiMask f.colHi
    |>.mapError solveErrorFromBridge
  pure (mapObjectiveForSense opts.sense sol)

@[extern "lean_soplex_solve_float"]
opaque solveFloatFlat {n : Nat}
    (numVars numConstraints : UInt32)
    (simplex : UInt8)
    (hasTimeLimit : Bool) (timeLimit : Float)
    (hasIterLimit : Bool) (iterLimit : UInt32)
    (verbose : Bool) (randomSeed : UInt32)
    (presolve : Bool)
    (c : @& ByteArray) (objOffset : @& ByteArray)
    (aRows aCols aVals : @& ByteArray)
    (rowLoMask rowLo : @& ByteArray)
    (rowHiMask rowHi : @& ByteArray)
    (colLoMask colLo : @& ByteArray)
    (colHiMask colHi : @& ByteArray) :
    Except String (FloatSolution n)

def mapFloatObjectiveForSense {n : Nat} (sense : ObjSense)
    (s : FloatSolution n) : FloatSolution n :=
  match sense with
  | .minimize => s
  | .maximize => { s with objective := s.objective.map Neg.neg }

/-- Floating-point solve through SoPlex. Mirrors `solveExact`'s ABI
    (packed-rational `Rat` marshalling) but builds the LP via
    `addColReal` / `addRowReal` and runs SoPlex in its default mode.

    The returned `primalAsRat` entries are exact rationals representing
    the IEEE-754 doubles SoPlex computed (via `mpq_set_d`), **not**
    decimal rationals and **not** verifier-grade certificates: e.g.
    `0.1` round-trips as `7205759403792794 / 2^56`. The distinct
    `FloatSolution` return type — separate from `Solution` — makes
    feeding these into the certificate checker hard to do by accident. -/
opaque solveFloat {m n : Nat} (opts : Options) (p : Problem m n) :
    Except SolveError (FloatSolution n) := do
  let opts ← validateOptions opts |>.mapError SolveError.invalidOptions
  let iterLimit ← ffiIterLimit opts
  let p ← validate p |>.mapError SolveError.invalidProblem
  let f ← problemFlatten (canonicalize opts.sense p) |>.mapError SolveError.invalidProblem
  let sol ← solveFloatFlat
    f.numVars f.numConstraints
    (simplexTag opts.simplex)
    opts.timeLimit.isSome (opts.timeLimit.getD 0.0)
    opts.iterLimit.isSome iterLimit
    opts.verbose opts.randomSeed opts.presolve
    f.c f.objOffset
    f.aRows f.aCols f.aVals
    f.rowLoMask f.rowLo
    f.rowHiMask f.rowHi
    f.colLoMask f.colLo
    f.colHiMask f.colHi
    |>.mapError solveErrorFromBridge
  pure (mapFloatObjectiveForSense opts.sense sol)

/-! ## MPS / LP file I/O.

  Four `opaque` entry points wired to SoPlex's `SPxLPBase<Rational>`
  format-specific readers / writers (see `soplex-ffi/ffi/lean_soplex_bridge.cpp`):

  * Bridge-level failures (file not found, parse error, write error)
    become `SolveError.parseError` carrying the path; the bridge
    captures the error message.
  * Reads return an *unvalidated* `Problem` — sparse entries appear in
    the order SoPlex emits them. Callers that want the normalised form
    should pass the result through `validate`.
  * Writes pre-normalise via `validate`. A malformed `Problem` surfaces
    as `SolveError.invalidProblem`.

  Round-trip equivalence under `validate` is *structural-after-validate*,
  not permutation-invariant: see `LPTest/FileIo.lean` in the
  `leanprover/lp` meta-package. Format-specific
  caveats — notably `writeLp` expanding ranged rows into two non-ranged
  rows — are SoPlex format properties, not bridge artefacts. -/

@[extern "lean_soplex_read_mps_ffi"]
opaque readMpsImpl (path : @& String) :
    Except String (Σ m n, Problem m n)

@[extern "lean_soplex_read_lp_ffi"]
opaque readLpImpl (path : @& String) :
    Except String (Σ m n, Problem m n)

@[extern "lean_soplex_write_mps_ffi"]
opaque writeMpsFlat
    (path : @& String)
    (numVars numConstraints : UInt32)
    (c : @& ByteArray) (objOffset : @& ByteArray)
    (aRows aCols aVals : @& ByteArray)
    (rowLoMask rowLo : @& ByteArray)
    (rowHiMask rowHi : @& ByteArray)
    (colLoMask colLo : @& ByteArray)
    (colHiMask colHi : @& ByteArray) :
    Except String Unit

@[extern "lean_soplex_write_lp_ffi"]
opaque writeLpFlat
    (path : @& String)
    (numVars numConstraints : UInt32)
    (c : @& ByteArray) (objOffset : @& ByteArray)
    (aRows aCols aVals : @& ByteArray)
    (rowLoMask rowLo : @& ByteArray)
    (rowHiMask rowHi : @& ByteArray)
    (colLoMask colLo : @& ByteArray)
    (colHiMask colHi : @& ByteArray) :
    Except String Unit

/-- Parse a `Problem` from an MPS file via SoPlex's rational reader.
    The dimensions are determined at runtime from the file, so the
    result is wrapped in a sigma `Σ m n, Problem m n`. -/
opaque readMps (path : System.FilePath) :
    Except SolveError (Σ m n, Problem m n) :=
  (readMpsImpl path.toString).mapError fun e => .parseError path.toString e

/-- Write a `Problem` to an MPS file via SoPlex's rational writer.
    The `Problem` is `validate`d before serialisation. -/
opaque writeMps {m n : Nat} (path : System.FilePath) (p : Problem m n) :
    Except SolveError Unit := do
  let p ← validate p |>.mapError SolveError.invalidProblem
  let s := path.toString
  let f ← problemFlatten p |>.mapError SolveError.invalidProblem
  writeMpsFlat s f.numVars f.numConstraints f.c f.objOffset
    f.aRows f.aCols f.aVals
    f.rowLoMask f.rowLo f.rowHiMask f.rowHi
    f.colLoMask f.colLo f.colHiMask f.colHi
    |>.mapError fun e => .parseError s e

/-- Parse a `Problem` from an LP-format file via SoPlex's rational reader.
    See `readMps` for the sigma-wrapped return type. -/
opaque readLp (path : System.FilePath) :
    Except SolveError (Σ m n, Problem m n) :=
  (readLpImpl path.toString).mapError fun e => .parseError path.toString e

/-- Write a `Problem` to an LP-format file via SoPlex's rational writer.
    The `Problem` is `validate`d before serialisation. Note that SoPlex's
    LP-format writer expands a ranged row (both `lo` and `hi` finite,
    `lo ≠ hi`) into two separate non-ranged rows. Use MPS for ranged
    rows if you need structural round-trip. -/
opaque writeLp {m n : Nat} (path : System.FilePath) (p : Problem m n) :
    Except SolveError Unit := do
  let p ← validate p |>.mapError SolveError.invalidProblem
  let s := path.toString
  let f ← problemFlatten p |>.mapError SolveError.invalidProblem
  writeLpFlat s f.numVars f.numConstraints f.c f.objOffset
    f.aRows f.aCols f.aVals
    f.rowLoMask f.rowLo f.rowHiMask f.rowHi
    f.colLoMask f.colLo f.colHiMask f.colHi
    |>.mapError fun e => .parseError s e

/--
Solve the equality-constrained LP

```
    minimise   c·x
    subject to A x = b
               0 ≤ x
```

with `c` length `numVars`, `b` length `numConstraints`, and `A` given in
sparse `(row, col, value)` form. Floating-point precision; **not** an
exact-mode certificate-producing solve. Used to verify the FFI / link /
runtime pipeline on every supported platform.
-/
def ffiCheckSolve
    (c : Array Float) (b : Array Float)
    (rows : Array UInt32) (cols : Array UInt32) (vals : Array Float) :
    FFICheckResult :=
  ffiCheckSolveImpl
    (floatArrayOfArray c) (floatArrayOfArray b)
    (packUInt32Array rows) (packUInt32Array cols)
    (floatArrayOfArray vals)

end LP
