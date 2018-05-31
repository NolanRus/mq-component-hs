{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module System.MQ.Component.Extras.Template.Worker
  ( workerController
  , workerScheduler
  ) where

import           Control.Exception                         (Exception(..), SomeException,
                                                            catch)
import           Control.Monad                             (when)
import           Control.Monad.Except                      (liftIO)
import           Control.Monad.State.Strict                (get)
import           System.Log.Logger                         (errorM)
import           Data.List                                 (findIndex, isPrefixOf, tails)
import           System.MQ.Component.Extras.Template.Types (MQActionS)
import           System.MQ.Component.Internal.Atomic       (updateLastMsgId)
import           System.MQ.Component.Internal.Config       (load2Channels,
                                                            load3Channels)
import           System.MQ.Component.Internal.Env          (Env (..),
                                                            ThreeChannels (..),
                                                            TwoChannels (..))
import           System.MQ.Error                           (MQError (..),
                                                            errorComponent)
import           System.MQ.Monad                           (MQMonadS,
                                                            foreverSafe,
                                                            runMQMonadS)
import           System.MQ.Protocol                        (Condition (..),
                                                            Message (..),
                                                            MessageLike (..),
                                                            MessageTag,
                                                            Props (..),
                                                            createMessage,
                                                            emptyHash, matches,
                                                            messageSpec,
                                                            messageType,
                                                            notExpires)
import           System.MQ.Transport                       (PushChannel, pull,
                                                            push, sub)

-- | Given 'WorkerAction' acts as component's communication layer that receives messages of type 'a'
-- from scheduler, processes them using 'WorkerAction' and sends result of type 'b' back to scheduler.
--
workerScheduler :: (MessageLike a, MessageLike b) => MQActionS s a b -> Env -> MQMonadS s ()
workerScheduler = worker Scheduler

-- | Given 'WorkerAction' acts as component's communication layer that receives messages of type 'a'
-- from controller, processes them using 'WorkerAction' and sends result of type 'b' to scheduler.
--
workerController :: (MessageLike a, MessageLike b) => MQActionS s a b -> Env -> MQMonadS s ()
workerController = worker Controller

--------------------------------------------------------------------------------
-- INTERNAL
--------------------------------------------------------------------------------

-- | We support two types of 'Worker'-like components: ones that receive messages from
-- scheduler and ones that receive messages from controller.
data WorkerType = Scheduler | Controller deriving (Eq, Show)

-- | Alias for function that given environment receives messages from queue.
--
type MessageReceiver s = MQMonadS s (MessageTag, Message)

-- | Given 'WorkerType' and 'WorkerAction' acts as component's communication layer
-- that receives messages of type 'a' from scheduler or controller (depending on 'WorkerType'),
-- processes them using 'WorkerAction' and sends result of type 'b' to scheduler.
--
worker :: forall a b s. (MessageLike a, MessageLike b) => WorkerType -> MQActionS s a b -> Env -> MQMonadS s ()
worker wType action env@Env{..} = do
    -- Depending on 'WorkerType', we define function using which worker will receive
    -- messages from queue. Also we define channel through which worker will
    -- send messages to queue
    (msgReceiver, schedulerIn) <- msgRecieverAndSchedulerIn

    foreverSafe name $ do
        (tag, msg@Message{..}) <- msgReceiver
        state <- get
        when (checkTag tag) $ do
            -- Set 'lastMsgId' to id of message that worker will process
            updateLastMsgId msgId atomic

            -- Process data from message using 'action'
            processTask state schedulerIn msg

            -- After message has been processed, clear 'lastMsgId'
            updateLastMsgId emptyHash atomic

  where
    msgRecieverAndSchedulerIn :: MQMonadS s (MessageReceiver s, PushChannel)
    msgRecieverAndSchedulerIn =
      case wType of
        Scheduler  -> (\(TwoChannels fs ts) -> (sub fs, ts)) <$> load2Channels
        Controller -> (\(ThreeChannels _ ts fc) -> (pull fc, ts)) <$> load3Channels name

    messageProps :: Props a
    messageProps = props

    checkTag :: MessageTag -> Bool
    checkTag = (`matches` (messageSpec :== spec messageProps :&& messageType :== mtype messageProps))

    processTask :: s -> PushChannel -> Message -> MQMonadS s ()
    processTask state schedulerIn Message{..} = do
        -- Runtime errors may occur during message parsing and execution of 'WorkerAction'. In order to process them
        -- without failures we use function 'handleError' that converts 'Exception's into 'MQError's
        responseE <- liftIO . handleError state $ (unpackM msgData >>= action env)

        case responseE of
          Right response      -> createMessage msgId creator notExpires response >>= push schedulerIn
          Left  (MQError c m) -> createMessage msgId creator notExpires (MQError c $ dropCallStack m) >>= push schedulerIn

    handleError :: s -> MQMonadS s b -> IO (Either MQError b)
    handleError state valM = catch (Right . fst <$> runMQMonadS valM state) handler
      where
        handler :: SomeException -> IO (Either MQError b)
        handler e = do
            errorM name $! show e
            let anyError = MQError errorComponent $ show e
            return . Left $ maybe anyError id (fromException e :: Maybe MQError)

            -- case (fromException e :: Maybe MQError) of
            --   (Just mqErr) -> return . Left $ mqErr
            --   Nothing -> return . Left . MQError errorComponent $ show e

    dropCallStack :: String -> String
    dropCallStack str = maybe str (\i -> take i str) $ findIndex (isPrefixOf "\nCallStack") (tails str)
