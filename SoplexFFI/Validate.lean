/-
  Pure-Lean validators for `Problem` and `Options`.

  Source of truth lives in `LPCore.Validate` (`kim-em/lp-core`).
  This module re-exports `validate`, `validateOptions`, `validateRaw`,
  and `Problem.ofRaw` so any consumer still writing `import
  SoplexFFI.Validate` keeps working.

  Pure-Lean only — no dependency on the native FFI.
-/

import LPCore.Validate
