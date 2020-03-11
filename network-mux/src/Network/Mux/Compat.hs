{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE GADTSyntax          #-}
{-# LANGUAGE ExistentialQuantification #-}

module Network.Mux.Compat (
      muxStart

      -- * Mux bearers
    , MuxBearer

    -- * Defining 'MuxApplication's
    , MuxMode (..)
    , HasInitiator
    , HasResponder
    , MuxApplication (..)
    , MuxMiniProtocol (..)
    , RunMiniProtocol (..)
    , MiniProtocolNum (..)
    , MiniProtocolLimits (..)
    , MiniProtocolDir (..)

      -- * Errors
    , MuxError (..)
    , MuxErrorType (..)

      -- * Tracing
    , traceMuxBearerState
    , MuxBearerState (..)
    , MuxTrace (..)
    , WithMuxBearer (..)
    ) where

import           Data.Void (Void)

import           Control.Monad
import           Control.Monad.Class.MonadAsync
import           Control.Monad.Class.MonadSTM.Strict
import           Control.Monad.Class.MonadThrow
import           Control.Tracer

import           Network.Mux.Types hiding (MiniProtocolInfo(..))
import qualified Network.Mux.Types as Types
import           Network.Mux.Trace
import           Network.Mux.Channel
import           Network.Mux (newMux, runMux, runMiniProtocol,
                              StartOnDemandOrEagerly(..), traceMuxBearerState)


newtype MuxApplication (mode :: MuxMode) m a b =
        MuxApplication [MuxMiniProtocol mode m a b]

data MuxMiniProtocol (mode :: MuxMode) m a b =
     MuxMiniProtocol {
       miniProtocolNum    :: !MiniProtocolNum,
       miniProtocolLimits :: !MiniProtocolLimits,
       miniProtocolRun    :: !(RunMiniProtocol mode m a b)
     }

data RunMiniProtocol (mode :: MuxMode) m a b where
  InitiatorProtocolOnly
    -- Initiator application; most simple application will be @'runPeer'@ or
    -- @'runPipelinedPeer'@ supplied with a codec and a @'Peer'@ for each
    -- @ptcl@.  But it allows to handle resources if just application of
    -- @'runPeer'@ is not enough.  It will be run as @'InitiatorDir'@.
    :: (Channel m -> m a)
    -> RunMiniProtocol InitiatorMode m a Void

  ResponderProtocolOnly
    -- Responder application; similarly to the @'MuxInitiatorApplication'@ but it
    -- will be run using @'ResponderDir'@.
    :: (Channel m -> m b)
    -> RunMiniProtocol ResponderMode m Void b

  InitiatorAndResponderProtocol
    -- Initiator and server applications.
    :: (Channel m -> m a)
    -> (Channel m -> m b)
    -> RunMiniProtocol InitiatorResponderMode m a b


muxStart
    :: forall m mode a b.
       ( MonadAsync m
       , MonadSTM m
       , MonadThrow (STM m)
       , MonadMask m
       )
    => Tracer m MuxTrace
    -> MuxApplication mode m a b
    -> MuxBearer m
    -> m ()
muxStart tracer muxapp bearer = do
    mux <- newMux (toMiniProtocolBundle muxapp)

    sequence_
      [ runMiniProtocol
          mux
          miniProtocolNum
          ptclDir
          StartEagerly
          action
      | let MuxApplication ptcls = muxapp
      , MuxMiniProtocol{miniProtocolNum, miniProtocolRun} <- ptcls
      , (ptclDir, action) <- selectRunner miniProtocolRun
      ]

    runMux tracer mux bearer
  where
    toMiniProtocolBundle :: MuxApplication mode m a b -> MiniProtocolBundle mode
    toMiniProtocolBundle (MuxApplication ptcls) =
      MiniProtocolBundle
        [ Types.MiniProtocolInfo {
            Types.miniProtocolNum,
            Types.miniProtocolDir,
            Types.miniProtocolLimits
          }
        | MuxMiniProtocol {
            miniProtocolNum,
            miniProtocolLimits,
            miniProtocolRun
          } <- ptcls
        , miniProtocolDir <- case miniProtocolRun of
            InitiatorProtocolOnly{} -> [InitiatorDirectionOnly]
            ResponderProtocolOnly{} -> [ResponderDirectionOnly]
            InitiatorAndResponderProtocol{} -> [InitiatorDirection, ResponderDirection]
        ]

    selectRunner :: RunMiniProtocol mode m a b
                 -> [(MiniProtocolDirection mode, Channel m -> m ())]
    selectRunner (InitiatorProtocolOnly initiator) =
      [(InitiatorDirectionOnly, void . initiator)]
    selectRunner (ResponderProtocolOnly responder) =
      [(ResponderDirectionOnly, void . responder)]
    selectRunner (InitiatorAndResponderProtocol initiator responder) =
      [(InitiatorDirection, void . initiator)
      ,(ResponderDirection, void . responder)]

