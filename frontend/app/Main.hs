{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE NumericUnderscores     #-}
{-# LANGUAGE RecordWildCards        #-}
{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE TupleSections          #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE MultiParamTypeClasses  #-}



module Main where

import Data.Text hiding (foldl, foldl1, map)
import qualified Data.Map as M
import qualified Data.CaseInsensitive as CI

import Control.Monad.Trace

import Data.Aeson.Types

import Data.Binary
import Data.Bifunctor
import Data.Binary.Instances.Time
import GHC.Generics (Generic)

import qualified Data.ByteString as B
import Data.String.Conversions

import Control.Monad.Trace.Class (rootSpanWith)
import Monitor.Tracing
import qualified Monitor.Tracing.Zipkin as ZPK
import UnliftIO (MonadUnliftIO, unliftIO, UnliftIO (unliftIO))
import UnliftIO.Exception
import UnliftIO.Concurrent (forkIO, threadDelay, killThread)

import Control.Concurrent.Supervisor
import Control.Monad
import Control.Monad.IO.Class
import qualified Control.Concurrent.MVar as MVar
import           Control.Concurrent.MVar (MVar)
import Control.Concurrent.STM
import Control.Concurrent.STM.TQueue
import Control.Monad.Reader

import System.Clock
import Formatting
import Formatting.Clock

import qualified Data.UUID          as UUID
import qualified Data.UUID.V4       as UUID
import           Data.UUID (UUID)

import qualified Database.Redis as R

import qualified Data.ByteString.Base16 as Base16
import Data.Time
import System.Random
import System.Timeout
import Text.Read (readMaybe)
import qualified Monitor.Tracing.Zipkin as ZIP
import qualified Control.Monad.Trace.Class as ZIP
import qualified Control.Monad.Trace.Class as ZPK

import Log
import Log.Backend.ElasticSearch

import Foreign.Marshal.Alloc

import qualified Network.Wreq as W
import Control.Lens
import Data.Aeson (toJSON)
import Data.Aeson.Lens (key, nth)
import Monitor.Tracing.Zipkin (b3FromHeaderValue)

channel :: B.ByteString
channel = "new_requests"

-- work queues:
--
-- incoming     - placed here by the websocket handlers
-- in_progress  - our worker moves from incoming to in_progress

-- worker took too long
-- worker crashed and never produced the result

queueIncoming :: B.ByteString
queueIncoming = "queue_incoming"

data Request = Request
    { reqID         :: !UUID
    , reqDateTime   :: !UTCTime
    , reqWords      :: ![String]
    }
  deriving (Generic, Eq, Show)

data ResponseStatus
    = ResponseOK
    | ResponseWorkerError !String
    | ResponseWorkerTimeout
  deriving (Generic, Eq, Show)

data Response = Response
    { respID        :: !UUID
    , respHash      :: ![(String, Maybe Double)]
    , respStatus    :: !ResponseStatus
    }
  deriving (Generic, Eq, Show)

data WorkItem = WorkItem
    { workID        :: !UUID
    , workReceived  :: !UTCTime
    , workB3        :: !ZIP.B3
    , workRequest   :: !Request
    , workResponse  :: !(Either String (Maybe Response))
    }
  deriving (Generic, Eq, Show)

instance Binary Request
instance Binary ResponseStatus
instance Binary Response
instance Binary WorkItem

instance Binary ZIP.TraceID where
    get = ZIP.TraceID <$> get

    put (ZIP.TraceID tid) = put tid

instance Binary ZIP.SpanID where
    get = ZIP.SpanID <$> get

    put (ZIP.SpanID sid) = put sid

instance Binary ZIP.B3 where
    get = ZIP.B3 <$> get <*> get <*> get <*> get <*> get

    put (ZIP.B3 tid sid isSampled isDebug parentSpanID) = do
        put tid
        put sid
        put isSampled
        put isDebug
        put parentSpanID

doTheWork :: (MonadTrace m, MonadIO m) => Request -> m Response
doTheWork Request{..} = ZPK.clientSpan "frontend.calldataservice" $ \(Just _b3) -> do
    xs <- forM reqWords $ \w -> do
        ZPK.clientSpan "frontend.get" $ \(Just b3) -> do
            let opts = foldl (&) W.defaults
                    $ map (\(k,v) -> W.header k .~ [cs v])
                    $ M.toList
                    $ ZPK.b3ToHeaders b3
                url = "http://localhost:8080/data/" <> w -- unsanitised

            liftIO $ print url
            r <- liftIO $ W.getWith opts url
            return $ r ^. W.responseBody -- ignoring response code, hurr hurr

    let respID = reqID
        respHash = Prelude.zip reqWords $ map (readMaybe . cs) xs
        respStatus = ResponseOK

    return Response{..}

insertIncoming :: R.Connection -> Request -> ZIP.B3 -> IO (Either R.Reply (Integer, WorkItem))
insertIncoming conn req b3 = do
    workItem <- WorkItem <$> UUID.nextRandom <*> getCurrentTime <*> pure b3 <*> pure req <*> pure (Right Nothing)

    x <- R.runRedis conn $ R.lpush queueIncoming [cs $ encode workItem]

    return $ second (,workItem) x

move :: Binary b => R.Connection -> B.ByteString -> B.ByteString -> IO (Either String b)
move conn q1 q2 = do

    x <- R.runRedis conn $ R.brpoplpush q1 q2 1_000_000

    case x of
        Left err
            -> return $ Left $ show err -- hurr hurr

        Right Nothing
            -> return $ Left "incoming queue empty"

        Right (Just x')
            -> case decodeOrFail (cs x') of
                    Left _
                        -> return $ Left "couldn't decode"

                    Right (_, _, x'')
                        -> return $ Right x''

mkNewRequest :: IO Request
mkNewRequest = Request <$> UUID.nextRandom <*> getCurrentTime <*> pure ["foo", "bar"]

workerNewRequests :: TraceT (ReaderT MyCoolApp IO) ()
workerNewRequests = do
    conn <- liftIO $ R.checkedConnect R.defaultConnectInfo

    forever $ do
        runRequest conn 2
        -- threadDelay 2_000_000

workerWorker
    :: (MonadIO m, MonadLog m, MonadTrace m)
    => String
    -> m ()
workerWorker workerID = do
    runID <- liftIO $ show <$> UUID.nextRandom

    let ourQueue = cs $ "worker.queue." <> workerID <> "." <> runID

    conn <- liftIO $ R.checkedConnect R.defaultConnectInfo

    forever $ do
        ew <- liftIO $ move conn queueIncoming ourQueue
        case ew of
            Left err -> return ()
            Right w  -> processWork conn ourQueue w

resultKey :: WorkItem -> String
resultKey w = "result." <> show (workID w)

processWork
    :: (MonadIO m, MonadLog m, MonadTrace m)
    => R.Connection
    -> B.ByteString
    -> WorkItem
    -> m ()
processWork conn ourQueue w = do
    threadDelay 120_000

    ZPK.rootSpan alwaysSampled "worker" $ ZIP.serverSpan (workB3 w) $ do
        childSpan "load_from_database"
                    $ threadDelay 500_000

        resp <- childSpan "do_the_work"
                    $ doTheWork $ workRequest w

        let w' = w { workResponse = Right $ Just resp }

        x <- childSpan "publish_result"
                $ liftIO $ R.runRedis conn $ R.multiExec $ do
                    let k = cs $ resultKey w'
                    R.lpop ourQueue
                    R.lpush k [cs $ encode w']
                    R.expire k 60 -- seconds

        logMessage LogInfo "worker.published" $ String $ cs $ show x

        case x of
            R.TxSuccess _ -> liftIO $ print $ "Finished working on " <> show (workID w)
            R.TxAborted   -> return () -- we will work on this item again
            R.TxError err -> error err

doubleFree :: IO ()
doubleFree = do
    x <- allocaBytes 1_024 return
    free x
    free x

main :: IO ()
main = do
    supervisor <- newSupervisor OneForOne

    replicateM_ 10 $ do
        workerID <- show <$> UUID.nextRandom
        putStrLn $ "spawning... " <> workerID

        void $ forkSupervised supervisor fibonacciRetryPolicy
             $ runApp "worker" zipkinSettingsServer $ workerWorker workerID

    replicateM_ 1 $ do
        void $ forkSupervised supervisor fibonacciRetryPolicy
            $ runApp "frontend" zipkinSettingsFrontEnd workerNewRequests

    let es = eventStream supervisor

    forever $ do
        e <- atomically $ readTQueue es
        print e

ep :: ZPK.Endpoint
ep = ZPK.Endpoint
    (Just "x4-laptop")
    Nothing
    (Just "127.0.0.1")
    Nothing

zipkinSettingsServer :: ZPK.Settings
zipkinSettingsServer = ZPK.defaultSettings
    { ZPK.settingsEndpoint          = Just "worker"
    , ZPK.settingsPublishPeriod     = Just $ secondsToNominalDiffTime 1
    }

zipkinSettingsFrontEnd :: ZPK.Settings
zipkinSettingsFrontEnd = ZPK.defaultSettings
    { ZPK.settingsEndpoint          = Just "api"
    , ZPK.settingsPublishPeriod     = Just $ secondsToNominalDiffTime 1
    }

runRequest :: (MonadIO m, MonadLog m, MonadTrace m) => R.Connection -> Integer -> m ()
runRequest conn timeoutSeconds = ZPK.rootSpan alwaysSampled "runRequest" $ do
    t0 <- liftIO $ getTime Monotonic

    -- pretend this came from an external client
    req <- childSpan "parse_request"
                $ liftIO mkNewRequest

    ew <- ZPK.clientSpan "call_worker" $ \(Just b3) ->
            liftIO $ tryAny $ insertIncoming conn req b3

    childSpan "get_worker_result" $ do
        case ew of
            Right (Right (n, w)) -> do
                ZPK.tag "work.id" $ cs $ show (workID w)

                liftIO $ putStrLn $ "Inserted " <> show (workID w) <> "; incoming queue size " <> show n
                result <- liftIO $ R.runRedis conn
                                 $ R.brpop [cs $ resultKey w]
                                           timeoutSeconds

                t1 <- liftIO $ getTime Monotonic

                let elapsed :: String
                    elapsed = cs $ format timeSpecs t0 t1

                ZPK.tag "tag.worker.walltime" (cs elapsed) -- hurr strings

                case result of
                    Right (Just (_key, value)) -> case decodeOrFail $ cs value of
                        Right (_, _, w::WorkItem) -> do
                            liftIO $ putStrLn $ elapsed <> " Received result: " <> show w
                            return ()
                        err -> error $ show err
                    Right Nothing -> return () -- didn't find anything in our queue
                    _ -> error $ show result

            _ -> error $ show ew

instance MonadLog (TraceT (ReaderT MyCoolApp IO)) where
    logMessage level k v = do
        le <- asks myLoggerEnv
        now <- liftIO getCurrentTime
        liftIO $ logMessageIO le now level k v

    localDomain d = local f
      where
        f (MyCoolApp le ad) = MyCoolApp le' ad
          where
            le' = le { leDomain = ld ++ [d] }
            ld  = leDomain le

    localMaxLogLevel level = local f
        where
            f (MyCoolApp le ad) = MyCoolApp le' ad
              where
                le' = le { leMaxLogLevel = level }

    getLoggerEnv = asks myLoggerEnv

    localData pairs = local f
      where
        f (MyCoolApp le ad) = MyCoolApp le' ad
          where
            le' = le { leData = ld ++ pairs }
            ld  = leData le

data MyCoolApp = MyCoolApp
    { myLoggerEnv :: LoggerEnv
    , myAppData :: Int
    }

esConfig :: ElasticSearchConfig
esConfig = defaultElasticSearchConfig
    { esServer  = "http://localhost:9200"
    , esIndex   = "my-app"
    }

-- If elasticsearch is down, this crashes on startup. Related: https://github.com/scrive/log/issues/49
runApp :: Text -> ZIP.Settings -> TraceT (ReaderT MyCoolApp IO) r -> IO r
runApp name zipSettings action = withElasticSearchLogger esConfig $ \logger -> do
        let le = LoggerEnv logger name [] [] LogInfo
            mca = MyCoolApp le 42
        runReaderT (ZPK.with zipSettings $ ZPK.run action) mca


