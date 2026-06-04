/-
  End-to-end FFI runtime check for `SoplexFFI`.
-/

import SoplexFFI

open LP

def main : IO UInt32 := do
  IO.println s!"SoPlex version: {LP.version}"

  unless System.Platform.isOSX do
    let exnRc := LP.exceptionCheck ()
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

  let scaled : Problem 1 1 :=
    { c := #v[-1]
      objOffset := 2
      a := #[(⟨0, by decide⟩, ⟨0, by decide⟩, 3)]
      rowBounds := #v[(none, some 6)]
      colBounds := #v[(none, none)] }
  match solveExact { ({} : Options) with presolve := false } scaled with
  | .error e =>
      IO.eprintln s!"scaled exact solve failed: {repr e}"
      return 4
  | .ok sol =>
      match sol.status, sol.certificate.dual with
      | .optimal, some d =>
          if d.rowUpper.toArray != #[(1 / 3 : Rat)] || d.colUpper.toArray != #[0] then
            IO.eprintln s!"expected exact scaled-row dual, got {repr sol.certificate}"
            return 5
      | _, _ =>
          IO.eprintln s!"expected optimal scaled-row certificate, got {repr sol}"
          return 6
  return 0
