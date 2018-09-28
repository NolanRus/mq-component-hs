{-# LANGUAGE RecordWildCards #-}

module Main where

import           Control.Monad.IO.Class                (liftIO)
import           System.Log.Logger                     (infoM)

import           Control.Monad                         (unless)
import           Control.Monad.Reader                  (ask)
import           ExampleCalculatorTypes                (CalculatorConfig (..),
                                                        CalculatorResult (..))
import           System.MQ.Protocol                    (Condition (..), createMessage, emptyId,
                                                        Props (..), Message (..), MessageTag,
                                                        messageTag, messageType, messageSpec, 
                                                        matches, MessageLike (..), notExpires)
import           System.MQ.Component                   (Env(..), runComponent, CompMonad, liftMQ)
import           System.MQ.Component.Internal.Atomic   (updateLastMsgId)
import           System.MQ.Component.Extras            (MQAction, throwComponentError, throwErrorIncorrectInput,
                                                        workerScheduler,
                                                        validateCondition, catchRuntimeError)

import           Debug.Trace

main :: IO ()
main = do
    traceM "Here"
    runComponent "example_calculator-hs" calculatorWorkerAction

-- | To use template 'Worker' we just need to define function of type 'MQAction'
-- that will process messages received from queue and return results of such processing.
-- Our calculator multiplies every number received in 'CalculatorConfig' by 228 and
-- returns result of that multiplication in 'CalculatorResult'.
--
calculatorWorkerAction :: Message -> CompMonad Message 
calculatorWorkerAction msg@Message{..} = do
    Env{..} <- ask
    let tag = messageTag msg
    unless (checkTag tag) $ error "I don't work with such tags"
    -- Set 'lastMsgId' to id of message that worker will process
    updateLastMsgId msgId atomic
    -- Process data from message using 'action'
    let Just CalculatorConfig{..} = unpack msgData
    result <- case action of
                    -- this error will be caught by worker template
                    "-" -> error "we can't subtract"
                    "+" -> pure $ CalculatorResult (first + second)
                    -- catch runtime error and throw custom MQError
                    "*" -> undefined -- catchRuntimeError (CalculatorResult $ first * second) 
                                     --         throwComponentError "Oops, some runtime error"
                    "/" -> -- do
                        -- validate input data
                        -- s <- validateCondition (/= 0.0) second "Division by zero is not allowed on Earth"
                        let s = second in
                        pure $ CalculatorResult (first / s)
                    m   -> undefined -- throwErrorIncorrectInput $ "Unknown calculator action: " ++ m
    -- After message has been processed, clear 'lastMsgId'
    updateLastMsgId emptyId atomic
    liftMQ $ createMessage msgId creator notExpires result
  where
    messageProps :: Props CalculatorConfig
    messageProps = props
    checkTag :: MessageTag -> Bool
    checkTag = (`matches` (messageSpec :== spec messageProps :&& messageType :== mtype messageProps))
