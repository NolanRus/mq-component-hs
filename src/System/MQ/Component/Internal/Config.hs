{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module System.MQ.Component.Internal.Config
  (
    loadEnv
  , load3Channels
  , load3ChannelsWithContext
  , load2Channels
  , load2ChannelsWithContext
  , loadTechChannels
  , loadTechChannelsWithContext
  , openCommunicationalConnectionToScheduler
  , openCommunicationalConnectionFromScheduler
  , openTechnicalConnectionToScheduler
  , openTechnicalConnectionFromScheduler
  ) where

import           Control.Concurrent.MVar          (newEmptyMVar)
import           Control.Monad.IO.Class           (liftIO)
import           Data.Aeson.Picker                ((|--))
import qualified Data.Text                        as T (Text, pack)
import           System.BCD.Config                (getConfigText)
import           System.MQ.Component.Internal.Env (Env (..), Name,
                                                   ThreeChannels (..),
                                                   TwoChannels (..))
import           System.MQ.Monad                  (MQMonadS)
import           System.MQ.Transport              (ConnectTo (..), Context,
                                                   Host, HostPort (..), Port,
                                                   contextM)
import           System.MQ.Transport              (PushChannel, SubChannel)

openCommunicationalConnectionToScheduler :: IO PushChannel
openCommunicationalConnectionToScheduler = openConnection comport schedulerInFromConfig

openCommunicationalConnectionFromScheduler :: IO SubChannel
openCommunicationalConnectionFromScheduler = openConnection comport schedulerOutFromConfig

openTechnicalConnectionToScheduler :: IO PushChannel
openTechnicalConnectionToScheduler = openConnection techport schedulerInFromConfig

openTechnicalConnectionFromScheduler :: IO SubChannel
openTechnicalConnectionFromScheduler = openConnection techport schedulerOutFromConfig

openConnection :: ConnectTo a => (SchedulerCfg -> Port) -> IO SchedulerCfg -> IO a
openConnection portFromConfig getConfig = do
    context' <- contextM
    config@SchedulerCfg{..} <- getConfig
    connectTo (HostPort host (portFromConfig config)) context'

loadEnv :: Name -> IO Env
loadEnv name' = do
    config         <- getConfigText
    let creator'   = config |-- ["params", T.pack name', "creator"]
    let logfile'   = config |-- ["params", T.pack name', "logfile"]
    let frequency' = config |-- ["params", T.pack name', "frequency"]
    Env name' creator' logfile' frequency' <$> liftIO newEmptyMVar

load3Channels :: forall s. Name -> MQMonadS s ThreeChannels
load3Channels name' = contextM >>= flip load3ChannelsWithContext name'

load3ChannelsWithContext :: forall s. Context -> Name -> MQMonadS s ThreeChannels
load3ChannelsWithContext context' name' = do
    sIn   <- liftIO schedulerInFromConfig
    sOut  <- liftIO schedulerOutFromConfig
    (ControllerCfg contr) <- liftIO $ controllerFromConfig name'

    fromScheduler  <- connectTo (comHelper sOut) context'
    toScheduler    <- connectTo (comHelper sIn) context'
    fromController <- connectTo contr context'
    pure ThreeChannels{..}

load2Channels :: forall s. MQMonadS s TwoChannels
load2Channels = contextM >>= load2ChannelsWithContext

load2ChannelsWithContext :: forall s. Context -> MQMonadS s TwoChannels
load2ChannelsWithContext = flip configHelper comHelper

loadTechChannels :: forall s. MQMonadS s TwoChannels
loadTechChannels = contextM >>= loadTechChannelsWithContext

loadTechChannelsWithContext :: forall s. Context -> MQMonadS s TwoChannels
loadTechChannelsWithContext = flip configHelper techHelper

--------------------------------------------------------------------------------
-- INTERNAL
--------------------------------------------------------------------------------

data SchedulerCfg = SchedulerCfg { host     :: Host
                                 , comport  :: Port
                                 , techport :: Port
                                 }

newtype ControllerCfg = ControllerCfg HostPort

configHelper :: forall s. Context -> (SchedulerCfg -> HostPort) -> MQMonadS s TwoChannels
configHelper context' helper = do
    sIn  <- liftIO schedulerInFromConfig
    sOut <- liftIO schedulerOutFromConfig

    fromScheduler <- connectTo (helper sOut) context'
    toScheduler   <- connectTo (helper sIn) context'
    pure TwoChannels{..}

comHelper :: SchedulerCfg -> HostPort
comHelper SchedulerCfg{..} = HostPort host comport

techHelper :: SchedulerCfg -> HostPort
techHelper SchedulerCfg{..} = HostPort host techport


controllerFromConfig :: Name -> IO ControllerCfg
controllerFromConfig name' = do
    config <- getConfigText
    let host' = config |-- ["deploy", "monique", "controller", "host"]
    let port' = config |-- ["params", T.pack name', "port"]
    pure . ControllerCfg $ HostPort host' port'

schedulerInFromConfig :: IO SchedulerCfg
schedulerInFromConfig = schedulerFromJSON ["deploy", "monique", "scheduler-in"]

schedulerOutFromConfig :: IO SchedulerCfg
schedulerOutFromConfig = schedulerFromJSON ["deploy", "monique", "scheduler-out"]

schedulerFromJSON :: [T.Text] -> IO SchedulerCfg
schedulerFromJSON route = do
    config <- getConfigText
    let getField f = config |-- (route ++ [f])
    pure $ SchedulerCfg (getField "host")
                        (getField "comport")
                        (getField "techport")

