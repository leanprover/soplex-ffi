/-
  Pure-Lean validators for `Problem` and `Options`.

  Source of truth lives in `LPCore.Validate` (`leanprover/lp-core`).
  This module re-exports `validate`, `validateOptions`, `validateRaw`,
  and `Problem.ofRaw` so any consumer still writing `import
  SoplexFFI.Validate` keeps working.

  Pure-Lean only — no dependency on the native FFI.
-/
module

public import LPCore.Validate

@[expose] public section
