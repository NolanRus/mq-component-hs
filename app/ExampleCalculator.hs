{-# LANGUAGE RecordWildCards #-}

module Main where

import           Control.Monad.IO.Class                (liftIO)
import           System.Log.Logger                     (infoM)

import           ExampleCalculatorTypes                (CalculatorConfig (..),
                                                        CalculatorResult (..))
import           System.MQ.Component                   (Env(..), runApp)
import           System.MQ.Component.Extras            (MQAction, throwComponentError, throwErrorIncorrectInput,
                                                        workerScheduler,
                                                        validateCondition, catchRuntimeError)

main :: IO ()
main = runApp "example_calculator-hs" $ workerScheduler calculatorWorkerAction

-- | To use template 'Worker' we just need to define function of type 'MQAction'
-- that will process messages received from queue and return results of such processing.
-- Our calculator multiplies every number received in 'CalculatorConfig' by 228 and
-- returns result of that multiplication in 'CalculatorResult'.
--
calculatorWorkerAction :: MQAction CalculatorConfig CalculatorResult
calculatorWorkerAction Env{..} CalculatorConfig{..} = do
    -- log messages can be written this way
    liftIO $ infoM name "Info log message"
    case action of
      -- this error will be caught by worker template
      "-" -> error "we can't subtract"
      "+" -> return . CalculatorResult $ first + second
      -- catch runtime error and throw custom MQError
      "*" -> catchRuntimeError (CalculatorResult $ first * second) throwComponentError "Oops, some runtime error"
      "/" -> do
          -- validate input data
          s <- validateCondition (/= 0.0) second "Division by zero is not allowed on Earth"
          return . CalculatorResult $ first / s
      m   -> throwErrorIncorrectInput $ "Unknown calculator action: " ++ m
