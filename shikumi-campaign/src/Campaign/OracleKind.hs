{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Reserved oracle fact kinds (Tier 4b, barriers #1 and #3).
-- Declares the closed allow-list of verification kinds that the ladder may gate.
-- Unknown kinds are recorded, never executed (invariant: closed vocabulary).
module Campaign.OracleKind
  ( OracleKind (..),
    kindAllowList,
    kindIsKnown,
    driverContractDoc,
  )
where

import Data.Text (Text)
import Data.Text qualified as T

-- | The closed allow-list of verification kinds.
-- Barrier #1: these kinds must be explicitly admitted before execution.
data OracleKind
  = OracleKindKvmConsoleBoot
  | OracleKindKstressSoak
  | OracleKindKbootstrapFixpoint
  | OracleKindKvmCrashConsistency
  deriving stock (Eq, Ord, Show)

-- | The allow-list that gate #1 checks against.
kindAllowList :: [OracleKind]
kindAllowList =
  [ OracleKindKvmConsoleBoot,
    OracleKindKstressSoak,
    OracleKindKbootstrapFixpoint,
    OracleKindKvmCrashConsistency
  ]

-- | Check whether a kind string is in the allow-list.
kindIsKnown :: Text -> Bool
kindIsKnown t =
  case T.breakOn ":" t of
    (kindStr, rest)
      | kindStr `elem` map kindName kindAllowList -> True
      | otherwise -> False
  where
    kindName k = case k of
      OracleKindKvmConsoleBoot -> "vm-console-boot"
      OracleKindKstressSoak -> "stress-soak"
      OracleKindKbootstrapFixpoint -> "bootstrap-fixpoint"
      OracleKindKvmCrashConsistency -> "vm-crash-consistency"

-- | Driver contract documentation for barrier #3.
-- Describes the execution seam: external drivers own console, timeouts, kill schedule.
-- Manifest facts carry: send/expect strings, kill schedules, stage inputs.
-- Reference designs: pgcl matrix-driver-all.sh, avocado/avocado-vt, expect/pexpect.
-- Defer in-process PTY/expect until a driver cannot express the interaction.
driverContractDoc :: Text
driverContractDoc =
  "Driver contract (barrier #3): external processes own console, timeouts, and kill schedule.\n"
    ++ "Manifest facts carry: send/expect strings, kill schedules, stage inputs.\n"
    ++ "Reference designs: pgcl matrix-driver-all.sh, avocado/avocado-vt,\n"
    ++ "expect/pexpect. Defer in-process PTY/expect until a driver cannot express the interaction."
