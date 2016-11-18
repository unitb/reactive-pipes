{-# LANGUAGE QuasiQuotes,RecursiveDo,TupleSections,TemplateHaskell,RankNTypes #-}
module Main where

import Control.Applicative
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Exception.Lens
-- import Control.Concurrent.Async
import Control.Lens hiding (each)
import Control.Monad
import Control.Monad.Writer

-- import System.Posix.Process.ByteString

-- import Data.Array
-- import Data.Bitraversable
-- import Data.Either.Combinators
-- import Data.Serialize
import Data.Void

import           Pipes 
import qualified Pipes.Prelude as P
import           Pipes.Reactive
import           Pipes.Reactive.Discrete
import           Pipes.Reactive.Interpreter as P
-- import           Pipes.Reactive.Socket
-- import           Pipes.Safe
import           Pipes.Tick

import Prelude hiding (putStr,getLine)

import Language.Haskell.TH hiding (match)

import System.Environment
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

foo8 :: ReactPipe s () ()
foo8 = do
    -- kb <- spawnSource $ (P.stdinLn >-> P.take 3) >> liftIO (print "end")
    _kb <- spawnSource $ (onTickSec $ each [1..] >-> P.map show >-> P.take 3) >> liftIO (print "end")
    -- _kb <- spawnSource $ (onTickSec $ each [1..] >-> P.map show >-> P.take 3) >> liftIO (print "end")
    result $ () <$ filterE ("2" ==) _kb
    -- result $ () <$ _kb
    reactimate $ print <$> _kb
    -- reactimate $ putStrLn "AAH!" <$ filterE ("2" ==) kb
    -- reactimate $ print <$> kb
    return ()

foo7 :: ReactPipe s Int ()
foo7 = do
        void $ spawnSource $ (P.zip (tick 5000000) $ each [1..6] >-> P.mapM print) >> return 3

foo1 :: ReactPipe s Int ()
foo1 = do
         e0 <- sourcePool_ $ do
            worker $ restart (retries 2) $ onTick 1000000 (each [1..6])
                 >-> P.mapM (liftA2 (>>) [sP|send (a): %d|] return)
                -- (tick 1000000)
            worker $ restart (retries 2) $ onTick 1000000 
                (each [7..16] >-> P.mapM (liftA2 (>>) [sP|send (b): %d|] return)) 
                -- (tick 1000000)
         -- >-> P.map (const ()) >-> numbers 0
         -- spawnSink e0 $ P.take 4 >-> P.drain >> return 13
         _ <- spawnSource $ onTickSec (each [1..5]) >> return 17
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
                -- worker $ (P.take 10 >-> P.mapM [sP|take: %d|] >-> P.drain) >> lift (putStrLn "print 11") >> return 11
                worker $ (P.take 11 >-> P.print) >> lift (putStrLn "print 11") >> return 11
         -- result e0
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

foo3 :: ReactPipe s Int ()
foo3 = mdo
        -- let ar = array (1,n) [  ]
            -- n  = 10
        e0 <- spawnSource $ P.zipWith const (each [1..10]) tickSec >-> P.map (1,) >> return 1
        e1 <- spawnSource $ P.zipWith const (each [1..10]) (tick 750000) >-> P.map (2,) >> fail "noooo!"
        e2 <- spawnSource $ P.zipWith const (each [1..10]) tickSec >-> P.map (3,) >> return 3
        reactimate $ print <$> e0
        reactimate $ print <$> e1
        reactimate $ print <$> e2
        v <- accumB (0,0,0) $ unionsWith (.) 
                [ set _1 . snd <$> e0 
                , set _2 . snd <$> e1 
                , set _3 . snd <$> e2 ]
        finalize $ [sP|Outcome: %?|] <$> v

foo5 :: ReactPipe s String ()
foo5 = do
        e0 <- spawnSource_ $ onTick 100000 (each [1..30])
        (pop,q) <- autonomous [] ((:) <$> e0) $ maybe retry return . uncons
        e1 <- pipePool pop $ do
            forM_ [1..2] $ \i -> do
                worker $ P.mapM $ \x -> do
                    threadDelay 2000000
                    return (i,x)
        reactimate $ [sP|+ Queue: %?; Dequeue: %d|] <$> q <@> pop
        reactimate $ [sP|- Processed: %?|] <$> e1
        reactimate $ [sP|Queue: %?; Adding %d|] <$> q <@> e0

foo4 :: ReactPipe s String ()
foo4 = do
        e0 <- spawnSource_ $ onTick 750000 (each [1..10])
        e1 <- spawnSource $ (tickSec >-> P.take 11) >> return "foo"
        -- e2 <- batch e0 $ unionWith const e0 (0 <$ e1)
        -- e3 <- match e0 $ unionWith const e0 (0 <$ e1)
        e2 <- batch e0 $ e1
        e3 <- match e0 $ e1
        reactimate $ [sP|batch: %?|] <$> e2
        reactimate $ [sP|match: %?|] <$> e3

type Block s = Writer [Event s (IO ())] ()

block :: Block s -> ReactPipe s r ()
block = reactimate . fmap f . unionsWith (>>) . execWriter
    where
        f x = putStrLn "begin" >> x >> putStrLn "end\n"

reactimate' :: Event s (IO ()) -> Block s
reactimate' = tell . pure

foo6 :: ReactPipe s String ()
foo6 = do
        e0 <- spawnSource $ onTickSec (each [1..10]) >> return "foo"
        b  <- stepper 0 e0
        e1 <- accumE 0 $ const <$> e0
        let d = stepperD 0 e0
        dx  <- changes d
        dx' <- updates d
        -- reactimate $ print <$> e0
        block $ do
            reactimate' $ [sP|b <@> e0: %?|] <$> ((,) <$> b <@> e0)
            reactimate' $ [sP|e1: %?|] <$> e1
            reactimate' $ [sP|dx:  %?|] <$> dx
            reactimate' $ [sP|dx': %?|] <$> dx'

foo2 :: ReactPipe s Void ()
foo2 = do
         e0 <- spawnSource $ restart (retries 2) $ P.zipWith const 
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
    -- x return value! (for all?)
    -- x finalizer
    -- x dynamic threads
    --   sockets
    --   checkpoint
    --   reverse the dependency between category and interpreter
    --      the category should be independent of the interpreter
    --      and so should the dynamic module
    --   translate exceptions into events
    -- x separate interpreter from abstract syntax
    --   the s parameter of events could be instantiated with an event/behavior 
    --          representation. It would prevent the FRP code from analyzing the
    --          contents.

    -- Free monad IO
    --   extendible language sum types from GHC.Generics

callTest :: Show r
         => (forall s. ReactPipe s r ())
         -> IO ()
callTest cmd = do
        x <- trying id $ runReactive cmd
        print x

main :: IO ()
main = do
    -- x <- trying id $ runReactive foo
    let m = $(do
            let takeWhileJustM _f [] = return []
                takeWhileJustM f (x:xs) = maybe (return []) (\y -> (y:) <$> takeWhileJustM f xs) =<< f x
                names n = [ n ++ show i | i <- [1..] ]
                pairE (e0,e1) = tupE [e0,e1]
                testCase t = [|callTest $(varE t)|]
                listDec n = zip (names n) <$> takeWhileJustM lookupValueName (names n)
            listE . map (pairE . bimap stringE testCase) =<< listDec "foo" )
    args <- getArgs
    case args of
        [x] 
            | Just cmd <- lookup x m -> do
                [sP|Running %s...\n|] x
                cmd
                threadDelay 2000000
        _ -> putStrLn "Expecting one of" >> mapM_ ([sP|- %s|].fst) m
    -- foo3

