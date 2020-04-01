{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE NumericUnderscores  #-}
{-# LANGUAGE PatternSynonyms     #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Background tasks:
--
-- * Copying blocks from the VolatileDB to the ImmutableDB
-- * Performing and scheduling garbage collections on the VolatileDB
-- * Writing snapshots of the LedgerDB to disk and deleting old ones
-- * Executing scheduled chain selections
module Ouroboros.Consensus.Storage.ChainDB.Impl.Background
  ( -- * Launch background tasks
    launchBgTasks
    -- * Copying blocks from the VolatileDB to the ImmutableDB
  , copyToImmDB
  , copyAndSnapshotRunner
  , updateLedgerSnapshots
     -- * Executing garbage collection
  , garbageCollect
    -- * Scheduling garbage collections
  , GcSchedule
  , GcParams (..)
  , newGcSchedule
  , scheduleGC
  , computeTimeForGC
  , gcScheduleRunner
    -- * Adding blocks to the ChainDB
  , addBlockRunner
    -- * Executing scheduled chain selections
  , scheduledChainSelection
  , scheduledChainSelectionRunner
  ) where

import           Control.Exception (assert)
import           Control.Monad (forM_, forever, unless, void)
import           Control.Tracer
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import           Data.Maybe (fromMaybe)
import           Data.Time.Clock
import           Data.Void (Void)
import           Data.Word
import           GHC.Stack (HasCallStack)

import           Ouroboros.Network.AnchoredFragment (AnchoredFragment (..))
import qualified Ouroboros.Network.AnchoredFragment as AF
import           Ouroboros.Network.Block (ChainHash (..), HasHeader, Point,
                     SlotNo (..), blockPoint, pointHash, pointSlot)
import           Ouroboros.Network.Point (WithOrigin (..))

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.BlockchainTime (onSlotChange)
import           Ouroboros.Consensus.Config
import           Ouroboros.Consensus.Ledger.SupportsProtocol
import           Ouroboros.Consensus.Protocol.Abstract
import           Ouroboros.Consensus.Util (whenJust)
import           Ouroboros.Consensus.Util.IOLike
import           Ouroboros.Consensus.Util.ResourceRegistry

import           Ouroboros.Consensus.Storage.ChainDB.API (BlockRef (..),
                     ChainDbFailure (..))
import qualified Ouroboros.Consensus.Storage.ChainDB.Impl.BlockCache as BlockCache
import           Ouroboros.Consensus.Storage.ChainDB.Impl.ChainSel
                     (addBlockSync, chainSelectionForBlock)
import qualified Ouroboros.Consensus.Storage.ChainDB.Impl.ImmDB as ImmDB
import qualified Ouroboros.Consensus.Storage.ChainDB.Impl.LgrDB as LgrDB
import           Ouroboros.Consensus.Storage.ChainDB.Impl.Types
import qualified Ouroboros.Consensus.Storage.ChainDB.Impl.VolDB as VolDB

{-------------------------------------------------------------------------------
  Launch background tasks
-------------------------------------------------------------------------------}

launchBgTasks
  :: forall m blk. (IOLike m, LedgerSupportsProtocol blk)
  => ChainDbEnv m blk
  -> Word64 -- ^ Number of immutable blocks replayed on ledger DB startup
  -> m ()
launchBgTasks cdb@CDB{..} replayed = do
    !addBlockThread <- launch $
      addBlockRunner cdb
    gcSchedule <- newGcSchedule
    !gcThread <- launch $
      gcScheduleRunner gcSchedule $ garbageCollect cdb
    !copyAndSnapshotThread <- launch $
      copyAndSnapshotRunner cdb gcSchedule replayed
    !chainSyncThread <- scheduledChainSelectionRunner cdb
    atomically $ writeTVar cdbKillBgThreads $
      sequence_ [addBlockThread, gcThread, copyAndSnapshotThread, chainSyncThread]
  where
    launch :: m Void -> m (m ())
    launch = fmap cancelThread . forkLinkedThread cdbRegistry

{-------------------------------------------------------------------------------
  Copying blocks from the VolatileDB to the ImmutableDB
-------------------------------------------------------------------------------}

-- | Copy the blocks older than @k@ from the VolatileDB to the ImmutableDB.
--
-- These headers of these blocks can be retrieved by dropping the @k@ most
-- recent blocks from the fragment stored in 'cdbChain'.
--
-- The copied blocks are removed from the fragment stored in 'cdbChain'.
--
-- This function does not remove blocks from the VolatileDB.
--
-- The 'SlotNo' of the tip of the ImmutableDB after copying the blocks is
-- returned. This can be used for a garbage collection on the VolatileDB.
--
-- NOTE: this function would not be safe when called multiple times
-- concurrently. To enforce thread-safety, a lock is obtained at the start of
-- this function and released at the end. So in practice, this function can be
-- called multiple times concurrently, but the calls will be serialised.
--
-- NOTE: this function /can/ run concurrently with all other functions, just
-- not with itself.
copyToImmDB
  :: forall m blk.
     ( IOLike m
     , ConsensusProtocol (BlockProtocol blk)
     , HasHeader blk
     , GetHeader blk
     , HasHeader (Header blk)
     , HasCallStack
     )
  => ChainDbEnv m blk
  -> m (WithOrigin SlotNo)
copyToImmDB CDB{..} = withCopyLock $ do
    toCopy <- atomically $ do
      curChain <- readTVar cdbChain
      let nbToCopy = max 0 (AF.length curChain - fromIntegral k)
          toCopy :: [Point blk]
          toCopy = map headerPoint
                 $ AF.toOldestFirst
                 $ AF.takeOldest nbToCopy curChain
      return toCopy

    if null toCopy
      -- This can't happen in practice, as we're only called when the fragment
      -- is longer than @k@. However, in the tests, we will be calling this
      -- function manually, which means it might be called when there are no
      -- blocks to copy.
      then trace NoBlocksToCopyToImmDB
      else forM_ toCopy $ \pt -> do
        let hash = case pointHash pt of
              BlockHash h -> h
              -- There is no actual genesis block that can occur on a chain
              GenesisHash -> error "genesis block on current chain"
        -- This call is cheap
        slotNoAtImmDBTip <- ImmDB.getSlotNoAtTip cdbImmDB
        assert (pointSlot pt >= slotNoAtImmDBTip) $ return ()
        blk <- VolDB.getKnownBlock cdbVolDB hash
        -- When we found a corrupt block, shut down the node. This exception
        -- will make sure we restart with validation enabled.
        unless (cdbCheckIntegrity blk) $
          let blockRef = BlockRef (blockPoint blk) (cdbIsEBB (getHeader blk))
          in throwM $ VolDbCorruptBlock blockRef

        -- We're the only one modifying the ImmutableDB, so the tip cannot
        -- have changed since we last checked it.
        ImmDB.appendBlock cdbImmDB blk
        -- TODO the invariant of 'cdbChain' is shortly violated between
        -- these two lines: the tip was updated on the line above, but the
        -- anchor point is only updated on the line below.
        atomically $ removeFromChain pt
        trace $ CopiedBlockToImmDB pt

    -- Get the /possibly/ updated tip of the ImmDB
    ImmDB.getSlotNoAtTip cdbImmDB
  where
    SecurityParam k = configSecurityParam cdbTopLevelConfig
    trace = traceWith (contramap TraceCopyToImmDBEvent cdbTracer)

    -- | Remove the header corresponding to the given point from the beginning
    -- of the current chain fragment.
    --
    -- PRECONDITION: the header must be the first one (oldest) in the chain
    removeFromChain :: Point blk -> STM m ()
    removeFromChain pt = do
      -- The chain might have been extended in the meantime.
      curChain <- readTVar cdbChain
      case curChain of
        hdr :< curChain'
          | headerPoint hdr == pt
          -> writeTVar cdbChain curChain'
        -- We're the only one removing things from 'curChain', so this cannot
        -- happen if the precondition was satisfied.
        _ -> error "header to remove not on the current chain"

    withCopyLock :: forall a. HasCallStack => m a -> m a
    withCopyLock = bracket_
      (fmap mustBeUnlocked $ tryTakeMVar cdbCopyLock)
      (putMVar  cdbCopyLock ())

    mustBeUnlocked :: forall b. HasCallStack => Maybe b -> b
    mustBeUnlocked = fromMaybe
                   $ error "copyToImmDB running concurrently with itself"

-- | Copy blocks from the VolDB to ImmDB and take snapshots of the LgrDB
--
-- We watch the chain for changes. Whenever the chain is longer than @k@, then
-- the headers older than @k@ are copied from the VolDB to the ImmDB (using
-- 'copyToImmDB'). Once that is complete,
--
-- * We periodically take a snapshot of the LgrDB (depending on its config).
--   NOTE: This implies we do not take a snapshot of the LgrDB if the chain
--   hasn't changed, irrespective of the LgrDB policy.
-- * Schedule GC of the VolDB ('scheduleGC') for the 'SlotNo' of the most
--   recent block that was copied.
--
-- It is important that we only take LgrDB snapshots when are are /sure/ they
-- have been copied to the ImmDB, since the LgrDB assumes that all snapshots
-- correspond to immutable blocks. (Of course, data corruption can occur and we
-- can handle it by reverting to an older LgrDB snapshot, but we should need
-- this only in exceptional circumstances.)
--
-- We do not store any state of the VolDB GC. If the node shuts down before GC
-- can happen, when we restart the node and schedule the /next/ GC, it will
-- /imply/ any previously scheduled GC, since GC is driven by slot number
-- ("garbage collect anything older than @x@").
copyAndSnapshotRunner
  :: forall m blk.
     ( IOLike m
     , ConsensusProtocol (BlockProtocol blk)
     , HasHeader blk
     , GetHeader blk
     , HasHeader (Header blk)
     )
  => ChainDbEnv m blk
  -> GcSchedule m
  -> Word64 -- ^ Number of immutable blocks replayed on ledger DB startup
  -> m Void
copyAndSnapshotRunner cdb@CDB{..} gcSchedule =
    loop Nothing
  where
    SecurityParam k      = configSecurityParam cdbTopLevelConfig
    LgrDB.DiskPolicy{..} = LgrDB.getDiskPolicy cdbLgrDB

    loop :: Maybe Time -> Word64 -> m Void
    loop mPrevSnapshot distance = do
      -- Wait for the chain to grow larger than @k@
      numToWrite <- atomically $ do
        curChain <- readTVar cdbChain
        check $ fromIntegral (AF.length curChain) > k
        return $ fromIntegral (AF.length curChain) - k

      -- Copy blocks to imm DB
      --
      -- This is a synchronous operation: when it returns, the blocks have been
      -- copied to disk (though not flushed, necessarily).
      copyToImmDB cdb >>= scheduleGC'

      now <- getMonotonicTime
      let distance' = distance + numToWrite
          elapsed   = (\prev -> now `diffTime` prev) <$> mPrevSnapshot

      if onDiskShouldTakeSnapshot elapsed distance' then do
        updateLedgerSnapshots cdb
        loop (Just now) 0
      else
        loop mPrevSnapshot distance'

    scheduleGC' :: WithOrigin SlotNo -> m ()
    scheduleGC' Origin      = return ()
    scheduleGC' (At slotNo) =
        scheduleGC
          (contramap TraceGCEvent cdbTracer)
          slotNo
          GcParams {
              gcDelay    = cdbGcDelay
            , gcInterval = cdbGcInterval
            }
          gcSchedule

-- | Write a snapshot of the LedgerDB to disk and remove old snapshots
-- (typically one) so that only 'onDiskNumSnapshots' snapshots are on disk.
updateLedgerSnapshots :: IOLike m => ChainDbEnv m blk -> m ()
updateLedgerSnapshots CDB{..} = do
    -- TODO avoid taking multiple snapshots corresponding to the same tip.
    void $ LgrDB.takeSnapshot  cdbLgrDB
    void $ LgrDB.trimSnapshots cdbLgrDB

{-------------------------------------------------------------------------------
  Executing garbage collection
-------------------------------------------------------------------------------}

-- | Trigger a garbage collection for blocks older than the given 'SlotNo' on
-- the VolatileDB.
--
-- Also removes the corresponding cached "previously applied points" from the
-- LedgerDB.
--
-- This is thread-safe as the VolatileDB locks itself while performing a GC.
--
-- TODO will a long GC be a bottleneck? It will block any other calls to
-- @putBlock@ and @getBlock@.
garbageCollect :: forall m blk. IOLike m => ChainDbEnv m blk -> SlotNo -> m ()
garbageCollect CDB{..} slotNo = do
    VolDB.garbageCollect cdbVolDB slotNo
    atomically $ do
      LgrDB.garbageCollectPrevApplied cdbLgrDB slotNo
      modifyTVar cdbInvalid $ fmap $ Map.filter ((>= slotNo) . invalidBlockSlotNo)
    traceWith cdbTracer $ TraceGCEvent $ PerformedGC slotNo

{-------------------------------------------------------------------------------
  Scheduling garbage collections
-------------------------------------------------------------------------------}

-- | A scheduled garbage collections.
--
-- Represented as a queue.
--
-- The background thread will continuously try to pop the first element of the
-- queue. Whenever it manages to pop a @('Time', 'SlotNo')@ off: it first
-- waits until the 'Time' is passed (using 'threadDelay' with the given 'Time'
-- minus the current 'Time') and then performs a garbage collection with the
-- given 'SlotNo'.
--
-- The 'Time's in the queue should be monotonically increasing. A fictional
-- example (with hh:mm:ss):
--
-- > [(16:01:12, SlotNo 1012), (16:04:38, SlotNo 1045), ..]
--
-- Scheduling a garbage collection with 'scheduleGC' will add an entry to the
-- end of the queue for the given slot at the time equal to now
-- ('getMonotonicTime') + the @gcDelay@. Unless the last entry in the queue
-- was scheduled for the same @gcInterval@, in that case the new entry
-- replaces the existing entry. The goal of this is to batch garbage
-- collections so that, when possible, at most one garbage collection happens
-- every @gcInterval@.
--
-- For example, starting with an empty queue and @gcDelay = 5min@ and
-- @gcInterval = 10s@:
--
-- At 8:43:22, we schedule a GC for slot 10:
--
-- > [(8:48:30, SlotNo 10)]
--
-- The scheduled time is rounded up to the next interval. Next, at 8:43:24, we
-- schedule a GC for slot 11:
--
-- > [(8:48:30, SlotNo 11)]
--
-- Note that the existing entry is replaced with the new one, as they map to
-- the same @gcInterval@. Instead of two GCs 2 seconds apart, we will only
-- schedule one GC.
--
-- Next, at 8:44:02, we schedule a GC for slot 12:
--
-- > [(8:48:30, SlotNo 11), (8:49:10, SlotNo 12)]
--
-- Now, a new entry was appended to the queue, as it doesn't map to the same
-- @gcInterval@ as the last one.
--
-- In other words, everything scheduled in the first 10s will be done after
-- 20s. The bounds are the open-closed interval:
--
-- > (now + gcDelay, now + gcDelay + gcInterval]
--
-- Whether we're syncing at high speed or downloading blocks as they are
-- produced, the length of the queue will be at most @gcDelay / gcInterval@,
-- e.g., 5min / 10s = 30 entries.
data GcSchedule m = GcSchedule (StrictTQueue m (Time, SlotNo))

data GcParams = GcParams {
      gcDelay    :: !DiffTime
      -- ^ How long to wait until performing the GC. See 'cdbsGcDelay'.
    , gcInterval :: !DiffTime
      -- ^ The GC interval: the minimum time between two GCs. See
      -- 'cdbsGcInterval'.
    }
  deriving (Show)

newGcSchedule :: IOLike m => m (GcSchedule m)
newGcSchedule = GcSchedule <$> atomically newTQueue

scheduleGC
  :: forall m blk. IOLike m
  => Tracer m (TraceGCEvent blk)
  -> SlotNo    -- ^ The slot to use for garbage collection
  -> GcParams
  -> GcSchedule m
  -> m ()
scheduleGC tracer slotNo gcParams (GcSchedule queue) = do
    timeScheduledForGC <- computeTimeForGC gcParams <$> getMonotonicTime
    atomically $ do
      mbLastScheduled <- peekTailQueue queue
      case mbLastScheduled of
        Just (lastTimeScheduledForGC, _lastSlotNo)
          | timeScheduledForGC == lastTimeScheduledForGC
          -> modifyTailTQueue queue (const (timeScheduledForGC, slotNo))
        _ -> writeTQueue queue (timeScheduledForGC, slotNo)
    traceWith tracer $ ScheduledGC slotNo timeScheduledForGC

computeTimeForGC
  :: GcParams
  -> Time      -- ^ Now
  -> Time      -- ^ The time at which to perform the GC
computeTimeForGC GcParams { gcDelay, gcInterval } (Time now) =
    Time $ picosecondsToDiffTime $
      -- We're rounding up to the nearest interval, because rounding down
      -- would mean GC'ing too early.
      roundUpToInterval
        (diffTimeToPicoseconds gcInterval)
        (diffTimeToPicoseconds (now + gcDelay))

-- | Round to an interval
--
-- PRECONDITION: interval > 0
--
-- >    [roundUpToInterval 5 n | n <- [1..15]]
-- > == [5,5,5,5,5, 10,10,10,10,10, 15,15,15,15,15]
--
-- >    roundUpToInterval 5 0
-- > == 0
roundUpToInterval :: (Integral a, Integral b) => b -> a -> a
roundUpToInterval interval x
    | m == 0
    = d * fromIntegral interval
    | otherwise
    = (d + 1) * fromIntegral interval
  where
    (d, m) = x `divMod` fromIntegral interval

gcScheduleRunner
  :: forall m. IOLike m
  => GcSchedule m
  -> (SlotNo -> m ())  -- ^ GC function
  -> m Void
gcScheduleRunner (GcSchedule queue) runGc = forever $ do
    (timeScheduledForGC, slotNo) <- atomically $
      readTQueue queue
    currentTime <- getMonotonicTime
    let toWait = max 0 (timeScheduledForGC `diffTime` currentTime)
    threadDelay toWait
    -- Garbage collection is called synchronously
    runGc slotNo

{-------------------------------------------------------------------------------
  Adding blocks to the ChainDB
-------------------------------------------------------------------------------}

-- | Read blocks from 'cdbBlocksToAdd' and add them synchronously to the
-- ChainDB.
addBlockRunner
  :: (IOLike m, LedgerSupportsProtocol blk, HasCallStack)
  => ChainDbEnv m blk
  -> m Void
addBlockRunner cdb@CDB{..} = forever $ do
    blockToAdd <- getBlockToAdd cdbBlocksToAdd
    addBlockSync cdb blockToAdd

{-------------------------------------------------------------------------------
  Executing scheduled chain selections
-------------------------------------------------------------------------------}

-- | Retrieve the 'FutureBlockToAdd's from 'cdbFutureBlocks' for which chain
-- selection was scheduled at the current slot. Run chain selection for each
-- of them.
scheduledChainSelection
  :: (IOLike m, LedgerSupportsProtocol blk, HasCallStack)
  => ChainDbEnv m blk
  -> SlotNo  -- ^ The current slot
  -> m ()
scheduledChainSelection cdb@CDB{..} curSlot = do
    (mbFutureBlocks, remaining)
      <- atomically $ updateTVar cdbFutureBlocks $ \futureBlocks ->
        -- Extract and delete the value stored at @curSlot@
        let (mbFutureBlocks, remaining) = Map.updateLookupWithKey
              (\_ _ -> Nothing) curSlot futureBlocks
        in (remaining, (mbFutureBlocks, remaining))
    -- The list is stored in reverse order so we can easily prepend. We
    -- reverse them here now so we add them in chronological order, even
    -- though this should not matter, as they are all blocks for the same
    -- slot: at most one block per slot can be adopted.
    --
    -- The only exception is an EBB, which shares the slot with a regular
    -- block. Either order of adding them would result in the same chain, but
    -- adding the EBB before the regular block is cheaper, as we can simply
    -- extend the current chain instead of adding a disconnected block first
    -- and then switching to a very short fork.
    whenJust (NE.reverse <$> mbFutureBlocks) $ \futureBlocks -> do
      let nbScheduled = fromIntegral $ sum $ length <$> Map.elems remaining
      traceWith cdbTracer $ TraceAddBlockEvent $
        RunningScheduledChainSelection
          (fmap (headerPoint . futureBlockHdr) futureBlocks)
          curSlot
          nbScheduled
      -- If an exception occurs during a call to 'chainSelectionForBlock',
      -- then no chain selection will be performed for the blocks after it.
      -- Only real errors that would shut down the ChainDB could be thrown. In
      -- which case, the ChainDB has to be (re)started, triggering a full
      -- chain selection, which would include these blocks. So there is no
      -- risk of "forgetting" to add a block.
      forM_ futureBlocks $ \(FutureBlockToAdd hdr varChainSelectionPerformed) -> do
        newTip <- chainSelectionForBlock cdb BlockCache.empty hdr
        -- Important: notify that chain selection has been performed for the block
        atomically $ putTMVar varChainSelectionPerformed newTip

-- | Whenever the current slot changes, call 'scheduledChainSelection' for the
-- (new) current slot.
--
-- This function forks of a background thread and terminates afterwards,
-- returning a handle to kill the background thread.
scheduledChainSelectionRunner
  :: (IOLike m, LedgerSupportsProtocol blk, HasCallStack)
  => ChainDbEnv m blk -> m (m ())
scheduledChainSelectionRunner cdb@CDB{..} =
    onSlotChange cdbBlockchainTime (scheduledChainSelection cdb)
