{-# LANGUAGE QuasiQuotes #-}
module Main where

import Control.Applicative
-- import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Monad
import Control.Monad.Catch

-- import System.Posix.Process.ByteString

import Data.Binary
import Data.Int
import Data.Word

import Data.ByteString.Lazy as BS hiding (putStrLn)
import Data.Either.Combinators
-- import Data.Serialize

import           Debug.Trace              (traceIO)

-- import           Pipes 
-- import qualified Pipes.Prelude as P
-- import           Pipes.Reactive
-- import           Pipes.Reactive.Interpreter as P
-- import           Pipes.Reactive.Socket
-- import           Pipes.Safe
-- import           Pipes.Tick

import Prelude hiding (putStr,getLine)

import Network.BSD as BSD
import Network.Socket
import Network.Socket.ByteString.Lazy as NSBS
import System.IO
import Text.Printf.TH

-- addr :: SocketAddress Inet6
-- addr = (SocketAddressInet6 inet6Any 8080 0 10)

-- foo3 = do
--     s <- makeSocket addr
--     connect s addr
--     p1 <- async $ runEffect $ each ["hello","world"] >-> toSocket s
--     p2 <- async $ runEffect $ for (fromSocket s) (lift . mapM_ putStrLn)
--     forM_ [p1,p2] wait
--     close s

withSocket ::  Family -> SocketType -> ProtocolNumber -> 
                  (Socket -> IO a) -> IO a
                  
withSocket family sktType protocol = 
    bracket (socket family sktType protocol)  -- acquire resource
            (\skt -> shutdown skt ShutdownBoth >> close skt) -- release

type XmitType = Int32

client :: PortNumber -> IO ()
client port = withSocketsDo $ do  
   protocol <- fmap BSD.protoNumber $ BSD.getProtocolByName "TCP"
   withSocket AF_INET Stream protocol $ \skt -> do

       localhost <- inet_addr "127.0.0.1"
       -- traceIO $ "localhost: " ++ showHex localhost ""
       let sktAddr = SockAddrInet port localhost
       connect skt sktAddr

       -- send msgs, EOT
       let testList = [1..4] :: [XmitType]
       putStrLn "to send:"    
       forM_ testList print   -- print test msgs
       hFlush stdout
       forM_ testList $ \n -> sendAsBS skt n
       sendEOT skt

-- | validated msg length
newtype MsgLen = MsgLen Word16

-- | encode with Binary                        
encodeXmitLen :: MsgLen -> ByteString
encodeXmitLen (MsgLen w) = encode w

-- | send EOT
sendEOT :: Socket -> IO ()
sendEOT skt = do
        NSBS.send skt $ encodeXmitLen msgLenEOT
        return ()

msgLenEOT = MsgLen 0

validateMsgLen :: Int64 -> Maybe MsgLen
validateMsgLen len = if len <= maxlen && len >= 0
                        then Just $ MsgLen $ fromIntegral len
                        else Nothing

maxlen = 0x0FFFF :: Int64

sendAsBS :: Binary a => Socket -> a -> IO ()
sendAsBS skt myData =
    case validateMsgLen len of
      Nothing -> traceIO $ -- error as trace msg
                    [s|sendAsBS: msg length %d out of range|] len

      Just msgLen -> do
        NSBS.send skt $ encodeXmitLen msgLen
        bytes <- NSBS.send skt bsMsg
        when (bytes /= len) $ traceIO "sendAsBS: bytes sent disagreement"
        -- return ()
  where
    bsMsg = encode myData
    len = BS.length bsMsg

main :: IO ()
main = do
    -- runReactive foo
    -- foo3
    putStrLn "done"

