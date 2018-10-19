{-# LANGUAGE RecordWildCards     #-}

module System.MQ.Component.Internal.Component
  ( runComponent
  , runComponentWithCustomTech
  , ConnectionHandler (..)
  ) where

import qualified Data.Text as T
import Control.Monad.Except
import Control.Concurrent.Chan.Unagi
import Control.Concurrent hiding (readChan, writeChan, newChan)
import System.MQ.Component.Internal.Atomic
import System.MQ.Component.Internal.Env
import System.MQ.Component.Internal.Config
import System.MQ.Monad
import System.MQ.Protocol
import System.MQ.Protocol.Technical
import System.MQ.Transport
import System.Log.Logger
import System.Log.Handler hiding (setLevel)
import System.Log.Handler.Simple
import System.Log.Formatter

data ConnectionHandler s 
    = ConnectionHandler 
    { handleConnection :: Env -> OutChan (MessageTag, Message) -> InChan Message -> MQMonadS s ()
    , typeSpecs :: [(MessageType, Spec)]
    }

handleMQError :: Env -> s -> MQMonadS s () -> IO ()
handleMQError Env{..} state' computation = do
    let wrappedComputation = catchError computation $ errorHandler name
    ((), _) <- runMQMonadS wrappedComputation state'
    pure ()

runComponent :: Name -> s -> ConnectionHandler s -> IO ()
runComponent name' state' runComm = runComponentWithCustomTech name' state' runComm defaultTechHandler
  where
    defaultTechHandler = ConnectionHandler runDefaultTechHandler [(Config, spec (props :: Props KillConfig))]

    runDefaultTechHandler :: Env -> OutChan (MessageTag, Message) -> InChan Message -> MQMonadS () ()
    runDefaultTechHandler env outChan inChan = do
        _ <- liftIO $ forkIO $ handleMQError env () $ handleKillMessages env outChan
        sendMonitoringMessages env inChan

    handleKillMessages :: Env -> OutChan (MessageTag, Message) -> MQMonadS () ()
    handleKillMessages Env{..} outChan =
       foreverSafe name $ do
           -- Handle Kill messages
           (tag, Message{..}) <- liftIO $ readChan outChan
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
                 liftIO $ infoM name ("TECHNICAL: task " ++ T.unpack killTaskId ++ " killed")
          where
            killSpec = spec (props :: Props KillConfig)

    sendMonitoringMessages :: Env -> InChan Message -> MQMonadS () ()
    sendMonitoringMessages Env{..} inChan =
        foreverSafe name $ do
            liftIO $ threadDelay (millisToMicros frequency)
            currentTime <- getTimeMillis
            curStatus   <- tryIsAlive atomic >>= maybe (pure False) pure
            curMessage  <- tryMessage atomic >>= maybe (pure "Communication layer's thread is down") pure
            let monResult = MonitoringData currentTime name curStatus curMessage
            msg <- createMessage emptyId creator notExpires monResult
            liftIO $ writeChan inChan msg
      where
        millisToMicros :: Int -> Int
        millisToMicros = (*) 1000

setupLogger :: Env -> IO ()
setupLogger Env{..} = do
    h <- fileHandler logfile INFO >>= \lh -> return $
             setFormatter lh (simpleLogFormatter "[$time : $loggername : $prio] $msg")
    updateGlobalLogger name (addHandler h)
    updateGlobalLogger name (setLevel INFO)

runComponentWithCustomTech :: Name -> s -> ConnectionHandler s -> ConnectionHandler () -> IO ()
runComponentWithCustomTech name' state' runComm runCustomTech = do
    env@Env{..} <- loadEnv name'
    setupLogger env
    (incomingIn, incomingOut) <- liftIO newChan
    (outgoingCommIn, outgoingCommOut) <- liftIO newChan
    (outgoingTechIn, outgoingTechOut) <- liftIO newChan
    (commIn, commOut) <- liftIO newChan 
    (techIn, techOut) <- liftIO newChan
    -- Collectors.
    -- Collectors are threads that collect messages from both communicational
    -- and technical channel and push them into single queue called `incoming`
    -- Later they are taken from this queue by dispatcher. There are also collectors
    -- which collect messages from handler threads and send them to scheduler.
    let openConnections = 
            [(openCommunicationalConnectionFromScheduler, typeSpecs runComm), 
             (openTechnicalConnectionFromScheduler, typeSpecs runCustomTech)]
    forM_ openConnections $ \(openConnection, typeSpecs) ->
        liftIO $ forkIO $ handleMQError env () $ do
            fromScheduler <- liftIO openConnection
            forM_ typeSpecs $ uncurry $ \type' spec ->
                subscribeToTypeSpec fromScheduler type' spec   
            foreverSafe name $ do
                message <- sub fromScheduler
                liftIO $ writeChan incomingIn message
    let outgoing = [(openCommunicationalConnectionToScheduler, outgoingCommOut), 
                    (openTechnicalConnectionToScheduler, outgoingTechOut)] 
    forM_ outgoing $ \(openConnection, channel) -> 
        liftIO $ forkIO $ handleMQError env () $ do
            toScheduler <- liftIO openConnection
            foreverSafe name $ do
                message <- liftIO $ readChan channel
                push toScheduler message
    -- Handlers.
    -- Handlers are threads that know how to act on the messages of specific
    -- type. For now there are only two kinds of messages: technical and communicational
    -- thus two threads are started here.
    _ <- liftIO $ forkIO $ handleMQError env state' $
        handleConnection runComm env commOut outgoingCommIn
    _ <- liftIO $ forkIO $ handleMQError env () $
        handleConnection runCustomTech env techOut outgoingTechIn
    -- Dispatcher.
    -- Dispatcher is a thread that determines which handler should receive
    -- message.
    forever $ do
        message@(tag, _) <- liftIO $ readChan incomingOut
        let killProps = props :: Props KillConfig
        let checkTag = (`matches` (messageSpec :== spec killProps :&& messageType :== mtype killProps))
        let channel = if checkTag tag then techIn else commIn
        liftIO $ writeChan channel message
