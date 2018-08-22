{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module System.MQ.Component.Internal.Technical.Kill
  (
    processKill
  ) where

import           Control.Concurrent                  (killThread)
import           Control.Concurrent.MVar             (takeMVar)
import           Control.Monad                       (when)
import           Control.Monad.Except                (liftIO)
import           Data.Maybe                          (fromJust)
import           Data.Text                           as T (unpack)
import           System.Log.Logger                   (infoM)
import           System.MQ.Component.Internal.Atomic (Atomic (..), tryLastMsgId)
import           System.MQ.Component.Internal.Config (loadTechChannels)
import           System.MQ.Component.Internal.Env    (Env (..),
                                                      TwoChannels (..))
import           System.MQ.Monad                     (MQMonad, foreverSafe)
import           System.MQ.Protocol                  (Condition (..),
                                                      Message (..),
                                                      MessageLike (..),
                                                      MessageType (..),
                                                      Props (..), matches,
                                                      messageSpec, messageType,
                                                      unpackM)
import           System.MQ.Protocol.Technical        (KillConfig (..))
import           System.MQ.Transport                 (sub)

-- | Receives message 'KillConfig' and if received ID is the same
-- as from communication thread then kill it.
--
processKill :: Env -> MQMonad ()
processKill Env{..} = do
   TwoChannels{..} <- loadTechChannels
   foreverSafe name $ do
       -- listen technical queue
       (tag, Message{..}) <- sub fromScheduler
       -- if reveive 'KillConfig' message then...
       when (tag `matches` (messageType :== Config :&& messageSpec :== killSpec)) $ do
         -- unpack message
         KillConfig{..} <- unpackM msgData
         -- get current task ID
         curMsgId <- tryLastMsgId atomic
         -- if current task ID is the same as in received message then...
         when (curMsgId == Just killTaskId) $ do
             -- get atomic 'MVar'
             Atomic{..} <- liftIO $ takeMVar atomic
             -- kill communication thread (it will be restarted later by main thread)
             liftIO $ killThread _threadId
             liftIO $ infoM name ("TECHNICAL: task " ++ T.unpack (fromJust curMsgId) ++ " killed")

  where
    killSpec = spec (props :: Props KillConfig)
