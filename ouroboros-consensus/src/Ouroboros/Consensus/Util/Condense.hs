{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE PatternSynonyms      #-}
{-# LANGUAGE TypeApplications     #-}
{-# LANGUAGE UndecidableInstances #-}

module Ouroboros.Consensus.Util.Condense (
    Condense(..)
  , Condense1(..)
  , condense1
  ) where

import qualified Data.ByteString as BS.Strict
import qualified Data.ByteString.Lazy as BS.Lazy
import           Data.Int
import           Data.List (intercalate)
import           Data.Map (Map)
import qualified Data.Map.Strict as Map
import           Data.Proxy
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Text (Text, unpack)
import           Data.Word
import           Formatting (build, sformat)
import           Numeric.Natural
import           Text.Printf (printf)

import           Control.Monad.Class.MonadTime (Time (..))

import           Cardano.Crypto (VerificationKey)
import           Cardano.Crypto.DSIGN (Ed448DSIGN, MockDSIGN, SigDSIGN,
                     pattern SigEd448DSIGN, pattern SigMockDSIGN,
                     SignedDSIGN (..))
import           Cardano.Crypto.Hash (Hash)
import           Cardano.Crypto.KES (MockKES, NeverKES, SigKES,
                     pattern SigMockKES, pattern SigSimpleKES,
                     pattern SignKeyMockKES, SignedKES (..), SimpleKES,
                     pattern VerKeyMockKES)
import           Cardano.Slotting.Slot (WithOrigin (..))

import           Ouroboros.Network.Block (BlockNo (..), ChainHash (..),
                     HeaderHash, SlotNo (..))

import           Ouroboros.Consensus.Util.HList (All, HList (..))
import qualified Ouroboros.Consensus.Util.HList as HList

{-------------------------------------------------------------------------------
  Main class
-------------------------------------------------------------------------------}

-- | Condensed but human-readable output
class Condense a where
  condense :: a -> String

{-------------------------------------------------------------------------------
  Rank-1 types
-------------------------------------------------------------------------------}

class Condense1 f where
  liftCondense :: (a -> String) -> f a -> String

-- | Lift the standard 'condense' function through the type constructor
condense1 :: (Condense1 f, Condense a) => f a -> String
condense1 = liftCondense condense

{-------------------------------------------------------------------------------
  Instances for standard types
-------------------------------------------------------------------------------}

instance Condense String where
  condense = id

instance Condense Text where
  condense = unpack

instance Condense Bool where
  condense = show

instance Condense Int where
  condense = show

instance Condense Int64 where
  condense = show

instance Condense Word where
  condense = show

instance Condense Word32 where
  condense = show

instance Condense Word64 where
  condense = show

instance Condense Natural where
  condense = show

instance Condense Rational where
  condense = printf "%.8f" . (fromRational :: Rational -> Double)

instance Condense1 [] where
  liftCondense f as = "[" ++ intercalate "," (map f as) ++ "]"

instance Condense1 Set where
  liftCondense f = liftCondense f . Set.toList

instance {-# OVERLAPPING #-} Condense [String] where
  condense ss = "[" ++ intercalate "," ss ++ "]"

instance {-# OVERLAPPABLE #-} Condense a => Condense [a] where
  condense = condense1

instance Condense a => Condense (Maybe a) where
  condense (Just a) = "Just " ++ condense a
  condense Nothing  = "Nothing"

instance Condense a => Condense (Set a) where
  condense = condense1

instance (Condense a, Condense b) => Condense (a, b) where
  condense (a, b) = condense (a :* b :* Nil)

instance (Condense a, Condense b, Condense c) => Condense (a, b, c) where
  condense (a, b, c) = condense (a :* b :* c :* Nil)

instance (Condense a, Condense b, Condense c, Condense d) => Condense (a, b, c, d) where
  condense (a, b, c, d) = condense (a :* b :* c :* d :* Nil)

instance (Condense a, Condense b, Condense c, Condense d, Condense e) => Condense (a, b, c, d, e) where
  condense (a, b, c, d, e) = condense (a :* b :* c :* d :* e :* Nil)

instance (Condense k, Condense a) => Condense (Map k a) where
  condense = condense . Map.toList

instance Condense BS.Strict.ByteString where
  condense bs = show bs ++ "<" ++ show (BS.Strict.length bs) ++ "b>"

instance Condense BS.Lazy.ByteString where
  condense bs = show bs ++ "<" ++ show (BS.Lazy.length bs) ++ "b>"

{-------------------------------------------------------------------------------
  Consensus specific general purpose types
-------------------------------------------------------------------------------}

instance All Condense as => Condense (HList as) where
  condense as = "(" ++ intercalate "," (HList.collapse (Proxy @Condense) condense as) ++ ")"

{-------------------------------------------------------------------------------
  Orphans for ouroboros-network
-------------------------------------------------------------------------------}

instance Condense BlockNo where
  condense (BlockNo n) = show n

instance Condense SlotNo where
  condense (SlotNo n) = show n

instance Condense (HeaderHash b) => Condense (ChainHash b) where
  condense GenesisHash   = "genesis"
  condense (BlockHash h) = condense h

instance Condense a => Condense (WithOrigin a) where
  condense Origin = "origin"
  condense (At a) = condense a

{-------------------------------------------------------------------------------
  Orphans for cardano-crypto-wrapper
-------------------------------------------------------------------------------}

instance Condense VerificationKey where
  condense = unpack . sformat build

{-------------------------------------------------------------------------------
  Orphans for cardano-crypto-classes
-------------------------------------------------------------------------------}

instance Condense (SigDSIGN v) => Condense (SignedDSIGN v a) where
  condense (SignedDSIGN sig) = condense sig

instance Condense (SigDSIGN Ed448DSIGN) where
  condense (SigEd448DSIGN s) = show s

instance Condense (SigDSIGN MockDSIGN) where
  condense (SigMockDSIGN _ i) = show i

instance Condense (SigKES v) => Condense (SignedKES v a) where
  condense (SignedKES sig) = condense sig

instance Condense (SigKES MockKES) where
    condense (SigMockKES n (SignKeyMockKES (VerKeyMockKES v) j d)) =
           show n
        <> ":"
        <> show v
        <> ":"
        <> show j
        <> ":"
        <> show d

instance Condense (SigKES NeverKES) where
  condense = show

instance Condense (SigDSIGN d) => Condense (SigKES (SimpleKES d)) where
    condense (SigSimpleKES sig) = condense sig

instance Condense (Hash h a) where
    condense = show

instance Condense Time where
    condense (Time dt) = show dt
