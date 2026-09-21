-- | Repair Receipt (campaign analogue of a seihou migration receipt)
--
-- A receipt is /evidence/, not a verdict: it records one pass-to-fail-to-pass
-- repair trajectory — the failing state (and its diagnostics), the applied
-- operations (original line numbers), and the passing state (and its clean
-- diagnostics). Per seihou ADR 0011, a migration receipt asserts a claim
-- about the project; per the Track 10 facts-only decision (and invariant #4),
-- the claim is re-derived, never trusted: `admitReceipt` replays the
-- operations and re-runs the named oracle on both states, and the receipt is
-- admissible to Campaign.Review only if every re-derived fact matches.
--
-- The merge gate stays where it has always been: approveBranch's own
-- oracle re-verification of the branch's files. The receipt is admissible
-- evidence feeding that gate — it can corroborate or contradict, never
-- decide.

let RepairOp = ./RepairOp.dhall
let SourceState = ./SourceState.dhall

in
  { rcName : Text
  , rcBlueprint : Text      -- ^ the RepairBlueprint this receipt answers
  , rcProject : Text
  , rcPath : Text           -- ^ must match the blueprint's path
  , rcOracleId : Text       -- ^ must match the blueprint's oracle
  , rcBefore : SourceState  -- ^ the failing state: diagnostics non-empty
  , rcOperations : List RepairOp
  , rcAfter : SourceState   -- ^ the passing state: diagnostics empty
  , rcCheckedBy : Text      -- ^ which checker produced the recorded diagnostics
  , rcCheckedAt : Text
  }
