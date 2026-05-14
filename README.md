# SoplexFFI

Lean 4 FFI bindings for [SoPlex](https://soplex.zib.de/), the linear
programming solver from the SCIP optimization suite.

This repository contains the direct binding only: the vendored SoPlex
build, the C++ bridge, Lean extern wrappers, marshalling, direct solve
APIs, and MPS / LP file I/O. The verified Lean layer lives in
[`kim-em/soplex`](https://github.com/kim-em/soplex).

## Build

System dependencies:

| Platform | Packages |
|----------|----------|
| Linux    | `cmake ninja-build libgmp-dev libgmpxx4ldbl libboost-dev` |
| macOS    | `brew install gmp boost cmake ninja` |
| Windows  | MSYS2 `mingw-w64-x86_64-{gcc,cmake,ninja,make,gmp,boost}` |

```bash
git clone --recurse-submodules https://github.com/kim-em/soplex-ffi
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
