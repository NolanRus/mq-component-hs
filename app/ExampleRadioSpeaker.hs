{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Concurrent                     (threadDelay)
import           Control.Monad.IO.Class                 (liftIO)
import           ExampleRadioTypes                      (RadioData (..))
import           System.MQ.Component                    (Env (..), runComponent, ConnectionHandler (..))
import           System.MQ.Monad                        (MQMonad, foreverSafe)
import           System.MQ.Protocol                     (MessageTag, Message, createMessage, emptyId, notExpires)
import           Control.Concurrent.Chan.Unagi          (InChan, OutChan, writeChan)

main :: IO ()
main = runComponent "example_radio-speaker-hs" () radioHandler
  where
    radioHandler = ConnectionHandler radioSpeaker []

-- | Our speaker sends to queue messages of type 'RadioConfig' containing phrase
-- "Good morning Vietnam! ..." every second.
--
radioSpeaker :: Env -> OutChan (MessageTag, Message) -> InChan Message -> MQMonad ()
radioSpeaker Env{..} _ inChan =
    foreverSafe name $ do
        msg <- createMessage emptyId creator notExpires $ RadioData "Good morning, Vietnam! This is example_radio-speaker-hs!"
        liftIO $ writeChan inChan msg
        liftIO $ print msg
        liftIO $ threadDelay 1000000
