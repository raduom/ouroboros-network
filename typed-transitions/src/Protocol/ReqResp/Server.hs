{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}

module Protocol.ReqResp.Server where

import Protocol.Core
import Protocol.ReqResp.Type

newtype Server m request response a = Server {
    -- | The client requested data identified by `resourceId`.
    runServer :: request -> m (response, a)
  }

-- | Create server side of the @'ReqRespProtocol'@.
--
streamServer
  :: Monad m
  => Server m request response a
  -> Peer (ReqRespProtocol request response) (ReqRespMessage request response)
          (Awaiting StIdle) (Finished StDone)
          m a
streamServer server =
  await $ \msg ->
  case msg of
    MsgRequest request -> lift $ do
      (resp, a) <- runServer server request
      return $ out (MsgResponse resp) (done a)