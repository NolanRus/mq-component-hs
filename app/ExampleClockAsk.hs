{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Control.Concurrent         (threadDelay)
import           Control.Monad.IO.Class     (liftIO)
import           ExampleClockTypes          (ClockConfig (..), ClockResult (..))
import           System.MQ.Component        (Env (..), TwoChannels (..),
                                             load2Channels, runApp)
import           System.MQ.Component.Extras (callForeignComponent)
import           System.MQ.Monad            (MQMonad, foreverSafe)
import           System.MQ.Protocol         (emptyId, notExpires)

main :: IO ()
main = runApp "example_clock-ask-hs" clockAsk

-- | This component asks question, waits for answer, prints result and waits one second.
--
clockAsk :: Env -> MQMonad ()
clockAsk env@Env{..} = do
    TwoChannels{..} <- load2Channels
    foreverSafe name $ do
        let clockConfig = ClockConfig "Hi, I am example_clock-ask-hs! What's time is now?"

        ClockResult{..} <- callForeignComponent env emptyId notExpires clockConfig

        liftIO . putStrLn $ "Now time is " ++ show answer
        liftIO $ threadDelay 1000000
