{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The dispatch shape over the /real/ verification processes: pgcl's
-- (arch × config) kernel boot matrix and telix's host-side verification.
--
-- The toy matrix (@Campaign.Matrix@) proved the shape on synthetic stages;
-- this module points the same shape at the processes that actually exist:
--
--   * A pgcl cell is @matrix-driver.sh LINUX_DIR ARCH CONFIG OUTDIR@ — one
--     kernel build plus one QEMU boot, one log per cell, verdict markers
--     written by the initramfs init itself. The arch/config vocabulary is
--     /discovered against reality/: arches are the driver's catalog
--     filtered by the cross toolchains and emulators present on this host,
--     configs filtered by which kernel trees exist. A box with no sh4
--     toolchain plans no sh4 cells.
--   * A telix unit is @make -C ~/src/telix verify@ — host unit tests plus
--     hygiene, output captured as the log.
--
-- Execution is /gated by an environment switch, by default off/: the
-- offline run journals the discovery, the exact per-cell command, and a
-- @planned@ verdict — the campaign plans real work without running
-- hour-long builds uninvited. @REAL_LIVE=1@ lifts the gate; every verdict
-- then comes from the log the tool wrote, never from a model's opinion.
--
-- Each cell is a keiro workflow: @verify-plan@ journals the exact command,
-- @run-cell@ journals the outcome, so a 40-minute cell that dies mid-flight
-- resumes instead of restarting — the property that matters when the matrix
-- is thousands of cells and days of wall clock. Lessons are recorded by the
-- /driver/ (Main.hs), not inside workflow steps, per Campaign.Memory's
-- layering.
module Campaign.Real
  ( -- * Units
    RealUnit (..),
    realCellId,
    realCellKey,
    realUnitCells,
    realWorkflowIdTagged,
    realCellFromWf,
    classifyCellLog,
    -- * Execution
    RealMode (..),
    realModeFromEnv,
    realLogPath,
    realAttemptRecord,
    runRealUnit,
    -- * Workflow
    realCellWorkflow,
    realWorkflowName,
    realRegistry,
    RealAttempt (..),
    realAttemptsOf,
  )
where

import Data.Aeson qualified as Aeson
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import Control.Exception qualified as E
import Effectful (Eff, IOE, liftIO, (:>))
import GHC.Generics (Generic)
import Keiro.Workflow (StepName (..), WorkflowId (..), step)
import Keiro.Workflow qualified as KeiroWorkflow (Workflow)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Keiro.Workflow.Types (WorkflowJournalEvent (..), WorkflowName (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.Process.Typed (proc, readProcess)

import Campaign.Cell (CellId (..))

-- ---------------------------------------------------------------------------
-- Units: one real verification cell
-- ---------------------------------------------------------------------------

-- | One real verification unit. @ruKind@ names the process family; the
-- remaining fields parameterize it exactly as the driver consumes them.
data RealUnit = RealUnit
  { ruProject :: !Text,
    -- ^ @pgcl@ or @telix@ — also the memory namespace the unit reports into
    ruKind :: !Text,
    -- ^ @qemu-boot-matrix@ or @host-verify@
    ruArch :: !Text,
    -- ^ target architecture (pgcl) or @host@ (telix)
    ruConfig :: !Text,
    -- ^ kernel config tier (pgcl) or the make target set (telix)
    ruArgs :: ![Text]
    -- ^ the driver arguments after LINUX_DIR, verbatim
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Aeson.ToJSON, Aeson.FromJSON)

-- | The unit's id, unique per (project × arch × config).
realCellId :: RealUnit -> CellId
realCellId u =
  CellId ("real:" <> ruProject u <> ":" <> ruArch u <> "@" <> ruConfig u)

-- | The unit's journal-stream key fragment (also the memory lesson's key).
-- Contains no @-@ on the project side and no @__@ anywhere, so workflow ids
-- can embed it unambiguously.
realCellKey :: RealUnit -> Text
realCellKey u = ruProject u <> "/" <> ruArch u <> "@" <> ruConfig u

-- | The pgcl arch/config vocabulary the driver speaks. A host's
-- /available/ units are this vocabulary intersected with reality.
pgclArchCatalog :: [Text]
pgclArchCatalog =
  [ "x86_64", "aarch64", "riscv64", "ppc64", "s390x", "sparc64",
    "loongarch64", "alpha", "riscv32", "m68k", "hppa", "mips64",
    "arm", "arm-lpae", "hppa64", "microblaze", "or1k", "xtensa", "sh4", "csky"
  ]

pgclConfigCatalog :: [Text]
pgclConfigCatalog = ["mainline", "0", "2", "4", "6"]

-- | The cross toolchain prefix each pgcl arch needs on PATH (the driver's
-- own @CC=@ column). @\"\"@ = builds with the host compiler.
pgclArchToolchain :: Text -> Text
pgclArchToolchain a = case a of
  "x86_64" -> ""
  "aarch64" -> "aarch64-linux-gnu-"
  "riscv64" -> "riscv64-linux-gnu-"
  "riscv32" -> "riscv32-linux-gnu-"
  "ppc64" -> "powerpc64le-linux-gnu-"
  "s390x" -> "s390x-linux-gnu-"
  "sparc64" -> "sparc64-linux-gnu-"
  "loongarch64" -> "loongarch64-linux-gnu-"
  "alpha" -> "alpha-linux-gnu-"
  "m68k" -> "m68k-linux-gnu-"
  "hppa" -> "hppa-linux-gnu-"
  "hppa64" -> "hppa64-linux-gnu-"
  "mips64" -> "mips64-linux-gnu-"
  "arm" -> "arm-linux-gnueabihf-"
  "arm-lpae" -> "arm-linux-gnueabihf-"
  "microblaze" -> "microblaze-linux-gnu-"
  "or1k" -> "or1k-linux-gnu-"
  "xtensa" -> "xtensa-dc233c-linux-uclibc-"
  "sh4" -> "sh4-linux-"
  "csky" -> "csky-linux-"
  _ -> "\1unmatched"

-- | The emulator each pgcl arch needs.
pgclArchQemu :: Text -> Text
pgclArchQemu a = case a of
  "x86_64" -> "qemu-system-x86_64"
  "aarch64" -> "qemu-system-aarch64"
  "riscv64" -> "qemu-system-riscv64"
  "riscv32" -> "qemu-system-riscv32"
  "ppc64" -> "qemu-system-ppc64"
  "s390x" -> "qemu-system-s390x"
  "sparc64" -> "qemu-system-sparc64"
  "loongarch64" -> "qemu-system-loongarch64"
  "alpha" -> "qemu-system-alpha"
  "m68k" -> "qemu-system-m68k"
  "hppa" -> "qemu-system-hppa"
  "hppa64" -> "qemu-system-hppa"
  "mips64" -> "qemu-system-mips64"
  "arm" -> "qemu-system-arm"
  "arm-lpae" -> "qemu-system-arm"
  "microblaze" -> "qemu-system-microblaze"
  "or1k" -> "qemu-system-or1k"
  "xtensa" -> "qemu-system-xtensa"
  "sh4" -> "qemu-system-sh4"
  "csky" -> "qemu-system-cskyv2"
  _ -> "\1unmatched"

-- | @command -v@ probe; False on lookup failure.
availableOnPath :: Text -> IO Bool
availableOnPath bin = do
  (ec, _, _) <- readProcess (proc "bash" ["-c", "command -v " <> T.unpack bin])
  pure (ec == ExitSuccess)

-- | The working kernel tree a pgcl config builds from.
pgclWorkDir :: Text -> Text
pgclWorkDir "mainline" = "/home/nyc/src/linux-mainline"
pgclWorkDir _ = "/home/nyc/src/linux"

-- | Discover the real units this host can run, from ground truth: the
-- driver's vocabulary intersected with the toolchains, emulators, and
-- kernel trees actually present, plus telix's host verification when the
-- checkout is there. The scan is cheap (@command -v@ and directory
-- existence only) — it plans, it never builds.
realUnitCells :: IO [RealUnit]
realUnitCells = do
  drvExists <- doesFileExist pgclDriverPath
  hasPgclTree <- doesDirectoryExist "/home/nyc/src/linux"
  hasMainlineTree <- doesDirectoryExist "/home/nyc/src/linux-mainline"
  archAvail <-
    mapM
      ( \a -> do
          ccOk <- case pgclArchToolchain a of
            "" -> availableOnPath "gcc"
            cc -> availableOnPath (cc <> "gcc")
          qemuOk <- availableOnPath (pgclArchQemu a)
          pure (a, ccOk && qemuOk)
      )
      (if drvExists then pgclArchCatalog else [])
  let usableArches = [a | (a, ok) <- archAvail, ok]
      -- mainline cells build the mainline tree; PGCL config cells build the
      -- PGCL development tree — each cell's tree must exist.
      pgclUnits =
        [ RealUnit "pgcl" "qemu-boot-matrix" a c [c]
        | a <- usableArches,
          c <- pgclConfigCatalog,
          treeExists (pgclWorkDir c) hasPgclTree hasMainlineTree
        ]
      treeExists w pgclOk mainOk
        | w == "/home/nyc/src/linux-mainline" = mainOk
        | otherwise = pgclOk
  hasTelix <- doesDirectoryExist "/home/nyc/src/telix"
  let telixUnits =
        [ RealUnit "telix" "host-verify" "host" "verify" []
        | hasTelix
        ]
  pure (pgclUnits <> telixUnits)

-- Ground-truth path the discovery reads.
pgclDriverPath :: FilePath
pgclDriverPath = "/home/nyc/src/pgcl/matrix-driver.sh"

-- ---------------------------------------------------------------------------
-- The verdict: read off the log the tool wrote
-- ---------------------------------------------------------------------------

-- | A cell's verdict, classified from its log — never a model's opinion.
-- The initramfs init prints a final @Test Summary: N passed, M failed@, and
-- per-suite subtotals like @LTP subtotals: N passed, M failed, K skipped@.
-- The final banner is sometimes lost to UART back-pressure when the cell
-- powers off (observed in the historical 80-cell logs), so /any/ passed/
-- failed subtotal line counts, the last one winning. The driver prints
-- @SKIP: no …@ for a missing toolchain or emulator; a log with no subtotal
-- at all is a boot/timeout failure. Returns @passed@ / @failed@ / @skipped@.
classifyCellLog :: Text -> Text
classifyCellLog logText
  | any (\l -> "SKIP: no " `T.isPrefixOf` T.strip l) (T.lines logText) = "skipped"
  | Just fails <- lastSubtotalFails logText =
      if fails == 0 && not (kernelWarned logText) then "passed" else "failed"
  | otherwise = "failed"
  where
    -- The failed count of the last "… N passed, M failed[ …]" line.
    lastSubtotalFails t = go Nothing (T.lines t)
      where
        go acc [] = acc
        go acc (l : ls) = go (case subtotalFails l of Just f -> Just f; Nothing -> acc) ls
    subtotalFails line = do
      -- "Test Summary: N passed, M failed" and "LTP subtotals: N passed, M
      -- failed, K skipped" both put each count /before/ its keyword (with
      -- commas the log writes mid-list, stripped here): the failed count is
      -- the word right before "failed".
      let ws = map (T.dropWhileEnd (== ',')) (T.words (T.strip line))
      case break (== "failed") ws of
        (before, _ : _) | (prev : _) <- reverse before, not (T.null prev) -> readIntT prev
        _ -> Nothing
    readIntT t = case reads (T.unpack t) of
      [(n, "")] -> Just (n :: Int)
      _ -> Nothing
    kernelWarned t =
      -- The init's own dmesg audit banner (precise: only prints when the
      -- kernel log matches its BUG/Oops/Bad-page-state patterns).
      any ("WARNING: kernel log contains errors" `T.isInfixOf`) (T.lines t)

-- | Where the driver writes this unit's log (under the run's output dir).
realLogPath :: RealUnit -> FilePath -> Text
realLogPath u outDir =
  T.pack outDir <> "/" <> ruArch u <> "_" <> ruConfig u <> ".log"

-- ---------------------------------------------------------------------------
-- Execution (the gated side effect)
-- ---------------------------------------------------------------------------

data RealMode = RealPlan | RealLive
  deriving stock (Eq, Show)

-- | @REAL_LIVE=1@ (or true/yes/on, case-insensitive) lifts the gate; every
-- other value — including absence — plans without executing.
realModeFromEnv :: IO RealMode
realModeFromEnv = do
  v <- lookupEnv "REAL_LIVE"
  pure $ case fmap (T.toLower . T.strip . T.pack) v of
    Just t | t `elem` ["1", "true", "yes", "on"] -> RealLive
    _ -> RealPlan

-- | The working tree a unit builds from: derived, not stored — a pgcl
-- cell's tree follows its config (mainline cells build mainline), telix
-- builds its own checkout.
realWorkDir :: RealUnit -> Text
realWorkDir u = case ruProject u of
  "telix" -> "/home/nyc/src/telix"
  _ -> pgclWorkDir (ruConfig u)

-- | The exact command a cell runs, as journaled (and as the operator would
-- type to run it by hand).
commandText :: RealUnit -> FilePath -> Text
commandText u outDir
  | ruKind u == "host-verify" =
      "make -C " <> realWorkDir u <> " verify"
  | otherwise =
      "bash " <> T.pack pgclDriverPath <> " " <> realWorkDir u <> " "
        <> T.intercalate " " (ruArch u : ruArgs u <> [T.pack outDir])

-- | Execute one unit for real. pgcl cells invoke the driver (which manages
-- its own PATH, build dir, QEMU and timeouts); telix runs make. Returns
-- (verdict, logPath) — the verdict read from the log the tool wrote, never
-- from the process exit code alone.
runRealUnit :: RealUnit -> FilePath -> IO (Text, Text)
runRealUnit u outDir
  | ruKind u == "host-verify" = do
      let logPath = T.pack outDir <> "/telix-host-verify.log"
      (ec, out, err) <-
        readProcess (proc "make" ["-C", T.unpack (realWorkDir u), "verify"])
      let body = TL.toStrict (TLE.decodeUtf8 out) <> "\n" <> TL.toStrict (TLE.decodeUtf8 err)
      TIO.writeFile (T.unpack logPath) body
      pure (verdictFrom ec body, logPath)
  | otherwise = do
      let logPath = realLogPath u outDir
          args = T.unpack (realWorkDir u) : map T.unpack (ruArch u : ruArgs u <> [T.pack outDir])
      (ec, _, _) <- readProcess (proc "bash" (pgclDriverPath : args))
      exists <- doesFileExist (T.unpack logPath)
      body <- if exists then T.pack <$> readFile (T.unpack logPath) else pure ""
      pure (verdictFrom ec body, logPath)
  where
    verdictFrom ec t = case classifyCellLog t of
      "skipped" -> "skipped"
      "passed" | ec == ExitSuccess -> "passed"
      _ -> "failed"

-- ---------------------------------------------------------------------------
-- The journaled attempt
-- ---------------------------------------------------------------------------

-- | One cell attempt as journaled data: the exact command planned, the
-- mode, the verdict (from the log in live mode; @planned@ offline), and
-- where the log lives.
data RealAttempt = RealAttempt
  { raN :: !Int,
    raCommand :: !Text,
    raMode :: !Text,
    raVerdict :: !Text,
    raLog :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.ToJSON, Aeson.FromJSON)

-- | The run step's action: plan always, execute only when live. Offline the
-- command is recorded and nothing runs — the plan is the product.
realAttemptRecord ::
  (IOE :> es) =>
  RealUnit ->
  FilePath ->
  RealMode ->
  Int ->
  Eff es RealAttempt
realAttemptRecord u outDir mode n = do
  let cmd = commandText u outDir
  case mode of
    RealPlan ->
      pure (RealAttempt n cmd "plan" "planned (offline; set REAL_LIVE=1)" "")
    RealLive -> do
      er <- liftIO (E.try (runRealUnit u outDir))
      pure $ case er of
        Left (_ :: IOError) -> RealAttempt n cmd "live" "failed (execution error)" ""
        Right (verdict, logP) -> RealAttempt n cmd "live" verdict logP

-- ---------------------------------------------------------------------------
-- The workflow and its registry
-- ---------------------------------------------------------------------------

-- | The cell workflow: journal the exact command, run (or refuse), done.
-- No retries at this rung: a cell is minutes-to-hours, and re-running a
-- failed cell is an operator decision informed by the journaled log path.
realCellWorkflow ::
  (KeiroWorkflow.Workflow :> es, IOE :> es, KirokuStoreResource :> es, Store :> es) =>
  RealUnit ->
  RealMode ->
  FilePath ->
  Eff es Text
realCellWorkflow u mode outDir = do
  _plan <- step (StepName "verify-plan") (pure (commandText u outDir))
  attempt <- step (StepName "run-cell") (realAttemptRecord u outDir mode 1)
  pure (raVerdict attempt)

-- | The workflow id embeds the cell key and the run tag, separated by @__@
-- (which cell keys cannot contain — keys use @/@ and @@@): the id carries
-- the unit's identity, so resume re-derives the unit from the journal's
-- own id, exactly like the matrix registry.
realWorkflowIdTagged :: RealUnit -> Text -> WorkflowId
realWorkflowIdTagged u tag =
  WorkflowId ("wf:real-cell-campaign-" <> realCellKey u <> "__" <> tag)

-- | The unit a workflow id names.
realCellFromWf :: WorkflowId -> Maybe RealUnit
realCellFromWf (WorkflowId t) = do
  rest <- T.stripPrefix "wf:real-cell-campaign-" t
  let (key, _tag) = T.breakOn "__" rest
  (proj, rest2) <- Just (T.breakOn "/" key)
  (arch, rest3) <- Just (T.breakOn "@" (T.drop 1 rest2))
  let cfg = T.drop 1 rest3
  pure $ unitFor proj arch cfg

unitFor :: Text -> Text -> Text -> RealUnit
unitFor "telix" _ _ =
  RealUnit "telix" "host-verify" "host" "verify" []
unitFor proj arch cfg =
  RealUnit
    { ruProject = proj,
      ruKind = "qemu-boot-matrix",
      ruArch = arch,
      ruConfig = cfg,
      ruArgs = [cfg]
    }

realWorkflowName :: WorkflowName
realWorkflowName = WorkflowName "real-cell-campaign"

realRegistry ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es) =>
  RealMode ->
  FilePath ->
  WorkflowRegistry es
realRegistry mode outDir =
  Map.fromList
    [ ( realWorkflowName,
        WorkflowDef $ \wid ->
          case realCellFromWf wid of
            Nothing ->
              error
                ( "realRegistry: malformed real workflow id "
                    <> T.unpack (T.take 96 (idTextOf wid))
                )
            Just u -> realCellWorkflow u mode outDir
      )
    ]
  where
    idTextOf (WorkflowId t) = t

-- | All journaled real attempts (from @run-cell@ steps) — the same decode
-- pattern Campaign.Matrix uses for its boot-stress steps.
realAttemptsOf :: [WorkflowJournalEvent] -> [RealAttempt]
realAttemptsOf = mapMaybeA extract
  where
    extract = \case
      StepRecorded name result _ | name == "run-cell" ->
        case Aeson.fromJSON result of
          Aeson.Success ra -> Just ra
          Aeson.Error _ -> Nothing
      _ -> Nothing

mapMaybeA :: (a -> Maybe b) -> [a] -> [b]
mapMaybeA f = foldr step' []
  where
    step' x acc = case f x of
      Just v -> v : acc
      Nothing -> acc
