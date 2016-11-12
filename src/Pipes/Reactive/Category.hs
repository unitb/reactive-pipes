{-# LANGUAGE  ExistentialQuantification
            , DataKinds
            , LambdaCase
            , KindSignatures #-}
module Pipes.Reactive.Category where

import Control.Applicative
import Control.Category
import Control.Exception
import Control.Lens
import Control.Monad

import Data.Bifunctor
import Data.Either.Combinators
import Data.These hiding (fromThese)

import           Prelude hiding (id,(.))

import           Pipes as P
import           Pipes.Internal
import qualified Pipes.Prelude as P
import           Pipes.Reactive
import           Pipes.Reactive.Interpreter
import           Pipes.Reactive.Dynamic hiding (execute')
import qualified Pipes.Reactive.Dynamic as P

data CPipe r a b = 
    CPipe (Pipe a b IO r)
    | forall a' b'. React 
        (Pipe a a' IO r) 
        (forall s. Event s a' -> ReactPipe s r (Event s b'))
        (Pipe b' b IO r)

arr :: (Profunctor arr,Category arr) 
    => (a -> b) -> arr a b
arr f = rmap f id

(*^*) :: Monad m
      => Pipe a b m r
      -> Pipe a' b' m r
      -> Pipe (Either a a') (Either b b') m r
(*^*) p0 p1 = await >>= \case 
            Right x -> either return (\p -> p0 *^* p x) 
                        =<< (step p1 >-> P.map Right)
            Left x  -> either return (\p -> p x *^* p1) 
                        =<< (step p0 >-> P.map Left)

fromThese :: Monad m => Pipe (These a b) (Either a b) m r
fromThese = P.for cat $ here (yield.Left) >=> there (yield.Right) >=> const (pure ())

getUnion :: (forall s. Event s a -> ReactPipe s r (Event s a'))
         -> (forall s. Event s b -> ReactPipe s r (Event s b'))
         -> (forall s. (Event s a,Event s b) -> ReactPipe s r (Event s (These a' b')))
getUnion cmd0 cmd1 (e0,e1) = liftA2 unionThese (cmd0 e0) (cmd1 e1)

(***) :: forall r a b a' b'
      .  CPipe r a b
      -> CPipe r a' b'
      -> CPipe r (Either a a') (Either b b')
CPipe p0 *** CPipe p1 = CPipe $ p0 *^* p1
CPipe p0 *** React p1a cmd p1b 
            = React (p0 *^* p1a) (\e -> getUnion return cmd $ splitEvent e) (fromThese >-> cat *^* p1b)
    where
        -- cmd' :: (forall s. Event s a -> Event s b -> ReactPipe s r (Event s (These a b)))
        -- cmd' e0 e1 = unionThese e0 <$> cmd e1
React p1a cmd p1b *** CPipe p0 
            = dimap swapEither swapEither $ CPipe p0 *** React p1a cmd p1b
React p0a cmd0 p0b *** React p1a cmd1 p1b 
            = React (p0a *^* p1a) (\e -> getUnion cmd0 cmd1 $ splitEvent e) (fromThese >-> p0b *^* p1b)
    where
        -- cmd' e0 e1 = liftA2 unionThese (cmd0 e0) (cmd1 e1)

step :: Monad m
     => Pipe a b m r 
     -> Proxy z z' () b m (Either r (a -> Pipe a b m r))
step (Request () f) = pure $ Right f
step (Respond x f)  = yield x >> step (f ())
step (M m)    = lift m >>= step
step (Pure x) = pure (Left x)

instance Functor (CPipe r a) where
    fmap = rmap

instance Profunctor (CPipe r) where
    dimap f g x = CPipe (P.map f) >>> x >>> CPipe (P.map g)

instance Category (CPipe r) where
    id = CPipe cat
    CPipe x . CPipe y = CPipe $ x <-< y
    CPipe x . React y p z = React y p (z >-> x)
    React x p y . CPipe z = React (z >-> x) p y
    React x p y . React z q w = React z (q >=> flip spawnPipe (w >-> x) >=> p) y

makeDynamic :: CPipe r a b
            -> ReifiedReactPipe' r a b
makeDynamic x = case x of
            CPipe p1 -> ReifiedReactPipe' $ \e -> spawnPipe e p1
            React p1 intl p2 -> ReifiedReactPipe' $ \e -> do
                    flip spawnPipe p2 =<< intl =<< spawnPipe e p1 

runCPipe :: Producer a IO r 
         -> CPipe r a b
         -> Consumer b IO r
         -> IO r
runCPipe prod (CPipe p) con = runEffect (prod >-> p >-> con)
runCPipe prod (React p0 f p1) con = runReactive $ do
        e <- spawnSource $ prod >-> p0
        e' <- f e
        spawnSink e' $ p1 >-> con

for :: forall r a b c
    .  CPipe r a b 
    -> (b -> CPipe () a c) 
    -> CPipe r a c
for p f = for' p $ makeDynamic . f

for' :: forall r a b c
     .  CPipe r a b 
     -> (b -> ReifiedReactPipe' () a c) 
     -> CPipe r a c
for' (React p0 cmd p1) f = React cat cmd' cat
    where
        cmd' :: (forall s. Event s a -> ReactPipe s r (Event s c))
        cmd' e = do
            e' <- flip spawnPipe p1 <=< cmd <=< flip spawnPipe p0 $ e
            execute' e (f <$> e')
for' (CPipe p0) f = React cat cmd cat
    where
        cmd :: (forall s. Event s a -> ReactPipe s r (Event s c))
        cmd e = do
            e' <- spawnPipe e p0 
            execute' e (f <$> e')

for_ :: forall r a b c
     .  CPipe r a b 
     -> (b -> ReifiedReactPipe () c) 
     -> CPipe r a c
for_ (React p0 cmd p1) f = React p0 
        (cmd >=> flip spawnPipe p1 >=> execute_ . fmap f) 
        cat
for_ (CPipe p0) f = React p0 (execute_ . fmap f) cat

liftPipe :: Pipe a b IO r 
         -> CPipe r a b
liftPipe = CPipe

liftReact :: (forall s. Event s a -> ReactPipe s r (Event s b))
          -> CPipe r a b
liftReact f = React cat f cat

execute' :: Event s a
         -> Event s (ReifiedReactPipe' () a b)
         -> ReactPipe s r (Event s b)
execute' e prog = do
        ((exc,_),r) <- first splitEvent <$> P.execute' e prog
        reactimate $ throw <$> exc
        return r


execute_ :: Event s (ReifiedReactPipe () c)
         -> ReactPipe s r (Event s c)
execute_ e = do
        ((exc,_),r) <- first splitEvent <$> execute e
        reactimate $ throw <$> exc
        return r

