module Database.PostgreSQL.Replicant.ReplicationSlot where

import Control.Exception
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import Database.PostgreSQL.LibPQ

import Database.PostgreSQL.Replicant.Exception
import Database.PostgreSQL.Replicant.PostgresUtils
import Database.PostgreSQL.Replicant.Types.Lsn

-- data ReplicationSlot =
--   ReplicationSlot
--   { replicationSlotName            :: ByteString
--   , replicationSlotConsistentPoint :: ByteString
--   , replicationSlotSnapshotName    :: ByteString
--   , replicationSlotOutputPlugin    :: ByteString
--   }
--   deriving (Eq, Show)

data ReplicationSlotInfo
  = ReplicationSlotInfo
  { slotName    :: ByteString
  , slotPlugin  :: ByteString
  , slotType    :: ReplicationSlotType
  , slotActive  :: ReplicationSlotActive
  , slotRestart :: LSN
  }
  deriving (Eq, Show)

data ReplicationSlotType = Logical | Physical | UnknownSlotType
  deriving (Eq, Show)

parseSlotType :: ByteString -> ReplicationSlotType
parseSlotType "logical"  = Logical
parseSlotType "physical" = Physical
parseSlotType _          = UnknownSlotType

data ReplicationSlotActive = Active | Inactive
  deriving (Eq, Show)

parseSlotActive :: ByteString -> ReplicationSlotActive
parseSlotActive "t" = Active
parseSlotActive "f" = Inactive
parseSlotActive _   = Inactive

createReplicationSlotCommand :: ByteString -> ByteString
createReplicationSlotCommand slotName =
  B.intercalate " " ["CREATE_REPLICATION_SLOT", slotName, "LOGICAL wal2json"]

-- | Create a replication slot using synchronous query execution.
-- @Nothing@ means the command was unsuccessful and the slot was not
-- created.
createReplicationSlotSync :: Connection -> ByteString -> IO (Maybe ReplicationSlotInfo)
createReplicationSlotSync conn slotName = do
  result <- exec conn $ createReplicationSlotCommand slotName
  case result of
    Nothing -> pure Nothing
    Just r  -> do
      sName           <- getvalue' r (toRow 0) (toColumn 0)
      consistentPoint <- getvalue' r (toRow 0) (toColumn 1)
      outputPlugin    <- getvalue' r (toRow 0) (toColumn 3)
      case (sName, consistentPoint, outputPlugin) of
        (Just s, Just c, Just op) ->
          case fromByteString c of
            Left _ -> throwIO $ ReplicantException "createReplicationSlotSync: invalid LSN detected"
            Right lsn -> pure $ Just (ReplicationSlotInfo s op Logical Active lsn)
        _ -> do
          err <- maybe "createReplicationSlotSync: unknown error" id <$> errorMessage conn
          throwIO $ ReplicantException (B8.unpack err)

getReplicationSlotInfoCommand :: Connection -> ByteString -> IO (Maybe ByteString)
getReplicationSlotInfoCommand conn slotName = do
  escapedName <- escapeStringConn conn slotName
  case escapedName of
    Nothing -> pure Nothing
    Just escaped ->
      pure $ Just $
      B.intercalate
      ""
      [ "select slot_name, plugin, slot_type, active, restart_lsn from pg_replication_slots where slot_name = '"
      , escaped
      , "';"
      ]

getReplicationSlotSync :: Connection -> ByteString -> IO (Maybe ReplicationSlotInfo)
getReplicationSlotSync conn slotName = do
  replicationSlotInfoQuery <- getReplicationSlotInfoCommand conn slotName
  case replicationSlotInfoQuery of
    Nothing -> pure Nothing
    Just query -> do
      result <- exec conn query
      case result of
        Nothing -> pure Nothing
        Just r  -> do
          slotName    <- getvalue' r (toRow 0) (toColumn 0)
          slotPlugin  <- getvalue' r (toRow 0) (toColumn 1)
          slotType    <- getvalue' r (toRow 0) (toColumn 2)
          slotActive  <- getvalue' r (toRow 0) (toColumn 3)
          slotRestart <- getvalue' r (toRow 0) (toColumn 4)
          case (slotName, slotPlugin, slotType, slotActive, slotRestart) of
            (Just n, Just p, Just t, Just a, Just r) -> do
              case fromByteString r of
                Left _ -> pure Nothing -- TODO: this shouldn't happen...
                Right lsn -> pure $ Just $ ReplicationSlotInfo n p (parseSlotType t) (parseSlotActive a) lsn
            _ ->  do
              err <- maybe "getReplicationSlotSync: unknown error" id <$> errorMessage conn
              throwIO $ ReplicantError err

-- | Create replication slot or retrieve the existing slot
setupReplicationSlot :: Connection -> ByteString -> IO (Maybe ReplicationSlotInfo)
setupReplicationSlot conn slotName = do
  maybeSlot <- getReplicationSlotSync conn slotName
  case maybeSlot of
    Just slot -> pure $ Just slot
    Nothing   -> createReplicationSlotSync conn slotName
