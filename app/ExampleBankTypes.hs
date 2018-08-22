{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

module ExampleBankTypes
  ( BankConfig (..)
  , BankResult (..)
  ) where

import           Data.Aeson              (FromJSON (..), ToJSON (..),
                                          genericParseJSON, genericToJSON)
import           Data.Aeson.Casing       (aesonDrop, snakeCase)
import           GHC.Generics            (Generic)
import qualified System.MQ.Encoding.JSON as JSON (pack, unpack)
import           System.MQ.Protocol      (MessageLike (..), MessageType (..),
                                          Props (..), jsonEncoding)

-- | 'BankConfig' represents configuration data for bank.
--
data BankConfig = BankConfig { months   :: Int
                             , perMonth :: Float
                             }
  deriving (Show, Generic)

instance ToJSON BankConfig where
  toJSON = genericToJSON $ aesonDrop 0 snakeCase
instance FromJSON BankConfig where
  parseJSON = genericParseJSON $ aesonDrop 0 snakeCase
instance MessageLike BankConfig where
  props = Props "example_bank" Config jsonEncoding
  pack = JSON.pack
  unpack = JSON.unpack

-- | 'BankResult' represents result data produced by bank.
--
newtype BankResult = BankResult { total :: Float }
  deriving (Show, Generic)

instance ToJSON BankResult
instance FromJSON BankResult
instance MessageLike BankResult where
  props = Props "example_bank" Result jsonEncoding
  pack = JSON.pack
  unpack = JSON.unpack

