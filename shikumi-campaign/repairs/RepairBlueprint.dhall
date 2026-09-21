-- | Repair Blueprint (campaign analogue of a seihou Blueprint)
--
-- A blueprint is the /task/ handed to an agent: which cell, which oracle,
-- the broken source state with its diagnostics, the repair rules, and the
-- prompt. It declares what the agent may do — it does not record what the
-- agent did. That record is a RepairReceipt, named by `rcBlueprint`.

let SourceState = ./SourceState.dhall

in
  { rbName : Text
  , rbProject : Text        -- ^ campaign project namespace (memory namespace)
  , rbTargetCell : Text     -- ^ the cell key the repaired source belongs to
  , rbOracleId : Text       -- ^ the CellOracle that verifies (e.g. "toy-markers")
  , rbPath : Text           -- ^ the source path exactly as the oracle names it
  , rbRules :
      { rrSubsetOnly : Bool -- ^ the repair must be a subset of the original (no additions, no reorder)
      , rrDeletionsOnly : Bool
      , rrMaxOperations : Natural
      }
  , rbBroken : SourceState  -- ^ the failing state the repair must start from
  , rbPrompt : Text         -- ^ what the agent is asked, verbatim
  }
