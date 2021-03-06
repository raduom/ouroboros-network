{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DerivingVia       #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE TypeFamilies      #-}
module Ouroboros.Consensus.Storage.ImmutableDB.API
  ( ImmutableDB (..)
  , closeDB
  , getTip
  , getBlockComponent
  , getEBBComponent
  , getBlockOrEBBComponent
  , appendBlock
  , appendEBB
  , stream
  , Iterator (..)
  , IteratorResult (..)
  , traverseIterator
  , iteratorToList

  , module Ouroboros.Consensus.Storage.ImmutableDB.Types
  ) where

import           Cardano.Prelude (NoUnexpectedThunks (..), OnlyCheckIsWHNF (..),
                     ThunkInfo (..))
import           Cardano.Slotting.Block
import           Cardano.Slotting.Slot

import           Data.ByteString.Builder (Builder)

import           GHC.Generics (Generic)
import           GHC.Stack (HasCallStack)

import           Ouroboros.Consensus.Util.ResourceRegistry (ResourceRegistry)

import           Ouroboros.Consensus.Storage.Common
import           Ouroboros.Consensus.Storage.ImmutableDB.Types

-- | API for the 'ImmutableDB'.
--
-- The 'ImmutableDB' stores binary blobs in 'SlotNo's, i.e. the blocks of a
-- chain.
--
-- The database is append-only, so you cannot append a blob to a slot in the
-- past. You can, however, skip slots, e.g., append to slot 0 and then to slot
-- 5, but afterwards, you can no longer append to slots 1-4. You can only
-- store at most one blob in each slot. It is not allowed to store an empty
-- blob in a slot (we would need a way to distinguish an empty blob from an
-- empty slot).
--
-- The blob stored in a slot can be queried with 'getBinaryBlob'. Blobs can be
-- efficiently streamed using 'Iterator's, see 'streamBinaryBlobs'.
--
-- An Epoch Boundary Block (EBB) can be appended to the start of each epoch
-- using 'appendEBB'.
--
-- The 'Tip' of the database can be queried with 'getTip'. This tip will
-- always point to a filled slot or an EBB that is present.
--
-- It is possible to delete blobs from the database using 'deleteAfter'.
--
-- The database can be explicitly closed, but can also be automatically closed
-- in case of an 'Ouroboros.Consensus.Storage.ImmutableDB.Types.UnexpectedError'.
data ImmutableDB hash m = ImmutableDB
  { -- | Close the database.
    --
    -- Idempotent.
    --
    -- __Note__: Use 'withDB' instead of this function.
    closeDB_
      :: HasCallStack => m ()
      -- TODO remove this operation from the public API and expose it using an
      -- internal record so it can be used by 'withDB'.

    -- | Return the tip of the database.
    --
    -- The tip of the database will never point to an unfilled slot or missing
    -- EBB.
    --
    -- Throws a 'ClosedDBError' if the database is closed.
  , getTip_
      :: HasCallStack => m (ImmTipWithInfo hash)

    -- | Get the block component of the block at the given 'SlotNo'.
    --
    -- Returns 'Nothing' if no blob was stored at the given slot.
    --
    -- Throws a 'ReadFutureSlotError' if the requested slot is in the future,
    -- i.e > the result of 'getTip'.
    --
    -- Throws a 'ClosedDBError' if the database is closed.
  , getBlockComponent_
      :: forall b. HasCallStack
      => BlockComponent (ImmutableDB hash m) b -> SlotNo -> m (Maybe b)

    -- | Get the block component of the EBB (Epoch Boundary Block) of the
    -- given epoch.
    --
    -- Returns 'Nothing' if no EEB was stored for the given epoch.
    --
    -- Throws a 'ReadFutureEBBError' if the requested EBB is in the future.
    --
    -- Throws a 'ClosedDBError' if the database is closed.
  , getEBBComponent_
      :: forall b. HasCallStack
      => BlockComponent (ImmutableDB hash m) b -> EpochNo -> m (Maybe b)

    -- | Get the block component of the block or EBB at the given slot with
    -- the given hash.
    --
    -- Also return 'EpochNo' in case of an EBB or the given 'SlotNo' in case
    -- of a regular block.
    --
    -- If the slot is empty, 'Nothing' is returned. If the slot is not empty,
    -- but the block (and or the EBB) in it doesn't have the given hash,
    -- 'Nothing' is also returned.
    --
    -- Throws a 'ReadFutureSlotError' if the requested slot is in the future.
    --
    -- Throws a 'ClosedDBError' if the database is closed.
  , getBlockOrEBBComponent_
      :: forall b. HasCallStack
      => BlockComponent (ImmutableDB hash m) b -> SlotNo -> hash -> m (Maybe b)

    -- | Appends a block at the given slot.
    --
    -- Throws an 'AppendToSlotInThePastError' if the given slot is <= the
    -- result of 'getTip'.
    --
    -- Throws a 'ClosedDBError' if the database is closed.
    --
    -- TODO the given binary blob may not be empty.
  , appendBlock_
      :: HasCallStack => SlotNo -> BlockNo -> hash -> BinaryInfo Builder -> m ()

    -- | Appends a block as the EBB of the given epoch.
    --
    -- The EEB can only be added before regular blobs are appended to the
    -- current epoch.
    --
    -- Throws an 'AppendToEBBInThePastError' if the given epoch is before the
    -- current or if the blobs have already been appended to the current
    -- epoch.
    --
    -- Throws a 'ClosedDBError' if the database is closed.
    --
    -- TODO the given binary blob may not be empty.
  , appendEBB_
      :: HasCallStack => EpochNo -> BlockNo -> hash -> BinaryInfo Builder -> m ()

    -- | Return an 'Iterator' to efficiently stream binary blocks out of the
    -- database.
    --
    -- Optionally, a start position (first argument) and/or a stop position
    -- (second argument) can be given that will be used to determine which
    -- range of blocks should be streamed.
    --
    -- The start and stop position are of type @(SlotNo, hash)@. Both are
    -- inclusive bounds. The 'SlotNo' can refer to an EBB, in which case the
    -- @hash@ is used to distinguish it from the regular block in the same
    -- slot. When there is no block (or EBB) in the given slot with the given
    -- hash, a 'WrongBoundError' is returned.
    --
    -- When no start position is given, streaming wil start from the first
    -- block in the database. When no stop position is given, streaming will
    -- stop at the tip of the database at the time of opening the iterator.
    -- This means that appends happening while streaming will not be visible
    -- to the iterator.
    --
    -- Slots that do not store a block are skipped by the iterator.
    --
    -- Throws an 'InvalidIteratorRangeError' if the start of the range is
    -- greater than the end of the range.
    --
    -- NOTE: 'WrongBoundError' is returned, but 'InvalidIteratorRangeError' is
    -- thrown. This is because the former is expected to occur during normal
    -- operation: the user doesn't know upfront if those blocks can be
    -- streamed or not. Checking it beforehand would be expensive and
    -- inefficient, and 'streamBlocks' is the best place to do it anyway. The
    -- latter exception indicates incorrect usage and should not happen during
    -- normal operation.
    --
    -- Throws a 'ReadFutureSlotError' if the start or end 'SlotNo' are in the
    -- future.
    --
    -- Throws a 'ClosedDBError' if the database is closed.
    --
    -- The iterator is automatically closed when exhausted, and can be
    -- prematurely closed with 'iteratorClose'.
  , stream_
      :: forall b. HasCallStack
      => ResourceRegistry m
      -> BlockComponent (ImmutableDB hash m) b
      -> Maybe (SlotNo, hash)
      -> Maybe (SlotNo, hash)
      -> m (Either (WrongBoundError hash)
                   (Iterator hash m b))
  }
  deriving NoUnexpectedThunks via OnlyCheckIsWHNF "ImmutableDB" (ImmutableDB hash m)

instance DB (ImmutableDB hash m) where
  -- The ImmutableDB doesn't have the ability to parse blocks and headers, it
  -- only returns raw blocks and headers.
  type DBBlock      (ImmutableDB hash m) = ()
  type DBHeader     (ImmutableDB hash m) = ()
  type DBHeaderHash (ImmutableDB hash m) = hash

-- | An 'Iterator' is a handle which can be used to efficiently stream binary
-- blobs. Slots not containing a blob and missing EBBs are skipped.
data Iterator hash m a = Iterator
  { -- | Steps an 'Iterator' yielding an 'IteratorResult'.
    --
    -- After returning the blob as an 'IteratorResult', the iterator is
    -- advanced to the next non-empty slot or non-empty EBB.
    --
    -- Throws a 'ClosedDBError' if the database is closed.
    --
    -- TODO NOTE(adn): This works under the assumption that the user is the
    -- exclusive owner of the iterator.
    --
    -- The iterator is automatically closed when exhausted
    -- ('IteratorExhausted'), and can be prematurely closed with
    -- 'iteratorClose'.
    iteratorNext    :: HasCallStack => m (IteratorResult a)

    -- | Return the epoch number (in case of an EBB) or slot number and hash
    -- of the next blob, if there is a next. Return 'Nothing' if not.
    --
    -- This operation is idempotent.
  , iteratorHasNext :: HasCallStack => m (Maybe (Either EpochNo SlotNo, hash))

    -- | Dispose of the 'Iterator' by closing any open handles.
    --
    -- Idempotent operation.
  , iteratorClose   :: HasCallStack => m ()
  } deriving (Functor)

-- | This only contains actions, we don't check anything
instance NoUnexpectedThunks (Iterator hash m a) where
  showTypeOf _ = "Iterator"
  whnfNoUnexpectedThunks _ctxt _itr = return NoUnexpectedThunks

-- | Variant of 'traverse' instantiated to @'Iterator' hash m@ that executes
-- the monadic function when calling 'iteratorNext'.
traverseIterator
  :: Monad m
  => (a -> m b)
  -> Iterator hash m a
  -> Iterator hash m b
traverseIterator f itr = Iterator{
      iteratorNext    = iteratorNext itr >>= traverse f
    , iteratorHasNext = iteratorHasNext itr
    , iteratorClose   = iteratorClose itr
    }

-- | The result of stepping an 'Iterator'.
data IteratorResult a
  = IteratorExhausted
  | IteratorResult a
  deriving (Show, Eq, Generic, Functor, Foldable, Traversable)

-- | Consume an 'Iterator' by stepping until it is exhausted. A list of all
-- the 'IteratorResult's (excluding the final 'IteratorExhausted') produced by
-- the 'Iterator' is returned.
iteratorToList :: (HasCallStack, Monad m)
               => Iterator hash m a -> m [a]
iteratorToList it = go []
  where
    go acc = do
      next <- iteratorNext it
      case next of
        IteratorExhausted  -> return $ reverse acc
        IteratorResult res -> go (res:acc)

{-------------------------------------------------------------------------------
  Wrappers that preserve 'HasCallStack'

  @ghc@ really should do this for us :-/
-------------------------------------------------------------------------------}

closeDB
  :: HasCallStack
  => ImmutableDB hash m
  -> m ()
closeDB = closeDB_

getTip
  :: HasCallStack
  => ImmutableDB hash m
  -> m (ImmTipWithInfo hash)
getTip = getTip_

getBlockComponent
  :: HasCallStack
  => ImmutableDB hash m
  -> BlockComponent (ImmutableDB hash m) b -> SlotNo -> m (Maybe b)
getBlockComponent = getBlockComponent_

getEBBComponent
  :: HasCallStack
  => ImmutableDB hash m
  -> BlockComponent (ImmutableDB hash m) b -> EpochNo -> m (Maybe b)
getEBBComponent = getEBBComponent_

getBlockOrEBBComponent
  :: HasCallStack
  => ImmutableDB hash m
  -> BlockComponent (ImmutableDB hash m) b -> SlotNo -> hash -> m (Maybe b)
getBlockOrEBBComponent = getBlockOrEBBComponent_

appendBlock
  :: HasCallStack
  => ImmutableDB hash m
  -> SlotNo -> BlockNo -> hash -> BinaryInfo Builder -> m ()
appendBlock = appendBlock_

appendEBB
  :: HasCallStack
  => ImmutableDB hash m
  -> EpochNo -> BlockNo -> hash -> BinaryInfo Builder -> m ()
appendEBB = appendEBB_

stream
  :: HasCallStack
  => ImmutableDB hash m
  -> ResourceRegistry m
  -> BlockComponent (ImmutableDB hash m) b
  -> Maybe (SlotNo, hash)
  -> Maybe (SlotNo, hash)
  -> m (Either (WrongBoundError hash)
               (Iterator hash m b))
stream = stream_
