{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The campaign's hands: how a journaled verdict touches the world.
--
-- Every repair so far lived only in a keiro journal — the campaign decided
-- well but touched nothing. This module is the boundary layer, built on one
-- safety rule: /the parent checkouts are never modified/. All work happens
-- in a @git worktree@ per project, pinned to a dedicated campaign branch,
-- under @\/tmp\/campaign-worktrees\/\<project\>@:
--
--   1. 'ensureCampaignWorktree' — idempotent: add the worktree on first
--      landing, reuse it afterwards (a replayed or re-run step sees the
--      same state either way, which is exactly what step durability
--      requires).
--   2. 'applyRepairInWorktree' — write the repaired bytes over the file.
--   3. 'verifyInWorktree' — run the /real/ oracle against the file as it
--      now exists in the worktree: the check the journal recorded is
--      re-derived from disk, not trusted.
--   4. 'commitLanding' — commit on the campaign branch. Idempotent: if the
--      exact repair is already the committed state (HEAD content equals the
--      repair), the commit is a no-op.
--
-- Nothing here is git-fancy: four @git@ invocations, all read-only against
-- the parent. A crash between any two steps leaves either the old or the
-- new file content — and the next run of the same step makes it converge,
-- because every function is a pure function of (repo, path, repair).
module Campaign.Hands
  ( -- * The landing record
    Landing (..),

    -- * The worktree lifecycle
    campaignBranchFor,
    appPhaseBranchFor,
    campaignWorktreePath,
    ensureCampaignWorktree,
    applyRepairInWorktree,
    verifyInWorktree,
    commitLanding,

    -- * Parent-repo observation (read-only)
    parentRepoPath,
    parentDirtyCount,
    gitCapture,
    git_,
  )
where

import Campaign.Oracle (CellOracle (..))
import Control.Monad (unless)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Process.Typed (proc, readProcess, runProcess_)
import Toy.Fixer.Domain (Diagnostic (..), Source (..), SourcePath)

-- | One landed repair, as the workflow returns it: everything the scoreboard
-- (and a human reviewing the branch) wants to know.
data Landing = Landing
  { landProject :: !Text,
    landPath :: !SourcePath,
    landWorktree :: !FilePath,
    landBranch :: !Text,
    landCommit :: !Text,
    landDiagnostics :: ![Diagnostic]
  }
  deriving stock (Eq, Show)

-- | The campaign branch: one per project, never @main@/@master@, so a human
-- reviewing the project sees exactly the campaign's work as a reviewable
-- diff against the default branch.
campaignBranchFor :: Text -> Text
campaignBranchFor _proj = "campaign/unused-imports"

-- | The application phase's branch: one campaign run, one reviewable branch,
-- per project — the same convention as act 18's per-run Mercury branches,
-- so every run replays reviewably and nothing mixes.
appPhaseBranchFor :: Text -> Text -> Text
appPhaseBranchFor runTag _proj = "campaign/app-" <> runTag

-- | Where a project's worktree for one campaign branch lives: one worktree
-- per (project, branch), so each campaign concept lands on its own isolated
-- working copy and no branch switching is ever needed.
campaignWorktreePath :: Text -> Text -> FilePath
campaignWorktreePath proj branch =
  "/tmp/campaign-worktrees" </> T.unpack proj </> T.unpack (T.replace "/" "-" branch)

worktreeExists :: FilePath -> IO Bool
worktreeExists = doesDirectoryExist

-- | The parent checkout, read-only: worktrees are /added/ from it.
parentRepoPath :: Text -> FilePath
parentRepoPath proj = "/home/nyc/src" </> T.unpack proj

-- | Run @git@ in a directory, discarding stdout, failing on exit code.
git_ :: FilePath -> [String] -> IO ()
git_ dir args = runProcess_ (proc "git" ("-C" : dir : args))

-- | Run @git@ in a directory, capturing trimmed stdout.
gitCapture :: FilePath -> [String] -> IO Text
gitCapture dir args = do
  (exitCode, out, err) <- readProcess (proc "git" ("-C" : dir : args))
  if exitCode == ExitSuccess
    then pure (T.strip (TL.toStrict (TLE.decodeUtf8 out)))
    else
      ioError . userError $
        "git "
          <> unwords args
          <> " failed in "
          <> dir
          <> ": "
          <> T.unpack (TL.toStrict (TLE.decodeUtf8 err))

-- | Idempotently ensure the project's worktree for one campaign branch
-- exists. First call adds it (creating the branch from the parent's HEAD if
-- the branch doesn't exist yet); later calls reuse it. Git refuses to re-add
-- an existing worktree path, so the happy path on re-run is the exists-check
-- — same observable state, no error.
ensureCampaignWorktree :: Text -> Text -> IO FilePath
ensureCampaignWorktree proj branch = do
  let wt = campaignWorktreePath proj branch
      parent = parentRepoPath proj
  createDirectoryIfMissing True (takeDirectory wt)
  -- Stale registrations (a deleted worktree directory leaves the branch
  -- "checked out" in git's metadata) would block re-adding; prune first —
  -- it only removes registrations whose directories are gone.
  git_ parent ["worktree", "prune"]
  exists <- worktreeExists wt
  unless exists $ do
    branchExists <- do
      (ec, _, _) <- readProcess (proc "git" ["-C", parent, "rev-parse", "--verify", "--quiet", T.unpack branch])
      pure (ec == ExitSuccess)
    if branchExists
      then git_ parent ["worktree", "add", wt, T.unpack branch]
      else git_ parent ["worktree", "add", wt, "-b", T.unpack branch]
  pure wt

-- | Write the repaired bytes over the cell's file inside the worktree.
-- The repair is the /complete file/, so converging is simple: reset the file
-- to the branch's committed state first (a crash-retry or replay starts
-- clean), then write. The parent checkout is never consulted for writes.
applyRepairInWorktree :: FilePath -> SourcePath -> Text -> IO ()
applyRepairInWorktree wt path repaired = do
  let fp = wt </> T.unpack path
  git_ wt ["checkout", "--", T.unpack path]
  writeFile fp (T.unpack repaired)

-- | Re-derive the oracle's verdict from the file as it exists on disk in the
-- worktree — the journal said the repair cleared the cell; the disk gets the
-- final word.
verifyInWorktree :: CellOracle -> FilePath -> SourcePath -> IO [Diagnostic]
verifyInWorktree oracle wt path = do
  let fp = wt </> T.unpack path
  ok <- doesFileExist fp
  if not ok
    then ioError (userError ("verifyInWorktree: missing file " <> fp))
    else do
      body <- readFile fp
      pure (oracleCheck oracle path (Source (T.pack body)))

-- | Commit the repair on the campaign branch. Idempotent: if HEAD's content
-- for the file already equals the repair (a re-run after a crash between
-- write and commit, or a replay), nothing is committed and the recorded
-- commit is the existing one.
commitLanding :: FilePath -> SourcePath -> Text -> IO Text
commitLanding wt path repaired = do
  headContent <- gitCapture wt ["show", "HEAD:" <> T.unpack path]
  if headContent == T.strip repaired
    then gitCapture wt ["rev-parse", "--short", "HEAD"]
    else do
      git_ wt ["add", T.unpack path]
      git_ wt ["commit", "-m", T.unpack (commitMessage path)]
      gitCapture wt ["rev-parse", "--short", "HEAD"]

-- | The parent checkout's dirty-entry count (read-only) — the driver's
-- before/after proof that landings never touch the parent.
parentDirtyCount :: Text -> IO Int
parentDirtyCount proj = do
  out <- gitCapture (parentRepoPath proj) ["status", "--porcelain"]
  pure (length (T.lines out))

commitMessage :: SourcePath -> Text
commitMessage path =
  "campaign: delete unused import(s) in "
    <> path
    <> "\n\nLanded by the shikumi-campaign durable campaign: the cell's repair\nwas proposed by the fixer program, accepted by the deletion-only guard,\nre-verified by the unused-import oracle inside this worktree, and\ncommitted here by a journaled landing step.\n"
