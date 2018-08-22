{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}

module ExampleCalculatorTypes
  ( CalculatorConfig (..)
  , CalculatorResult (..)
  ) where

import           Data.Aeson              (FromJSON (..), ToJSON (..))
import           GHC.Generics            (Generic)
import qualified System.MQ.Encoding.JSON as JSON (pack, unpack)
import           System.MQ.Protocol      (MessageLike (..), MessageType (..),
                                          Props (..), jsonEncoding)

-- | 'CalculatorConfig' represents configuration data for calculator.
--
data CalculatorConfig = CalculatorConfig { first  :: Float
                                         , second :: Float
                                         , action :: String
                                         }
  deriving (Show, Generic)

instance ToJSON CalculatorConfig
instance FromJSON CalculatorConfig
instance MessageLike CalculatorConfig where
  props = Props "example_calculator" Config jsonEncoding
  pack = JSON.pack
  unpack = JSON.unpack

-- | 'CalculatorResult' represents result data produced by calculator.
--
newtype CalculatorResult = CalculatorResult { answer :: Float }
  deriving (Show, Generic)

instance ToJSON CalculatorResult
instance FromJSON CalculatorResult
instance MessageLike CalculatorResult where
  props = Props "example_calculator" Result jsonEncoding
  pack = JSON.pack
  unpack = JSON.unpack
