{-# LANGUAGE QuasiQuotes #-}
module Main where

import Control.Applicative
import Control.Concurrent (threadDelay)
import Control.Monad

import           Pipes 
import qualified Pipes.Prelude as P
import           Pipes.Reactive
import           Pipes.Reactive.Interpreter as P
import           Pipes.Tick

import Prelude hiding (putStr,getLine)

import Text.Printf.TH

-- import Reactive.Banana hiding (Event)
-- import Reactive.Banana.Frameworks

-- moment :: Event Int -> MomentIO ()
-- moment e = do
--     let e' = (+) <$> e
--     e'' <- accumE 0 $ unionWith (.) e' e'
--     reactimate $ print <$> e''

-- main' :: IO ()
-- main' = do
--     (h,f) <- newAddHandler
--     n <- compile $ do
--         e <- fromAddHandler h
--         moment e
--     actuate n
--     mapM_ f [1..4]

-- numbers :: Monad m 
--         => Int 
--         -> Pipe () Int m r
-- numbers n = await >> yield n >> numbers (n+1)

foo :: ReactPipe s r ()
foo = do
         e0 <- spawnSourceWith (retries 2) $ P.zipWith const 
                (each [1..6] >-> P.mapM (liftA2 (>>) [sP|send: %d|] return)) 
                (tick 1000000)
         -- >-> P.map (const ()) >-> numbers 0
         e1 <- pipePool e0 $ do
                worker $ P.mapM $ \n -> do
                    threadDelay 50000
                    -- fail "fool"
                    [sP|- %?|] ("first",n)
                    return $ ("first",n)
                worker $ do
                    liftIO $ threadDelay 250000
                    P.mapM $ \n -> do
                        threadDelay 50000
                        -- fail "fool"
                        [sP|- %?|] ("second",n)
                        return $ ("second",n)
         sinkPool e1 $ do
                worker $ forever $ do
                        lift . [sP|reactimate: 1a) %?|] =<< await
                        lift . [sP|reactimate: 1b) %?|] =<< await
                        lift $ threadDelay 2000000
                worker $ forever $ do
                        lift . [sP|reactimate: 2a) %?|] =<< await
                        lift . [sP|reactimate: 2b) %?|] =<< await
                        lift $ threadDelay 2000000
         reactimate $ print <$> e1

foo2 :: ReactPipe s r ()
foo2 = do
         e0 <- spawnSourceWith (retries 2) $ P.zipWith const 
                (each [1..3]) 
                (tick 1000000) >> fail "foo"
         -- >-> P.map (const ()) >-> numbers 0
         e1 <- spawnPipe e0 $ P.mapM $ \n -> do
                        threadDelay 500000
                        -- fail "fool"
                        return $ 3 * n
         reactimate $ print <$> unionsWith (+) [e0,e1,(2*) <$> e1]

    -- Next: 
    -- x remove Typeable
    -- x restarting processes
    -- x interleave
    -- x seal the channel to avoid STM exceptions
    --   seal input
    --   return value! (for all?)
    --   dynamic threads
    --   sockets
    --   checkpoint
    --   translate exceptions into events
    --   separate interpreter from abstract syntax
    --   the s parameter of events could be instantiated with an event/behavior 
    --          representation. It would prevent the FRP code from analyzing the
    --          contents.

    -- Free monad IO
    --   extendible language sum types from GHC.Generics

main :: IO ()
main = do
    runReactive foo

