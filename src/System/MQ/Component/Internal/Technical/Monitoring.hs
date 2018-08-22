{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module System.MQ.Component.Internal.Technical.Monitoring
  ( processMonitoring
  ) where

import           Control.Concurrent                  (threadDelay)
import           Control.Monad.Except                (liftIO)
import           System.MQ.Component.Internal.Atomic (tryIsAlive, tryMessage)
import           System.MQ.Component.Internal.Config (loadTechChannels)
import           System.MQ.Component.Internal.Env    (Env (..),
                                                      TwoChannels (..))
import           System.MQ.Monad                     (MQMonad, foreverSafe)
import           System.MQ.Protocol                  (createMessage, emptyId,
                                                      getTimeMillis, notExpires)
import           System.MQ.Protocol.Technical        (MonitoringData (..))
import           System.MQ.Transport                 (push)

-- | Every time collects information about component and sends it to the scheduler.
--
processMonitoring :: Env -> MQMonad ()
processMonitoring Env{..} = do
    TwoChannels{..} <- loadTechChannels

    foreverSafe name $ do
        liftIO $ threadDelay (millisToMicros frequency)
        currentTime <- getTimeMillis
        curStatus   <- tryIsAlive atomic >>= maybe (pure False) pure
        curMessage  <- tryMessage atomic >>= maybe (pure "Communication layer's thread is down") pure

        let monResult = MonitoringData currentTime name curStatus curMessage

        msg <- createMessage emptyId creator notExpires monResult
        push toScheduler msg

  where
    millisToMicros :: Int -> Int
    millisToMicros = (*) 1000
