{-# LANGUAGE ExistentialQuantification
           , GeneralizedNewtypeDeriving
           , ConstraintKinds
           , TypeOperators
           , LambdaCase
           , QuasiQuotes
           , RankNTypes
           , GADTs
           , TemplateHaskell
           , RecursiveDo
           , DeriveFunctor #-}
module Pipes.Reactive 
    ( module Pipes.Reactive 
    , module Pipes.Reactive.Class
    , module Pipes.Reactive.Event
    , module Pipes.Reactive.Types  )
where

import Control.Applicative
import Control.Category
import Control.Concurrent.STM
import Control.Exception.Lens
import Control.Lens
import Control.Monad.Catch hiding (onException)
import Control.Monad.Free
import Control.Monad.RWS
import Control.Monad.Writer

import           Data.List.NonEmpty hiding (reverse)

import           Pipes
import           Pipes.Core
import qualified Pipes.Prelude as P
import           Pipes.Reactive.Class
import           Pipes.Reactive.Types

import Prelude hiding ((.),id)

import Pipes.Reactive.Event

data Restart a = Restart Int (Prism' SomeException a)


switchB :: MonadReact s r m
        => Behavior s a
        -> Event s (Behavior s a) 
        -> m (Behavior s a)
switchB b e = do
    Behavior b' <- stepper b e
    let unBe (Behavior v) = v
    return $ Behavior $ join $ unBe <$> b'

-- switchE :: Event s (Event s a) -> Event s a
-- switchE (Event (ChannelSet ch0) (ChannelSet ch1)) = Event (ChannelSet _) (ChannelSet _)

match :: MonadReact s r m
      => Event s a 
      -> Event s b
      -> m (Event s a)
match input tick = do
    lastE <- stepper Nothing $ unionWith const (Just <$> input) (Nothing <$ tick)
    return $ filterJust $ lastE <@ tick

batch :: MonadReact s r m
      => Event s a
      -> Event s b
      -> m (Event s (NonEmpty a))
batch input tick = do
    lastE <- accumB [] $ unionWith (>>>) (const [] <$ tick) ((:) <$> input)
    return $ filterJust $ nonEmpty.reverse <$> lastE <@ tick

filterApply :: Behavior s (a -> Bool) -> Event s a -> Event s a
filterApply v = filterJust . apply ((\p x -> guard (p x) >> Just x) <$> v)

whenE :: Behavior s Bool -> Event s a -> Event s a
whenE p = filterApply (const <$> p)

filterE :: (a -> Bool) -> Event s a -> Event s a
filterE p = filterApply (pure p)

infixl 4 <@>
infixl 4 <@

(<@>) :: Behavior s (a -> b)
      -> Event s a 
      -> Event s b
(<@>) = apply

(<@) :: Behavior s b
     -> Event s a 
     -> Event s b
(<@) = apply . fmap const

apply :: Behavior s (a -> b)
      -> Event s a 
      -> Event s b
apply _ Never = Never
apply (Behavior f) (Event out g) = Event (applyCS f out) (applyCS f g)

result :: MonadReact s r m
       => Event s r
       -> m ()
result e = liftReact $ ReactPipe $ Free $ Return e $ Pure ()

finalize :: MonadReact s r m
         => Behavior s (IO ()) 
         -> m ()
finalize final = liftReact $ ReactPipe $ Free $ Finalize final $ Pure ()

resource :: MonadReact s r m 
         => IO x
         -> (x -> IO ())
         -> m x
resource alloc free = do
      r <- liftIO alloc
      finalize $ pure $ free r
      return r

spawnSource :: (MonadReact s r m)
            => Producer a IO r 
            -> m (Event s a)
spawnSource = spawnSourceWith $ return ()

spawnSource_ :: (MonadReact s r m)
             => Producer a IO ()
             -> m (Event s a)
spawnSource_ = spawnSourceWith_ $ return ()

spawnSourceWith :: (MonadReact s r m,IORunnable f)
                => ChannelOpt' f
                -> Producer a f r 
                -> m (Event s a)
spawnSourceWith opt source = sourcePoolWith opt $ worker source

spawnSourceWith_ :: (MonadReact s r m,IORunnable f)
                 => ChannelOpt' f 
                 -> Producer a f ()
                 -> m (Event s a)
spawnSourceWith_ opt source = sourcePoolWith_ opt $ worker source

sourcePool :: (MonadReact s r m)
           => SourcePool IO a r ()
           -> m (Event s a)
sourcePool = sourcePoolWith $ return ()

sourcePool_ :: (MonadReact s r m)
            => SourcePool IO a () ()
            -> m (Event s a)
sourcePool_ = sourcePoolWith_ $ return ()

sourcePoolWith_ :: (MonadReact s r m,IORunnable f)
                => ChannelOpt' f
                -> SourcePool f a () ()
                -> m (Event s a)
sourcePoolWith_ _ source = liftReact $ ReactPipe $ case nonEmpty $ execWriter source of
                              Just xs -> Free (Source (f <$> xs) Pure)
                              Nothing -> Pure Never
    where
        f = hoist lift

sourcePoolWith :: (MonadReact s r m,IORunnable f)
               => ChannelOpt' f
               -> SourcePool f a r ()
               -> m (Event s a)
sourcePoolWith _ source = liftReact $ case nonEmpty $ execWriter source of
                              Just xs -> ReactPipe (Free $ Source (f <$> xs) Pure) 
                                            >>= uncurry split . splitEvent
                              Nothing -> ReactPipe $ Pure Never
    where
        f x = (hoist lift x >-> P.map Right) >>= yield . Left
        split x y = result x >> return y

worker :: Proxy a a' b b' f r
       -> ThreadPool f a a' b b' r ()
worker = tell . pure

spawnSink :: (MonadReact s r m)
          => Event s a 
          -> Consumer a IO r 
          -> m ()
spawnSink = spawnSinkWith $ return ()

spawnSink_ :: (MonadReact s r m)
           => Event s a 
           -> Consumer a IO () 
           -> m ()
spawnSink_ = spawnSinkWith_ $ return ()

spawnSinkWith :: (MonadReact s r m,IORunnable f)
              => ChannelOpt a a' f z
              -> Event s a 
              -> Consumer a' f r 
              -> m ()
spawnSinkWith opt e = sinkPoolWith opt e . worker

spawnSinkWith_ :: (MonadReact s r m,IORunnable f)
               => ChannelOpt a a' f z
               -> Event s a 
               -> Consumer a' f () 
               -> m ()
spawnSinkWith_ opt e = sinkPoolWith_ opt e . worker

sinkPoolWith :: (MonadReact s r m,IORunnable f)
             => ChannelOpt a a' f z
             -> Event s a 
             -> SinkPool f a' r () 
             -> m ()
sinkPoolWith opt e sinks = liftReact $ case nonEmpty $ execWriter sinks of
        Just xs -> ReactPipe (Free $ Transform (() <$ opt) (f <$> xs) e Pure)
                      >>= result
        Nothing -> ReactPipe $ Pure ()
    where
        f x = (hoist lift x >-> P.map closed) >>= yield

sinkPoolWith_ :: (MonadReact s r m,IORunnable f)
              => ChannelOpt a a' f z
              -> Event s a 
              -> SinkPool f a' () () 
              -> m ()
sinkPoolWith_ opt e sinks = liftReact $ ReactPipe $ case nonEmpty $ execWriter sinks of
              Just xs -> Free (Sink (() <$ opt) (hoist lift <$> xs) e $ Pure ())
              Nothing -> Pure ()

sinkPool :: (MonadReact s r m)
         => Event s a 
         -> SinkPool IO a r () 
         -> m ()
sinkPool = sinkPoolWith $ return ()

sinkPool_ :: (MonadReact s r m)
          => Event s a 
          -> SinkPool IO a () () 
          -> m ()
sinkPool_ = sinkPoolWith_ $ return ()

spawnPipe :: (MonadReact s r m)
          => Event s a 
          -> Pipe a b IO r
          -> m (Event s b)
spawnPipe = spawnPipeWith $ return ()

spawnPipe_ :: MonadReact s r m
           => Event s a 
           -> Pipe a b IO ()
           -> m (Event s b)
spawnPipe_ = spawnPipeWith_ $ return ()

spawnPipeWith :: (MonadReact s r m,IORunnable f)
              => ChannelOpt a a' f z
              -> Event s a 
              -> Pipe a' b f r
              -> m (Event s b)
spawnPipeWith opt e = pipePoolWith opt e . worker

spawnPipeWith_ :: (MonadReact s r m,IORunnable f)
               => ChannelOpt a a' f z
               -> Event s a 
               -> Pipe a' b f ()
               -> m (Event s b)
spawnPipeWith_ opt e = pipePoolWith_ opt e . worker

pipePool :: (MonadReact s r m)
         => Event s a 
         -> PipePool IO a b r ()
         -> m (Event s b)
pipePool = pipePoolWith $ return ()

pipePool_ :: (MonadReact s r m)
          => Event s a 
          -> PipePool IO a b () ()
          -> m (Event s b)
pipePool_ = pipePoolWith_ $ return ()

pipePoolWith :: (MonadReact s r m,IORunnable f)
             => ChannelOpt a a' f z
             -> Event s a 
             -> PipePool f a' b r ()
             -> m (Event s b)
pipePoolWith opt e pipes = liftReact $ case nonEmpty $ execWriter pipes of
        Just xs ->  ReactPipe (Free $ Transform (() <$ opt) (f <$> xs) e Pure)
                      >>= uncurry split . splitEvent
        Nothing -> ReactPipe $ Pure Never
    where
        f x = (hoist lift x >-> P.map Right) >>= yield . Left
        split x y = result x >> return y

pipePoolWith_ :: (MonadReact s r m,IORunnable f)
              => ChannelOpt a a' f z
              -> Event s a 
              -> PipePool f a' b () ()
              -> m (Event s b)
pipePoolWith_ opt e pipes = liftReact $ ReactPipe $ case nonEmpty $ execWriter pipes of
        Just xs -> Free (Transform (() <$ opt) (hoist lift <$> xs) e Pure)
        Nothing -> Pure Never

retriesOnly :: Int -> Prism' SomeException a -> Restart a
retriesOnly = Restart

retries :: Int -> Restart SomeException
retries n = Restart n id

autonomous :: MonadReact s r m
           => a 
           -> Event s (a -> a) 
           -> (a -> STM (b,a))
           -> m (Event s b,Behavior s a)
autonomous = autonomousWith $ return ()

autonomousEventWith :: MonadReact s r m
                    => ChannelOpt' IO
                    -> a 
                    -> Event s (a -> a) 
                    -> (a -> STM (b,a))
                    -> m (Event s b,Event s a)
autonomousEventWith opt x e f = do
        ref <- liftReact $ ReactPipe $ Free $ MkBehavior x e Pure
        e'  <- spawnSourceWith opt $ forever $ do
                y <- lift $ atomically $ do
                    (e',x') <- f =<< readTVar ref
                    writeTVar ref $! x'
                    return (e',x')
                yield y
        -- return (e',Behavior $ readTVar ref)
        return (fst <$> e',snd <$> e')

autonomousWith :: MonadReact s r m
               => ChannelOpt' IO
               -> a 
               -> Event s (a -> a) 
               -> (a -> STM (b,a))
               -> m (Event s b,Behavior s a)
autonomousWith opt x e f = do
        ref <- liftReact $ ReactPipe $ Free $ MkBehavior x e Pure
        e'  <- spawnSourceWith opt $ forever $ do
                y <- lift $ atomically $ do
                    (e',x') <- f =<< readTVar ref
                    writeTVar ref $! x'
                    return e'
                yield y
        return (e',Behavior $ readTVar ref)

accumB :: MonadReact s r m
       => a -> Event s (a -> a)
       -> m (Behavior s a)
accumB x e = liftReact $ ReactPipe $ Free $ MkBehavior x e (Pure . Behavior . readTVar)

accumE :: MonadReact s r m
       => a 
       -> Event s (a -> a)
       -> m (Event s a)
accumE x e = liftReact $ ReactPipe $ Free $ AccumEvent x e Pure

-- reactimate :: MonadReact s r m
--            => Event s (IO ())
--            -> m ()
-- reactimate e = liftReact $ ReactPipe $ Free $ Reactimate e $ Pure ()

stepper :: MonadReact s r m
        => a 
        -> Event s a
        -> m (Behavior s a)
stepper x = accumB x . fmap const

type ThreadPool f a a' b b' r = Writer [Proxy a a' b b' f r]

type SinkPool f a r = Writer [Consumer a f r]
type SourcePool f a r = Writer [Producer a f r]
type PipePool f a b r = Writer [Pipe a b f r]

decrease :: Restart b -> Restart b
decrease (Restart n pr) = Restart (n-1) pr

prismOf :: Restart b -> Prism' SomeException b
prismOf (Restart _ pr) = pr

restartAndMonitor :: (MonadMask m,MonadIO m,Show b)
                  => Restart b
                  -> Proxy a a' () b m a 
                  -> Proxy a a' () b m a 
restartAndMonitor r = do
      restart r . monitor (prismOf r)

monitor :: MonadCatch m
        => Prism' SomeException b
        -> Proxy a a' () b m a 
        -> Proxy a a' () b m a 
monitor pr pipe = do
      e <- trying 
            (filtered (isn't _ThreadKilled).pr) 
            pipe
      either 
          (liftA2 (>>) yield $ throwM . review pr) 
          return 
          e

restart :: (MonadCatch m,MonadIO m,Show a)
        => Restart a
        -> Proxy x x' () y m r
        -> Proxy x x' () y m r
restart r@(Restart n pr) eff 
               | n <= 0    = eff
               | otherwise = do
                  trying (filtered (isn't _ThreadKilled).pr) eff >>= \case 
                    Left e -> do
                      liftIO $ print e
                      restart (decrease r) eff
                    Right res -> return res
