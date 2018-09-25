{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}

module System.MQ.Component.Internal.App
  (
    runApp
  , runAppS
  , runAppWithTech
  , runComponent
  , liftMQ
  , CompMonad
  , runTech
  , processKill
  , processMonitoring
  ) where

import           Control.Concurrent                                (ThreadId,
                                                                    forkIO,
                                                                    threadDelay,
                                                                    killThread)
import           Control.Concurrent.MVar                           (isEmptyMVar,
                                                                    putMVar,
                                                                    takeMVar)
import           Control.Monad                                     (forever,
                                                                    when)
import           Control.Monad.Except                              (MonadError(..))
import           Control.Monad.IO.Class                            (MonadIO(..))
import           Control.Monad.State                               (MonadState(..))
import           Control.Monad.Reader                              (ReaderT (..),
                                                                    MonadReader (..))
import           Data.Text                                          as T (pack, unpack)
import           Data.Maybe                                        (fromJust)
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
import           System.MQ.Component.Internal.Atomic               (createAtomic, 
                                                                    Atomic (..), 
                                                                    tryLastMsgId,
                                                                    tryIsAlive,
                                                                    tryMessage)
import           System.MQ.Component.Internal.Config               (loadEnv,
                                                                    loadTechChannels,
                                                                    load2Channels)
import           System.MQ.Component.Internal.Env                  (Env (..),
                                                                    Name,
                                                                    TwoChannels (..))
import           System.MQ.Component.Internal.Technical.Kill       (processKill)
import           System.MQ.Component.Internal.Technical.Monitoring (processMonitoring)
import           System.MQ.Error                                   (MQError(..))
import           System.MQ.Protocol                                (Message (..), 
                                                                    MessageTag, 
                                                                    MessageLike (..), 
                                                                    Condition (..),
                                                                    MessageType (..),
                                                                    Props,
                                                                    matches,
                                                                    messageTag,
                                                                    messageType,
                                                                    messageSpec,
                                                                    notExpires,
                                                                    createMessage,
                                                                    emptyId,
                                                                    getTimeMillis,
                                                                    spec)
import           System.MQ.Protocol.Technical                      (MonitoringData (..),
                                                                    KillConfig (..))
import           System.MQ.Monad                                   (MQMonad,
                                                                    MQMonadS,
                                                                    errorHandler,
                                                                    runMQMonad,
                                                                    runMQMonadS,
                                                                    foreverSafe)
import           System.MQ.Transport                               (PushChannel,
                                                                    SubChannel,
                                                                    sub,
                                                                    push)
import           Control.Concurrent.Chan.Unagi                     

newtype CompMonadS s a = CompMonadS (ReaderT Env (MQMonadS s) a)
  deriving ( Monad
           , Functor
           , Applicative
           , MonadReader Env
           , MonadIO
           , MonadError MQError
           , MonadState s)

type CompMonad = CompMonadS ()

runCompMonadS :: CompMonadS s a -> Env -> MQMonadS s a
runCompMonadS (CompMonadS r) = runReaderT r 

runCompMonad :: CompMonad a -> Env -> MQMonadS () a
runCompMonad = runCompMonadS 

liftMQ :: MQMonadS s a -> CompMonadS s a 
liftMQ m = CompMonadS $ ReaderT (const m)

technicalPart :: CompMonad ()
technicalPart = do
    (mainChanIn, mainChanOut) <- liftIO newChan
    (techChanIn, techChanOut) <- liftIO newChan
    TwoChannels{..} <- liftMQ loadTechChannels
    _ <- startCollectingMessagesFromScheduler fromScheduler techChanIn
    _ <- startSendingMessagesToScheduler toScheduler mainChanOut
    _ <- startKillMessageHandling techChanOut
    _ <- startMonitoring mainChanIn
    pure ()
  where
    startCollectingMessagesFromScheduler :: SubChannel -> InChan (MessageTag, Message) -> CompMonad ThreadId
    startCollectingMessagesFromScheduler fromScheduler techChanIn = do
        Env{..} <- ask
        liftIO $ forkIO $ processMQError $
            foreverSafe name $ do
                msg <- sub fromScheduler
                liftIO $ writeChan techChanIn msg

    startSendingMessagesToScheduler :: PushChannel -> OutChan (MessageTag, Message) -> CompMonad ThreadId
    startSendingMessagesToScheduler toScheduler techChanOut = do
        Env{..} <- ask
        liftIO $ forkIO $ processMQError $
            foreverSafe name $ do
                (_, msg) <- liftIO $ readChan techChanOut
                push toScheduler msg

    startKillMessageHandling :: OutChan (MessageTag, Message) -> CompMonad ThreadId
    startKillMessageHandling techChanOut = do
        Env{..} <- ask
        liftIO $ forkIO $ processMQError $
           foreverSafe name $ do
                -- listen technical queue
                (tag, Message{..}) <- liftIO $ readChan techChanOut
                -- if reveive 'KillConfig' message then...
                when (tag `matches` (messageType :== Config :&& messageSpec :== killSpec)) $ do
                  -- unpack message
                  KillConfig{..} <- unpackM msgData
                  -- get current task ID
                  curMsgId <- tryLastMsgId atomic
                  -- if current task ID is the same as in received message then...
                  when (curMsgId == Just killTaskId) $ do
                      -- get atomic 'MVar'
                      Atomic{..} <- liftIO $ takeMVar atomic
                      -- kill communication thread (it will be restarted later by main thread)
                      liftIO $ killThread _threadId
                      liftIO $ infoM name ("TECHNICAL: task " ++ T.unpack (fromJust curMsgId) ++ " killed")
      where
        killSpec = spec (props :: Props KillConfig)

    startMonitoring :: InChan (MessageTag, Message) -> CompMonad ThreadId
    startMonitoring mainChanIn = do
        Env{..} <- ask
        liftIO $ forkIO $ processMQError $
            foreverSafe name $ do
                liftIO $ threadDelay (millisToMicros frequency)
                currentTime <- getTimeMillis
                curStatus   <- tryIsAlive atomic >>= maybe (pure False) pure
                curMessage  <- tryMessage atomic >>= maybe (pure "Communication layer's thread is down") pure
                let monResult = MonitoringData currentTime name curStatus curMessage
                msg <- createMessage emptyId (T.pack name) notExpires monResult
                liftIO $ writeChan mainChanIn (messageTag msg, msg)
      where
        millisToMicros :: Int -> Int
        millisToMicros = (*) 1000

communicationalPart :: (Message -> CompMonad Message) -> CompMonad ()
communicationalPart messageHandler = do
    env@Env{..} <- ask
    (mainChanIn, mainChanOut) <- liftIO newChan
    (commChanIn, commChanOut) <- liftIO newChan
    TwoChannels{..} <- liftMQ load2Channels
    startCollectingMessagesFromScheduler fromScheduler commChanIn
    startSendingMessagesToScheduler toScheduler commChanOut
    liftIO $ forkIO $ processMQError $ 
        foreverSafe name $ do   
            (tag, msg) <- liftIO $ readChan commChanOut
            response <- runCompMonad (messageHandler msg) env
            liftIO $ writeChan commChanIn (messageTag response, response)
    pure ()
  where
    startCollectingMessagesFromScheduler :: SubChannel -> InChan (MessageTag, Message) -> CompMonad ThreadId
    startCollectingMessagesFromScheduler fromScheduler commChanIn = do
        Env{..} <- ask
        liftIO $ forkIO $ processMQError $
            foreverSafe name $ do
                msg <- sub fromScheduler
                liftIO $ writeChan commChanIn msg

    startSendingMessagesToScheduler :: PushChannel -> OutChan (MessageTag, Message) -> CompMonad ThreadId
    startSendingMessagesToScheduler toScheduler commChanOut = do
        Env{..} <- ask
        liftIO $ forkIO $ processMQError $
            foreverSafe name $ do
                (_, msg) <- liftIO $ readChan commChanOut
                push toScheduler msg

runComponent :: Name -> (Message -> CompMonad Message) -> IO ()
runComponent name' messageHandler = do
    env@Env{..} <- loadEnv name'
    -- setupLogger env
    infoM name "running component..."
    infoM name "running technical fork..."
    _ <- forkIO $ processMQError $ runCompMonad technicalPart env
    infoM name "running communication fork..."
    _ <- forkIO $ processMQError $ runCompMonad (communicationalPart messageHandler) env
    pure ()

processMQError :: MQMonad () -> IO ()
processMQError = fmap fst . flip runMQMonadS () . flip catchError (errorHandler "empty")

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
            infoM name "there is no communication thread, creating new one..."
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
