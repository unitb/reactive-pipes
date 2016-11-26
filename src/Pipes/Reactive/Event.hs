{-# LANGUAGE QuasiQuotes #-}
module Pipes.Reactive.Event where

import Control.Applicative
import Control.Lens
import Control.Monad
import Control.Monad.STM

import           Data.Foldable
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Monoid (First)
import           Data.Semigroup hiding (First)
import           Data.These

import Pipes.Concurrent
import Prelude hiding (foldr)
import Text.Printf.TH

import Unsafe.Coerce

data Event s a = Event 
        (ChannelSet s a) 
        (ChannelSet s a)
    | Never
    deriving Functor

newtype ChannelSet s a = ChannelSet
            { register' :: Map SenderId (Channel s a) }
    deriving (Functor)

data Channel s a = 
        forall b. Channel 
            (Output' b -> STM ()) 
            (b -> STM (Maybe a))

newtype Output' a = Output' (STM (Output a,STM Int))

instance Functor (Channel s) where
    fmap f (Channel b g) = Channel b $ (mapped.mapped %~ f) . g


newtype SenderId = SenderId Int
    deriving (Enum,Eq,Ord)

instance Show SenderId where
    show (SenderId n) = [s|(%d)|] n

unionsWith :: Foldable f
           => (a -> a -> a)
           -> f (Event s a) -> Event s a
unionsWith f = foldr (unionWith f) Never

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

filterPrism :: Getting (First a) t a -> Event s t -> Event s a
filterPrism pr = filterJust . fmap (preview pr)

filterJust :: Event s (Maybe a) -> Event s a
filterJust Never = Never
filterJust (Event f g) = Event (catChannelSet f) (catChannelSet g)

splitEvent :: Event s (Either a b) -> (Event s a,Event s b)
splitEvent e = (filterPrism _Left e,filterPrism _Right e)

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

catChannelSet :: ChannelSet s (Maybe a) -> ChannelSet s a
catChannelSet (ChannelSet m) = ChannelSet $ catChannel <$> m

catChannel :: Channel s (Maybe a) -> Channel s a
catChannel (Channel x y) = Channel x (fmap join . y)


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

instance Semigroup a => Monoid (Event s a) where
    mempty  = Never
    mappend = unionWith (<>)
    mconcat = unionsWith (<>)
instance Semigroup a => Semigroup (Event s a) where
