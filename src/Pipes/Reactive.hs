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
module Pipes.Reactive where

import Control.Applicative
import Control.Category
import Control.Concurrent.STM
import Control.Exception.Lens
import Control.Lens
import Control.Monad.Catch hiding (onException)
import Control.Monad.Free
import Control.Monad.RWS
import Control.Monad.State
import Control.Monad.Writer

import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.List.NonEmpty hiding (reverse)
import           Data.These

import           Pipes
import           Pipes.Concurrent 
import           Pipes.Core
import qualified Pipes.Prelude as P
import           Pipes.Safe hiding (register,bracket)

import Prelude hiding ((.),id)

import Unsafe.Coerce

import Text.Printf.TH

newtype ChannelLength = ChannelLength Int

data ReactiveF s r a = 
        forall b. Source (State ChannelLength ())
              (NonEmpty (Producer b (SafeT IO) ())) 
              (Event s b -> a)
        | forall b. Sink (State ChannelLength ())
              (NonEmpty (Consumer b (SafeT IO) ())) 
              (Event s b) a
        | forall i o. Transform (State ChannelLength ())
              (NonEmpty (Pipe i o (SafeT IO) ())) 
              (Event s i) 
              (Event s o -> a)
        | forall b. MkBehavior b (Event s (b -> b)) (TVar b -> a)
        | forall b. AccumEvent b (Event s (b -> b)) (Event s b -> a)
        | Reactimate (Event s (IO ())) a
        | ReactimateSTM (Event s (STM ())) a
        | forall b. MFix (b -> Free (ReactiveF s r) b) (b -> a)
        | LiftIO (IO a)
        | Return (Event s r) a
        | Finalize (Behavior s (IO ())) a

instance MonadIO (ReactPipe s r) where
    liftIO cmd = ReactPipe $ Free (LiftIO $ Pure <$> cmd)

instance Functor (ReactiveF s r) where
    fmap f (Source opt src g)  = Source opt src $ f . g
    fmap f (Sink opt snk e g)  = Sink opt snk e $ f g
    fmap f (Transform opt pipe e g) = Transform opt pipe e $ f . g
    fmap f (MkBehavior x e g)  = MkBehavior x e $ f . g
    fmap f (Reactimate e g)    = Reactimate e $ f g
    fmap f (ReactimateSTM e g) = ReactimateSTM e $ f g
    fmap f (AccumEvent x e g)  = AccumEvent x e $ f . g
    fmap f (LiftIO x)          = LiftIO $ f <$> x
    fmap f (MFix x g)          = MFix x $ f . g
    fmap f (Return x g)        = Return x $ f g
    fmap f (Finalize x g)      = Finalize x $ f g

instance MonadFix (ReactPipe s r) where
    mfix f = ReactPipe $ Free $ MFix (runReact . f) Pure
        where 
          runReact (ReactPipe m) = m

data Restart a = Restart Int (Prism' SomeException a)

newtype ReactPipe s r a = ReactPipe (Free (ReactiveF s r) a)
    deriving (Functor,Applicative,Monad)

newtype SenderId = SenderId Int
    deriving (Enum,Eq,Ord)

instance Show SenderId where
    show (SenderId n) = [s|(%d)|] n

newtype ChannelSet s a = ChannelSet
            { register' :: Map SenderId (Channel s a) }
    deriving (Functor)

data Channel s a = 
        forall b. Channel 
            (Output' b -> STM ()) 
            (b -> STM (Maybe a))

data Event s a = Event 
        (ChannelSet s a) 
        (ChannelSet s a)
    | Never
    deriving Functor

data Behavior s a = Behavior (STM a)
    deriving (Functor)

instance Functor (Channel s) where
    fmap f (Channel b g) = Channel b $ (mapped.mapped %~ f) . g

newtype Output' a = Output' (STM (Output a,STM Int))

chanLen :: Lens' ChannelLength Int
chanLen f (ChannelLength n) = ChannelLength <$> f n

switchB :: Behavior s a
        -> Event s (Behavior s a) 
        -> ReactPipe s r (Behavior s a)
switchB b e = do
    Behavior b' <- stepper b e
    let unBe (Behavior v) = v
    return $ Behavior $ join $ unBe <$> b'

-- switchE :: Event s (Event s a) -> Event s a
-- switchE (Event (ChannelSet ch0) (ChannelSet ch1)) = Event (ChannelSet _) (ChannelSet _)

match :: Event s a 
      -> Event s b
      -> ReactPipe s r (Event s a)
match input tick = do
    lastE <- stepper Nothing $ unionWith const (Just <$> input) (Nothing <$ tick)
    return $ filterJust $ lastE <@ tick

batch :: Event s a
      -> Event s b
      -> ReactPipe s r (Event s (NonEmpty a))
batch input tick = do
    lastE <- accumB [] $ unionWith (>>>) (const [] <$ tick) ((:) <$> input)
    return $ filterJust $ nonEmpty.reverse <$> lastE <@ tick

apCh :: (r -> r') 
     -> (a -> a -> a)
     -> (r -> STM (Maybe a))
     -> (r' -> STM (Maybe a))
     -> (r -> STM (Maybe a))
apCh refl f x y = liftA2 (liftA2 $ combineMaybe f) x (y.refl)

combineMaybe :: (a -> a -> a)
             -> Maybe a
             -> Maybe a
             -> Maybe a
combineMaybe f (Just x) y = (f x <$> y) <|> Just x
combineMaybe _f Nothing y = y


combine :: (a -> a -> a) 
        -> Channel s a 
        -> Channel s a 
        -> Channel s a 
combine f (Channel r x) (Channel _ y) = Channel r $ apCh unsafeCoerce f x y

applyC :: STM (a -> b)
       -> Channel s a
       -> Channel s b
applyC f (Channel b ch) = Channel b $ (liftA2 fmap f).ch

applyCS :: STM (a -> b)
        -> ChannelSet s a
        -> ChannelSet s b
applyCS f (ChannelSet m) = ChannelSet $ applyC f <$> m

unionCS :: (a -> a -> a)
        -> ChannelSet s a
        -> ChannelSet s a
        -> ChannelSet s a
unionCS f (ChannelSet ch) (ChannelSet ch') = ChannelSet $ Map.unionWith (combine f) ch ch'

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

result :: Event s r
       -> ReactPipe s r ()
result e = ReactPipe $ Free $ Return e $ Pure ()

finalize :: Behavior s (IO ()) 
         -> ReactPipe s r ()
finalize final = ReactPipe $ Free $ Finalize final $ Pure ()

resource :: IO x
         -> (x -> IO ())
         -> ReactPipe s r x
resource alloc free = do
      r <- liftIO alloc
      finalize $ pure $ free r
      return r

spawnSource :: Producer a IO r 
            -> ReactPipe s r (Event s a)
spawnSource = spawnSourceWith $ return ()

spawnSource_ :: Producer a IO ()
             -> ReactPipe s r (Event s a)
spawnSource_ = spawnSourceWith_ $ return ()

spawnSourceWith :: State ChannelLength z
                -> Producer a IO r 
                -> ReactPipe s r (Event s a)
spawnSourceWith opt source = sourcePoolWith opt $ worker source

spawnSourceWith_ :: State ChannelLength z
                 -> Producer a IO ()
                 -> ReactPipe s r (Event s a)
spawnSourceWith_ opt source = sourcePoolWith_ opt $ worker source

sourcePool :: SourcePool a r ()
           -> ReactPipe s r (Event s a)
sourcePool = sourcePoolWith $ return ()

sourcePool_ :: SourcePool a () ()
            -> ReactPipe s r (Event s a)
sourcePool_ = sourcePoolWith_ $ return ()

sourcePoolWith_ :: State ChannelLength z
                -> SourcePool a () ()
                -> ReactPipe s r (Event s a)
sourcePoolWith_ opt source = ReactPipe $ case nonEmpty $ execWriter source of
                              Just xs -> Free (Source (() <$ opt) (f <$> xs) Pure)
                              Nothing -> Pure Never
    where
        f = hoist lift

sourcePoolWith :: State ChannelLength z
               -> SourcePool a r ()
               -> ReactPipe s r (Event s a)
sourcePoolWith opt source = case nonEmpty $ execWriter source of
                              Just xs -> ReactPipe (Free $ Source (() <$ opt) (f <$> xs) Pure) 
                                            >>= uncurry split . splitEvent
                              Nothing -> ReactPipe $ Pure Never
    where
        f x = (hoist lift x >-> P.map Right) >>= yield . Left
        split x y = result x >> return y

worker :: Proxy a a' b b' IO r
       -> ThreadPool a a' b b' r ()
worker = tell . pure

spawnSink :: Event s a 
          -> Consumer a IO r 
          -> ReactPipe s r ()
spawnSink = spawnSinkWith $ return ()

spawnSink_ :: Event s a 
           -> Consumer a IO () 
           -> ReactPipe s r ()
spawnSink_ = spawnSinkWith_ $ return ()

spawnSinkWith :: State ChannelLength z
              -> Event s a 
              -> Consumer a IO r 
              -> ReactPipe s r ()
spawnSinkWith opt e = sinkPoolWith opt e . worker

spawnSinkWith_ :: State ChannelLength z
               -> Event s a 
               -> Consumer a IO () 
               -> ReactPipe s r ()
spawnSinkWith_ opt e = sinkPoolWith_ opt e . worker

sinkPoolWith :: State ChannelLength z
             -> Event s a 
             -> SinkPool a r () 
             -> ReactPipe s r ()
sinkPoolWith opt e sinks = case nonEmpty $ execWriter sinks of
                            Just xs -> ReactPipe (Free $ Transform (() <$ opt) (f <$> xs) e Pure)
                                          >>= result
                            Nothing -> ReactPipe $ Pure ()
    where
        f x = (hoist lift x >-> P.map closed) >>= yield

sinkPoolWith_ :: State ChannelLength z
              -> Event s a 
              -> SinkPool a () () 
              -> ReactPipe s r ()
sinkPoolWith_ opt e sinks = ReactPipe $ case nonEmpty $ execWriter sinks of
                            Just xs -> Free (Sink (() <$ opt) (hoist lift <$> xs) e $ Pure ())
                            Nothing -> Pure ()

sinkPool :: Event s a 
         -> SinkPool a r () 
         -> ReactPipe s r ()
sinkPool = sinkPoolWith $ return ()

sinkPool_ :: Event s a 
          -> SinkPool a () () 
          -> ReactPipe s r ()
sinkPool_ = sinkPoolWith_ $ return ()

spawnPipe :: Event s a 
          -> Pipe a b IO r
          -> ReactPipe s r (Event s b)
spawnPipe = spawnPipeWith $ return ()

spawnPipe_ :: Event s a 
           -> Pipe a b IO ()
           -> ReactPipe s r (Event s b)
spawnPipe_ = spawnPipeWith_ $ return ()

spawnPipeWith :: State ChannelLength z
              -> Event s a 
              -> Pipe a b IO r
              -> ReactPipe s r (Event s b)
spawnPipeWith opt e = pipePoolWith opt e . worker

spawnPipeWith_ :: State ChannelLength z
               -> Event s a 
               -> Pipe a b IO ()
               -> ReactPipe s r (Event s b)
spawnPipeWith_ opt e = pipePoolWith_ opt e . worker

pipePool :: Event s a 
         -> PipePool a b r ()
         -> ReactPipe s r (Event s b)
pipePool = pipePoolWith $ return ()

pipePool_ :: Event s a 
          -> PipePool a b () ()
          -> ReactPipe s r (Event s b)
pipePool_ = pipePoolWith_ $ return ()

pipePoolWith :: State ChannelLength z
             -> Event s a 
             -> PipePool a b r ()
             -> ReactPipe s r (Event s b)
pipePoolWith opt e pipes = case nonEmpty $ execWriter pipes of
        Just xs ->  ReactPipe (Free $ Transform (() <$ opt) (f <$> xs) e Pure)
                      >>= uncurry split . splitEvent
        Nothing -> ReactPipe $ Pure Never
    where
        f x = (hoist lift x >-> P.map Right) >>= yield . Left
        split x y = result x >> return y

pipePoolWith_ :: State ChannelLength z
              -> Event s a 
              -> PipePool a b () ()
              -> ReactPipe s r (Event s b)
pipePoolWith_ opt e pipes = ReactPipe $ case nonEmpty $ execWriter pipes of
        Just xs -> Free (Transform (() <$ opt) (hoist lift <$> xs) e Pure)
        Nothing -> Pure Never

retriesOnly :: Int -> Prism' SomeException a -> Restart a
retriesOnly = Restart

retries :: Int -> Restart SomeException
retries n = Restart n id

autonomous :: a 
           -> Event s (a -> a) 
           -> (a -> STM (b,a))
           -> ReactPipe s r (Event s b,Behavior s a)
autonomous = autonomousWith $ return ()

autonomousEventWith :: State ChannelLength z 
                    -> a 
                    -> Event s (a -> a) 
                    -> (a -> STM (b,a))
                    -> ReactPipe s r (Event s b,Event s a)
autonomousEventWith opt x e f = do
        ref <- ReactPipe $ Free $ MkBehavior x e Pure
        e'  <- spawnSourceWith opt $ forever $ do
                y <- lift $ atomically $ do
                    (e',x') <- f =<< readTVar ref
                    writeTVar ref $! x'
                    return (e',x')
                yield y
        -- return (e',Behavior $ readTVar ref)
        return (fst <$> e',snd <$> e')

autonomousWith :: State ChannelLength z 
               -> a 
               -> Event s (a -> a) 
               -> (a -> STM (b,a))
               -> ReactPipe s r (Event s b,Behavior s a)
autonomousWith opt x e f = do
        ref <- ReactPipe $ Free $ MkBehavior x e Pure
        e'  <- spawnSourceWith opt $ forever $ do
                y <- lift $ atomically $ do
                    (e',x') <- f =<< readTVar ref
                    writeTVar ref $! x'
                    return e'
                yield y
        return (e',Behavior $ readTVar ref)

accumB :: a -> Event s (a -> a)
       -> ReactPipe s r (Behavior s a)
accumB x e = ReactPipe $ Free $ MkBehavior x e (Pure . Behavior . readTVar)

accumE :: a -> Event s (a -> a)
       -> ReactPipe s r (Event s a)
accumE x e = ReactPipe $ Free $ AccumEvent x e Pure

reactimate :: Event s (IO ())
           -> ReactPipe s r ()
reactimate e = ReactPipe $ Free $ Reactimate e $ Pure ()

unionsWith :: Foldable f
           => (a -> a -> a)
           -> f (Event s a) -> Event s a
unionsWith f = foldr (unionWith f) Never

fromThat :: These a b -> Maybe b -> These a b
fromThat x Nothing = x
fromThat (This x) (Just y)    = These x y
fromThat (That _) (Just y)    = That y
fromThat (These x _) (Just y) = These x y
fromThis :: These a b -> Maybe a -> These a b
fromThis x Nothing = x
fromThis (That x) (Just y)    = These y x
fromThis (This _) (Just y)    = This y
fromThis (These _ x) (Just y) = These y x

unionThese :: Event s a
           -> Event s b
           -> Event s (These a b)
unionThese e0 e1 = unionWith f (This <$> e0) (That <$> e1)
    where
        f x y = fromThat x $ y^?there

unionWith :: (a -> a -> a)
          -> Event s a -> Event s a -> Event s a
unionWith _ e Never = e
unionWith _ Never e = e
unionWith f (Event e0 e0') (Event e1 e1') = Event 
        (unionCS f e0 e1) 
        (unionCS f e0' e1') 

never :: Event s a
never = Never

filterE :: (a -> Bool) -> Event s a -> Event s a
filterE p = filterApply (pure p)

filterApply :: Behavior s (a -> Bool) -> Event s a -> Event s a
filterApply v = filterJust . apply ((\p x -> guard (p x) >> Just x) <$> v)

whenE :: Behavior s Bool -> Event s a -> Event s a
whenE p = filterApply (const <$> p)

catChannelSet :: ChannelSet s (Maybe a) -> ChannelSet s a
catChannelSet (ChannelSet m) = ChannelSet $ catChannel <$> m

catChannel :: Channel s (Maybe a) -> Channel s a
catChannel (Channel x y) = Channel x (fmap join . y)

filterPrism :: Prism' t a -> Event s t -> Event s a
filterPrism pr = filterJust . fmap (preview pr)

filterJust :: Event s (Maybe a) -> Event s a
filterJust Never = Never
filterJust (Event f g) = Event (catChannelSet f) (catChannelSet g)

splitEvent :: Event s (Either a b) -> (Event s a,Event s b)
splitEvent e = (filterPrism _Left e,filterPrism _Right e)

stepper :: a -> Event s a
        -> ReactPipe s r (Behavior s a)
stepper x = accumB x . fmap const

instance Applicative (Behavior s) where
    pure = Behavior . pure
    Behavior f <*> Behavior x = Behavior $ f <*> x

type ThreadPool a a' b b' r = Writer [Proxy a a' b b' IO r]

type SinkPool a r = Writer [Consumer a IO r]
type SourcePool a r = Writer [Producer a IO r]
type PipePool a b r = Writer [Pipe a b IO r]

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

reactimateSTM :: Event s (STM ()) -> ReactPipe s r ()
reactimateSTM e = ReactPipe $ Free $ ReactimateSTM e $ Pure ()

