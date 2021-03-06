{-# LANGUAGE CPP                  #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE NamedFieldPuns       #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE StandaloneDeriving   #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE UndecidableInstances #-}

module Ouroboros.Consensus.Ledger.Extended (
    -- * Extended ledger state
    BlockPreviouslyApplied(..)
  , ExtLedgerState(..)
  , ExtValidationError(..)
  , applyExtLedgerState
  , foldExtLedgerState
    -- * Serialisation
  , encodeExtLedgerState
  , decodeExtLedgerState
    -- * Lemmas
  , lemma_protocoLedgerView_applyLedgerBlock
  ) where

import           Codec.CBOR.Decoding (Decoder)
import           Codec.CBOR.Encoding (Encoding)
import           Control.Monad.Except
import           Data.Proxy
import           Data.Typeable
import           GHC.Generics (Generic)
import           GHC.Stack

import           Cardano.Prelude (NoUnexpectedThunks (..))

import           Ouroboros.Network.Block

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Config
import           Ouroboros.Consensus.HeaderValidation
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Ledger.SupportsProtocol
import           Ouroboros.Consensus.Protocol.Abstract
import           Ouroboros.Consensus.Util (repeatedlyM)
import           Ouroboros.Consensus.Util.Assert

{-------------------------------------------------------------------------------
  Extended ledger state
-------------------------------------------------------------------------------}

-- | Extended ledger state
--
-- This is the combination of the header state and the ledger state proper.
data ExtLedgerState blk = ExtLedgerState {
      ledgerState :: !(LedgerState blk)
    , headerState :: !(HeaderState blk)
    }
  deriving (Generic)

data ExtValidationError blk =
    ExtValidationErrorLedger !(LedgerError blk)
  | ExtValidationErrorHeader !(HeaderError blk)
  deriving (Generic)

instance LedgerSupportsProtocol blk => NoUnexpectedThunks (ExtValidationError blk)

deriving instance LedgerSupportsProtocol blk => Show (ExtLedgerState     blk)
deriving instance LedgerSupportsProtocol blk => Show (ExtValidationError blk)
deriving instance LedgerSupportsProtocol blk => Eq   (ExtValidationError blk)

-- | We override 'showTypeOf' to show the type of the block
--
-- This makes debugging a bit easier, as the block gets used to resolve all
-- kinds of type families.
instance LedgerSupportsProtocol blk => NoUnexpectedThunks (ExtLedgerState blk) where
  showTypeOf _ = show $ typeRep (Proxy @(ExtLedgerState blk))

deriving instance ( LedgerSupportsProtocol blk
                  , Eq (ConsensusState (BlockProtocol blk))
                  ) => Eq (ExtLedgerState blk)

data BlockPreviouslyApplied =
    BlockPreviouslyApplied
  -- ^ The block has been previously applied and validated against the given
  -- ledger state and no block validations should be performed.
  | BlockNotPreviouslyApplied
  -- ^ The block has not been previously applied to the given ledger state and
  -- all block validations should be performed.

-- | Update the extended ledger state
--
-- Updating the extended state happens in 3 steps:
--
-- * We call 'applyChainTick' to process any changes that happen at epoch
--   boundaries.
-- * We call 'applyLedgerBlock' to process the block itself; this looks at both
--   the header and the body of the block, but /only/ involves the ledger,
--   not the consensus chain state.
-- * Finally, we pass the updated ledger view to then update the consensus
--   chain state.
--
-- Note: for Byron, this currently deviates from the spec. We apply scheduled
-- updates /before/ checking the signature, but the spec does this the other
-- way around. This means that in the spec delegation updates scheduled for
-- slot @n@ are really only in effect at slot @n+1@.
-- See <https://github.com/input-output-hk/cardano-ledger-specs/issues/1007>
applyExtLedgerState :: (LedgerSupportsProtocol blk, HasCallStack)
                    => BlockPreviouslyApplied
                    -> TopLevelConfig blk
                    -> blk
                    -> ExtLedgerState blk
                    -> Except (ExtValidationError blk) (ExtLedgerState blk)
applyExtLedgerState prevApplied cfg blk ExtLedgerState{..} = do
    let tickedLedger@TickedLedgerState { tickedLedgerState } =
          applyChainTick
            (configLedger cfg)
            (blockSlot blk)
            ledgerState
        ledgerView =
          protocolLedgerView
            (configLedger cfg)
            tickedLedgerState
    headerState' <- withExcept ExtValidationErrorHeader $
                      validateHeader
                        cfg
                        ledgerView
                        (getHeader blk)
                        headerState
    ledgerState' <- case prevApplied of
                       BlockNotPreviouslyApplied ->
                         withExcept ExtValidationErrorLedger $
                           applyLedgerBlock
                             (configLedger cfg)
                             blk
                             tickedLedger
                       BlockPreviouslyApplied -> pure $
                         reapplyLedgerBlock
                           (configLedger cfg)
                           blk
                           tickedLedger
    return $!
      assertWithMsg
        (lemma_protocoLedgerView_applyLedgerBlock
          (configLedger cfg)
          blk
          ledgerState)
        (ExtLedgerState ledgerState' headerState')

foldExtLedgerState :: (LedgerSupportsProtocol blk, HasCallStack)
                   => BlockPreviouslyApplied
                   -> TopLevelConfig blk
                   -> [blk] -- ^ Blocks to apply, oldest first
                   -> ExtLedgerState blk
                   -> Except (ExtValidationError blk) (ExtLedgerState blk)
foldExtLedgerState prevApplied = repeatedlyM . (applyExtLedgerState prevApplied)

-- | Lemma:
--
-- > let tickedLedger = applyChainTick cfg (blockSlot blk) st
-- > in Right st' = runExcept $
-- >   applyLedgerBlock cfg blk tickedLedger ->
-- >      protocolLedgerView st'
-- >   == protocolLedgerView (tickedLedgerState tickedLedger)
--
-- In other words: 'applyLedgerBlock' doesn't affect the result of
-- 'protocolLedgerView'.
--
-- This should be true for each ledger because consensus depends on it.
lemma_protocoLedgerView_applyLedgerBlock
  :: LedgerSupportsProtocol blk
  => LedgerConfig blk
  -> blk
  -> LedgerState blk
  -> Either String ()
lemma_protocoLedgerView_applyLedgerBlock cfg blk st
    | Right lhs' <- runExcept lhs
    , lhs' /= rhs
    = Left $ unlines
      [ "protocolLedgerView /= protocolLedgerView . applyLedgerBlock"
      , show lhs'
      , " /= "
      , show rhs
      ]
    | otherwise
    = Right ()
  where
    tickedLedger = applyChainTick cfg (blockSlot blk) st
    lhs = protocolLedgerView cfg <$> applyLedgerBlock cfg blk tickedLedger
    rhs = protocolLedgerView cfg  $  tickedLedgerState        tickedLedger

{-------------------------------------------------------------------------------
  Serialisation
-------------------------------------------------------------------------------}

encodeExtLedgerState :: (LedgerState   blk -> Encoding)
                     -> (ConsensusState (BlockProtocol blk) -> Encoding)
                     -> (HeaderHash    blk -> Encoding)
                     -> (TipInfo       blk -> Encoding)
                     -> ExtLedgerState blk -> Encoding
encodeExtLedgerState encodeLedgerState
                     encodeConsensusState
                     encodeHash
                     encodeInfo
                     ExtLedgerState{..} = mconcat [
      encodeLedgerState  ledgerState
    , encodeHeaderState' headerState
    ]
  where
    encodeHeaderState' = encodeHeaderState
                           encodeConsensusState
                           encodeHash
                           encodeInfo

decodeExtLedgerState :: (forall s. Decoder s (LedgerState    blk))
                     -> (forall s. Decoder s (ConsensusState (BlockProtocol blk)))
                     -> (forall s. Decoder s (HeaderHash     blk))
                     -> (forall s. Decoder s (TipInfo        blk))
                     -> (forall s. Decoder s (ExtLedgerState blk))
decodeExtLedgerState decodeLedgerState
                     decodeConsensusState
                     decodeHash
                     decodeInfo = do
    ledgerState <- decodeLedgerState
    headerState <- decodeHeaderState'
    return ExtLedgerState{..}
  where
    decodeHeaderState' = decodeHeaderState
                           decodeConsensusState
                           decodeHash
                           decodeInfo
