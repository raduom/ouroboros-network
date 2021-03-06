{-# LANGUAGE DataKinds      #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes     #-}

module Ouroboros.Network.Diffusion
  ( DiffusionTracers (..)
  , DiffusionArguments (..)
  , AcceptedConnectionsLimit (..)
  , DiffusionApplications (..)
  , OuroborosApplication (..)
  , runDataDiffusion
    -- * re-exports
  , simpleSingletonVersions
  , IPSubscriptionTarget (..)
  , DnsSubscriptionTarget (..)
  , ConnectionId (..)
  )
  where

import qualified Control.Concurrent.Async as Async
import           Control.Tracer (Tracer)
import           Data.Functor (void)
import           Data.Void (Void)
import           Data.ByteString.Lazy (ByteString)

import           Network.Mux (MuxTrace (..), WithMuxBearer (..))
import           Network.Socket (SockAddr, AddrInfo)
import qualified Network.Socket as Socket

import           Ouroboros.Network.Snocket (LocalAddress, SocketSnocket, LocalSnocket)
import qualified Ouroboros.Network.Snocket as Snocket

import           Ouroboros.Network.Protocol.Handshake.Version

import           Ouroboros.Network.ErrorPolicy
import           Ouroboros.Network.IOManager
import           Ouroboros.Network.Mux
import           Ouroboros.Network.NodeToClient (NodeToClientVersion (..) )
import qualified Ouroboros.Network.NodeToClient as NodeToClient
import           Ouroboros.Network.NodeToNode ( NodeToNodeVersion (..)
                                              , AcceptedConnectionsLimit (..)
                                              , AcceptConnectionsPolicyTrace (..)
                                              )
import qualified Ouroboros.Network.NodeToNode   as NodeToNode
import           Ouroboros.Network.Socket ( ConnectionId (..)
                                          , NetworkMutableState
                                          , newNetworkMutableState
                                          , cleanNetworkMutableState
                                          , NetworkServerTracers (..)
                                          )
import           Ouroboros.Network.Subscription.Ip
import           Ouroboros.Network.Subscription.Dns
import           Ouroboros.Network.Subscription.Worker (LocalAddresses (..))
import           Ouroboros.Network.Tracers

data DiffusionTracers = DiffusionTracers {
      dtIpSubscriptionTracer   :: Tracer IO (WithIPList (SubscriptionTrace SockAddr))
       -- ^ IP subscription tracer
    , dtDnsSubscriptionTracer  :: Tracer IO (WithDomainName (SubscriptionTrace SockAddr))
      -- ^ DNS subscription tracer
    , dtDnsResolverTracer      :: Tracer IO (WithDomainName DnsTrace)
      -- ^ DNS resolver tracer
    , dtMuxTracer              :: Tracer IO (WithMuxBearer (ConnectionId SockAddr) MuxTrace)
      -- ^ Mux tracer
    , dtMuxLocalTracer         :: Tracer IO (WithMuxBearer (ConnectionId LocalAddress) MuxTrace)
      -- ^ Mux tracer for local clients
    , dtHandshakeTracer        :: Tracer IO NodeToNode.HandshakeTr
      -- ^ Handshake protocol tracer
    , dtHandshakeLocalTracer   :: Tracer IO NodeToClient.HandshakeTr
      -- ^ Handshake protocol tracer for local clients
    , dtErrorPolicyTracer      :: Tracer IO (WithAddr SockAddr     ErrorPolicyTrace)
    , dtLocalErrorPolicyTracer :: Tracer IO (WithAddr LocalAddress ErrorPolicyTrace)
    , dtAcceptPolicyTracer     :: Tracer IO AcceptConnectionsPolicyTrace
      -- ^ Trace rate limiting of accepted connections
    }


-- | Network Node argumets
--
data DiffusionArguments = DiffusionArguments {
      daAddresses    :: [AddrInfo]
      -- ^ diffusion addresses
    , daLocalAddress :: FilePath
      -- ^ address for local clients
    , daIpProducers  :: IPSubscriptionTarget
      -- ^ ip subscription addresses
    , daDnsProducers :: [DnsSubscriptionTarget]
      -- ^ list of domain names to subscribe to
    , daAcceptedConnectionsLimit :: AcceptedConnectionsLimit
      -- ^ parameters for limiting number of accepted connections
    }

data DiffusionApplications = DiffusionApplications {

      daResponderApplication      :: Versions
                                       NodeToNodeVersion
                                       DictVersion
                                       (ConnectionId SockAddr ->
                                          OuroborosApplication
                                            ResponderApp
                                            ByteString IO Void ())
      -- ^ NodeToNode reposnder application (server role)

    , daInitiatorApplication      :: Versions
                                       NodeToNodeVersion
                                       DictVersion 
                                       (ConnectionId SockAddr ->
                                          OuroborosApplication
                                            InitiatorApp
                                            ByteString IO () Void)
      -- ^ NodeToNode initiator application (client role)

    , daLocalResponderApplication :: Versions
                                       NodeToClientVersion
                                       DictVersion
                                       (ConnectionId LocalAddress ->
                                          OuroborosApplication
                                            ResponderApp
                                            ByteString IO Void ())
      -- ^ NodeToClient responder applicaton (server role)

    , daErrorPolicies :: ErrorPolicies
      -- ^ error policies
    }

runDataDiffusion
    :: DiffusionTracers
    -> DiffusionArguments 
    -> DiffusionApplications
    -> IO ()
runDataDiffusion tracers
                 DiffusionArguments { daAddresses
                                    , daLocalAddress
                                    , daIpProducers
                                    , daDnsProducers
                                    , daAcceptedConnectionsLimit
                                    }
                 applications@DiffusionApplications { daErrorPolicies } =
    withIOManager $ \iocp -> do

    let -- snocket for remote communication.
        snocket :: SocketSnocket
        snocket = Snocket.socketSnocket iocp

        -- snocket for local clients connected using Unix socket or named pipe.
        -- we currently don't support remotely connected local clients.  If we
        -- need to we can add another adress for local clients.
        localSnocket :: LocalSnocket
        localSnocket = Snocket.localSnocket iocp daLocalAddress

    -- networking mutable state
    networkState <- newNetworkMutableState
    networkLocalState <- newNetworkMutableState

    void $
      -- clean state thread
      Async.withAsync (cleanNetworkMutableState networkState) $ \cleanNetworkStateThread ->

        -- clean local state thread
        Async.withAsync (cleanNetworkMutableState networkLocalState) $ \cleanLocalNetworkStateThread ->

          -- fork server for local clients
          Async.withAsync (runLocalServer localSnocket networkLocalState) $ \_ ->

            -- fork servers for remote peers
            withAsyncs (runServer snocket networkState . Socket.addrAddress <$> daAddresses) $ \_ ->

              -- fork ip subscription
              Async.withAsync (runIpSubscriptionWorker snocket networkState) $ \_ ->

                -- fork dns subscriptions
                withAsyncs (runDnsSubscriptionWorker snocket networkState <$> daDnsProducers) $ \_ ->

                  -- If any other threads throws 'cleanNetowrkStateThread' and
                  -- 'cleanLocalNetworkStateThread' threads will will finish.
                  Async.waitEither_ cleanNetworkStateThread cleanLocalNetworkStateThread

  where
    DiffusionTracers { dtIpSubscriptionTracer
                     , dtDnsSubscriptionTracer
                     , dtDnsResolverTracer
                     , dtMuxTracer
                     , dtMuxLocalTracer
                     , dtHandshakeTracer
                     , dtHandshakeLocalTracer
                     , dtErrorPolicyTracer
                     , dtLocalErrorPolicyTracer
                     , dtAcceptPolicyTracer
                     } = tracers

    initiatorLocalAddresses :: LocalAddresses SockAddr
    initiatorLocalAddresses = LocalAddresses
      { laIpv4 =
          -- IPv4 address
          --
          -- We can't share portnumber with our server since we run separate
          -- 'MuxInitiatorApplication' and 'MuxResponderApplication'
          -- applications instead of a 'MuxInitiatorAndResponderApplication'.
          -- This means we don't utilise full duplex connection.
          if any (\ai -> Socket.addrFamily ai == Socket.AF_INET) daAddresses
            then Just (Socket.SockAddrInet 0 0)
            else Nothing
      , laIpv6 =
          -- IPv6 address
          if any (\ai -> Socket.addrFamily ai == Socket.AF_INET6) daAddresses
            then Just (Socket.SockAddrInet6 0 0 (0, 0, 0, 0) 0)
            else Nothing
      , laUnix = Nothing
      }

    remoteErrorPolicy, localErrorPolicy :: ErrorPolicies
    remoteErrorPolicy = NodeToNode.remoteNetworkErrorPolicy <> daErrorPolicies
    localErrorPolicy  = NodeToNode.localNetworkErrorPolicy <> daErrorPolicies

    runLocalServer :: LocalSnocket -> NetworkMutableState LocalAddress -> IO Void
    runLocalServer sn networkLocalState =
      NodeToClient.withServer
        sn
        (NetworkServerTracers
          dtMuxLocalTracer
          dtHandshakeLocalTracer
          dtLocalErrorPolicyTracer
          dtAcceptPolicyTracer)
        networkLocalState
        (Snocket.localAddressFromPath daLocalAddress)
        (daLocalResponderApplication applications)
        localErrorPolicy

    runServer :: SocketSnocket -> NetworkMutableState SockAddr -> SockAddr -> IO Void
    runServer sn networkState address =
      NodeToNode.withServer
        sn
        (NetworkServerTracers
          dtMuxTracer
          dtHandshakeTracer
          dtErrorPolicyTracer
          dtAcceptPolicyTracer)
        networkState
        daAcceptedConnectionsLimit
        address
        (daResponderApplication applications)
        remoteErrorPolicy

    runIpSubscriptionWorker :: SocketSnocket
                            -> NetworkMutableState SockAddr
                            -> IO Void
    runIpSubscriptionWorker sn networkState = NodeToNode.ipSubscriptionWorker
      sn
      (NetworkSubscriptionTracers
        dtMuxTracer
        dtHandshakeTracer
        dtErrorPolicyTracer
        dtIpSubscriptionTracer)
      networkState
      SubscriptionParams
        { spLocalAddresses         = initiatorLocalAddresses
        , spConnectionAttemptDelay = const Nothing
        , spErrorPolicies          = remoteErrorPolicy
        , spSubscriptionTarget     = daIpProducers
        }
      (daInitiatorApplication applications)

    runDnsSubscriptionWorker :: SocketSnocket
                             -> NetworkMutableState SockAddr
                             -> DnsSubscriptionTarget
                             -> IO Void
    runDnsSubscriptionWorker sn networkState dnsProducer = NodeToNode.dnsSubscriptionWorker
      sn
      (NetworkDNSSubscriptionTracers
        dtMuxTracer
        dtHandshakeTracer
        dtErrorPolicyTracer
        dtDnsSubscriptionTracer
        dtDnsResolverTracer)
      networkState
      SubscriptionParams
        { spLocalAddresses         = initiatorLocalAddresses
        , spConnectionAttemptDelay = const Nothing
        , spErrorPolicies          = remoteErrorPolicy
        , spSubscriptionTarget     = dnsProducer
        }
      (daInitiatorApplication applications)


--
-- Auxilary functions
--

-- | Structural fold using 'Async.withAsync'.
--
withAsyncs :: [IO a] -> ([Async.Async a] -> IO b) -> IO b
withAsyncs as0 k = go [] as0
  where
    go threads []       = k threads
    go threads (a : as) = Async.withAsync a $ \thread -> go (thread : threads) as
