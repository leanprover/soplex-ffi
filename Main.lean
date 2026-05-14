/-
  End-to-end FFI runtime check for `SoplexFFI`.
-/

import SoplexFFI

open Soplex

def main : IO UInt32 := do
  IO.println s!"SoPlex version: {Soplex.version}"

  unless System.Platform.isOSX do
    let exnRc := Soplex.exceptionCheck ()
    IO.println s!"exception check = {exnRc}"
    if exnRc != 0 then
      IO.eprintln s!"std::exception throw/catch broken (rc={exnRc}); cross-stdlib ABI mismatch"
      return 3

  let result := ffiCheckSolve
    (c    := #[1.0, 1.0])
    (b    := #[1.0])
    (rows := #[0, 0])
    (cols := #[0, 1])
    (vals := #[1.0, 1.0])

  IO.println s!"ret    = {result.ret}"
  IO.println s!"obj    = {result.obj}"
  IO.println s!"primal = {result.primal.toList}"

  if result.ret != 0 then
    IO.eprintln s!"expected optimal (ret=0), got ret={result.ret}"
    return 1
  if (result.obj - 1.0).abs > 1e-9 then
    IO.eprintln s!"expected objective close to 1.0, got {result.obj}"
    return 2
  return 0
