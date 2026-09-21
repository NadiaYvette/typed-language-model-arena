-- alpha-todo-strip: the pass-to-fail repair task for the toy corpus's
-- alpha.py (two TODO markers; the minimal diff deletes both lines). The
-- oracle is "toy-markers" (Campaign.Oracle markerOracle), the same oracle
-- the review side verifies against.

let RepairBlueprint = ./RepairBlueprint.dhall
let SS = ./SourceState.dhall

in
  { rbName = "alpha-todo-strip"
  , rbProject = "toy"
  , rbTargetCell = "toy-fixer/alpha.py"
  , rbOracleId = "toy-markers"
  , rbPath = "alpha.py"
  , rbRules =
      { rrSubsetOnly = True
      , rrDeletionsOnly = True
      , rrMaxOperations = 2
      }
  , rbBroken =
      { ssSource = "def alpha():\n    # TODO: implement alpha\n    # TODO: also handle the edge case\n    return 1"
      , ssDiagnostics =
          [ "alpha.py:2: warning: [W-todo] found a TODO marker"
          , "alpha.py:3: warning: [W-todo] found a TODO marker"
          ] : List Text
      } : SS
  , rbPrompt = "alpha.py fails with two W-todo warnings. Delete the two TODO lines with the minimal diff; change nothing else."
  } : RepairBlueprint
