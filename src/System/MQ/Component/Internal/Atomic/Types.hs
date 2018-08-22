{-# LANGUAGE TemplateHaskell #-}

module System.MQ.Component.Internal.Atomic.Types
  ( Atomic (..)
  , IsAlive
  , lastMsgId
  , message
  , threadId
  , isAlive
  ) where

import           Control.Concurrent (ThreadId)
import           Control.Lens.TH    (makeLenses)
import           System.MQ.Protocol (Id)


-- | 'IsAlive' is the state for the communication layer's thread, which can be in two states: running or down.
--
type IsAlive = Bool

-- | 'Atomic' contains atomic information that is needed for communication and technical layers.
--
data Atomic = Atomic { _threadId  :: ThreadId -- ^ communication layer's 'ThreadId'
                     , _isAlive   :: IsAlive  -- ^ shows whether communication thread is alive
                     , _message   :: String   -- ^ some useful messages for monitoring from communication layer
                     , _lastMsgId :: Id       -- ^ id of last message that was received on communication level
                     }
  deriving (Show, Eq, Ord)

makeLenses ''Atomic


