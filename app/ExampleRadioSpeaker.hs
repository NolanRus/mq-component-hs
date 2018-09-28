{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Concurrent     (threadDelay)
import           Control.Monad          (forever)
import           Control.Monad.IO.Class (liftIO)
import           ExampleRadioTypes      (RadioData (..))
import           System.MQ.Component    (Env (..), TwoChannels (..),
                                         load2Channels, runApp)
import           System.MQ.Monad        (MQMonad)
import           System.MQ.Protocol     (createMessage, emptyId, notExpires)
import           System.MQ.Transport    (push)

main :: IO ()
main = runApp "example_radio-speaker-hs" radioSpeaker

-- | Our speaker sends to queue messages of type 'RadioConfig' containing phrase
-- "Good morning Vietnam! ..." every second.
--
radioSpeaker :: Env -> MQMonad ()
radioSpeaker Env{..} = do
    TwoChannels{..} <- load2Channels
    forever $ do
        msg <- createMessage emptyId creator notExpires $ RadioData "Good morning, Vietnam! This is example_radio-speaker-hs!"

        push toScheduler msg
        liftIO $ print msg
        liftIO $ threadDelay 1000000
