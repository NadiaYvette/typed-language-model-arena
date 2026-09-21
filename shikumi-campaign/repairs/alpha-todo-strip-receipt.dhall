-- Receipt for blueprint alpha-todo-strip: the applied trajectory.
-- Operations carry the ORIGINAL line numbers; replay drops the named lines
-- in one pass. The recorded diagnostics are the checker's real output
-- (showDiagnostic rendering), re-derived at admission time — a tampered
-- claim fails re-derivation, so the record is evidence, never a verdict.

let RepairReceipt = ./RepairReceipt.dhall
let SS = ./SourceState.dhall

in
  { rcName = "alpha-todo-strip-receipt"
  , rcBlueprint = "alpha-todo-strip"
  , rcProject = "toy"
  , rcPath = "alpha.py"
  , rcOracleId = "toy-markers"
  , rcBefore =
      { ssSource = "def alpha():\n    # TODO: implement alpha\n    # TODO: also handle the edge case\n    return 1"
      , ssDiagnostics =
          [ "alpha.py:2: warning: [W-todo] found a TODO marker"
          , "alpha.py:3: warning: [W-todo] found a TODO marker"
          ] : List Text
      } : SS
  , rcOperations =
      [ { opLine = 3, opText = "    # TODO: also handle the edge case" }
      , { opLine = 2, opText = "    # TODO: implement alpha" }
      ] : List { opLine : Natural, opText : Text }
  , rcAfter =
      { ssSource = "def alpha():\n    return 1"
      , ssDiagnostics = [] : List Text
      } : SS
  , rcCheckedBy = "toy-fixer checker (Toy.Fixer.Domain.checkSource)"
  , rcCheckedAt = "2026-09-21"
  } : RepairReceipt
