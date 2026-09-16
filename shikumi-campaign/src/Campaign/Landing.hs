{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The landing workflow: a journaled process whose steps touch the world.
--
-- The fix campaign's output is a repair recorded in a keiro journal. This
-- workflow is the second half of the loop: it takes that repair and makes it
-- real — worktree, file write, on-disk re-verification, commit on the
-- campaign branch — with every effectful step journaled exactly like an LM
-- attempt was. Replay never re-writes or re-commits: the 'LandingRecord' is
-- the durable decision.
--
-- The repair arrives as workflow input (the driver reads the accepted repair
-- out of the fix journal); the workflow's own steps are the landing. If the
-- on-disk verification disagrees with the journal, the record says so and
-- /nothing is committed/ — the disk gets the final word, and a human reviews
-- the worktree instead of a wrong commit landing.
module Campaign.Landing
  ( -- * The journaled landing record
    LandingRecord (..),

    -- * The workflow and its names
    landProjectCellWorkflow,
    landingWorkflowName,
    landingWorkflowId,
    landingWorkflowIdFor,
    landingStreamNameText,

    -- * Registry and journal readback
    registerLanding,
    landingRecordOf,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath ((</>))
import Effectful (Eff, IOE, liftIO, (:>))
import GHC.Generics (Generic)

import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowJournalEvent (..), step, unWorkflowId)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Keiro.Workflow.Types (WorkflowName (..))

import Campaign.Hands
  ( applyRepairInWorktree,
    commitLanding,
    ensureCampaignWorktree,
    verifyInWorktree,
  )
import Campaign.Oracle (CellOracle (..), ProjectCell (..), pythonSyntaxCheck, unusedImportOracle)
import Campaign.Workflow (campaignStreamNameText)
import Toy.Fixer.Domain (Source (..), SourcePath, showDiagnostic)

-- | The journaled result of one landing: where the repair now lives, whether
-- the on-disk check agreed with the journal, and (when it did) the commit it
-- became. JSON-safe by construction — it rides the journal codec.
data LandingRecord = LandingRecord
  { lrProject :: !Text,
    lrPath :: !SourcePath,
    lrWorktree :: !Text,
    lrBranch :: !Text,
    lrCommit :: !Text,
    lrVerified :: !Bool,
    lrDiagnostics :: ![Text]
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON, FromJSON)

-- | Land one project cell's accepted repair. The three hands steps run as
-- one journaled decision: worktree ensured, repair written, verification
-- re-derived from disk, commit made (only when verification agrees).
landProjectCellWorkflow ::
  (Workflow :> es, IOE :> es) =>
  ProjectCell ->
  CellOracle ->
  -- | the branch to commit on (one campaign concept, one branch)
  Text ->
  -- | the accepted repair, as read from the fix journal
  Text ->
  Eff es Text
landProjectCellWorkflow pc oracle branch repair = do
  recd <- step (StepName "land-repair") (landAction pc oracle branch repair)
  pure $
    if lrVerified recd
      then "landed: " <> lrCommit recd <> " on " <> lrBranch recd <> " (" <> lrWorktree recd <> ")"
      else "not landed: verification failed on disk — " <> T.intercalate "; " (lrDiagnostics recd)

landAction ::
  (IOE :> es) =>
  ProjectCell ->
  CellOracle ->
  Text ->
  Text ->
  Eff es LandingRecord
landAction pc oracle branch repair = liftIO $ do
  let proj = pcProject pc
      path = pcPath pc
  wt <- ensureCampaignWorktree proj branch
  applyRepairInWorktree wt path repair
  -- The syntax floor, re-derived from disk like the oracle's verdict: the
  -- disk gets the final word, and a file that does not parse never commits.
  diskBody <- T.pack <$> readFile (wt </> T.unpack path)
  mSyn <- pythonSyntaxCheck path (Source diskBody)
  case mSyn of
    Just syn ->
      pure
        LandingRecord
          { lrProject = proj,
            lrPath = path,
            lrWorktree = T.pack wt,
            lrBranch = branch,
            lrCommit = "",
            lrVerified = False,
            lrDiagnostics = [syn]
          }
    Nothing -> do
      diags <- verifyInWorktree oracle wt path
      if not (null diags)
        then
          pure
            LandingRecord
              { lrProject = proj,
                lrPath = path,
                lrWorktree = T.pack wt,
                lrBranch = branch,
                lrCommit = "",
                lrVerified = False,
                lrDiagnostics = map showDiagnostic diags
              }
        else do
          commit <- commitLanding wt path repair
          pure
            LandingRecord
              { lrProject = proj,
                lrPath = path,
                lrWorktree = T.pack wt,
                lrBranch = branch,
                lrCommit = commit,
                lrVerified = True,
                lrDiagnostics = []
              }

-- | The landing workflow's name — registered alongside the fix campaigns.
landingWorkflowName :: WorkflowName
landingWorkflowName = WorkflowName "campaign-landing"

-- | One landing per project cell, keyed like its fix workflow so the pair is
-- visible in any stream listing.
landingWorkflowId :: (Text, SourcePath) -> WorkflowId
landingWorkflowId (proj, path) =
  WorkflowId ("land-" <> proj <> ":" <> path)

-- | A landing id under a fresh-campaign prefix (@"react-"@ and friends), so
-- a second act's landings journal under their own streams.
landingWorkflowIdFor :: Text -> (Text, SourcePath) -> WorkflowId
landingWorkflowIdFor pfx (proj, path) =
  WorkflowId ("land-" <> pfx <> proj <> ":" <> path)

landingStreamNameText :: (Text, SourcePath) -> Text
landingStreamNameText spec =
  campaignStreamNameText landingWorkflowName (landingWorkflowId spec)

-- | The landing half of the registry. The repairs are captured at
-- construction — the driver read them from the fix journals. (A later
-- process resuming a parked landing re-reads the same journals; the repair
-- is a function of the journal, so this is deterministic.)
registerLanding ::
  (Workflow :> es, IOE :> es) =>
  -- | each project cell with its accepted repair
  [(ProjectCell, Text)] ->
  WorkflowRegistry es
registerLanding cellsWithRepairs =
  Map.fromList
    [ ( landingWorkflowName,
        WorkflowDef $ \wid ->
          case [ (pc, r) | (pc, r) <- cellsWithRepairs, unWorkflowId (landingWorkflowId (pcProject pc, pcPath pc)) == unWorkflowId wid ] of
            [(pc, repair)] -> landProjectCellWorkflow pc unusedImportOracle "campaign/unused-imports" repair
            _ -> error ("registerLanding: no cell for workflow " <> show wid)
      )
    ]

-- | Pull the landing records back out of a decoded journal — the same
-- readback shape as the fix attempts' extraction in the driver.
landingRecordOf :: [WorkflowJournalEvent] -> [LandingRecord]
landingRecordOf = mapMaybe extract
  where
    extract = \case
      StepRecorded name result _
        | "land-repair" `T.isPrefixOf` name ->
            case Aeson.fromJSON result of
              Aeson.Success lr -> Just lr
              _ -> Nothing
      _ -> Nothing
