{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Monad.IO.Class     (liftIO)
import           ExampleRadioTypes          (RadioData (..))
import           System.MQ.Component        (runApp)
import           System.MQ.Component.Extras (MQActionVoid, listenerComm)

main :: IO ()
main = runApp "example_radio-listener-hs" $ listenerComm radioListener

-- | To use template 'Listener' we just need to define function of type 'MQActionVoid'
-- that will process messages received from queue. Our listener will receive messages
-- of type 'RadioData' and print their content.
--
radioListener :: MQActionVoid RadioData
radioListener _ RadioData{..} = liftIO $ putStrLn $ "I heard something on a radio: " ++ message
