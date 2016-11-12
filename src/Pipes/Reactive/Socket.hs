module Pipes.Reactive.Socket 
    -- ( module Pipes.Reactive.Socket )
    -- , module System.Socket 
    -- , module System.Socket.Family.Inet6 )
where

-- import Control.Lens
-- import Control.Monad
-- import Control.Monad.Free
-- import Control.Monad.Trans.Either

-- import Data.ByteString as B
-- import Data.Either.Combinators
-- import Data.Proxy
-- import Data.Serialize

-- import Pipes hiding (Proxy)
-- import Pipes.Reactive
-- import Pipes.Safe

-- import System.Socket 
-- import System.Socket.Family.Inet6
-- import System.Socket.Type.Stream
-- import System.Socket.Protocol.TCP

-- listenTo :: MonadSafe m
--          => SocketAddress Inet6 
--          -> Socket Inet6 Stream TCP 
--          -> Producer (Socket Inet6 Stream TCP, SocketAddress Inet6) m r
-- listenTo addr s = do
--             liftIO $ do
--                 setSocketOption s (ReuseAddress True)
--                 setSocketOption s (V6Only False)
--                 bind s addr -- (SocketAddressInet6 inet6Any 8080 0 0)
--                 listen s 5
--             forever $ liftIO (accept s) >>= yield

-- listener :: MonadSafe m
--          => SocketAddress Inet6 
--          -> Producer (Socket Inet6 Stream TCP, SocketAddress Inet6) m r
-- listener addr = do
--     bracket 
--         (liftIO (socket :: IO (Socket Inet6 Stream TCP)))
--         (liftIO . close)
--         (listenTo addr)

-- makeSocket :: MonadIO m
--            => SocketAddress Inet6 
--            -> m (Socket Inet6 Stream TCP)
-- makeSocket addr = liftIO $ do
--             s <- socket :: IO (Socket Inet6 Stream TCP)
--             setSocketOption s (ReuseAddress True)
--             setSocketOption s (V6Only False)
--             return s

-- -- query :: (Serialize a,Serialize b)
-- --       => SocketAddress Inet6
-- --       -> Event s a
-- --       -> _ConcMoment s (Event s (Maybe b))
-- -- query addr e = do
-- --         s <- liftIO (socket :: IO (Socket Inet6 Stream TCP))
-- --         liftIO $ do
-- --             setSocketOption s (ReuseAddress True)
-- --             setSocketOption s (V6Only False)
-- --             bind s addr
-- --         _toConsumer (forever $ await >>= \x -> sendLen s (encode x)) e
-- --         _fromProducer $ forever $ receiveLen s >>= yield . rightToMaybe . (decode =<<)

-- sendLen :: MonadIO m
--         => Socket f t p
--         -> ByteString 
--         -> m ()
-- sendLen s xs = liftIO $ do
--     _ <- send s (encode $ B.length xs) msgNoSignal
--     void $ send s xs msgNoSignal

-- fromSocket :: (MonadIO m,Serialize a)
--            => Socket f t p
--            -> Producer (Either String a) m r
-- fromSocket s = forever $ do
--         xs <- receiveLen s
--         yield $ decode =<< xs

-- toSocket :: (MonadIO m,Serialize a)
--          => Socket f t p 
--          -> Consumer a m r
-- toSocket s = forever $ do
--         x <- await
--         sendLen s $ encode x

-- receiveLen :: MonadIO m
--            => Socket f t p
--            -> m (Either String ByteString)
-- receiveLen s = liftIO $ runEitherT $ do
--         let intSize = B.length $ encode (0 :: Int)
--         n <- EitherT $ decode <$> receive s intSize msgNoSignal
--         EitherT $ decode <$> receive s n msgNoSignal

