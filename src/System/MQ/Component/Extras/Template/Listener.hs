{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module System.MQ.Component.Extras.Template.Listener
  ( listenerComm
  , listenerTech
  ) where

import           Control.Monad                             (when)
import           System.MQ.Component.Extras.Template.Types (MQActionVoidS)
import           System.MQ.Component.Internal.Atomic       (updateLastMsgId)
import           System.MQ.Component.Internal.Config       (load2Channels,
                                                            loadTechChannels)
import           System.MQ.Component.Internal.Env          (Env (..),
                                                            TwoChannels (..))
import           System.MQ.Monad                           (MQMonadS,
                                                            foreverSafe)
import           System.MQ.Protocol                        (Condition (..),
                                                            Message (..),
                                                            MessageLike (..),
                                                            MessageTag,
                                                            Props (..), emptyId,
                                                            matches,
                                                            messageSpec,
                                                            messageType)
import           System.MQ.Transport                       (SubChannel,
                                                            Subscribe (..), sub)

-- | Listener of communication level's scheduler
--
listenerComm :: MessageLike a => MQActionVoidS s a -> Env -> MQMonadS s ()
listenerComm analyser env = load2Channels >>= listenerWithChannels analyser env

-- | Listener of technical level's scheduler
--
listenerTech :: MessageLike a => MQActionVoidS s a -> Env -> MQMonadS s ()
listenerTech analyser env = loadTechChannels >>= listenerWithChannels analyser env

-- | Template `listener` allows user to gather data from queue and perform different actions with it
--
listenerWithChannels :: forall a s. MessageLike a => MQActionVoidS s a -> Env -> TwoChannels -> MQMonadS s ()
listenerWithChannels analyser env@Env{..} TwoChannels{..} = do
    subscribeToTypeSpec fromScheduler (mtype messageProps) (spec messageProps)
    foreverSafe name $ obtainData env fromScheduler analyser
  where
    messageProps :: Props a
    messageProps = props

-- | Receive from queue message with given type, spec and pId and process it using 'MQActionVoid'
--
obtainData :: forall a s. MessageLike a => Env -> SubChannel -> MQActionVoidS s a -> MQMonadS s ()
obtainData env@Env{..} subChannel analyser = do
    (tag, Message{..}) <- sub subChannel

    when (filterTag tag) $ do
      -- Set 'lastMsgId' to id of message that worker will process
      updateLastMsgId msgId atomic

      -- Process data from message using 'action'
      unpackM msgData >>= analyser env

      -- After message has been processed, clear 'lastMsgId'
      updateLastMsgId emptyId atomic

  where
    Props{..} = props :: Props a

    filterTag :: MessageTag -> Bool
    filterTag = (`matches` (messageType :== mtype :&& messageSpec :== spec))

