module Pipes.Reactive.Discrete where

import Data.Bifunctor
import Pipes.Reactive -- hiding ((<@>),(<@))

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

toBehavior :: Discrete s a -> ReactPipe s r (Behavior s a)
toBehavior (Discrete f x step) = stepper (f x) . fmap f =<< accumE x step

stepperD :: a
         -> Event s a
         -> Discrete s a
stepperD x = Discrete id x . fmap const

accumD :: a
       -> Event s (a -> a)
       -> Discrete s a
accumD = Discrete id

updates :: Discrete s a
        -> ReactPipe s r (Event s a)
updates (Discrete f x step) = do
        fmap f <$> accumE x step

changes :: Discrete s a
        -> ReactPipe s r (Event s (a,a))
changes (Discrete f x step) = do
        e <- fmap f <$> accumE x step
        b <- stepper (f x) e
        return $ (,) <$> b <@> e

oldValue :: Discrete s a
         -> ReactPipe s r (Event s a)
oldValue (Discrete f x step) = do
        e <- fmap f <$> accumE x step
        b <- stepper (f x) e
        return $ b <@ e

