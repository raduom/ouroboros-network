{-# LANGUAGE DataKinds                #-}
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE FlexibleInstances        #-}
{-# LANGUAGE NamedFieldPuns           #-}
{-# LANGUAGE TypeFamilies             #-}
{-# OPTIONS_GHC -Wno-orphans #-}
module Test.ThreadNet.TxGen.Shelley
  ( ShelleyTxGenExtra(..)
  ) where

import           Control.Monad.Except (runExcept)
import           Crypto.Number.Generate (generateBetween, generateMax)
import           Crypto.Random (MonadRandom)
import           Data.Map (Map)
import qualified Data.Map as Map

import           Ouroboros.Consensus.Config
import           Ouroboros.Consensus.Ledger.Abstract

import qualified Shelley.Spec.Ledger.Keys as SL
import qualified Shelley.Spec.Ledger.LedgerState as SL
import qualified Shelley.Spec.Ledger.STS.Ledger as STS
import qualified Shelley.Spec.Ledger.TxData as SL
import qualified Shelley.Spec.Ledger.UTxO as SL

import           Ouroboros.Consensus.Shelley.Ledger

import           Test.QuickCheck.Gen (Gen (..))
import           Test.QuickCheck.Random (mkQCGen)

import           Test.ThreadNet.TxGen (TxGen (..))

import qualified Test.Shelley.Spec.Ledger.ConcreteCryptoTypes as CSL
import qualified Test.Shelley.Spec.Ledger.Generator.Core as Gen
import qualified Test.Shelley.Spec.Ledger.Generator.Utxo as Gen

import           Test.Consensus.Shelley.MockCrypto (TPraosMockCrypto)

data ShelleyTxGenExtra = ShelleyTxGenExtra
  { stgeKeyPairs :: SL.KeyPairs TPraosMockCrypto
  }

instance TxGen (ShelleyBlock TPraosMockCrypto) where

  type TxGenExtra (ShelleyBlock TPraosMockCrypto) = ShelleyTxGenExtra

  -- TODO #1823
  testGenTxs _numCoreNodes curSlotNo cfg lst stge = do
      n <- generateBetween 0 20
      go [] n $ applyChainTick (configLedger cfg) curSlotNo lst
    where
      go :: MonadRandom m
         => [GenTx (ShelleyBlock TPraosMockCrypto)]  -- ^ Accumulator
         -> Integer  -- ^ Number of txs to still produce
         -> TickedLedgerState (ShelleyBlock TPraosMockCrypto)
         -> m [GenTx (ShelleyBlock TPraosMockCrypto)]
      go acc 0 _  = return (reverse acc)
      go acc n st = do
        tx <- quickCheckAdapter $ genTx cfg st (stgeKeyPairs stge)
        case runExcept $ applyTx (configLedger cfg) tx st of
          -- We don't mind generating invalid transactions
          Left  _   -> go (tx:acc) (n - 1) st
          Right st' -> go (tx:acc) (n - 1) st'

-- STS PredicateFailure - [[CertsFailure (PoolFailure StakePoolRetirementWrongEpochPOOL)]]

genTx
  :: TopLevelConfig (ShelleyBlock TPraosMockCrypto)
  -> TickedLedgerState (ShelleyBlock TPraosMockCrypto)
  -> SL.KeyPairs TPraosMockCrypto
  -> Gen (GenTx (ShelleyBlock TPraosMockCrypto))
genTx _cfg TickedLedgerState { tickedSlotNo, tickedLedgerState } keyPairs =
    mkShelleyTx <$> Gen.genTx
      ledgerEnv
      (utxoSt, dpState)
      keyPairs
      keyHashMap
      scripts
      coreKeys
      keysByStakeHash
  where
    ShelleyLedgerState { shelleyState } = tickedLedgerState

    epochState :: CSL.EpochState
    epochState = SL.nesEs shelleyState

    ledgerEnv :: STS.LedgerEnv
    ledgerEnv = STS.LedgerEnv {
        ledgerSlotNo   = tickedSlotNo
      , ledgerIx       = 0 -- TODO Ix
      , ledgerPp       = SL.esPp epochState
      , ledgerReserves =
            SL._reserves
          . SL.esAccountState
          $ epochState
      }

    utxoSt :: CSL.UTxOState
    utxoSt =
        SL._utxoState
      . SL.esLState
      $ epochState

    dpState :: CSL.DPState
    dpState =
        SL._delegationState
      . SL.esLState
      $ epochState

-- UTxO (fromList [(TxIn (TxId {_TxId = 7af9b492}) 0,TxOut (AddrBase (KeyHashObj (DiscKeyHash a936e9f6)) (KeyHashObj (DiscKeyHash f1314e34))) (Coin 1000))])

    keyHashMap :: Map CSL.AnyKeyHash CSL.KeyPair
    keyHashMap = Map.fromList $ concat $
      [ [ (SL.hashAnyKey (SL.vKey payKey), payKey)
        , (SL.hashAnyKey (SL.vKey stakeKey), stakeKey)
        ]
      | (payKey, stakeKey) <- keyPairs
      ]

    -- TODO
    scripts :: CSL.MultiSigPairs
    scripts = []

    -- TODO
    -- These are used for submitting update proposals and voting on them
    coreKeys :: [(CSL.CoreKeyPair, Gen.AllPoolKeys)]
    coreKeys = []

    keysByStakeHash :: Map CSL.KeyHash CSL.KeyPair
    keysByStakeHash = Map.fromList
      [ (SL.hashKey (SL.vKey stakeKey), stakeKey)
      | (_payKey, stakeKey) <- keyPairs
      ]

{-------------------------------------------------------------------------------
  QuickCheck to MonadRandom adapter
-------------------------------------------------------------------------------}

-- | Run the generator by producing a random seed
quickCheckAdapter :: MonadRandom m => Gen a -> m a
quickCheckAdapter (MkGen g) = do
    seed <- fromIntegral <$> generateMax (fromIntegral (maxBound :: Int))
    return $ g (mkQCGen seed) 30
