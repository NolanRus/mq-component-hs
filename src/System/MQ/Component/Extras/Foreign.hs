{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module System.MQ.Component.Extras.Foreign
 ( callForeignComponent
 ) where

import           Control.Monad.Except                (catchError, liftIO,
                                                      throwError)
import           Control.Monad.Fix                   (fix)
import           Data.ByteString                     (ByteString)
import           Data.Text                           as T (null, unpack)
import           System.Log.Logger                   (infoM)
import           System.MQ.Component.Extras.Error    (throwForeignError)
import           System.MQ.Component.Internal.Config (load2ChannelsWithContext)
import           System.MQ.Component.Internal.Env    (Env (..),
                                                      TwoChannels (..))
import           System.MQ.Error                     (MQError (..))
import           System.MQ.Monad                     (MQMonadS)
import           System.MQ.Protocol                  (Id, Message (..),
                                                      MessageLike (..),
                                                      MessageTag, Props (..),
                                                      Timestamp, createMessage,
                                                      messagePid)
import           System.MQ.Transport                 (Context, SubChannel,
                                                      Subscribe (..), closeM,
                                                      contextM, push, sub,
                                                      terminateM)

-- | Allows user to send message to queue and receive response to it.
-- IMPORTANT: in MoniQue should exist and be running component that will
-- respond to that message, otherwise call will stuck in an infinite loop.
callForeignComponent :: forall a b s . (MessageLike a, MessageLike b) => Env       -- ^ 'Env' of component
                                                                      -> Id        -- ^ id of message that begets message that will be send
                                                                      -> Timestamp -- ^ expiration date of message that will be sent to foreign component
                                                                      -> a         -- ^ data that will be sent in message
                                                                      -> MQMonadS s b -- ^ result of foreign component's computation
callForeignComponent Env{..} curId expires mdata = do
    context <- contextM
    channels@TwoChannels{..} <- load2ChannelsWithContext context

    dataMsg@Message{..} <- createMessage curId creator expires mdata

    subscribeToTypeSpec fromScheduler (mtype responseProps) (spec responseProps)

    liftIO $ infoM name $ "FOREIGN CALL: Sending message with id " ++ T.unpack msgId ++ " to queue"
    push toScheduler dataMsg

    responseData <- receiveResponse fromScheduler msgId `catchError` catchWithClose context channels
    subscribeToTypeSpec fromScheduler (mtype responseProps) (spec responseProps)

    -- Close sockets and context that they are opened in
    closeConnection context channels

    return responseData

  where
    responseProps :: Props b
    responseProps = props

    -- Receives messages from queue until message with given pId is received
    receiveResponse :: SubChannel -> Id -> MQMonadS s b
    receiveResponse schedulerOut pId = fix $ \action -> do
        (tag, Message{..}) <- sub schedulerOut `catchError` handleSub
        -- If message's tag is empty, that means message is broken and
        -- we should wait for next message. Otherwise we check whether
        -- tag's pId matches given 'pId'
        if not (T.null tag) && checkTag pId tag
          then do
              liftIO $ infoM name $ "FOREIGN CALL: Received response for message with id " ++ T.unpack msgPid ++ " from queue"
              unpackM msgData `catchError` const (errorMsgToError msgData)
          else action

    checkTag :: Id -> MessageTag -> Bool
    checkTag pId = (== pId) . messagePid

    -- | If message received from queue can't be decoded into MoniQue message,
    -- then we set its tag to empty.
    handleSub :: MQError -> MQMonadS s (MessageTag, Message)
    handleSub _ = return ("", error "Received broken message.")

    errorMsgToError :: ByteString -> MQMonadS s b
    errorMsgToError bs = unpackM bs >>= throwForeignError . errorMessage

    closeConnection :: Context -> TwoChannels -> MQMonadS s ()
    closeConnection context TwoChannels{..} = closeM fromScheduler >> closeM toScheduler >> terminateM context

    catchWithClose :: Context -> TwoChannels -> MQError -> MQMonadS s b
    catchWithClose context channels e = closeConnection context channels >> throwError e
