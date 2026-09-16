{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The human merge seam: operator verdicts over landed campaign branches,
-- journaled like every other campaign event.
--
-- The application phase lands repairs on @campaign\/\<run\>@ branches in git
-- worktrees, and stops there — on purpose. Merging is a human decision. This
-- module is the boundary layer for that decision:
--
--   * 'listReviewBranches' — every @campaign\/*@ branch of a project with
--     its ahead-count and merged-ness, so a verdict is never guessed from
--     memory.
--   * 'approveBranch' — re-verify every file the branch touched with the
--     real oracle against the /branch's own bytes/ (read from its worktree),
--     then merge @--no-ff@ into the project's default branch /in the parent
--     checkout/, then delete the review branch and its worktree. The parent
--     checkout is where the landing phase never wrote; an explicit human
--     approval is precisely the sanction that lifts that rule, and a
--     merge whose working tree is clean leaves no dirty entries — the
--     dirty-count invariant still observable, now across the merge too.
--   * 'rejectBranch' — delete the review branch and its worktree. The
--     reason lives in the kioku session, not in git history (a rejected
--     branch leaves no commits to annotate).
--
-- Every function is a pure function of (repo, branch) plus the oracle, so a
-- re-run converges the way the landing layer's steps do.
module Campaign.Review
  ( -- * Branch inventory
    ReviewBranch (..),
    listReviewBranches,
    defaultBranchOf,

    -- * The verdicts
    approveBranch,
    rejectBranch,
    ApprovalOutcome (..),
  )
where

import Control.Exception (try)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process.Typed (proc, readProcess)

import Campaign.Hands (campaignWorktreePath, gitCapture, parentRepoPath)
import Campaign.Oracle (CellOracle (..))
import Toy.Fixer.Domain (Source (..), showDiagnostic)

-- | One reviewable branch of one project, as 'listReviewBranches' reports it.
data ReviewBranch = ReviewBranch
  { rbProject :: !Text,
    rbBranch :: !Text,
    rbCommitsAhead :: !Int,
    rbMerged :: !Bool
  }
  deriving stock (Eq, Show)

-- | Run git in a directory, capturing trimmed stdout; fail with stderr
-- ('gitCapture' does both — re-bound here for a local name).
gitIn :: FilePath -> [String] -> IO Text
gitIn = gitCapture

-- | A git call whose failure is a /verdict/, not a crash: returns True iff
-- the command succeeded (exit 0). Used for @merge-base --is-ancestor@ and
-- the @--check@-style probes whose exit code /is/ the answer.
gitProbe :: FilePath -> [String] -> IO Bool
gitProbe dir args = do
  (ec, _, _) <- readProcess (proc "git" ("-C" : dir : args))
  pure (ec == ExitSuccess)

-- | The project's default branch — the merge target of an approval. Read
-- from the parent checkout: @origin/HEAD@ when the clone records it (works
-- even from a detached checkout, e.g. a vendored repo pinned to a release
-- tag), otherwise the currently checked-out branch.
defaultBranchOf :: Text -> IO Text
defaultBranchOf proj = do
  let parent = parentRepoPath proj
      fromOrigin = gitIn parent ["rev-parse", "--abbrev-ref", "origin/HEAD"]
      fromHead = gitIn parent ["symbolic-ref", "--short", "HEAD"]
  fromOriginOr <- try fromOrigin :: IO (Either IOError Text)
  case fromOriginOr of
    Right b | b /= "origin/HEAD" -> pure (T.strip b)
    _ -> T.strip <$> fromHead

-- | Every @campaign\/*@ branch of a project, with how far ahead of the
-- default branch it is and whether git already considers it merged.
listReviewBranches :: Text -> IO [ReviewBranch]
listReviewBranches proj = do
  let parent = parentRepoPath proj
  def <- defaultBranchOf proj
  branchLines <- filter (not . T.null) . T.lines <$> gitIn parent ["branch", "--format=%(refname:short)"]
  let campaignBranches = [b | b <- branchLines, "campaign/" `T.isPrefixOf` b]
  mapM (meta def) campaignBranches
  where
    meta def b = do
      ahead <- do
        out <- gitIn (parentRepoPath proj) ["rev-list", "--count", T.unpack def <> ".." <> T.unpack b]
        pure $ case reads (T.unpack (T.strip out)) :: [(Int, String)] of
          [(n, _)] -> n
          _ -> 0
      merged <- gitProbe (parentRepoPath proj) ["merge-base", "--is-ancestor", T.unpack b, T.unpack def]
      pure (ReviewBranch proj b ahead merged)

-- | The result of an approval: the merge commit (short hash; empty when the
-- gate refused), the files the branch touched, and the pre-merge
-- verification's diagnostics (empty = clean).
data ApprovalOutcome = ApprovalOutcome
  { aoMergeCommit :: !Text,
    aoFiles :: ![Text],
    aoDiagnostics :: ![Text]
  }
  deriving stock (Eq, Show)

-- | Approve one review branch: re-verify every touched file with the real
-- oracle against the /branch's own bytes/ (read from its worktree — the
-- parent checkout may carry the very defects this branch fixes), then merge
-- @--no-ff@ into the project's default branch in the parent checkout, then
-- delete the review branch and its worktree. Diagnostics at the gate mean
-- /no merge/ — the outcome reports them instead.
approveBranch :: CellOracle -> Text -> Text -> IO ApprovalOutcome
approveBranch oracle proj branch = do
  def <- defaultBranchOf proj
  let parent = parentRepoPath proj
  -- The branch's worktree must exist (it is where the branch's bytes live).
  gitIn parent ["worktree", "prune"]
  hasWt <- doesDirectoryExist (campaignWorktreePath proj branch)
  if not hasWt
    then pure (ApprovalOutcome "" [] ["branch worktree missing: " <> T.pack wt <> " — nothing to verify, nothing merged"])
    else do
      -- The parent must be on the default branch with a clean tree: the
      -- merge is a ref transaction on top of it, and the dirty-count
      -- invariant must hold before and after.
      dirty <- gitIn parent ["status", "--porcelain"]
      if not (T.null (T.strip dirty))
        then pure (ApprovalOutcome "" [] ["parent checkout dirty — refusing to merge; clean it first"])
        else do
          -- A detached parent (a vendored repo pinned to a release tag, say)
          -- has no branch to merge into; merging there would strand commits
          -- on detached HEAD. The operator checks out the default branch.
          onBranch <- gitProbe parent ["symbolic-ref", "--quiet", "HEAD"]
          if not onBranch
            then
              pure
                ApprovalOutcome
                  { aoMergeCommit = "",
                    aoFiles = [],
                    aoDiagnostics =
                      [ "parent checkout is detached (no branch checked out) — "
                          <> "nothing to merge into; check out the default branch first"
                      ]
                  }
            else do
              files <-
                filter (not . T.null) . map T.strip . T.lines
                  <$> gitIn parent ["diff", "--name-only", T.unpack def <> "..." <> T.unpack branch]
              diags <- fmap concat . mapM (verifyOne wt) $ files
              if not (null diags)
                then pure (ApprovalOutcome "" files diags)
                else do
                  -- HEAD is the merge target (the parent is on a branch and
                  -- clean — checked above). origin/<def> is a remote-tracking
                  -- ref and does NOT move on merge, so the advance check
                  -- below must read HEAD, never the tracking ref.
                  before <- gitIn parent ["rev-parse", "--short", "HEAD"]
                  -- Converge on re-runs: if the branch is already an
                  -- ancestor of HEAD (a previous approval merged it, or the
                  -- operator merged by hand), the verdict is plain "merged".
                  already <- gitProbe parent ["merge-base", "--is-ancestor", T.unpack branch, "HEAD"]
                  if already
                    then do
                      gitIn parent ["worktree", "remove", "--force", wt]
                      gitIn parent ["branch", "-d", T.unpack branch]
                      pure (ApprovalOutcome before files [])
                    else do
                      mergedOr <-
                        try
                          ( gitIn
                              parent
                              [ "merge",
                                "--no-ff",
                                "--no-edit",
                                "-m",
                                T.unpack (mergeMsg branch),
                                T.unpack branch
                              ]
                          ) :: IO (Either IOError Text)
                      case mergedOr of
                        Left _ -> do
                          -- A conflict leaves the parent's index and worktree
                          -- dirty — the one state the campaign never leaves a
                          -- checkout in. Abort; the branch stays reviewable.
                          _ <- try (gitIn parent ["merge", "--abort"]) :: IO (Either IOError Text)
                          pure
                            ApprovalOutcome
                              { aoMergeCommit = "",
                                aoFiles = files,
                                aoDiagnostics =
                                  [ "merge aborted — git reported a conflict between "
                                      <> branch
                                      <> " and "
                                      <> def
                                      <> "; the parent checkout is restored, the branch stays reviewable"
                                  ]
                              }
                        Right out -> do
                          mc <- gitIn parent ["rev-parse", "--short", "HEAD"]
                          if mc == before
                            then
                              -- "Already up to date": the branch's content is
                              -- in HEAD even though its commits are not (a
                              -- re-fix of a file another branch already
                              -- fixed). Content-wise idempotent: retire.
                              if "Already up to date" `T.isInfixOf` out
                                then do
                                  gitIn parent ["worktree", "remove", "--force", wt]
                                  gitIn parent ["branch", "-d", T.unpack branch]
                                  pure (ApprovalOutcome before files [])
                                else pure (ApprovalOutcome "" files ["merge produced no new commit on the checked-out branch — unexpected; investigate"])
                            else do
                              -- Merged: retire the branch and its worktree. -d
                              -- (not -D) refuses if git disagrees that it merged.
                              gitIn parent ["worktree", "remove", "--force", wt]
                              gitIn parent ["branch", "-d", T.unpack branch]
                              pure (ApprovalOutcome mc files [])
  where
    wt = campaignWorktreePath proj branch
    verifyOne wtPath f = do
      body <- readBranchFile wtPath f
      pure (map showDiagnostic (oracleCheck oracle f (Source body)))
    -- The branch's own bytes, from its worktree on disk — the same bytes
    -- the landing gate verified (the parent checkout may still carry the
    -- very defects this branch fixes).
    readBranchFile wtPath f = do
      let fp = wtPath </> T.unpack f
      ok <- doesFileExist fp
      if ok
        then T.pack <$> readFile fp
        else pure ("<<missing on branch worktree: " <> T.pack fp <> ">>")

-- | Reject one review branch: the branch and its worktree go away. The
-- reason lives in the kioku session, not in git history.
rejectBranch :: Text -> Text -> IO ()
rejectBranch proj branch = do
  let parent = parentRepoPath proj
      wt = campaignWorktreePath proj branch
  gitIn parent ["worktree", "prune"]
  hasWt <- doesDirectoryExist wt
  if hasWt
    then do
      _ <- gitIn parent ["worktree", "remove", "--force", wt]
      pure ()
    else pure ()
  _ <- gitIn parent ["branch", "-D", T.unpack branch]
  pure ()

mergeMsg :: Text -> Text
mergeMsg branch =
  "Merge " <> branch <> ": campaign repairs, approved by the operator\n\n"
    <> "Landed by the shikumi-campaign application phase, verified by the\n"
    <> "oracle, re-verified at the merge seam, and approved by a human\n"
    <> "verdict (journaled in the campaign's memory).\n"
