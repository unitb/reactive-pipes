{-# LANGUAGE ExistentialQuantification
           , GeneralizedNewtypeDeriving
           , ConstraintKinds
           , TypeOperators
           , CPP
           , LambdaCase
           , RankNTypes
           , GADTs
           , TemplateHaskell
           , RecursiveDo
           , DeriveFunctor #-}
module Pipes.Reactive where

import Control.Applicative
import Control.Exception.Lens
import Control.Lens
import Control.Monad.Catch hiding (onException)
import Control.Monad.Free
import Control.Monad.RWS
import Control.Monad.Writer
import Control.Concurrent.STM

import Data.Functor.Apply
import Data.Functor.Contravariant
import Data.List.NonEmpty
import           Data.Map (Map)
import qualified Data.Map as Map

import           Pipes
import           Pipes.Concurrent -- (Buffer)
import           Pipes.Safe hiding (register,bracket)

import Unsafe.Coerce

data ReactiveF s r a = 
        forall b e. Show e => Source (Restart e) 
              (NonEmpty (Producer b (SafeT IO) ())) 
              (Event s b -> a)
        | forall b e. Show e => Sink (Restart e) 
              (NonEmpty (Consumer b (SafeT IO) ())) 
              (Event s b) a
        | forall e i o. Show e => Transform (Restart e)  
              (NonEmpty (Pipe i o (SafeT IO) ())) 
              (Event s i) 
              (Event s o -> a)
        | forall b. MkBehavior b (Event s (b -> b)) (Behavior s b -> a)
        | forall b. AccumEvent b (Event s (b -> b)) (Event s b -> a)
        | Reactimate (Event s (IO ())) a
        --  | Return (Event s r) a

instance Functor (ReactiveF s r) where
    -- fmap f (Return e g) = Return e $ f g
    fmap f (Source n s g) = Source n s $ f . g
    fmap f (Sink n s e g) = Sink n s e $ f g
    fmap f (Transform n s e g) = Transform n s e $ f . g
    fmap f (MkBehavior s e g)  = MkBehavior s e $ f . g
    fmap f (Reactimate e g)    = Reactimate e $ f g
    fmap f (AccumEvent x e g)  = AccumEvent x e $ f . g

-- type Restart = RestartImpl (->) Contravariant
-- type Restart' b = forall p. RestartImpl p Applicative b
-- data Restart a = Restart Int (forall f. (Functor f) => Optic' p f SomeException a)
data Restart a = Restart Int (Prism' SomeException a)

type ReactPipe s r = Free (ReactiveF s r)

newtype SenderId = SenderId Int
    deriving (Enum,Eq,Ord)

newtype ChannelSet s a = ChannelSet
            { register' :: Map SenderId (Channel s a) }
    deriving (Functor)

data Channel s a = 
        forall b. Channel 
            { r  :: Output' b -> STM () 
            , r' :: b -> STM (Maybe a) }

data Event s a = Event 
        (ChannelSet s a) 
        (ChannelSet s a)
    --  | Union (a -> a -> a) (Event a) (Event a)
    --  | forall b. FMap (b -> STM a) (Event b)
    | Never
    deriving Functor

data Behavior s a = Behavior (STM a)
    deriving (Functor)

instance Functor (Channel s) where
    fmap f (Channel b g) = Channel b $ (mapped.mapped %~ f) . g

#if !MIN_VERSION_pipes_concurrency(2,0,6)
instance Contravariant Output where
    contramap f (Output g) = Output $ g.f
#endif

newtype Output' a = Output' (STM (Output a,STM ()))

-- data Delimitor a = Value a | Terminator
--     deriving (Functor,Foldable,Traversable)

apCh :: (r -> r') 
     -> (r -> STM (Maybe (a -> b)))
     -> (r' -> STM (Maybe a))
     -> (r -> STM (Maybe b))
apCh refl f x = liftA2 (liftA2 (<*>)) f (x.refl)
-- apCh Nothing _ _ = error "foo apCh"

instance Apply (Channel s) where
    -- pure x = Channel $ \out -> void $ send out x
    Channel r f <.> Channel _ x = Channel r $ apCh unsafeCoerce f x

-- newtype Output a = Output (a -> STM )

applyC :: STM (a -> b)
       -> Channel s a
       -> Channel s b
applyC f (Channel b ch) = Channel b $ (liftA2 fmap f).ch
    -- where
    --     h (Output cmd) = Output $ \x -> f >>= cmd . ($ x)

applyCS :: STM (a -> b)
        -> ChannelSet s a
        -> ChannelSet s b
applyCS f (ChannelSet m) = ChannelSet $ applyC f <$> m

unionCS :: (a -> a -> a)
        -> ChannelSet s a
        -> ChannelSet s a
        -> ChannelSet s a
unionCS f (ChannelSet ch) (ChannelSet ch') = ChannelSet $ Map.unionWith (liftF2 f) ch ch'
    -- where
    --     h (Output cmd) = Output $ \x -> f >>= cmd . ($ x)

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

-- apply (Behavior f) (FMap g e)      = FMap ((f <*>) . g) e
-- apply (Behavior f) e@(Union _ _ _) = FMap ((f <*>) . pure) e

spawnSource :: Producer a IO () 
            -> ReactPipe s r (Event s a)
spawnSource = spawnSourceWith $ retries 0

spawnSourceWith :: Show k
                => Restart k
                -> Producer a IO () 
                -> ReactPipe s r (Event s a)
spawnSourceWith n source = sourcePoolWith n $ worker source

sourcePool :: SourcePool a () ()
           -> ReactPipe s r (Event s a)
sourcePool = sourcePoolWith (retries 0)

sourcePoolWith :: Show k
               => Restart k
               -> SourcePool a () ()
               -> ReactPipe s r (Event s a)
sourcePoolWith n source = case nonEmpty $ execWriter source of
                              Just xs -> Free (Source n (hoist lift <$> xs) Pure)
                              Nothing -> Pure Never

worker :: Proxy a a' b b' IO r
       -> ThreadPool a a' b b' r ()
worker = tell . pure

spawnSink :: Event s a 
          -> Consumer a IO () 
          -> ReactPipe s r ()
spawnSink = spawnSinkWith $ retries 0

spawnSinkWith :: Show k
              => Restart k
              -> Event s a 
              -> Consumer a IO () 
              -> ReactPipe s r ()
spawnSinkWith n e = sinkPoolWith n e . worker

sinkPoolWith :: Show k
             => Restart k
             -> Event s a 
             -> SinkPool a () () 
             -> ReactPipe s r ()
sinkPoolWith n e sinks = case nonEmpty $ execWriter sinks of
                            Just xs -> Free (Sink n (hoist lift <$> xs) e $ Pure ())
                            Nothing -> Pure ()

sinkPool :: Event s a 
         -> SinkPool a () () 
         -> ReactPipe s r ()
sinkPool = sinkPoolWith (retries 0)

spawnPipe :: Event s a 
          -> Pipe a b IO ()
          -> ReactPipe s r (Event s b)
spawnPipe = spawnPipeWith $ retries 0

spawnPipeWith :: Show k
              => Restart k
              -> Event s a 
              -> Pipe a b IO ()
              -> ReactPipe s r (Event s b)
spawnPipeWith n e = pipePoolWith n e . worker

pipePool :: Event s a 
         -> PipePool a b () ()
         -> ReactPipe s r (Event s b)
pipePool = pipePoolWith $ retries 0

pipePoolWith :: Show k
             => Restart k
             -> Event s a 
             -> PipePool a b () ()
             -> ReactPipe s r (Event s b)
pipePoolWith n e pipes = case nonEmpty $ execWriter pipes of
        Just xs -> Free (Transform n (hoist lift <$> xs) e Pure)
        Nothing -> Pure Never

retriesOnly :: Int -> Prism' SomeException a -> Restart a
retriesOnly = Restart

retries :: Int -> Restart SomeException
retries n = Restart n id

accumB :: a -> Event s (a -> a)
       -> ReactPipe s r (Behavior s a)
accumB x e = Free $ MkBehavior x e Pure

accumE :: a -> Event s (a -> a)
       -> ReactPipe s r (Event s a)
accumE x e = Free $ AccumEvent x e Pure

reactimate :: Event s (IO ())
           -> ReactPipe s r ()
reactimate e = Free $ Reactimate e $ Pure ()

unionsWith :: Foldable f
           => (a -> a -> a)
           -> f (Event s a) -> Event s a
unionsWith f = foldr (unionWith f) Never

    -- c :: Channel a
    -- f :: a -> a -> a
    -- (\x -> f x x) <$> c
unionWith :: (a -> a -> a)
          -> Event s a -> Event s a -> Event s a
unionWith _ e Never = e
unionWith _ Never e = e
-- unionWith f e0 e1 = Union f e0 e1
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

-- spawnSink' :: Event s a 
--            -> Consumer' a IO r 
--            -> ReactPipe s r ()
-- spawnSink' e proc = do
--         e' <- spawnPipe e $ proc >>= yield
--         Free $ Return e' $ Pure ()

-- spawnSource' :: Producer a IO r 
--              -> ReactPipe s r (Event s a)
-- spawnSource' proc = do
--         (e,e') <- fmap splitEvent . spawnSource 
--                 $ (proc >-> P.map Left) >>= yield . Right
--         Free $ Return e' $ Pure ()
--         return e

-- spawnPipe' :: Event s a
--            -> Pipe a b IO r 
--            -> ReactPipe s r (Event s b)
-- spawnPipe' e proc = do
--         (e0,e1) <- fmap splitEvent . spawnPipe e 
--                 $ (proc >-> P.map Left) >>= yield . Right
--         Free $ Return e1 $ Pure ()
--         return e0

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

-- ** Interpreter

restart :: (MonadCatch m,MonadIO m,Show a)
        => Restart a
        -> Proxy x x' () y m r
        -> Proxy x x' () y m r
restart r@(Restart n pr) eff 
               | n <= 0    = eff
               | otherwise = do
                  trying (filtered (isn't _ThreadKilled).pr) eff >>= \case 
                  -- trying _ eff >>= \case 
                    Left e -> do
                      liftIO $ print e
                      restart (decrease r) eff
                    Right r -> return r

-- restart :: (MonadCatch m,MonadMask m,MonadIO m,Show a)
--         => Restart a
--         -> Proxy x x' () y m r
--         -> Proxy x x' () y m r
-- restart n eff = hoist runSafeT (restart' n $ hoist lift eff)

