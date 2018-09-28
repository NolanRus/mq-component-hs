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
import           System.MQ.Component.Internal.Config               (loadEnv, load2Channels, loadTechChannels)
import           System.MQ.Component.Internal.Env                  (Env (..),
                                                                    Name,
                                                                    TwoChannels (..))
import           System.MQ.Component.Internal.Technical.Kill       (processKill)
import           System.MQ.Component.Internal.Technical.Monitoring (processMonitoring)
import           System.MQ.Monad                                   (MQMonad,
                                                                    MQMonadS,
                                                                    errorHandler,
                                                                    runMQMonad,
                                                                    runMQMonadS,
                                                                    foreverSafe)
import           System.MQ.Protocol                                (Message, MessageTag)
import           Control.Concurrent.Chan.Unagi                     (newChan, InChan, OutChan, writeChan, readChan)
import           System.MQ.Transport                               (SubChannel, PushChannel, sub, push)

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

------------------------------------------------------------------------------
------------------------------------------------------------------------------
------------------------------------------------------------------------------

type ConnectionHandler s = Env -> OutChan (MessageTag, Message) -> InChan Message -> MQMonadS s ()

handleMQError :: Env -> s -> MQMonadS s () -> IO ()
handleMQError Env{..} state' computation = do
    let wrappedComputation = catchError computation $ errorHandler name
    ((), _) <- runMQMonadS wrappedComputation state'
    pure ()

handleConnection :: Env -> SubChannel -> PushChannel -> ConnectionHandler s -> MQMonadS s ()
handleConnection env fromScheduler toScheduler handler = do
    (mainIn, mainOut) <- liftIO newChan
    (jobIn, jobOut) <- liftIO newChan
    liftIO $ forkIO $ handleMQError env () $ collectMessagesFromScheduler env fromScheduler jobIn
    liftIO $ forkIO $ handleMQError env () $ transferMessagesToScheduler env mainOut toScheduler
    handler env jobOut mainIn
  where
    collectMessagesFromScheduler :: Env -> SubChannel -> InChan (MessageTag, Message) -> MQMonadS () ()
    collectMessagesFromScheduler Env{..} fromScheduler jobIn = 
        foreverSafe name $ do
            tagAndMsg <- sub fromScheduler
            liftIO $ writeChan jobIn tagAndMsg

    transferMessagesToScheduler :: Env -> OutChan Message -> PushChannel -> MQMonadS () ()
    transferMessagesToScheduler Env{..} mainOut toScheduler = 
        foreverSafe name $ do
            msg <- liftIO $ readChan mainOut
            push toScheduler msg

runTechPart :: Env -> ConnectionHandler () -> MQMonad ()
runTechPart env runCustomTech = do
    TwoChannels{..} <- loadTechChannels
    handleConnection env fromScheduler toScheduler runCustomTech

runCommPart :: Env -> ConnectionHandler s -> MQMonadS s ()
runCommPart env runComm = do
    TwoChannels{..} <- load2Channels
    handleConnection env fromScheduler toScheduler runComm

runComponent :: Name -> s -> ConnectionHandler s -> ConnectionHandler () -> IO ()
runComponent name' state' runComm runCustomTech = do
    env@Env{..} <- loadEnv name'
    setupLogger env
    infoM name "running component..."
    infoM name "running technical fork..."
    _ <- forkIO $ processMQError () $ runTechPart env runCustomTech
    _ <- forkIO $ processMQError state' $ runCommPart env runComm
    pure ()
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

