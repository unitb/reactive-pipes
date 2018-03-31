{-# LANGUAGE BangPatterns #-}
module Pipes.Reactive.Discrete.Alt where

import Control.Lens
import Pipes.Reactive 

data PairR a b = PairR a !b 
    deriving (Functor,Foldable,Traversable)

instance Field1 (PairR a b) (PairR c b) a c where
    _1 f (PairR x y) = (\x' -> PairR x' y) <$> f x

instance Field2 (PairR a b) (PairR a d) b d where
    _2 f (PairR x y) = PairR x <$> f y

instance Bifunctor PairR where
    bimap f g (PairR x y) = PairR (f x) (g y)

data Discrete s a = 
    forall b. Discrete (PairR a b) (Event s (b -> (PairR a b)))

instance Functor (Discrete s) where
    fmap f (Discrete x step) = Discrete (x & _1 %~ f) (fmap (_1 %~ f) <$> step)
instance Applicative (Discrete s) where
    pure x = Discrete (PairR x ()) never
    Discrete (PairR xF sF) stepF <*> Discrete (PairR xX sX) stepX = 
            Discrete 
                (PairR (xF xX) (xF,xX,sF,sX))
                (fmap eval <$> unionWith (.) (stepF' <$> stepF) (stepX' <$> stepX))
        where
          eval t@(g,a,_x,_y) = PairR (g a) t
          stepF' f (_g,a,x,y) = g' `seq` x' `seq` (g',a,x',y)
                where PairR g' x' = f x
          stepX' f (g,_a,x,y) = a' `seq` y' `seq` (g,a',x,y')
                where PairR a' y' = f y

toBehavior :: MonadReact s r m
           => Discrete s a 
           -> m (Behavior s a)
toBehavior d@(Discrete x _) = stepper (x^._1) =<< updates d

-- applyD :: Discrete s (a -> b) -> Event s a -> Event s b
-- applyD (Discrete x e) = _

double :: a -> PairR a a
double x = PairR x x

stepperD :: a
         -> Event s a
         -> Discrete s a
stepperD x = accumD x . fmap const

accumD :: a
       -> Event s (a -> a)
       -> Discrete s a
accumD x e = Discrete (double x) $ fmap double <$> e

updates :: MonadReact s r m
        => Discrete s a
        -> m (Event s a)
updates (Discrete x step) = do
        fmap (view _1) <$> accumE x (lmap (view _2) <$> step)

changes :: MonadReact s r m
        => Discrete s a
        -> m (Event s (a,a))
changes (Discrete x0 step) = do
        let memo (PairR x y) = PairR undefined (x,y)
            mkPair (PairR old (new,_)) = (old,new)
            toPair (PairR x y) = (x,y)
            nextPair f (PairR _a (a',b)) = PairR a' (toPair $ f b)
        fmap mkPair <$> accumE (memo x0) (nextPair <$> step)

oldValue :: MonadReact s r m
         => Discrete s a
         -> m (Event s a)
oldValue = fmap (fmap fst) . changes

valueD :: Discrete s a -> a
valueD (Discrete (PairR x _) _) = x

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

