{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Monad                          (when)
import           Control.Monad.IO.Class                 (liftIO)
import           ExampleRadioTypes                      (RadioData (..))
import           System.MQ.Component                    (Env (..), runComponent, ConnectionHandler (..))
import           System.MQ.Monad
import           System.MQ.Protocol
import           Control.Concurrent.Chan.Unagi          (InChan, OutChan, readChan)
import           System.Log.Logger                      (infoM)

main :: IO ()
main = runComponent "example_radio-listener-hs" () appHandler
  where
    appHandler = ConnectionHandler app [(mtype messageProps, spec messageProps)]

    messageProps :: Props RadioData
    messageProps = props 

app :: Env -> OutChan (MessageTag, Message) -> InChan Message -> MQMonad ()
app Env{..} outChan _ = do
  -- We can't subscribe to specific topic so far, so we're just receiveing all messages.
  -- subscribeToTypeSpec from (mtype messageProps) (spec messageProps)
  liftIO $ infoM name "App is started"
  foreverSafe name $ do
      -- receive message
      (tag, Message{..}) <- liftIO $ readChan outChan
      liftIO $ infoM name "Message was read"
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
