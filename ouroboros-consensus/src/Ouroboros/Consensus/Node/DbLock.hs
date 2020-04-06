{-# LANGUAGE OverloadedStrings #-}

module Ouroboros.Consensus.Node.DbLock (
    DbLocked (..)
  , dbLockFile
  , lockDB
  ) where

import           Control.Concurrent
import           Control.Monad (void)
import           Data.Text (Text)
import           Ouroboros.Consensus.Storage.FS.API
import           Ouroboros.Consensus.Storage.FS.API.Types
import           Ouroboros.Consensus.Util.ResourceRegistry

import           Control.Exception
import           System.FileLock

-- | This can run from multiple processes concurrently, without any locking.
-- It creates the db directory and its lock file, if any of them doesn't exist
-- already.
createDBFolder :: Monad m => HasFS m h -> m ()
createDBFolder hasFS = do
    createDirectoryIfMissing hasFS True root
    void $ hOpen hasFS pFile (WriteMode AllowExisting)
  where
    root  = mkFsPath []
    pFile = fsPathFromList ["dblock"]

-- | We try to lock the db multiple times, before we give up and throw an
-- exception. Each time, we sleep for an increasing duration. Maximum total
-- sleeping time is about 1.5 sec. The file is unlocked when the @registry@ is
-- closed.
lockDB :: ResourceRegistry IO -> HasFS IO h ->  FilePath -> IO ()
lockDB registry hasFS dbPath = do
    createDBFolder hasFS
    lockAttempt 0
  where
    lockAttempt :: Int -> IO ()
    lockAttempt n = do
      mlockFile <- allocateEither
                    registry
                    (const $ justToRight <$> tryLockFile lockFilePath Exclusive)
                    (\f -> unlockFile f >> return True)
      case (mlockFile, n) of
        (Left (), 5) -> throwIO $ DbLocked lockFilePath
        (Left (), _) -> do
          -- TODO: We should log that we failed to take the lock, sleeping and
          -- retrying.
          threadDelay $ (n + 1) * 100000
          lockAttempt $ n + 1
        (Right _, _) -> return ()

    pFile        = fsPathFromList [dbLockFile]
    lockFilePath = fsToFilePath (MountPoint dbPath) pFile

    justToRight  = maybe (Left ()) Right

dbLockFile :: Text
dbLockFile = "dblock"

newtype DbLocked = DbLocked FilePath
    deriving (Eq, Show)

instance Exception DbLocked where
    displayException (DbLocked f) =
      "The db is used by another process. File \"" <> f <> "\" is locked"
