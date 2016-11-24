{-# LANGUAGE QuasiQuotes #-}
module Pipes.Reactive.Types where

import Control.Applicative
import Control.Category
import Control.Concurrent.STM
import Control.Monad.Free
import Control.Monad.RWS
import Control.Monad.State

import           Data.List.NonEmpty hiding (reverse)

import           Pipes
import           Pipes.Reactive.Event
import           Pipes.Safe hiding (register,bracket)

import Prelude hiding ((.),id)

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
        --  | Reactimate (Event s (IO ())) a
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
    -- fmap f (Reactimate e g)    = Reactimate e $ f g
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

-- data Restart a = Restart Int (Prism' SomeException a)

newtype ReactPipe s r a = ReactPipe (Free (ReactiveF s r) a)
    deriving (Functor,Applicative,Monad)

data Behavior s a = Behavior (STM a)
    deriving (Functor)

instance Applicative (Behavior s) where
    pure = Behavior . pure
    Behavior f <*> Behavior x = Behavior $ f <*> x
