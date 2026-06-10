/-
  Marshalling benchmark for `SoplexFFI`.

  Generates a sparse LP with rational data, then times

  * `problemFlatten` alone — the Lean-side marshalling cost, and
  * `solveExact` / `solveFloat` end-to-end — flatten + bridge decode +
    SoPlex solve + result extraction.

  Run with `lake exe bench [n]` (default `n = 2000` variables /
  constraints, 5 entries per row). Used for the before/after numbers
  on marshalling changes; not part of `lake test`.
-/

import SoplexFFI

open LP

/-- Tridiagonal-ish sparse LP with non-integer rationals everywhere:
    minimize `Σ c_j x_j` subject to ranged rows and boxed columns.
    With `scale := 1` the data is small (1–6 digit) rationals; larger
    `scale` (e.g. `10^45`) produces certificate-sized multi-limb
    numerators and denominators. -/
def mkBench (n : Nat) (hn : 0 < n) (scale : Int) : Problem n n :=
  let q : Nat → Nat → Rat := fun a b => ((scale + a : Int) : Rat) / ((scale * 3 + b : Int) : Rat)
  { c := Vector.ofFn fun j => q (j.val + 1) (2 * j.val + 3)
    a := (Array.ofFn fun i : Fin n =>
            Array.ofFn fun d : Fin 5 =>
              let j : Fin n := ⟨(i.val + d.val * 7) % n, Nat.mod_lt _ hn⟩
              (i, j, q (i.val + d.val + 1) (j.val + 2))).flatten
    rowBounds := Vector.ofFn fun i =>
      (some (-(q (i.val + 5) (i.val + 2))), some (q (i.val + 5) (i.val + 2)))
    colBounds := Vector.ofFn fun j =>
      (some (-(q (j.val + 9) (j.val + 4))), some (q (j.val + 9) (j.val + 4))) }

def timeMs (act : IO α) : IO (α × Float) := do
  let t0 ← IO.monoNanosNow
  let r ← act
  let t1 ← IO.monoNanosNow
  return (r, (t1 - t0).toFloat / 1e6)

def main (args : List String) : IO UInt32 := do
  let n := (args.head? >>= (·.toNat?)).getD 2000
  let scaleDigits := ((args.drop 1).head? >>= (·.toNat?)).getD 0
  let fullSolves := scaleDigits == 0
  if h : 0 < n then
    let p := mkBench n h ((10:Int)^scaleDigits)
    IO.println s!"n = {n}, nnz = {p.a.size}, rational scale = 10^{scaleDigits}"
    -- `IO.lazyPure` keeps the compiler from floating the pure
    -- computations out of the timed window.
    let (flatRes, tFlat) ← timeMs <| IO.lazyPure fun _ => problemFlatten p
    match flatRes with
    | .ok f => IO.println s!"problemFlatten: {tFlat}ms (marshalled values size {f.aVals.size + f.c.size})"
    | .error e => throw <| IO.userError s!"flatten failed: {repr e}"
    if fullSolves then
      let (exactRes, tExact) ← timeMs <| IO.lazyPure fun _ =>
        solveExact { ({} : Options) with presolve := false } p
      match exactRes with
      | .ok sol => IO.println s!"solveExact: {tExact}ms (status {repr sol.status})"
      | .error e => throw <| IO.userError s!"solveExact failed: {repr e}"
      let (floatRes, tFloat) ← timeMs <| IO.lazyPure fun _ =>
        solveFloat { ({} : Options) with presolve := false } p
      match floatRes with
      | .ok sol => IO.println s!"solveFloat: {tFloat}ms (status {repr sol.status})"
      | .error e => throw <| IO.userError s!"solveFloat failed: {repr e}"
    -- `iterLimit := 1` stops SoPlex almost immediately, so this isolates
    -- input marshalling (flatten + bridge decode + LP build) from the
    -- simplex itself.
    for _ in [0:3] do
      let (iterRes, tIter) ← timeMs <| IO.lazyPure fun _ =>
        solveExact { ({} : Options) with presolve := false, iterLimit := some 1 } p
      match iterRes with
      | .ok sol => IO.println s!"solveExact (iterLimit 1): {tIter}ms (status {repr sol.status})"
      | .error e => throw <| IO.userError s!"solveExact iter-limited failed: {repr e}"
    return 0
  else
    IO.eprintln "n must be positive"
    return 1
