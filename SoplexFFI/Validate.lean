/-
  Pure-Lean validators for `Problem` and `Options`.

  `validate` normalizes and rejects every `Problem` value before it
  reaches the FFI or the certificate checker. It guarantees:

  * Every array field has the declared length.
  * Sparse entry `(row, col)` bounds are carried by `Fin` indices.
  * Every bound pair has `lo ≤ hi`.
  * Sparse entries are sorted by `(row, col)`.
  * Duplicate `(row, col)` entries are summed.
  * Zero-valued sparse entries are dropped.

  This is the pure Lean boundary before data reaches either C++ or
  the verifier.
-/

import SoplexFFI.Types

namespace Soplex

/-! ## `validateOptions`. -/

/-- Reject obviously-invalid `Options` before they reach C++. -/
def validateOptions (o : Options) : Except OptionError Options := do
  -- NaN time-limit: distinct from a negative value so the error
  -- message can be useful.
  match o.timeLimit with
  | none     => pure ()
  | some t   =>
    if t.isNaN then
      throw .nanTimeLimit
    if t < 0.0 then
      throw (.negativeTimeLimit t)
  match o.iterLimit with
  | none   => pure ()
  | some n =>
    if n = 0 then
      throw .zeroIterLimit
    if n > ffiMaxInt then
      throw (.iterLimitTooLarge ffiMaxInt n)
  pure o

/-! ## `validate`. -/

private def finEntryOfRaw {numConstraints numVars : Nat}
    (entry : Nat × Nat × Rat) :
    Except ProblemError (Fin numConstraints × Fin numVars × Rat) := do
  let (r, c, v) := entry
  if hr : r < numConstraints then
    if hc : c < numVars then
      pure (⟨r, hr⟩, ⟨c, hc⟩, v)
    else
      throw (.indexOutOfRange .col c numVars)
  else
    throw (.indexOutOfRange .row r numConstraints)

def Problem.ofRaw {numConstraints numVars : Nat}
    (p : RawProblem numConstraints numVars) :
    Except ProblemError (Problem numConstraints numVars) := do
  let a ← p.a.mapM finEntryOfRaw
  pure {
    c := p.c
    objOffset := p.objOffset
    a := a
    rowBounds := p.rowBounds
    colBounds := p.colBounds
  }

/-- Compare `(row, col)` pairs lexicographically. -/
@[inline] private def entryLt {m n : Nat}
    (x y : Fin m × Fin n × Rat) : Bool :=
  let (r₁, c₁, _) := x
  let (r₂, c₂, _) := y
  r₁.val < r₂.val || (r₁ = r₂ && c₁.val < c₂.val)

/-- Sum consecutive equal-key entries in a sorted sparse list, drop
    zero results, and return the normalised array. Assumes input is
    already sorted by `entryLt`. -/
private def collapseSorted {m n : Nat} (a : Array (Fin m × Fin n × Rat)) :
    Array (Fin m × Fin n × Rat) :=
  match a.toList with
  | [] => #[]
  | first :: rest => Id.run do
      let mut out : Array (Fin m × Fin n × Rat) := Array.mkEmpty a.size
      let mut curR : Fin m := first.1
      let mut curC : Fin n := first.2.1
      let mut curV : Rat := first.2.2
      for entry in rest do
        let (r, c, v) := entry
        if r = curR && c = curC then
          curV := curV + v
        else
          if curV ≠ 0 then
            out := out.push (curR, curC, curV)
          curR := r
          curC := c
          curV := v
      if curV ≠ 0 then
        out := out.push (curR, curC, curV)
      return out

/-- Normalise the sparse matrix: sort, sum duplicates, drop zeros. -/
private def normaliseSparse {m n : Nat} (a : Array (Fin m × Fin n × Rat)) :
    Array (Fin m × Fin n × Rat) :=
  collapseSorted (a.qsort entryLt)

/-- Validate and normalise a `Problem`.

    On success the returned `Problem` is structurally identical to the
    input *except* that `a` has been sorted, deduplicated, and pruned of
    zero entries. Field-level checks live here so the FFI and the
    checker can both assume well-formed inputs without re-validating. -/
def validate {numConstraints numVars : Nat} (p : Problem numConstraints numVars) :
    Except ProblemError (Problem numConstraints numVars) := do
  -- Bound inversions for columns.
  for i in [0:p.colBounds.toArray.size] do
    match p.colBounds.toArray[i]! with
    | (some lo, some hi) =>
      if lo > hi then throw (.boundInverted .col i lo hi)
    | _ => pure ()
  -- Bound inversions for rows.
  for i in [0:p.rowBounds.toArray.size] do
    match p.rowBounds.toArray[i]! with
    | (some lo, some hi) =>
      if lo > hi then throw (.boundInverted .row i lo hi)
    | _ => pure ()
  let a' := normaliseSparse p.a
  pure { p with a := a' }

/-- Convert raw natural sparse indices to `Fin` once at the boundary,
    then validate and normalise the resulting typed problem. -/
def validateRaw {numConstraints numVars : Nat}
    (p : RawProblem numConstraints numVars) :
    Except ProblemError (Problem numConstraints numVars) := do
  let p ← Problem.ofRaw p
  validate p

end Soplex
