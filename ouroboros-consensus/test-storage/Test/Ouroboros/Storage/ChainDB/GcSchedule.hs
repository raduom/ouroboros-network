{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE NamedFieldPuns             #-}
module Test.Ouroboros.Storage.ChainDB.GcSchedule (tests, example) where

import           Data.List

import           Data.Time.Clock

import           Ouroboros.Network.Block (SlotNo (..))

import           Ouroboros.Consensus.Util (safeMaximum)
import           Ouroboros.Consensus.Util.Condense
import           Ouroboros.Consensus.Util.IOLike

import           Ouroboros.Consensus.Storage.ChainDB.Impl.Background
                     (GcParams (..), computeTimeForGC)

import           Test.QuickCheck
import           Test.Tasty
import           Test.Tasty.QuickCheck

import           Test.Util.QuickCheck

-- TODO test whether the real implementation, i.e., 'scheduleGC' matches the
-- model in this file.

tests :: TestTree
tests = testGroup "GcSchedule"
    [ testProperty "unnecessary overlap" prop_unnecessaryOverlap
    ]

newtype Block = Block Int
  deriving stock   (Show)
  deriving newtype (Condense)

blockArrivalTime :: Block -> Time
blockArrivalTime (Block n) = Time (secondsToDiffTime (fromIntegral n))

blockSlotNo :: Block -> SlotNo
blockSlotNo (Block n) = SlotNo (fromIntegral n)

-- | Queue of scheduled GCs, in reverse order
newtype GcQueue = GcQueue { unGcQueue :: [(Time, SlotNo)] }
  deriving newtype (Condense)

instance Show GcQueue where
  show = condense

-- | Blocks still to GC, together with the earliest time at which the block
-- could have been GC'ed.
--
-- Order doesn't matter.
--
-- NOTE: in the real implementation, a GC for slot @s@ means removing all
-- blocks with a slot number < @s@ (because of EBBs, which share the slot with
-- the regular block after it). In this test, we ignore this and use <=, so a
-- GC for the slot of the block will remove the block.
newtype GcBlocks = GcBlocks { unGcBlocks :: [(Block, Time)] }
  deriving newtype (Condense)

instance Show GcBlocks where
  show = condense

data GcState = GcState {
      gcQueue  :: GcQueue
    , gcBlocks :: GcBlocks
    }
  deriving (Show)

emptyGcState :: GcState
emptyGcState = GcState (GcQueue []) (GcBlocks [])

-- Property 1: length (gcDelay / gcInterval + 1)
queueLength :: GcState -> Int
queueLength = length . unGcQueue . gcQueue

-- Property 2: size of overlap between ImmutableDB and VolatileDB
overlap :: GcState -> Int
overlap = length . unGcBlocks . gcBlocks

-- | Number of blocks that could be GC'ed but haven't been
unnecessaryOverlap
  :: Time  -- ^ The current time
  -> GcState
  -> Int
unnecessaryOverlap now =
    length . filter ((<= now) . snd) . unGcBlocks . gcBlocks

-- | Property 3:
--
-- 'unnecessaryOverlap' < the number of blocks that could arrive in a
-- 'gcInterval'.
prop_unnecessaryOverlap :: TestSetup -> Property
prop_unnecessaryOverlap (TestSetup gcParams@GcParams { gcInterval } nbBlocks) =
    counterexample (show trace) $ conjoin
      [ gcSummaryUnnecessary `lt` blocksInInterval gcInterval
      | GcStateSummary { gcSummaryUnnecessary } <- trace
      ]
  where
    blocks = map Block [1..fromIntegral nbBlocks]
    trace =
      map (uncurry computeGcStateSummary) $ computeTrace gcParams blocks

blocksInInterval :: DiffTime -> Int
blocksInInterval interval = round (realToFrac interval :: Double)

data GcStateSummary = GcStateSummary {
      gcSummaryNow         :: Time
    , gcSummaryQueue       :: GcQueue
    , gcSummaryQueueLength :: Int
    , gcSummaryOverlap     :: Int
    , gcSummaryUnnecessary :: Int
    }
  deriving (Show)

computeGcStateSummary :: Time -> GcState -> GcStateSummary
computeGcStateSummary now gcState = GcStateSummary {
      gcSummaryNow         = now
    , gcSummaryQueue       = gcQueue                gcState
    , gcSummaryQueueLength = queueLength            gcState
    , gcSummaryOverlap     = overlap                gcState
    , gcSummaryUnnecessary = unnecessaryOverlap now gcState
    }

step
  :: GcParams
  -> Block
  -> GcState
  -> GcState
step gcParams block = runGc . schedule
  where
    slot = blockSlotNo block
    now  = blockArrivalTime block

    runGc :: GcState -> GcState
    runGc gcState = GcState {
          gcQueue  = GcQueue gcQueueLater
        , gcBlocks = case mbHighestGCedSlot of
            Nothing              -> gcBlocks gcState
            Just highestGCedSlot -> GcBlocks $
              filter
                ((> highestGCedSlot) . blockSlotNo . fst)
                (unGcBlocks (gcBlocks gcState))
        }
      where
        (gcQueueLater, gcQueueNow) =
          partition ((> now) . fst) (unGcQueue (gcQueue gcState))
        mbHighestGCedSlot = safeMaximum $ map snd gcQueueNow


    schedule :: GcState -> GcState
    schedule gcState = GcState {
          gcQueue  = GcQueue gcQueue'
        , gcBlocks = GcBlocks $
              (block, gcDelay gcParams `addTime` now)
            : unGcBlocks (gcBlocks gcState)
        }
      where
        scheduledTime = computeTimeForGC gcParams now
        gcQueue' = case unGcQueue (gcQueue gcState) of
          (prevScheduledTime, _prevSlot):queue'
            | scheduledTime == prevScheduledTime
            -> (scheduledTime, slot):queue'
          queue
            -> (scheduledTime, slot):queue

type Trace a = [a]

-- scanl f z [x1, x2, ...] == [z, z `f` x1, (z `f` x1) `f` x2, ...]
computeTrace :: GcParams -> [Block] -> Trace (Time, GcState)
computeTrace gcParams blocks =
    zip
      (map blockArrivalTime blocks)
      (drop 1 (scanl (flip (step gcParams)) emptyGcState blocks))

example :: GcParams -> Trace GcStateSummary
example gcParams =
    map (uncurry computeGcStateSummary) $
    computeTrace gcParams blocks
  where
    blocks = map Block [1..1000]

data TestSetup = TestSetup GcParams Word
  deriving (Show)

instance Arbitrary TestSetup where
  arbitrary = do
    gcDelay    <- secondsToDiffTime <$> choose (0, 100)
    gcInterval <- secondsToDiffTime <$> choose (1, 120)
    let gcParams = GcParams { gcDelay, gcInterval }
    nbBlocks <- fromIntegral . (* 10) <$> getSize
    return $ TestSetup gcParams nbBlocks

  shrink (TestSetup gcParams nbBlocks) =
    [TestSetup gcParams nbBlocks' | nbBlocks' <- shrink nbBlocks]
