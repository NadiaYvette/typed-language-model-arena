{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The dispatch shape over the /real/ verification processes: pgcl's
-- (arch × config) kernel boot matrix and telix's host-side verification.
--
-- The toy matrix (@Campaign.Matrix@) proved the shape on synthetic stages;
-- this module points the same shape at the processes that actually exist:
--
--   * A pgcl cell is @matrix-driver-all.sh LINUX_DIR ARCH CONFIG OUTDIR@ — one
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
    PgclArchRow (..),
    pgclArchRowsFromDriver,
    realWorkflowIdTagged,
    realCellFromWf,     classifyCellLog,
     classifyCellLogArch,
     verdictFrom,
     knownFailuresFor,
    -- * Scheduling from memory
    RealScheduleEntry (..),
    RealSchedule (..),
    CellEvidence (..),
    evidenceFromLessons,
    scheduleFromEvidence,
    lessonAdviceFor,
    -- * Execution
    RealMode (..),
    realModeFromEnv,
    realBudgetFromEnv,
    budgetedMode,
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
import Data.Maybe (mapMaybe)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import Control.Exception qualified as E
import Data.Time (NominalDiffTime, diffUTCTime, getCurrentTime)
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
import Text.Read (readMaybe)

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

-- | One parsed row of the driver's per-arch @case@ block: the arch key,
-- the cross toolchain prefix (@""@ = host compiler), and the emulator
-- binary (the first word of the driver's @QEMU=@ column).
data PgclArchRow = PgclArchRow
  { paArch :: !Text,
    paToolchain :: !Text,
    paQemuBin :: !Text
  }
  deriving stock (Eq, Show)

-- | Parse the driver's per-arch vocabulary straight out of 'pgclDriverPath'
-- — /the/ source of truth. The live alpha batch failed fast on
-- @ERROR: unknown arch alpha@ because this module carried hand-mirrored
-- tables with arches the driver does not speak; the mirror drifted, the
-- driver refused, and the journal caught it. Parsing the driver itself
-- makes drift impossible: discovery can only plan arches the driver
-- actually accepts. Each case row is a line like
-- @  aarch64)  LA=arm64;  CC=aarch64-linux-gnu-;  ...  QEMU="qemu-system-aarch64 ...";  ...;;@
-- parsed by shape: an @\<arch\>)@ head, a @CC=@ field before the next @;@,
-- a first word inside @QEMU="@. Nothing else in the script has that shape,
-- and keys are restricted to @[@a-z0-9-@]@ so the @*)@ catch-all and bash
-- constructs never match. A missing or row-less driver plans no pgcl cells.
pgclArchRowsFromDriver :: FilePath -> IO [PgclArchRow]
pgclArchRowsFromDriver path = do
  exists <- doesFileExist path
  if not exists
    then pure []
    else do
      body <- TIO.readFile path
      -- First occurrence per arch wins: the driver's opening case block is
      -- the canonical per-arch table; later case blocks re-use keys like
      -- @ppc64)@ as multi-line specialization arms, and only the first
      -- row carries the full LA/CC/QEMU columns.
      pure (List.nubBy (\a b -> paArch a == paArch b) [row | l <- T.lines body, Just row <- [parseArchRow (T.stripStart l)]])
  where
    parseArchRow l = do
      let (key, rest) = T.breakOn ")" l
          keyT = T.strip key
      guardKey keyT
      after <- T.stripPrefix ")" rest
      let fields = map T.strip (T.splitOn ";" after)
          ccOf = case [T.drop 3 f | f <- fields, "CC=" `T.isPrefixOf` f] of
            -- the driver writes the host compiler as CC="" — quotes out
            (v : _) -> T.dropAround (== '"') (T.strip v)
            [] -> ""
          qemuOf = case [T.drop 5 f | f <- fields, "QEMU=" `T.isPrefixOf` f] of
            (v : _) ->
              T.takeWhile (\c -> c /= '"' && c /= ' ') (T.dropWhile (== '"') (T.strip v))
            [] -> ""
      pure (PgclArchRow keyT ccOf qemuOf)
    guardKey k
      | T.null k = Nothing
      -- underscore lives in real arch keys (x86_64, loongarch64 has none
      -- but riscv32's neighbors do); the class stays narrow enough that
      -- the @*)@ catch-all and bash constructs never match.
      | T.all (\c -> ('a' <= c && c <= 'z') || ('0' <= c && c <= '9') || c == '-' || c == '_') k = Just ()
      | otherwise = Nothing

pgclConfigCatalog :: [Text]
pgclConfigCatalog = ["mainline", "0", "2", "4", "6"]

-- | Mirror of matrix-driver-all.sh's sh4 toolchain fallback: probe the
-- x-tools cross-gcc dirs the driver's own PATH loop searches.
sh4XToolsProbe :: Text -> Text
sh4XToolsProbe cc =
  "for d in \"$HOME\"/x-tools/*/sh4-linux/bin \"$HOME\"/x-tools/sh-sh4--*/bin; do\n\
  \  [ -x \"$d/" <> cc <> "gcc\" ] && exit 0\ndone; exit 1"

-- | @command -v@ probe; False on lookup failure.
availableOnPath :: Text -> IO Bool
availableOnPath bin = bashProbe ("command -v " <> bin)

-- | @bash -c@ probe; False on any nonzero exit.
bashProbe :: Text -> IO Bool
bashProbe snippet = do
  (ec, _, _) <- readProcess (proc "bash" ["-c", T.unpack snippet])
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
  archRows <- pgclArchRowsFromDriver pgclDriverPath
  hasPgclTree <- doesDirectoryExist "/home/nyc/src/linux"
  hasMainlineTree <- doesDirectoryExist "/home/nyc/src/linux-mainline"
  archAvail <-
    mapM
      ( \row -> do
          ccOk <- case paToolchain row of
            "" -> availableOnPath "gcc"
            cc -> do
              ok <- availableOnPath (cc <> "gcc")
              -- matrix-driver-all.sh prepends @$HOME/x-tools@ cross-gcc dirs
              -- to PATH for sh4 only; mirror that fallback verbatim so
              -- discovery plans what the driver can actually run (the sh4
              -- toolchain is not on the default PATH).
              if ok || paArch row /= "sh4"
                then pure ok
                else bashProbe (sh4XToolsProbe cc)
          qemuOk <- availableOnPath (paQemuBin row)
          pure (paArch row, ccOk && qemuOk)
      )
      archRows
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

-- Ground-truth path the discovery reads: the full-catalog driver. The
-- reduced matrix-driver.sh speaks only 10 of the 20 arches the historical
-- matrix ran; -all is the driver the 80-cell campaigns actually used.
pgclDriverPath :: FilePath
pgclDriverPath = "/home/nyc/src/pgcl/matrix-driver-all.sh"

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
-- at all is a boot/timeout failure. Returns @passed@ / @failed@ /
-- @passed-waived@ / @skipped@. The waived verdict applies only when /every/
-- failure the log names is on the arch's documented known-failure baseline
-- (see 'knownFailuresFor') — any unnamed or novel failure still fails the
-- cell. Not arch-scoped for @host-verify@ units, whose logs carry no LTP.
classifyCellLogArch :: Text -> Text -> Text
classifyCellLogArch arch logText
  | any (\l -> "SKIP: no " `T.isPrefixOf` T.strip l) (T.lines logText) = "skipped"
  | Just fails <- lastSubtotalFails logText =
      if fails == 0 && not (kernelWarned logText) then "passed"
      else if fails > 0 && waivedByBaseline fails then "passed-waived" else "failed"
  | otherwise = "failed"
  where
    waivedByBaseline n = case ltpFailList logText of
      Just names ->
        not (null names)
          && names == List.nub names
          && length names == n
          && all (`elem` knownFailuresFor arch) names
      Nothing -> False
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
    -- The init's compact fail list — @LTP FAIL LIST: name1 name2 …@ — printed
    -- exactly when /tmp/ltp-fail-names.txt is non-empty, so presence of the
    -- line and of the subtotal are the same condition; the name multiset must
    -- then match the subtotal's failed count.
    ltpFailList t = case mapMaybe ltpNames (T.lines t) of
      [] -> Nothing
      lists -> Just (concat lists)
    -- Console lines carry kernel timestamp prefixes ("[   48.227898]   LTP
    -- FAIL LIST: …"), so anchor on the marker as a substring, not a line
    -- prefix — the same discipline that lets the word-based subtotal scan
    -- survive the prefixes.
    ltpNames l = case T.breakOn "LTP FAIL LIST:" l of
      (_, rest) | not (T.null rest) -> Just (filter (not . T.null) (T.words (T.drop (T.length ("LTP FAIL LIST:" :: Text)) rest)))
      _ -> Nothing

-- | Documented known-failure baselines, per arch: test names the project's
-- own repeated boots show failing identically on the /current/ stack — the
-- kernel-CI /known-fails/ pattern. A cell whose failures are exactly these
-- names (all named, none extra, none duplicated) is not a regression: its
-- verdict is @passed-waived@, priced and journaled like a pass.
--
-- loongarch64 evidence: three consecutive hand-boots (2026-09-18, 5.15-tree
-- defconfig + current initramfs) fail the identical set @fork07 fork09
-- fork13 mmap3@ — fork/mmap timing-stress tests under la464 emulation (the
-- init itself notes fork-heavy tests trip LTP alarms on slow QEMU targets).
-- The April matrix's musl-SIGSEGV trio (madvise12, mmap18, munmap01) is
-- /history/: those were musl bugs, since fixed — a baseline must track the
-- stack it judges, not its archive. Empty for arches with no documented
-- baseline: their cells verdict strictly.
knownFailuresFor :: Text -> [Text]
knownFailuresFor "loongarch64" = ["fork07", "fork09", "fork13", "mmap3"]
knownFailuresFor _ = []

-- | The un-scoped classifier kept for callers without an arch in hand
-- (probe scripts, log archaeology): baseline waiving disabled.
classifyCellLog :: Text -> Text
classifyCellLog = classifyCellLogArch ""

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

-- | @REAL_LIMIT=@\<n\> — the pacing budget for a live run: only the first
-- @n@ cells in schedule order execute; the rest plan, journaling
-- @planned (beyond REAL_LIMIT=@\<n\>@)@ — an honest, machine-parseable
-- account, not a fake verdict. Absent means no limit; @0@ is the
-- deliberate dry-run (gate lifted, nothing executes). A /present but
-- invalid/ value is an operator error and fails loudly — a budget that
-- silently meant "unlimited" would fail open, and the whole point of a
-- budget is to fail closed.
realBudgetFromEnv :: IO (Maybe Int)
realBudgetFromEnv = do
  v <- lookupEnv "REAL_LIMIT"
  case v of
    Nothing -> pure Nothing
    Just s -> case readMaybe (T.unpack (T.strip (T.pack s))) of
      Just n | n >= 0 -> pure (Just n)
      _ ->
        error
          ( "REAL_LIMIT=" <> s <> " is not a non-negative integer"
              <> " (live cells this invocation; 0 = plan only)"
          )

-- | The mode one cell runs under, given the run's mode, the budget, and
-- the cell's schedule rank (1-indexed, from 'seRank'). Live beyond the
-- budget would defeat the budget's point; plan inside it would defeat
-- the run's. A plan run stays plan everywhere — the budget only
-- distributes an already-lifted gate.
budgetedMode :: RealMode -> Maybe Int -> Int -> RealMode
budgetedMode RealPlan _ _ = RealPlan
budgetedMode RealLive mlim rank = case mlim of
  Just n | rank > n -> RealPlan
  _ -> RealLive

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

-- | The verdict gate for a driver-run pgcl cell: the log classifier (which
-- owns ground truth about the /guest/) crossed with the driver's own exit
-- code (which owns whether the /harness/ completed: rc=0 means the guest
-- powered off cleanly; rc=124 is the boot timeout). Kept top-level and
-- exported so the CLASSIFY probe exercises the exact pipeline act 23 runs —
-- when this gate learned about @passed-waived@, its last consumer learned
-- at the same time.
verdictFrom :: ExitCode -> Text -> Text -> Text
verdictFrom ec arch t = case classifyCellLogArch arch t of
  "skipped" -> "skipped"
  "passed" | ec == ExitSuccess -> "passed"
  -- A baseline-waived cell is priced and journaled like a pass — but
  -- only when the guest actually exited cleanly (rc=0, the poweroff
  -- completed); a timeout wearing a waived log is still a failure.
  "passed-waived" | ec == ExitSuccess -> "passed-waived"
  _ -> "failed"

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
      pure (hostVerdictFrom ec body, logPath)
  | otherwise = do
      let logPath = realLogPath u outDir
          args = T.unpack (realWorkDir u) : map T.unpack (ruArch u : ruArgs u <> [T.pack outDir])
      (ec, _, _) <- readProcess (proc "bash" (pgclDriverPath : args))
      exists <- doesFileExist (T.unpack logPath)
      body <- if exists then T.pack <$> readFile (T.unpack logPath) else pure ""
      pure (verdictFrom ec (ruArch u) body, logPath)

-- | A make target has no subtotal banners: make's exit code /is/ the
-- verdict (it propagates cargo and fmt failures), and the @verify@ target's
-- own @Telix-side checks passed.@ marker — printed only after both
-- prerequisites succeeded — corroborates a /complete/ run. Success without
-- the marker is conservatively failed (a truncated or redefined target);
-- the journaled log tells the operator which.
hostVerdictFrom :: ExitCode -> Text -> Text
hostVerdictFrom ExitSuccess body
  | "Telix-side checks passed." `T.isInfixOf` body = "passed"
  | otherwise = "failed"
hostVerdictFrom _ _ = "failed"

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
    raLog :: !Text,
    raSeconds :: !(Maybe NominalDiffTime)
    -- ^ Driver-measured wall time of a live run; offline plans carry
    -- @Nothing@. In-band so the lesson line can carry cost, and cost then
    -- feeds the scheduler like any other evidence.
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
  Text ->
  Int ->
  Eff es RealAttempt
realAttemptRecord u outDir mode planWhy n = do
  let cmd = commandText u outDir
  case mode of
    RealPlan ->
      pure (RealAttempt n cmd "plan" ("planned (" <> planWhy <> ")") "" Nothing)
    RealLive -> do
      t0 <- liftIO getCurrentTime
      er <- liftIO (E.try (runRealUnit u outDir))
      t1 <- liftIO getCurrentTime
      let dt = Just (diffUTCTime t1 t0)
      pure $ case er of
        Left (_ :: IOError) -> RealAttempt n cmd "live" "failed (execution error)" "" dt
        Right (verdict, logP) -> RealAttempt n cmd "live" verdict logP dt

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
  Text ->
  FilePath ->
  Eff es Text
realCellWorkflow u mode planWhy outDir = do
  _plan <- step (StepName "verify-plan") (pure (commandText u outDir))
  attempt <- step (StepName "run-cell") (realAttemptRecord u outDir mode planWhy 1)
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
  (RealUnit -> (RealMode, Text)) ->
  FilePath ->
  WorkflowRegistry es
realRegistry modeFor outDir =
  Map.fromList
    [ ( realWorkflowName,
        WorkflowDef $ \wid ->
          case realCellFromWf wid of
            Nothing ->
              error
                ( "realRegistry: malformed real workflow id "
                    <> T.unpack (T.take 96 (idTextOf wid))
                )
            Just u -> case modeFor u of
              (m, planWhy) -> realCellWorkflow u m planWhy outDir
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

-- ---------------------------------------------------------------------------
-- Scheduling from memory: evidence-ordered cells
-- ---------------------------------------------------------------------------

-- | What memory knows (so far) about one cell.
data CellEvidence = CellEvidence
  { ceKey :: !Text,
    ceVerdict :: !VerdictClass,
    ceSeconds :: !(Maybe Double),
    ceAttempts :: !Int
  }
  deriving stock (Eq, Show)

-- | The three evidence classes a cell can have. Constructor order is the
-- severity order: @max@ /derives/ it, so the worst outcome wins when
-- lessons merge (passed < unknown < failed).
data VerdictClass = VCPassed | VCUnknown | VCFailed
  deriving stock (Eq, Ord, Show)

-- | Fold lessons into per-cell evidence: only the worst outcome (failed >
-- unknown > passed) and the slowest run survive — the scheduler plans for
-- the worst thing the cell has ever done, at its slowest.
evidenceFromLessons :: [Text] -> Map.Map Text CellEvidence
evidenceFromLessons = foldr step Map.empty
  where
    step lesson acc = case parseAdvice lesson of
      Nothing -> acc
      Just (key, vc, msecs) ->
        Map.insertWith merge key (CellEvidence key vc msecs 1) acc
      where
        merge new old =
          CellEvidence
            { ceKey = ceKey old,
              ceVerdict = max (ceVerdict new) (ceVerdict old),
              ceSeconds = maxMay (ceSeconds new) (ceSeconds old),
              ceAttempts = ceAttempts old + ceAttempts new
            }
    maxMay (Just a) (Just b) = Just (max a b)
    maxMay x _ = x

-- | Parse one lesson's advice into evidence. The lesson format is the one
-- the act writes: @cell <key> [live] <verdict>[ (Ns); …]@. The bracketed
-- segment is the /mode/; the verdict text follows it. A prefix is not
-- enough — @pgcl/arm@ must not match @pgcl/arm-lpae@ — so the key is the
-- token between @cell @ and @ [@. Only @live@ attempts count as evidence:
-- a plan knows nothing about the cell.
parseAdvice :: Text -> Maybe (Text, VerdictClass, Maybe Double)
parseAdvice lesson = do
  rest0 <- T.stripPrefix "cell " lesson
  let (key, rest1) = T.breakOn " [" rest0
  rest1' <- T.stripPrefix " [" rest1
  let (mode, rest2) = T.breakOn "]" rest1'
      rest3 = T.stripStart (T.drop 1 rest2)
      vc = classOf rest3
      -- The measured duration, if present, is a parenthesized "(Ns)"
      -- /after/ the verdict words ("failed (execution error)" has no
      -- trailing 's' count and won't parse as one).
      beforeSemi = T.takeWhile (/= ';') rest3
      secs = case T.breakOn "(" beforeSemi of
        (_, parenRest) | "(" `T.isPrefixOf` parenRest ->
          readDouble (T.takeWhile (/= 's') (T.drop 1 parenRest))
        _ -> Nothing
  if mode == "live" then Just (key, vc, secs) else Nothing
  where
    classOf v
      | "failed" `T.isPrefixOf` v = VCFailed
      | "passed" `T.isPrefixOf` v = VCPassed
      | otherwise = VCUnknown
    readDouble t = case reads (T.unpack t) of
      [(d, "")] -> Just (d :: Double)
      _ -> Nothing

-- | One row of the journaled schedule: the unit, where it sits, and why.
-- The rationale is /data/, not prose — it journals the scheduler's inputs
-- alongside its output.
data RealScheduleEntry = RealScheduleEntry
  { seUnit :: !RealUnit,
    seRank :: !Int,
    seWhy :: !Text
  }
  deriving stock (Eq, Show)

-- | The schedule: ordered rows plus the evidence map that ordered them.
data RealSchedule = RealSchedule
  { schRows :: ![RealScheduleEntry],
    schEvidence :: !(Map.Map Text CellEvidence)
  }
  deriving stock (Eq, Show)

-- | Order cells by evidence: failed first (reproduce while fresh), then
-- unknown, then passed — cheapest-first within each tier. A cell with no
-- evidence is /unknown/, not /passed/: absence of failure is not success.
-- Within a tier, cost orders only among cells that /have/ measured cost
-- (never-run and unknown-cost cells sort by key for stability).
scheduleFromEvidence :: [RealUnit] -> Map.Map Text CellEvidence -> RealSchedule
scheduleFromEvidence units ev =
  RealSchedule
    { schRows = zipWith (\n (u, why) -> RealScheduleEntry u n why) [1 ..] ordered,
      schEvidence = ev
    }
  where
    ordered = concat [tierOf VCFailed, tierOf VCUnknown, tierOf VCPassed]
    tierOf vc = List.sortOn (\(u, _) -> (costOf u, realCellKey u)) [(u, whyOf u) | u <- units, tierClassOf u == vc]
    tierClassOf u = maybe VCUnknown ceVerdict (Map.lookup (realCellKey u) ev)
    costOf u = case Map.lookup (realCellKey u) ev >>= ceSeconds of
      Just s -> (0, s)
      Nothing -> (1, 0)
    whyOf u = case Map.lookup (realCellKey u) ev of
      Nothing -> "no evidence yet"
      Just e ->
        (case ceVerdict e of
           VCFailed -> "worst outcome failed"
           VCUnknown -> "unclassified"
           VCPassed -> "worst outcome passed")
          <> (case ceSeconds e of
                Just s -> ", worst run " <> T.pack (showR1 s) <> "s"
                Nothing -> "")
          <> (if ceAttempts e > 1 then ", " <> T.pack (show (ceAttempts e)) <> " live runs" else "")

-- | One decimal place, without pulling in printf formatting.
showR1 :: Double -> String
showR1 x = show (fromIntegral (round (x * 10) :: Int) / 10 :: Double)

-- | The lesson line the act writes after a live run — exactly the format
-- 'evidenceFromLessons' parses back. Duration in-band so the scheduler
-- sees cost without reading journals.
lessonAdviceFor :: RealUnit -> Text -> Maybe NominalDiffTime -> Text -> Text
lessonAdviceFor u verdict msecs logPath =
  "cell "
    <> realCellKey u
    <> " [live] "
    <> verdict
    <> maybe "" (\d -> " (" <> T.pack (showR1 (realToFrac d)) <> "s)") msecs
    <> "; log at "
    <> logPath
