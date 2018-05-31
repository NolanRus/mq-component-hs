{-# LANGUAGE RankNTypes #-}

module System.MQ.Component.Extras.Error
  ( throwComponentError
  , throwForeignError
  , throwErrorIncorrectInput
  ) where

import           Control.Monad.Except (throwError)
import           System.MQ.Error      (MQError (..), errorComponent,
                                       errorForeign, errorIncorrectInput)
import           System.MQ.Monad      (MQMonadS)

throwErrorIncorrectInput :: String -> MQMonadS s a
throwErrorIncorrectInput = throwError . MQError errorIncorrectInput

throwComponentError :: String -> MQMonadS s a
throwComponentError = throwError . MQError errorComponent

throwForeignError :: String -> MQMonadS s a
throwForeignError = throwError . MQError errorForeign
