{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Monad          (when)
import           Control.Monad.IO.Class (liftIO)
import           ExampleRadioTypes      (RadioData (..))
import           System.MQ.Component    (Env (..), TwoChannels (..),
                                         load2Channels, runApp)
import           System.MQ.Monad
import           System.MQ.Protocol
import           System.MQ.Transport

main :: IO ()
main = runApp "example_radio-listener-hs" app

app :: Env -> MQMonadS () ()
app Env{..} = do
  TwoChannels from _ <- load2Channels
  -- Following line is equal to `subscribeTo from "data:example_radio"`.
  -- It is equal to subscribe to all messages that starts with "data:example_radio".
  subscribeToTypeSpec from (mtype messageProps) (spec messageProps)

  foreverSafe name $ do
      -- receive message
      (tag, Message{..}) <- sub from
      -- be sure that tag is correct
      when (checkTag tag) $ do
          -- unpack data from the message
          unpacked <- unpackM msgData
          -- and process it
          process unpacked
  where
    messageProps :: Props RadioData
    messageProps = props

    checkTag :: MessageTag -> Bool
    checkTag = (`matches` (messageSpec :== spec messageProps :&& messageType :== mtype messageProps))

    process :: RadioData -> MQMonadS () ()
    process RadioData{..} = liftIO $ putStrLn $ "I heard something on a radio: " ++ message
