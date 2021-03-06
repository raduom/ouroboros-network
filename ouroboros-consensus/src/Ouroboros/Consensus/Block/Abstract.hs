{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies          #-}

module Ouroboros.Consensus.Block.Abstract (
    -- * Protocol
    BlockProtocol
    -- * Configuration
  , BlockConfig
    -- * Working with headers
  , GetHeader(..)
  , headerHash
  , headerPrevHash
  , headerPoint
  ) where

import           Data.FingerTree.Strict (Measured (..))

-- TODO: Should we re-export (a subset of?) this module so that we don't need
-- to import from ouroboros-network so often?
import           Ouroboros.Network.Block

{-------------------------------------------------------------------------------
  Protocol
-------------------------------------------------------------------------------}

-- | Map block to consensus protocol
type family BlockProtocol blk :: *

{-------------------------------------------------------------------------------
  Configuration
-------------------------------------------------------------------------------}

-- | Static configuration required to work with this type of blocks
data family BlockConfig blk :: *

{-------------------------------------------------------------------------------
  Link block to its header
-------------------------------------------------------------------------------}

class GetHeader blk where
  data family Header blk :: *
  getHeader :: blk -> Header blk

type instance BlockProtocol (Header blk) = BlockProtocol blk

{-------------------------------------------------------------------------------
  Some automatic instances for 'Header'

  Unfortunately we cannot give a 'HasHeader' instance; if we mapped from a
  header to a block instead we could do

  > instance HasHeader hdr => HasHeader (Block hdr) where
  >  ..

  but we can't do that when we do things this way around.
-------------------------------------------------------------------------------}

type instance HeaderHash (Header blk) = HeaderHash blk

instance HasHeader blk => StandardHash (Header blk)

instance HasHeader (Header blk) => Measured BlockMeasure (Header blk) where
  measure = blockMeasure

{-------------------------------------------------------------------------------
  Convenience wrappers around 'HasHeader' that avoids unnecessary casts
-------------------------------------------------------------------------------}

headerHash :: HasHeader (Header blk) => Header blk -> HeaderHash blk
headerHash = blockHash

headerPrevHash :: HasHeader (Header blk) => Header blk -> ChainHash blk
headerPrevHash = castHash . blockPrevHash

headerPoint :: HasHeader (Header blk) => Header blk -> Point blk
headerPoint = castPoint . blockPoint
