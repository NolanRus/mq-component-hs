module System.MQ.Component.Extras.Validation
  ( validateCondition
  , validateConditionMaybe
  , catchRuntimeError
  ) where

import           System.IO.Unsafe                 (unsafePerformIO)

import           Control.Exception                (catch, SomeException)

import           System.MQ.Component.Extras.Error (throwErrorIncorrectInput)
import           System.MQ.Monad                  (MQMonadS)

-- Checks if condition fulfilled.
-- If not, throws throwErrorIncorrectInput with corresponding message, returns value otherwise
validateCondition :: (a -> Bool) -> a -> String -> MQMonadS s a
validateCondition condition val msg = if (condition val)
                                        then return val
                                        else throwErrorIncorrectInput msg

-- If there is (Just val) then checks if condition fulfilled.
-- If not, throws throwErrorIncorrectInput with corresponding message, returns value otherwise
-- If there is Nothing, does nothing
validateConditionMaybe :: (a -> Bool) -> Maybe a -> String -> MQMonadS s (Maybe a)
validateConditionMaybe condition (Just val) msg = if (condition val)
                                                    then return $ Just val
                                                    else throwErrorIncorrectInput msg
validateConditionMaybe _ Nothing _              = return Nothing

-- Catches any runtime error and throws custom MQError with corresponding code and message
catchRuntimeError :: a -> (String -> MQMonadS s a) -> String -> MQMonadS s a
catchRuntimeError val throwFunc msg = unsafePerformIO $ (val `seq` return . return $ val) `catch` handler
  where
    handler e = return . throwFunc $ msg ++ ": " ++ show (e::SomeException)
