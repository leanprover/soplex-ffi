# SoplexFFI

[![Lean](https://img.shields.io/badge/Lean-4.31.0--rc1-blue.svg)](./lean-toolchain)
[![License](https://img.shields.io/github/license/leanprover/soplex-ffi.svg)](./LICENSE)

> **New here? Start at [`leanprover/lp`](https://github.com/leanprover/lp)** — the entry
> point for the `lp` / `maximize` tactics and the verified LP solver. This repository is one
> package of that family: the raw SoPlex FFI bindings.

Lean 4 FFI bindings for [SoPlex](https://soplex.zib.de/), the linear
programming solver from the SCIP optimization suite.

This repository contains the direct binding only: the vendored SoPlex
build, the C++ bridge, Lean extern wrappers, marshalling, direct solve
APIs, and MPS / LP file I/O. The verified Lean layer lives in
[`leanprover/lp`](https://github.com/leanprover/lp).

## Build

System dependencies:

| Platform | Packages |
|----------|----------|
| Linux    | `build-essential cmake libgmp-dev libgmpxx4ldbl libboost-dev` |
| macOS    | `brew install gmp boost cmake` (plus Xcode Command Line Tools) |
| Windows  | MSYS2 `mingw-w64-x86_64-{gcc,cmake,ninja,make,gmp,boost}` |

```bash
git clone --recurse-submodules https://github.com/leanprover/soplex-ffi
cd soplex-ffi
lake exe ffi-check
```

If you cloned without submodules, Lake attempts to initialize the
vendored SoPlex submodule automatically. If that fails, run
`git submodule update --init --recursive`.

## Layout

```
SoplexFFI.lean          # direct FFI package entry point
SoplexFFI/              # thin Lean API, types, and validation
ffi/                    # C++ bridge and C ABI entry points
vendor/soplex           # vendor submodule (scipopt/soplex, tag v8.0.2)
lakefile.lean           # Lake package and extern_lib build
```

## Licence

`SoplexFFI` is licenced under the [Apache License 2.0](./LICENSE),
matching SoPlex itself. The compiled binary's GMP runtime dependency
(LGPL) is linked dynamically by default. SoPlex itself is linked into
the Lean shared library from the vendored static archive.
