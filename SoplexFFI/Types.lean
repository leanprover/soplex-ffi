/-
  Data types shared by the certificate checker and the FFI binding.

  Source of truth lives in `LPCore.Types` (`leanprover/lp-core`). This
  module re-exports the vocabulary so any consumer still writing
  `import SoplexFFI.Types` and referencing `LP.Problem`,
  `LP.Options`, `LP.Certificate`, `LP.Solution`,
  `LP.SolveError`, etc. keeps working.

  Pure-Lean only — no dependency on the native FFI.
-/

import LPCore.Types
