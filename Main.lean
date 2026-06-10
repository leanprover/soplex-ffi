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

  -- Multi-limb marshalling check: numerators / denominators well past
  -- 64 bits in both directions across the packed-rational encoding.
  -- Minimizing `big · x` over `x ∈ [bigNeg, 1]` puts the optimum at the
  -- multi-limb lower bound, so both the primal and the objective must
  -- survive the round trip exactly.
  let big : Rat := ((10:Int)^40 + 7 : Int) / ((10:Int)^39 + 3 : Int)
  let bigNeg : Rat := -(((2:Int)^200 + 9 : Int) / ((3:Int)^120 : Int))
  let wide : Problem 1 1 :=
    { c := #v[big]
      objOffset := bigNeg
      a := #[(⟨0, by decide⟩, ⟨0, by decide⟩, 1)]
      rowBounds := #v[(some bigNeg, some 1)]
      colBounds := #v[(some bigNeg, some 1)] }
  match solveExact { ({} : Options) with presolve := false } wide with
  | .error e =>
      IO.eprintln s!"multi-limb exact solve failed: {repr e}"
      return 7
  | .ok sol =>
      -- The reported objective is `c·x + objOffset`, with the offset
      -- added exactly; here both factors and the offset are multi-limb.
      let expected := big * bigNeg + bigNeg
      if sol.status != .optimal || sol.objective != some expected ||
          (sol.certificate.primal.map (·.toArray)) != some #[bigNeg] then
        IO.eprintln s!"expected exact multi-limb optimum, got {repr sol}"
        return 8

  -- Nonzero `objOffset` under `.maximize`: canonicalization negates
  -- both `c` and the offset, so this pins the sign bookkeeping across
  -- the bridge and the sense flip. Maximize `x + 7` over `x ≤ 5`.
  let offMax : Problem 1 1 :=
    { c := #v[1]
      objOffset := 7
      a := #[(⟨0, by decide⟩, ⟨0, by decide⟩, 1)]
      rowBounds := #v[(none, some 5)]
      colBounds := #v[(none, none)] }
  match solveExact { ({} : Options) with sense := .maximize, presolve := false } offMax with
  | .error e =>
      IO.eprintln s!"maximize-with-offset solve failed: {repr e}"
      return 16
  | .ok sol =>
      if sol.status != .optimal || sol.objective != some 12 ||
          (sol.certificate.primal.map (·.toArray)) != some #[5] then
        IO.eprintln s!"expected objective 12 (= 5 + 7) under maximize, got {repr sol}"
        return 17

  -- Float path with nonzero `objOffset`: minimize `x + 5/2` over `x ≥ 3`.
  let offFloat : Problem 1 1 :=
    { c := #v[1]
      objOffset := 5/2
      a := #[(⟨0, by decide⟩, ⟨0, by decide⟩, 1)]
      rowBounds := #v[(some 3, none)]
      colBounds := #v[(none, none)] }
  match solveFloat { ({} : Options) with presolve := false } offFloat with
  | .error e =>
      IO.eprintln s!"float solve with offset failed: {repr e}"
      return 18
  | .ok sol =>
      match sol.status, sol.objective with
      | .optimal, some obj =>
          if (obj - 5.5).abs > 1e-9 then
            IO.eprintln s!"expected float objective close to 5.5, got {obj}"
            return 19
      | _, _ =>
          IO.eprintln s!"expected optimal float solve with objective, got {repr sol}"
          return 20

  -- Infeasible: `x ≥ 1` and `x ≤ 0` as two rows; the Farkas dual must
  -- come back through the mask-aware certificate extraction.
  let infeas : Problem 2 1 :=
    { c := #v[1]
      a := #[(⟨0, by decide⟩, ⟨0, by decide⟩, 1), (⟨1, by decide⟩, ⟨0, by decide⟩, 1)]
      rowBounds := #v[(some 1, none), (none, some 0)]
      colBounds := #v[(none, none)] }
  match solveExact { ({} : Options) with presolve := false } infeas with
  | .error e =>
      IO.eprintln s!"infeasible solve failed: {repr e}"
      return 9
  | .ok sol =>
      if sol.status != .infeasible || sol.certificate.dual.isNone then
        IO.eprintln s!"expected infeasible with Farkas dual, got {repr sol}"
        return 10

  -- Unbounded: minimize `-x` with `x ≥ 0` free above; base point + ray.
  let unb : Problem 1 1 :=
    { c := #v[-1]
      a := #[(⟨0, by decide⟩, ⟨0, by decide⟩, 1)]
      rowBounds := #v[(some 0, none)]
      colBounds := #v[(some 0, none)] }
  match solveExact { ({} : Options) with presolve := false } unb with
  | .error e =>
      IO.eprintln s!"unbounded solve failed: {repr e}"
      return 11
  | .ok sol =>
      if sol.status != .unbounded || sol.certificate.ray.isNone then
        IO.eprintln s!"expected unbounded with ray, got {repr sol}"
        return 12

  -- MPS write / read round trip, multi-limb values included.
  let rt : Problem 1 2 :=
    { c := #v[big, -bigNeg]
      a := #[(⟨0, by decide⟩, ⟨0, by decide⟩, big), (⟨0, by decide⟩, ⟨1, by decide⟩, bigNeg)]
      rowBounds := #v[(some (-big), some big)]
      colBounds := #v[(some 0, some 1), (some bigNeg, none)] }
  let mpsPath := System.FilePath.mk "round-trip-check.mps"
  match writeMps mpsPath rt with
  | .error e =>
      IO.eprintln s!"writeMps failed: {repr e}"
      return 13
  | .ok () => pure ()
  match readMps mpsPath with
  | .error e =>
      IO.eprintln s!"readMps failed: {repr e}"
      return 14
  | .ok ⟨mr, nr, pr⟩ =>
      IO.FS.removeFile mpsPath
      if mr != 1 || nr != 2 || pr.c.toArray != #[big, -bigNeg] ||
          pr.rowBounds.toArray != #[(some (-big), some big)] ||
          pr.colBounds.toArray != #[(some 0, some 1), (some bigNeg, none)] ||
          (pr.a.map (·.2.2)) != #[big, bigNeg] then
        IO.eprintln s!"MPS round trip mismatch, got {repr pr}"
        return 15
  return 0
