{-# LANGUAGE OverloadedStrings   #-}
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
                                                                    threadDelay,
                                                                    killThread)
import           Control.Concurrent.MVar                           (isEmptyMVar,
                                                                    putMVar,
                                                                    takeMVar)
import           Control.Monad                                     (forever,
                                                                    when)
import           Data.Text                                          as T (unpack)
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
import           System.MQ.Encoding.MessagePack                    (pack)
import           Control.Concurrent.Chan.Unagi                     

technicalPart :: MQMonad ()
technicalPart = do
    (mainChanIn, mainChanOut) <- liftIO $ newChan
    (techChanIn, techChanOut) <- liftIO $ newChan
    TwoChannels{..} <- loadTechChannels
    startCollectingMessagesFromScheduler fromScheduler techChanIn
    startSendingMessagesToScheduler toScheduler techChanOut
    startKillMessageHandling techChanOut
    startMonitoring mainChanIn
  where
    startCollectingMessagesFromScheduler :: SubChannel -> InChan (MessageTag, Message) -> MQMonad ()
    startCollectingMessagesFromScheduler fromScheduler techChanIn = do
        liftIO $ forkIO $ processMQError $ do
            foreverSafe "tech-orchestrator-collector" $ do
                msg <- sub fromScheduler
                liftIO $ writeChan techChanIn msg
        pure ()

    startSendingMessagesToScheduler :: PushChannel -> OutChan (MessageTag, Message) -> MQMonad ()
    startSendingMessagesToScheduler toScheduler techChanOut = do
        liftIO $ forkIO $ processMQError $ do
            foreverSafe "tech-orchestrator-sender" $ do
                (tag, msg) <- liftIO $ readChan techChanOut
                push toScheduler msg
        pure ()

    startKillMessageHandling :: OutChan (MessageTag, Message) -> MQMonad ()
    startKillMessageHandling techChanOut = do
        env@Env{..} <- liftIO $ loadEnv "kill-handler"
        liftIO $ forkIO $ processMQError $ do 
           foreverSafe "kill-handler" $ do
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
        pure ()
      where
        killSpec = spec (props :: Props KillConfig)

    startMonitoring :: InChan (MessageTag, Message) -> MQMonad ()
    startMonitoring mainChanIn = do
        env@Env{..} <- liftIO $ loadEnv "monitoring producer"
        liftIO $ forkIO $ processMQError $ do
            foreverSafe "monitoring-producer" $ do
                liftIO $ threadDelay (millisToMicros frequency)
                currentTime <- getTimeMillis
                curStatus   <- tryIsAlive atomic >>= maybe (pure False) pure
                curMessage  <- tryMessage atomic >>= maybe (pure "Communication layer's thread is down") pure
                let monResult = MonitoringData currentTime name curStatus curMessage
                msg <- createMessage emptyId "monitoring-producer" notExpires monResult
                liftIO $ writeChan mainChanIn (messageTag msg, msg)
        pure ()
      where
        millisToMicros :: Int -> Int
        millisToMicros = (*) 1000

communicationalPart :: (Message -> MQMonad Message) -> MQMonad ()
communicationalPart messageHandler = do
    (mainChanIn, mainChanOut) <- liftIO $ newChan
    (commChanIn, commChanOut) <- liftIO $ newChan
    TwoChannels{..} <- load2Channels
    startCollectingMessagesFromScheduler fromScheduler commChanIn
    startSendingMessagesToScheduler toScheduler commChanOut
    foreverSafe "message-handler" $ do   
        (tag, msg) <- liftIO $ readChan commChanOut
        response <- messageHandler msg
        liftIO $ writeChan commChanIn (messageTag response, response)
  where
    startCollectingMessagesFromScheduler :: SubChannel -> InChan (MessageTag, Message) -> MQMonad ()
    startCollectingMessagesFromScheduler fromScheduler commChanIn = do
        liftIO $ forkIO $ processMQError $ do
            foreverSafe "com-orchestrator-collector" $ do
                msg <- sub fromScheduler
                liftIO $ writeChan commChanIn msg
        pure()

    startSendingMessagesToScheduler :: PushChannel -> OutChan (MessageTag, Message) -> MQMonad ()
    startSendingMessagesToScheduler toScheduler commChanOut = do
        liftIO $ forkIO $ processMQError $ do
            foreverSafe "com-orchestrator-sender" $ do
                (tag, msg) <- liftIO $ readChan commChanOut
                push toScheduler msg
        pure()

runComponent :: Name -> (Message -> MQMonad Message) -> IO ()
runComponent name' messageHandler = do
    env@Env{..} <- loadEnv name'
    -- setupLogger env
    infoM name "running component..."
    infoM name "running technical fork..."
    forkIO $ processMQError $ technicalPart
    infoM name "running communication fork..."
    forkIO $ processMQError $ communicationalPart messageHandler
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
