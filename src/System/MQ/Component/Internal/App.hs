{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module System.MQ.Component.Internal.App
  (
    runApp
  , runAppS
  , runAppWithTech
  , runTech
  , processKill
  , processMonitoring
  ) where

import           Control.Concurrent                                (forkIO,
                                                                    threadDelay)
import           Control.Concurrent.MVar                           (isEmptyMVar,
                                                                    putMVar)
import           Control.Monad                                     (forever,
                                                                    when)
import           Control.Monad.Except                              (catchError)
import           Control.Monad.IO.Class                            (liftIO)
import           System.Log.Formatter                              (simpleLogFormatter)
import           System.Log.Handler                                (setFormatter)
import           System.Log.Handler.Simple                         (fileHandler)
import           System.Log.Logger                                 (Priority (..),
                                                                    addHandler,
                                                                    infoM,
                                                                    setLevel,
                                                                    updateGlobalLogger)
import           System.MQ.Component.Internal.Atomic               (createAtomic)
import           System.MQ.Component.Internal.Config               (loadEnv)
import           System.MQ.Component.Internal.Env                  (Env (..),
                                                                    Name)
import           System.MQ.Component.Internal.Technical.Kill       (processKill)
import           System.MQ.Component.Internal.Technical.Monitoring (processMonitoring)
import           System.MQ.Monad                                   (MQMonad,
                                                                    MQMonadS,
                                                                    errorHandler,
                                                                    runMQMonad,
                                                                    runMQMonadS)

runApp :: Name -> (Env -> MQMonad ()) -> IO ()
runApp name' = runAppS name' ()

runAppS :: Name -> s -> (Env -> MQMonadS s ()) -> IO ()
runAppS name' state runComm = runAppWithTechS name' state runComm runTech

runAppWithTech :: Name -> (Env -> MQMonad ()) -> (Env -> MQMonad ()) -> IO ()
runAppWithTech name' = runAppWithTechS name' ()

runAppWithTechS :: forall s. Name -> s -> (Env -> MQMonadS s ()) -> (Env -> MQMonad ()) -> IO ()
runAppWithTechS name' state runComm runCustomTech = do
    env@Env{..} <- loadEnv name'

    setupLogger env

    infoM name "running component..."

    infoM name "running technical fork..."
    _ <- forkIO $ processMQError () $ runCustomTech env

    forever $ do
        atomicIsEmpty <- isEmptyMVar atomic

        when atomicIsEmpty $ do
            infoM name "there is not communication thread, creating new one..."
            commThreadId <- forkIO $ processMQError state $ runComm env

            let newAtomic = createAtomic commThreadId
            putMVar atomic newAtomic

        threadDelay oneSecond

  where
    processMQError :: p -> MQMonadS p () -> IO ()
    processMQError state' = fmap fst . flip runMQMonadS state' . flip catchError (errorHandler name')

    setupLogger :: Env -> IO ()
    setupLogger Env{..} = do
        h <- fileHandler logfile INFO >>= \lh -> return $
                 setFormatter lh (simpleLogFormatter "[$time : $loggername : $prio] $msg")
        updateGlobalLogger name (addHandler h)
        updateGlobalLogger name (setLevel INFO)

    oneSecond :: Int
    oneSecond = 10^(6 :: Int)

runTech :: Env -> MQMonad ()
runTech env@Env{..} = do
    _ <- liftIO . forkIO . runMQMonad $ processKill env
    processMonitoring env
