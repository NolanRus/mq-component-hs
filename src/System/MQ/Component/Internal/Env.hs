{-# LANGUAGE DuplicateRecordFields #-}

module System.MQ.Component.Internal.Env
  (
    Name
  , Env (..)
  , TwoChannels (..)
  , ThreeChannels (..)
  ) where

import           Control.Concurrent.MVar             (MVar)
import           System.MQ.Component.Internal.Atomic (Atomic)
import           System.MQ.Protocol                  (Creator)
import           System.MQ.Transport                 (PullChannel, PushChannel,
                                                      SubChannel)


type Name = String

data Env = Env { name      :: Name
               , creator   :: Creator
               , logfile   :: FilePath
               , frequency :: Int
               , atomic    :: MVar Atomic
               }

data TwoChannels = TwoChannels { fromScheduler :: SubChannel
                               , toScheduler   :: PushChannel
                               }

data ThreeChannels = ThreeChannels { fromScheduler  :: SubChannel
                                   , toScheduler    :: PushChannel
                                   , fromController :: PullChannel
                                   }
