{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

module ExampleRadioTypes
  ( RadioData (..)
  ) where

import           Data.Aeson              (FromJSON (..), ToJSON (..))
import           GHC.Generics            (Generic)
import qualified System.MQ.Encoding.JSON as JSON (pack, unpack)
import           System.MQ.Protocol      (MessageLike (..), MessageType (..),
                                          Props (..), jsonEncoding)

-- | 'RadioData' represents some data that can be trasfered from one component to another.
--
newtype RadioData = RadioData { message :: String }
  deriving (Show, Generic)

instance ToJSON RadioData
instance FromJSON RadioData
instance MessageLike RadioData where
  props = Props "example_radio" Data jsonEncoding
  pack = JSON.pack
  unpack = JSON.unpack
