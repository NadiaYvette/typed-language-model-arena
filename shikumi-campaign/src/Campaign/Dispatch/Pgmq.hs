{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Campaign.Dispatch.Pgmq
  ( enqueueDispatch,
    PGMQMessage (..),
  )
where

import Campaign.Dispatch (DispatchAction)
import Data.Aeson (ToJSON, encode)
import GHC.Generics (Generic)
import Keiro.Workflow.Awakeable (AwakeableId)

-- | Message payload for the PGMQ queue
data PGMQMessage = PGMQMessage
  { action :: !DispatchAction,
    awakeableId :: !AwakeableId
  }
  deriving (Show, Generic, ToJSON)

-- | Placeholder for actual PGMQ enqueue
-- Needs integration with pgmq-hs
enqueueDispatch :: DispatchAction -> AwakeableId -> IO ()
enqueueDispatch act aid = do
  let _msg = PGMQMessage act aid
  -- TODO: Use pgmq-hasql or pgmq-effectful to enqueue
  putStrLn $ "[pgmq] Enqueued dispatch: " ++ show (encode _msg)
