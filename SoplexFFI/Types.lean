/-
  Data types shared by the certificate checker and the FFI binding.

  Source of truth lives in `LPCore.Types` (`kim-em/lp-core`). This
  module re-exports the vocabulary so any consumer still writing
  `import SoplexFFI.Types` and referencing `Soplex.Problem`,
  `Soplex.Options`, `Soplex.Certificate`, `Soplex.Solution`,
  `Soplex.SolveError`, etc. keeps working.

  Pure-Lean only — no dependency on the native FFI.
-/

import LPCore.Types
