{-# LANGUAGE BangPatterns #-}
module Pipes.Reactive.Discrete where

import Control.Lens
import Data.Bifunctor
import Pipes.Reactive -- hiding ((<@>),(<@))

data PairR a b = PairR a !b 
    deriving (Functor,Foldable,Traversable)

instance Field1 (PairR a b) (PairR c b) a c where
    _1 f (PairR x y) = (\x' -> PairR x' y) <$> f x

instance Field2 (PairR a b) (PairR a d) b d where
    _2 f (PairR x y) = PairR x <$> f y

instance Bifunctor PairR where
    bimap f g (PairR x y) = PairR (f x) (g y)

data Discrete s a = 
    forall b. Discrete (b -> a) b (Event s (b -> b))

instance Functor (Discrete s) where
    fmap f (Discrete g x step) = Discrete (f . g) x step
instance Applicative (Discrete s) where
    pure x = Discrete id x never
    Discrete gF xF stepF <*> Discrete gX xX stepX = 
          Discrete 
              (uncurry ($) . bimap gF gX) 
              (xF,xX) 
              (unionWith (.) (first <$> stepF) (second <$> stepX))

-- applyD :: Discrete s (a -> b) -> Event s a -> Event s b
-- applyD (Discrete f x e) = _

toBehavior :: MonadReact s r m
           => Discrete s a 
           -> m (Behavior s a)
toBehavior d@(Discrete f x _step) = stepper (f x) =<< updates d

double :: a -> PairR a a
double x = PairR x x

stepperD :: a
         -> Event s a
         -> Discrete s a
stepperD x = accumD x . fmap const

accumD :: a
       -> Event s (a -> a)
       -> Discrete s a
accumD = Discrete id

updates :: MonadReact s r m
        => Discrete s a
        -> m (Event s a)
updates (Discrete f x step) = do
        fmap f <$> accumE x step

changes :: MonadReact s r m
        => Discrete s a
        -> m (Event s (a,a))
changes d@(Discrete f x _step) = do
        e <- updates d
        b <- stepper (f x) e
        return $ (,) <$> b <@> e

oldValue :: MonadReact s r m
         => Discrete s a
         -> m (Event s a)
oldValue d@(Discrete f x _step) = do
        e <- updates d
        b <- stepper (f x) e
        return $ b <@ e

valueD :: Discrete s a -> a
valueD (Discrete f x _) = f x

poll :: MonadReact s r m
     => Event s b 
     -> Discrete s a
     -> m (Event s a)
poll e d = do
    ch <- updates d
    match ch e

pollAndHold :: MonadReact s r m
            => Event s b
            -> Discrete s a
            -> m (Discrete s a)
pollAndHold e d = do
    e' <- poll e d
    return $ stepperD (valueD d) e'

