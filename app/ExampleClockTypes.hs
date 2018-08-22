{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

module ExampleClockTypes
  ( ClockConfig (..)
  , ClockResult (..)
  ) where

import           Data.Aeson              as JSON (FromJSON (..), ToJSON (..))
import           GHC.Generics            (Generic)
import qualified System.MQ.Encoding.JSON as JSON (pack, unpack)
import           System.MQ.Protocol      (MessageLike (..), MessageType (..),
                                          Props (..), jsonEncoding)

-- | 'ClockConfig' represents configuration data for clock.
--
newtype ClockConfig = ClockConfig { question :: String }
  deriving (Show, Generic)

instance ToJSON ClockConfig
instance FromJSON ClockConfig
instance MessageLike ClockConfig where
  props = Props "example_clock" Config jsonEncoding
  pack = JSON.pack
  unpack = JSON.unpack

-- | 'ClockResult' represents result data produced by clock example.
--
newtype ClockResult = ClockResult { answer :: Int }
  deriving (Show, Generic)

instance ToJSON ClockResult
instance FromJSON ClockResult
instance MessageLike ClockResult where
  props = Props "example_clock" Result jsonEncoding
  pack = JSON.pack
  unpack = JSON.unpack
