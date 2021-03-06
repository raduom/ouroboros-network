{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wno-orphans #-}
module Test.Ouroboros.Storage.ChainDB.AddBlock
  ( tests
  ) where

import qualified Codec.CBOR.Encoding as CBOR
import qualified Codec.CBOR.Write as CBOR
import           Codec.Serialise (decode, encode)
import           Control.Exception (throw)
import           Control.Monad (void)
import qualified Data.ByteString.Lazy as Lazy
import           Data.List (permutations, transpose)

import           Test.QuickCheck
import           Test.Tasty
import           Test.Tasty.QuickCheck

import           Control.Monad.IOSim

import           Control.Tracer

import           Ouroboros.Network.MockChain.Chain (Chain)
import qualified Ouroboros.Network.MockChain.Chain as Chain

import           Ouroboros.Consensus.Block (IsEBB (..), getHeader)
import           Ouroboros.Consensus.BlockchainTime.Mock
import           Ouroboros.Consensus.Config
import           Ouroboros.Consensus.Ledger.Extended
import           Ouroboros.Consensus.Util (chunks)
import           Ouroboros.Consensus.Util.AnchoredFragment
import           Ouroboros.Consensus.Util.Condense (condense)
import           Ouroboros.Consensus.Util.IOLike
import           Ouroboros.Consensus.Util.ResourceRegistry

import           Ouroboros.Consensus.Storage.ChainDB (ChainDbArgs (..),
                     TraceAddBlockEvent (..), addBlock, toChain, withDB)
import qualified Ouroboros.Consensus.Storage.ChainDB as ChainDB
import           Ouroboros.Consensus.Storage.ImmutableDB (BinaryInfo (..),
                     ChunkInfo, HashInfo (..),
                     ValidationPolicy (ValidateAllChunks))
import qualified Ouroboros.Consensus.Storage.ImmutableDB.Impl.Index as Index
import           Ouroboros.Consensus.Storage.LedgerDB.DiskPolicy
                     (defaultDiskPolicy)
import           Ouroboros.Consensus.Storage.LedgerDB.InMemory
                     (ledgerDbDefaultParams)
import           Ouroboros.Consensus.Storage.VolatileDB
                     (BlockValidationPolicy (..), mkBlocksPerFile)

import           Test.Util.ChunkInfo
import           Test.Util.FS.Sim.MockFS (MockFS)
import qualified Test.Util.FS.Sim.MockFS as Mock
import           Test.Util.FS.Sim.STM (simHasFS)
import           Test.Util.Orphans.IOLike ()
import           Test.Util.Orphans.NoUnexpectedThunks ()
import           Test.Util.SOP
import           Test.Util.TestBlock

import           Test.Ouroboros.Storage.ChainDB.Model (ModelSupportsBlock (..))
import qualified Test.Ouroboros.Storage.ChainDB.Model as Model
import           Test.Ouroboros.Storage.ChainDB.StateMachine ()

tests :: TestTree
tests = testGroup "AddBlock"
    [ testProperty "addBlock multiple threads" prop_addBlock_multiple_threads
    ]


-- | Add a bunch of blocks from multiple threads and check whether the
-- resulting chain is correct.
--
-- Why not use the parallel state machine tests for this? If one thread adds a
-- block that fits onto the current block and the other thread adds a
-- different block that also fits onto the current block, then the outcome
-- depends on scheduling: either outcome is fine, but they will be different.
-- quickcheck-state-machine expects the outcome to be deterministic.
--
-- Hence this test: don't check whether the resulting chain is equal to the
-- model chain, but check whether they are equally preferable (candidates). In
-- fact, it is more complicated than that. Say @k = 2@ and we first add the
-- following blocks in the given order: @A@, @B@, @C@, @A'@, @B'@, @C'@, @D'@,
-- then the current chain will end with @C@, even though the fork ending with
-- @D'@ would be longer. The reason is for this is that we would have to roll
-- back more @k@ blocks to switch to this fork. Now imagine that the last four
-- blocks in the list above get added before the first three, then the current
-- chain would have ended with @D'@. So the order in which blocks are added
-- really matters.
--
-- We take the following approach to check whether the resulting chain is
-- correct:
--
-- * We take the list of blocks to add
-- * For each permutation of this list:
--   - We add all the blocks in the permuted list to the model
--   - We check whether the current chain of the model is equally preferable
--     to the resulting chain. If so, the test passes.
-- * If none of the permutations result in an equally preferable chain, the
--   test fails.
--
-- TODO test with multiple protocols
-- TODO test with different thread schedulings for the simulator
prop_addBlock_multiple_threads :: SmallChunkInfo -> BlocksPerThread -> Property
prop_addBlock_multiple_threads (SmallChunkInfo chunkInfo) bpt =
  -- TODO coverage checking
    tabulate "Event" (map constrName trace) $
    counterexample ("Actual chain: " <> condense actualChain) $
    counterexample
      "No interleaving of adding blocks found that results in the same chain" $
    any (equallyPreferable actualChain) (map modelAddBlocks (permutations blks))
  where
    blks = blocks bpt

    hashInfo = testHashInfo (map tbHash blks)

    actualChain :: Chain TestBlock
    trace       :: [TraceAddBlockEvent TestBlock]
    (actualChain, trace) = run $ do
        -- Open the DB
        fsVars <- (,,)
          <$> uncheckedNewTVarM Mock.empty
          <*> uncheckedNewTVarM Mock.empty
          <*> uncheckedNewTVarM Mock.empty
        withRegistry $ \registry -> do
          let args = mkArgs cfg chunkInfo initLedger dynamicTracer registry hashInfo fsVars
          withDB args $ \db -> do
            -- Add blocks concurrently
            mapConcurrently_ (mapM_ (addBlock db)) $ blocksPerThread bpt
            -- Obtain the actual chain
            toChain db

    -- The current chain after all the given blocks were added to a fresh
    -- model.
    modelAddBlocks :: [TestBlock] -> Chain TestBlock
    modelAddBlocks theBlks =
        Model.currentChain $
        Model.addBlocks cfg theBlks $
        -- Make sure no blocks are "from the future"
        Model.advanceCurSlot cfg maxBound $
        Model.empty initLedger

    equallyPreferable :: Chain TestBlock -> Chain TestBlock -> Bool
    equallyPreferable chain1 chain2 =
      compareAnchoredCandidates cfg
        (Chain.toAnchoredFragment (getHeader <$> chain1))
        (Chain.toAnchoredFragment (getHeader <$> chain2)) == EQ

    cfg :: TopLevelConfig TestBlock
    cfg = singleNodeTestConfig

    initLedger :: ExtLedgerState TestBlock
    initLedger = testInitExtLedger

    dynamicTracer :: Tracer (SimM s) (ChainDB.TraceEvent TestBlock)
    dynamicTracer = Tracer $ \case
      ChainDB.TraceAddBlockEvent ev -> traceM ev
      _                             -> return ()

    run :: (forall s. SimM s a) -> (a, [TraceAddBlockEvent TestBlock])
    run m = (res, evs)
      where
      tr  = runSimTrace m
      res = either throw id $ traceResult True tr
      evs = selectTraceEventsDynamic tr

{-------------------------------------------------------------------------------
  Auxiliary
-------------------------------------------------------------------------------}

mapConcurrently_ :: forall m a. IOLike m => (a -> m ()) -> [a] -> m ()
mapConcurrently_ f = go
  where
    go :: [a] -> m ()
    go []     = return ()
    go (x:xs) =
      withAsync (f  x)  $ \y  ->
      withAsync (go xs) $ \ys ->
        void $ waitBoth y ys

{-------------------------------------------------------------------------------
  Generators
-------------------------------------------------------------------------------}

newtype Threads = Threads { unThreads :: Int }
    deriving (Eq, Show)

instance Arbitrary Threads where
  arbitrary = Threads <$> choose (2, 10)
  shrink (Threads n) = [Threads n' | n' <- [2..n-1]]


data BlocksPerThread = BlocksPerThread
  { bptBlockTree   :: !BlockTree
  , bptPermutation :: !Permutation
  , bptThreads     :: !Threads
  }

blocks :: BlocksPerThread -> [TestBlock]
blocks BlocksPerThread{..} =
    permute bptPermutation $ treeToBlocks bptBlockTree

blocksPerThread :: BlocksPerThread -> [[TestBlock]]
blocksPerThread bpt@BlocksPerThread{..} =
    transpose $ chunks (unThreads bptThreads) $ blocks bpt

instance Show BlocksPerThread where
  show bpt = unlines $ zipWith
    (\(i :: Int) blks -> "thread " <> show i <> ": " <> condense blks)
    [0..]
    (blocksPerThread bpt)

instance Arbitrary BlocksPerThread where
  arbitrary = BlocksPerThread
     -- Limit the number of blocks to 10, because the number of interleavings
     -- grows factorially.
    <$> scale (min 10) arbitrary
    <*> arbitrary
    <*> arbitrary
  shrink (BlocksPerThread bt p t) =
    -- No need to shrink permutations
    [BlocksPerThread bt  p t' | t'  <- shrink t]  <>
    [BlocksPerThread bt' p t  | bt' <- shrink bt]


{-------------------------------------------------------------------------------
  ChainDB args
-------------------------------------------------------------------------------}

mkArgs :: IOLike m
       => TopLevelConfig TestBlock
       -> ChunkInfo
       -> ExtLedgerState TestBlock
       -> Tracer m (ChainDB.TraceEvent TestBlock)
       -> ResourceRegistry m
       -> HashInfo TestHash
       -> (StrictTVar m MockFS, StrictTVar m MockFS, StrictTVar m MockFS)
          -- ^ ImmutableDB, VolatileDB, LedgerDB
       -> ChainDbArgs m TestBlock
mkArgs cfg chunkInfo initLedger tracer registry hashInfo
       (immDbFsVar, volDbFsVar, lgrDbFsVar) = ChainDbArgs
    { -- Decoders
      cdbDecodeHash           = decode
    , cdbDecodeBlock          = const <$> decode
    , cdbDecodeHeader         = const <$> decode
    , cdbDecodeLedger         = decode
    , cdbDecodeConsensusState = decode
    , cdbDecodeTipInfo        = decode

      -- Encoders
    , cdbEncodeHash           = encode
    , cdbEncodeBlock          = addDummyBinaryInfo . encode
    , cdbEncodeHeader         = encode
    , cdbEncodeLedger         = encode
    , cdbEncodeConsensusState = encode
    , cdbEncodeTipInfo        = encode

      -- HasFS instances
    , cdbHasFSImmDb           = simHasFS immDbFsVar
    , cdbHasFSVolDb           = simHasFS volDbFsVar
    , cdbHasFSLgrDB           = simHasFS lgrDbFsVar

      -- Policy
    , cdbImmValidation        = ValidateAllChunks
    , cdbVolValidation        = ValidateAll
    , cdbBlocksPerFile        = mkBlocksPerFile 4
    , cdbParamsLgrDB          = ledgerDbDefaultParams (configSecurityParam cfg)
    , cdbDiskPolicy           = defaultDiskPolicy (configSecurityParam cfg)

      -- Integration
    , cdbTopLevelConfig       = cfg
    , cdbChunkInfo            = chunkInfo
    , cdbHashInfo             = hashInfo
    , cdbIsEBB                = const Nothing
    , cdbCheckIntegrity       = const True
    , cdbBlockchainTime       = fixedBlockchainTime maxBound
    , cdbGenesis              = return initLedger
    , cdbAddHdrEnv            = \_ _ -> id
    , cdbImmDbCacheConfig     = Index.CacheConfig 2 60

    -- Misc
    , cdbTracer               = tracer
    , cdbTraceLedger          = nullTracer
    , cdbRegistry             = registry
    , cdbBlocksToAddSize      = 2
      -- We don't run the background threads, so these are not used
    , cdbGcDelay              = 1
    , cdbGcInterval           = 1
    }
  where
    addDummyBinaryInfo :: CBOR.Encoding -> BinaryInfo CBOR.Encoding
    addDummyBinaryInfo blob = BinaryInfo
      { binaryBlob   = blob
      -- The serialised @Header TestBlock@ is the same as the serialised
      -- @TestBlock@
      , headerOffset = 0
      , headerSize   = fromIntegral $ Lazy.length (CBOR.toLazyByteString blob)
      }

{-------------------------------------------------------------------------------
  Orphan instances
-------------------------------------------------------------------------------}

instance ModelSupportsBlock TestBlock where
  isEBB = const IsNotEBB
