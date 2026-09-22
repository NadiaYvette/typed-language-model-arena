{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-unused-top-binds #-}

-- | The campaign's cell aggregate, authored as a keiki transducer.
--
-- Every act so far parsed journals ad hoc (@decodedJournal@,
-- @journaledAttempts@, per-act scoreboards). This module replaces all of
-- that with one typed state machine:
--
--   * the journal events keiro already writes ('WorkflowJournalEvent') are
--     interpreted into aggregate events ('CellEvent') by one pure function;
--   * 'cellAggregate' — a @SymTransducer@ over
--     @CellOpen → CellHumanQueried → CellClearedVertex \/
--     CellEscalatedVertex@ — replays them, with the attempt counter owned
--     by the machine, not by the parser;
--   * 'cellReplayStep' drives it one journal event at a time (the shibuya
--     fan-out consumes journals this way, in global order), and
--     'replayCellJournal' folds a whole journal (the offline audit);
--   * both paths share the exact same step function, so the live read
--     model and the offline read model /must/ agree — act 13 checks it.
--
-- The lifecycle mirrors what the campaign's workflows really do:
--
--   * attempts are a self-loop on 'CellOpen' and increment the counter;
--   * @publish-human-query@ moves to 'CellHumanQueried' — NOT terminal,
--     because the human answers and the workflow /resumes/ (the informed
--     retry of act 2);
--   * a resumed attempt returns to 'CellOpen'; a completion while parked
--     (the human said stop) escalates terminally;
--   * @WorkflowCompleted@ while open clears the cell — the attempt count it
--     reports is /derived state/, emitted as a register term so replay
--     verifies it instead of trusting the parser;
--   * @WorkflowFailed@ / @WorkflowCancelled@ terminate as escalated.
--
-- A journal whose event stream disagrees with the machine fails replay
-- loudly — that is the point of a verification read model.
module Campaign.Aggregate
  ( -- * Domain payloads
    CellAttemptedData (..),
    CellClearedData (..),
    CellEscalatedData (..),
    CellCmd (..),
    CellEvent (..),

    -- * Registers, vertices, transducer
    CellRegs,
    CellVertex (..),
    initialCellRegs,
    cellAggregate,
    cellMermaid,

    -- * Journal interpretation and replay
    CellReplayState (..),
    cellReplayInitial,
    cellReplayStep,
    replayCellJournal,
    cellVertexOf,

    -- * Read model
    CellSummary (..),
    cellSummaryOf,
  )
where

import Campaign.Cell (FixAttempt (..))
import Data.Aeson qualified as Aeson
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Keiki.Builder (reg, (.=))
import Keiki.Builder qualified as B
import Keiki.Core
import Keiki.Generics.TH (deriveAggregateCtors, deriveWireCtors)
import Keiki.Render.Mermaid (toMermaid)
import Keiro.Workflow.Types (WorkflowJournalEvent (..))

-- * Domain payloads ----------------------------------------------------------

data CellAttemptedData = CellAttemptedData
  { caAttempt :: !Int,
    caSucceeded :: !Bool,
    caAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

data CellClearedData = CellClearedData
  { ccAttempts :: !Int,
    ccAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

data CellEscalatedData = CellEscalatedData
  { ceReason :: !Text,
    ceAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

-- | Commands the aggregate accepts. The read model only ever replays the
-- event side, but keiki's transducers are bidirectional: the command side
-- is what a /driver/ would issue, and inversion means an event log
-- reconstructs the commands that produced it.
data CellCmd
  = AttemptCell CellAttemptedData
  | ClearCell CellClearedData
  | EscalateCell CellEscalatedData
  deriving stock (Eq, Show, Generic)

data CellEvent
  = CellAttempted CellAttemptedData
  | CellCleared CellClearedData
  | CellEscalated CellEscalatedData
  deriving stock (Eq, Show, Generic)

-- * Registers, vertices, transducer -----------------------------------------

type CellRegs =
  '[ '("cellAttemptCount", Int),
     '("cellClearedAt", UTCTime),
     '("cellEscalatedReason", Text)
   ]

data CellVertex
  = CellOpen
  | -- | The human has been queried but not answered; the workflow is
    -- parked on the awakeable. Attempts after the answer resume here.
    CellHumanQueried
  | CellClearedVertex
  | CellEscalatedVertex
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Initial registers: the attempt counter starts at a real zero (a fresh
-- cell has attempted nothing), while the terminal registers start as
-- deferred errors — they are written by the edge that makes them live,
-- before any read that could force them.
initialCellRegs :: RegFile CellRegs
initialCellRegs =
  RCons
    (Proxy @"cellAttemptCount")
    0
    ( RCons
        (Proxy @"cellClearedAt")
        (error "uninit: cellClearedAt")
        (RCons (Proxy @"cellEscalatedReason") (error "uninit: cellEscalatedReason") RNil)
    )

$( deriveAggregateCtors
     ''CellCmd
     ''CellRegs
     [ ("AttemptCell", "Attempt"),
       ("ClearCell", "Clear"),
       ("EscalateCell", "Escalate")
     ]
 )

$( deriveWireCtors
     ''CellEvent
     [ ("CellAttempted", "CellAttempted"),
       ("CellCleared", "CellCleared"),
       ("CellEscalated", "CellEscalated")
     ]
 )

-- | The aggregate. Attempts self-loop; the human query parks; the two
-- exits are cleared (from open) and escalated (from parked or open, on
-- failure\/cancellation\/human-decided-stop). The attempt count carried by
-- the cleared event is a register term — replay verifies the derived
-- count.
cellAggregate :: Guarded CellRegs CellVertex CellCmd CellEvent
cellAggregate = B.buildTransducer
  CellOpen
  initialCellRegs
  (\case CellClearedVertex -> True; CellEscalatedVertex -> True; _ -> False)
  do
    B.from CellOpen do
      B.onCmd inCtorAttempt $ \d -> B.do
        B.slot @"cellAttemptCount" .= tadd (reg @"cellAttemptCount") (lit 1)
        B.emit
          wireCellAttempted
          CellAttemptedTermFields
            { caAttempt = d.caAttempt,
              caSucceeded = d.caSucceeded,
              caAt = d.caAt
            }
        B.goto CellOpen

      B.onCmd inCtorClear $ \d -> B.do
        B.slot @"cellClearedAt" .= d.ccAt
        B.emit
          wireCellCleared
          CellClearedTermFields
            { ccAttempts = d.ccAttempts,
              ccAt = d.ccAt
            }
        B.goto CellClearedVertex

      B.onCmd inCtorEscalate $ \d -> B.do
        B.slot @"cellEscalatedReason" .= d.ceReason
        B.emit
          wireCellEscalated
          CellEscalatedTermFields
            { ceReason = d.ceReason,
              ceAt = d.ceAt
            }
        B.goto CellHumanQueried

    B.from CellHumanQueried do
      -- The human answered; the workflow resumes with an informed retry.
      B.onCmd inCtorAttempt $ \d -> B.do
        B.slot @"cellAttemptCount" .= tadd (reg @"cellAttemptCount") (lit 1)
        B.emit
          wireCellAttempted
          CellAttemptedTermFields
            { caAttempt = d.caAttempt,
              caSucceeded = d.caSucceeded,
              caAt = d.caAt
            }
        B.goto CellOpen

      -- The human said stop: the workflow completes without another
      -- attempt, and the campaign closes the cell as escalated.
      B.onCmd inCtorEscalate $ \d -> B.do
        B.slot @"cellEscalatedReason" .= d.ceReason
        B.emit
          wireCellEscalated
          CellEscalatedTermFields
            { ceReason = d.ceReason,
              ceAt = d.ceAt
            }
        B.goto CellEscalatedVertex

-- | The aggregate's state machine as a Mermaid state diagram.
cellMermaid :: Text
cellMermaid = toMermaid cellAggregate

-- * Journal interpretation and replay ----------------------------------------

-- | Streaming replay state for one cell's journal.
data CellReplayState = CellReplayState
  { crsWrapper :: !(InFlight CellVertex CellEvent),
    crsRegs :: !(RegFile CellRegs)
  }

cellReplayInitial :: CellReplayState
cellReplayInitial = CellReplayState (Settled CellOpen) initialCellRegs

-- | The machine's current vertex (the streaming wrapper may be mid-chain
-- after multi-event emissions; the vertex is current in both arms).
cellVertexOf :: CellReplayState -> CellVertex
cellVertexOf st = case st.crsWrapper of
  Settled v -> v
  InFlight v _ -> v

-- | Interpret one journal event into the aggregate's event alphabet.
-- @Nothing@ means "not part of the cell story" (setup steps, settle
-- timers, rotations, redundant completions).
interpret ::
  CellReplayState ->
  WorkflowJournalEvent ->
  Maybe CellEvent
interpret st = \case
  StepRecorded name result at
    | name == "publish-human-query" ->
        Just (CellEscalated (CellEscalatedData "budget-exhausted-human-query" at))
    | "propose-fix-" `T.isPrefixOf` name ->
        case Aeson.fromJSON result :: Aeson.Result FixAttempt of
          Aeson.Success fa ->
            Just (CellAttempted (CellAttemptedData fa.faAttempt fa.faSucceeded at))
          Aeson.Error _ -> Nothing
    -- Setup steps, settle timers, and any other bookkeeping are not part
    -- of the cell story.
    | otherwise -> Nothing
  WorkflowCompleted at -> case cellVertexOf st of
    CellOpen ->
      -- The count is read from the machine's own counter — derived state
      -- owned by the aggregate, supplied as event data. (It cannot be
      -- emitted as a register term: keiki inversion recovers commands from
      -- input fields and literals only.)
      Just (CellCleared (CellClearedData (attemptCountOf st.crsRegs) at))
    -- The human said stop; completing the workflow closes the cell as
    -- escalated, not cleared.
    CellHumanQueried ->
      Just (CellEscalated (CellEscalatedData "workflow-closed-after-human-query" at))
    -- Already terminal; a duplicate completion carries no new story.
    _ -> Nothing
  WorkflowFailed reason at -> case cellVertexOf st of
    CellOpen -> Just (CellEscalated (CellEscalatedData reason at))
    CellHumanQueried -> Just (CellEscalated (CellEscalatedData reason at))
    _ -> Nothing
  WorkflowCancelled at -> case cellVertexOf st of
    CellOpen -> Just (CellEscalated (CellEscalatedData "workflow-cancelled" at))
    CellHumanQueried -> Just (CellEscalated (CellEscalatedData "workflow-cancelled" at))
    _ -> Nothing
  WorkflowContinuedAsNew {} -> Nothing

-- | Step the aggregate by one journal event. Foreign events leave the
-- state untouched; aggregate events must replay cleanly or the whole
-- stream fails loudly.
cellReplayStep ::
  CellReplayState ->
  WorkflowJournalEvent ->
  Either String CellReplayState
cellReplayStep st wje = case interpret st wje of
  Nothing -> Right st
  Just ce ->
    case applyEventStreamingEither cellAggregate st.crsWrapper st.crsRegs ce of
      Left failure -> Left (show failure)
      Right (wrapper', regs') -> Right (CellReplayState wrapper' regs')

-- | Offline replay: fold a whole journal through the same step function
-- the live fan-out uses.
replayCellJournal ::
  [WorkflowJournalEvent] ->
  Either String CellReplayState
replayCellJournal = go cellReplayInitial
  where
    go st [] = Right st
    go st (e : es) = cellReplayStep st e >>= \st' -> go st' es

-- * Read model ---------------------------------------------------------------

-- | The aggregate's projection onto what the campaign reports per cell.
-- Unwritten registers are never forced: 'csClearedAt' is only read in the
-- cleared vertex, the reason only where an escalation edge wrote it.
data CellSummary = CellSummary
  { csVertex :: !CellVertex,
    csAttempts :: !Int,
    csClearedAt :: !(Maybe UTCTime),
    csEscalatedReason :: !(Maybe Text),
    -- | The machine reached a terminal vertex (cleared or escalated). An
    -- open or parked cell means the journal ended without a verdict —
    -- the incomplete\/awaiting-human case every earlier act detected by
    -- hand.
    csComplete :: !Bool
  }
  deriving stock (Eq, Show)

cellSummaryOf :: CellReplayState -> CellSummary
cellSummaryOf st = summary (cellVertexOf st) st.crsRegs
  where
    summary vertex regs =
      CellSummary
        { csVertex = vertex,
          csAttempts = attemptCountOf regs,
          csClearedAt = case vertex of
            CellClearedVertex -> Just (clearedAtOf regs)
            _ -> Nothing,
          csEscalatedReason = case vertex of
            CellHumanQueried -> Just (escalatedReasonOf regs)
            CellEscalatedVertex -> Just (escalatedReasonOf regs)
            _ -> Nothing,
          csComplete = case vertex of
            CellClearedVertex -> True
            CellEscalatedVertex -> True
            _ -> False
        }

-- | Register readers. Each pattern match refines the register spine to the
-- exact slot, so these cannot misread the register file.
attemptCountOf :: RegFile CellRegs -> Int
attemptCountOf (RCons (_ :: Proxy "cellAttemptCount") n _) = n

clearedAtOf :: RegFile CellRegs -> UTCTime
clearedAtOf (RCons _ _ (RCons (_ :: Proxy "cellClearedAt") t _)) = t

escalatedReasonOf :: RegFile CellRegs -> Text
escalatedReasonOf (RCons _ _ (RCons _ _ (RCons (_ :: Proxy "cellEscalatedReason") r RNil))) = r
