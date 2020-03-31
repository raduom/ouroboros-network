{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | A wrapper around 'TQueue' with the following advantages:
--
-- * Enforces the /elements/ in the queue to be in WHNF.
-- * Keeps track of the length of the queue, allowing for a \( O(1) \) length
--   query.
-- * Provides the 'peekTailQueue' and 'modifyTailTQueue' operations to
--   efficiently query and modify the last element in the queue.
--
-- TODO re-export by IOLike?
module Ouroboros.Consensus.Util.MonadSTM.StrictTQueue
  ( StrictTQueue -- abstract
  , newTQueue
  , readTQueue
  , tryReadTQueue
  , writeTQueue
  , isEmptyTQueue
  , lengthTQueue
  , peekTailQueue
  , modifyTailTQueue
  ) where

import           Control.Monad.Class.MonadSTM.Strict (MonadSTM, STM, StrictTVar,
                     TQueue)
import qualified Control.Monad.Class.MonadSTM.Strict as STM


data StrictTQueue m a = StrictTQueue
    { queueLength :: !(StrictTVar m Int)
    , queue       :: !(TQueue m a)
    , queueTail   :: !(StrictTVar m (Maybe a))
    }

-- | Build and returns a new instance of 'StrictTQueue'.
newTQueue :: MonadSTM m => STM m (StrictTQueue m a)
newTQueue = StrictTQueue
    <$> STM.newTVar 0
    <*> STM.newTQueue
    <*> STM.newTVar Nothing

-- | Read the next value from the 'StrictTQueue'.
readTQueue :: forall m a. MonadSTM m => StrictTQueue m a -> STM m a
readTQueue StrictTQueue { queueLength, queue, queueTail } = do
    x <- STM.readTQueue queue `STM.orElse` readTail
    STM.modifyTVar queueLength pred
    return x
  where
    readTail :: STM m a
    readTail = do
      mbTail <- STM.updateTVar queueTail (\mbTail -> (Nothing, mbTail))
      case mbTail of
        Nothing -> STM.retry
        Just x  -> return x

-- | A version of 'readTQueue' which does not retry. Instead it returns
-- @Nothing@ if no value is available.
tryReadTQueue :: MonadSTM m => StrictTQueue m a -> STM m (Maybe a)
tryReadTQueue q = fmap Just (readTQueue q) `STM.orElse` return Nothing

-- | Write a value to the tail a 'StrictTQueue'.
writeTQueue :: MonadSTM m => StrictTQueue m a -> a -> STM m ()
writeTQueue StrictTQueue { queueLength, queue, queueTail } !x = do
    mbTail <- STM.readTVar queueTail
    -- If we have a tail, move it to the 'queue'
    case mbTail of
      Just tl -> STM.writeTQueue queue tl
      Nothing -> return ()
    STM.writeTVar queueTail (Just x)
    STM.modifyTVar queueLength succ

-- | Returns 'True' if the supplied 'StrictTQueue' is empty.
isEmptyTQueue :: MonadSTM m => StrictTQueue m a -> STM m Bool
isEmptyTQueue = fmap (== 0) . lengthTQueue

-- | Return the length of the 'StrictTQueue'.
lengthTQueue :: MonadSTM m => StrictTQueue m a -> STM m Int
lengthTQueue = STM.readTVar . queueLength

-- | Get the last value written to the 'StrictTQueue' without removing it,
-- returning @Nothing@ when the queue is empty.
peekTailQueue :: MonadSTM m => StrictTQueue m a -> STM m (Maybe a)
peekTailQueue = STM.readTVar . queueTail

-- | Modify the tail of the 'StrictQueue', i.e., the last value written to the
-- queue, /if/ present. If the queue is empty, does nothing.
modifyTailTQueue :: MonadSTM m => StrictTQueue m a -> (a -> a) -> STM m ()
modifyTailTQueue StrictTQueue { queueTail } modify = do
    mbTail <- STM.readTVar queueTail
    case mbTail of
      Nothing -> return ()
      Just tl -> STM.writeTVar queueTail (Just tl')
        where
          !tl' = modify tl
