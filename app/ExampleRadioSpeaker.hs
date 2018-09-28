{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Concurrent     (threadDelay)
import           Control.Monad          (forever)
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Reader   (ask)
import           ExampleRadioTypes      (RadioData (..))
import           System.MQ.Component    (Env (..), TwoChannels (..),
                                         load2Channels, runApp, 
                                         CompMonad, runComponent, liftMQ)
import           System.MQ.Monad        (MQMonad)
import           System.MQ.Protocol     (Message, createMessage, emptyId, notExpires)
import           System.MQ.Transport    (push)
import  System.Log.Logger

main :: IO ()
main = do
    updateGlobalLogger rootLoggerName (setLevel DEBUG)
    runComponent "example_radio-speaker-hs" radioSpeaker

-- | Our speaker sends to queue messages of type 'RadioConfig' containing phrase
-- "Good morning Vietnam! ..." every second.
--
radioSpeaker :: Message -> CompMonad Message
radioSpeaker _ = do
    liftIO $ debugM "radioSpeaker" "handle"
    Env{..} <- ask
    let radioData = RadioData "Good morning, Vietnam! This is example_radio-speaker-hs!"
    liftMQ $ createMessage "42" creator notExpires radioData
