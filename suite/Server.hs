{-# LANGUAGE QuasiQuotes,OverloadedStrings #-}
module Main where

-- import Control.Applicative
-- import Control.Concurrent (threadDelay)
-- import Control.Concurrent.Async
-- import Control.Monad

-- import System.Posix.Process.ByteString

-- import Data.Either.Combinators
-- import Data.Serialize

-- import Network.Socket

-- import           Pipes 
-- import qualified Pipes.Prelude as P
-- import           Pipes.Reactive
-- import           Pipes.Reactive.Interpreter as P
-- import           Pipes.Reactive.Socket
-- import           Pipes.Safe
-- import           Pipes.Tick

import Prelude hiding (putStr,getLine)

-- import Text.Printf.TH

-- addr :: SocketAddress Inet6
-- addr = (SocketAddressInet6 inet6Any 8080 0 10)

-- foo3 = do
--     p0 <- async $ runEffect $ runSafeP $ 
--             for (listener addr >-> P.take 3) $ \(s,_) -> 
--                 finally 
--                     (do xs <- fromRight' . (decode =<<) <$> receiveLen s
--                         liftIO $ putStrLn xs
--                         sendLen s $ encode $ reverse xs) 
--                     (close s >> putStrLn "close")
--     wait p0

-- main :: IO ()
-- main = do
--     -- runReactive foo
--     foo3
--     putStrLn "done"

 
import Network.Socket hiding (send)
import Network.Socket.ByteString
 
main :: IO ()
main = do
    sock <- socket AF_INET Stream 0    -- create socket
    setSocketOption sock ReuseAddr 1   -- make socket immediately reusable - eases debugging.
    bind sock (SockAddrInet 4242 iNADDR_ANY)   -- listen on TCP port 4242.
    listen sock 2                              -- set a max of 2 queued connections
    mainLoop sock                              -- unimplemented

-- in Main.hs
 
mainLoop :: Socket -> IO ()
mainLoop sock = do
    conn <- accept sock     -- accept a connection and handle it
    runConn conn            -- run our server's logic
    mainLoop sock           -- repeat
 
runConn :: (Socket, SockAddr) -> IO ()
runConn (sock, _) = do
    _ <- send sock "Hello!\n"
    close sock

