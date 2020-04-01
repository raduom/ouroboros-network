{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE RecordWildCards            #-}
module Test.Ouroboros.Storage.ChainDB.GcSchedule (tests, example) where

import           Data.Fixed (div')
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
    [ testProperty "queueLength"        prop_queueLength
    , testProperty "overlap"            prop_overlap
    , testProperty "unnecessaryOverlap" prop_unnecessaryOverlap
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

-- | Property 1
--
-- TODO: English
prop_queueLength :: TestSetup -> Property
prop_queueLength TestSetup{..} =
    conjoin
      [ gcSummaryQueueLength `lt` (gcDelay `div'` gcInterval) + 1
      | GcStateSummary { gcSummaryQueueLength } <- testTrace
      ]
  where
    GcParams{..} = testGcParams

-- | Property 2:
--
-- TODO: English
prop_overlap :: TestSetup -> Property
prop_overlap TestSetup{..} =
    conjoin
      [ gcSummaryOverlap `lt` blocksInInterval (gcDelay + gcInterval)
      | GcStateSummary { gcSummaryOverlap } <- testTrace
      ]
  where
    GcParams{..} = testGcParams

-- | Property 3:
--
-- 'unnecessaryOverlap' < the number of blocks that could arrive in a
-- 'gcInterval'.
prop_unnecessaryOverlap :: TestSetup -> Property
prop_unnecessaryOverlap TestSetup{..} =
    conjoin
      [ gcSummaryUnnecessary `lt` blocksInInterval gcInterval
      | GcStateSummary { gcSummaryUnnecessary } <- testTrace
      ]
  where
    GcParams{..} = testGcParams

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

summarise :: GcParams -> Int -> Trace GcStateSummary
summarise gcParams numBlocks =
   map (uncurry computeGcStateSummary) $
     computeTrace gcParams blocks
  where
    blocks = map Block [1..numBlocks]

example :: GcParams -> Trace GcStateSummary
example gcParams = summarise gcParams 1000

data TestSetup = TestSetup {
    -- | Number of blocks
    --
    -- This determines the length of the trace. Shrinking this value means
    -- we find the smallest trace that yields the error
    testNumBlocks :: Int

    -- | GC delay in seconds
    --
    -- We keep this as a separate value /in seconds/ so that (1) it is easily
    -- shrinkable and (2) we can meaningfully use 'blocksInInterval'
  , testDelay     :: Integer

    -- | GC interval in seconds
    --
    -- See 'testDelay'
  , testInterval  :: Integer

    -- Derived
  , testGcParams  :: GcParams
  , testTrace     :: Trace GcStateSummary
  }
  deriving (Show)

mkTestSetup :: Int -> Integer -> Integer -> TestSetup
mkTestSetup numBlocks delay interval = TestSetup {
      testNumBlocks = numBlocks
    , testDelay     = delay
    , testInterval  = interval
      -- Derived values
    , testGcParams  = gcParams
    , testTrace     = summarise gcParams numBlocks
    }
  where
    gcParams :: GcParams
    gcParams = GcParams {
          gcDelay    = secondsToDiffTime delay
        , gcInterval = secondsToDiffTime interval
        }

instance Arbitrary TestSetup where
  arbitrary =
      mkTestSetup
        <$> ((* 10) <$> getSize) -- Number of blocks
        <*> choose (0, 100)      -- Delay
        <*> choose (1, 120)      -- Interval

  shrink TestSetup{..} = concat [
        [ mkTestSetup testNumBlocks' testDelay testInterval
        | testNumBlocks' <- shrink testNumBlocks
        ]

      , [ mkTestSetup testNumBlocks testDelay' testInterval
        | testDelay' <- shrink testDelay
        ]

      , [ mkTestSetup testNumBlocks testDelay testInterval'
        | testInterval' <- shrink testInterval
        , testInterval' > 0
        ]

        -- Shrink two values shrink /together/
        -- Note: we don't compute all possible combinations, we shrink both
      , [ mkTestSetup testNumBlocks testDelay' testInterval'
        | testDelay    > 0
        , testInterval > 1
        , let testDelay'    = testDelay    - 1
        , let testInterval' = testInterval - 1
        ]
      ]
