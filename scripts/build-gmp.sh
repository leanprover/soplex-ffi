#!/usr/bin/env bash
# Build a PIC, statically-linkable GMP into the package's vendor tree.
#
# The Linux toolchain that ships with `leanprover/lean4` includes its own
# `libgmp.a` but on x86_64 some of its objects (e.g. `memory.o`, `assert.o`)
# are not compiled with `-fPIC`, so they cannot be linked into a shared
# library (`ld.lld: relocation R_X86_64_PC32 cannot be used against symbol
# 'stderr'`). The bridge needs a known-PIC `libgmp.a` because:
#
#   * The bridge calls `__gmpz_*` and `__gmpq_*` symbols directly. When
#     `libsoplexffi.so` is dlopen'd into `lean`, those symbols must NOT
#     interpose with Lean's bundled GMP (see soplex-ffi#18); resolving
#     them statically against a vendored `libgmp.a` and hiding them with
#     `-Wl,--exclude-libs` is the only way to guarantee no interposition.
#
#   * No system-supplied `libgmp.a` we can rely on (Ubuntu / Debian /
#     RHEL / Alpine) is uniformly PIC; the toolchain's own copy is mixed.
#
# This script downloads the canonical GNU GMP tarball, verifies its
# checksum, and configures with `--with-pic --disable-shared
# --enable-static`. The resulting archive lives at
# `build-gmp/.libs/libgmp.a` under the package directory; the lakefile
# names it explicitly in `moreLinkArgs`.
#
# Idempotent: writes `build-gmp/.ready` on success and short-circuits on
# subsequent runs. The Lake `JobM` step ignores the timestamp of this
# marker for trace purposes; the target's own `addPureTrace gmpVersion`
# is what forces a rebuild when we bump the GMP pin.

set -euo pipefail

GMP_VERSION="${GMP_VERSION:-6.3.0}"
# SHA-256 of gmp-6.3.0.tar.xz as published at https://ftp.gnu.org/gnu/gmp/.
GMP_SHA256="${GMP_SHA256:-a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898}"
GMP_URL_PRIMARY="${GMP_URL_PRIMARY:-https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VERSION}.tar.xz}"
GMP_URL_MIRROR="${GMP_URL_MIRROR:-https://gmplib.org/download/gmp/gmp-${GMP_VERSION}.tar.xz}"

if [ $# -ne 1 ]; then
  echo "usage: $0 <package-dir>" >&2
  exit 64
fi

PKG_DIR="$1"
BUILD_DIR="${PKG_DIR}/build-gmp"
SRC_DIR="${BUILD_DIR}/gmp-${GMP_VERSION}"
TARBALL="${BUILD_DIR}/gmp-${GMP_VERSION}.tar.xz"
READY="${BUILD_DIR}/.ready"
# Final libgmp.a path the lakefile names in `moreLinkArgs` — staged at a
# fixed location independent of the GMP version, so bumping
# `GMP_VERSION` doesn't require touching the lakefile's link block.
STAGED_LIB="${BUILD_DIR}/libgmp.a"
# Where `make` actually deposits the static archive after libtool linking.
BUILT_LIB="${SRC_DIR}/.libs/libgmp.a"

mkdir -p "${BUILD_DIR}"

if [ -f "${READY}" ] && [ -f "${STAGED_LIB}" ]; then
  exit 0
fi

# Fetch the tarball if missing or with a mismatched checksum.
need_download=1
if [ -f "${TARBALL}" ]; then
  if sha256sum --check --status <<< "${GMP_SHA256}  ${TARBALL}"; then
    need_download=0
  else
    rm -f "${TARBALL}"
  fi
fi

if [ "${need_download}" = "1" ]; then
  if ! curl --fail --silent --show-error --location --output "${TARBALL}" "${GMP_URL_PRIMARY}"; then
    curl --fail --silent --show-error --location --output "${TARBALL}" "${GMP_URL_MIRROR}"
  fi
  sha256sum --check --status <<< "${GMP_SHA256}  ${TARBALL}"
fi

# Re-extract on any rebuild so the source tree is clean.
rm -rf "${SRC_DIR}"
tar -xf "${TARBALL}" -C "${BUILD_DIR}"

cd "${SRC_DIR}"

# `--with-pic --disable-shared --enable-static` guarantees every object
# in the resulting `libgmp.a` is position-independent. `--disable-assembly`
# is intentionally omitted: GMP's hand-tuned asm is the whole point of
# vendoring this, and it stays PIC on every architecture we target.
./configure \
  --quiet \
  --with-pic \
  --disable-shared \
  --enable-static \
  --disable-cxx \
  --enable-fat \
  CFLAGS="-O2 -fPIC"

if command -v nproc >/dev/null 2>&1; then
  JOBS="$(nproc)"
else
  JOBS=4
fi

make --silent -j"${JOBS}"

if [ ! -f "${BUILT_LIB}" ]; then
  echo "build-gmp: expected ${BUILT_LIB} after make, but it is missing" >&2
  exit 1
fi

cp -f "${BUILT_LIB}" "${STAGED_LIB}"
touch "${READY}"
