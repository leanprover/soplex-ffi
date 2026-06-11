/-
  In-elaborator FFI smoke check. The `#eval` below drives `solveExact`
  through the bridge inside the running `lean` process, matching how
  downstream callers (e.g. `lp-tactic`'s `by lp`) invoke the FFI at
  elaboration time. The executable-only `ffi-check` driver in `Main.lean`
  links the bridge statically and so does not exercise the dlopen-into-
  `lean` path, where GMP symbol interposition against Lean's bundled GMP
  used to crash this binding; this module pins the no-crash property
  upstream.
-/
module

public import SoplexFFI

@[expose] public section

open LP

private def smoke : Problem 1 1 :=
  { c := #v[1]
    a := #[(⟨0, by decide⟩, ⟨0, by decide⟩, 1)]
    rowBounds := #v[(some 0, none)]
    colBounds := #v[(some 0, none)] }

private def runSmoke : IO Unit := do
  match solveExact { presolve := false : Options } smoke with
  | .ok sol =>
    unless sol.status = .optimal do
      throw <| IO.userError s!"in-elaborator solveExact: expected optimal, got {repr sol.status}"
  | .error e =>
    throw <| IO.userError s!"in-elaborator solveExact failed: {repr e}"

#eval runSmoke
