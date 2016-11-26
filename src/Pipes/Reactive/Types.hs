{-# LANGUAGE QuasiQuotes,TemplateHaskell #-}
module Pipes.Reactive.Types where

import Control.Applicative
import Control.Category
import Control.Concurrent.STM
import Control.Lens
import Control.Monad.Free
import Control.Monad.RWS
import Control.Monad.State

import Data.List.NonEmpty hiding (reverse)
import Data.Proxy as P

import           Pipes
import           Pipes.Reactive.Event
import           Pipes.Safe hiding (register,bracket)

import Prelude hiding ((.),id)

data Wait a b where
    Unbounded :: Wait a a
    Bounded :: Int -> Wait a (Maybe a)
    NoWait :: Wait a (Maybe a)

data ChannelLength = ChannelLength 
    { _chanLen :: Int  }

makeLenses ''ChannelLength

type ChannelOpt' f = forall z. ChannelOpt z z f ()

data ChannelOpt a b (f :: * -> *) z = ChannelOpt (State ChannelLength z) (Wait a b)
    deriving (Functor)

instance a ~ b => Applicative (ChannelOpt a b f) where
    pure x = ChannelOpt (pure x) Unbounded
    ChannelOpt f opt <*> ChannelOpt x _ = ChannelOpt (f <*> x) opt
instance a ~ b => Monad (ChannelOpt a b f) where
    ChannelOpt m opt >>= f = ChannelOpt (m >>= getState . f) opt
        where getState (ChannelOpt x _) = x
instance a ~ b => MonadState ChannelLength (ChannelOpt a b f) where
    state f = ChannelOpt (state f) Unbounded


(<|) :: Wait a a' -> ChannelOpt a k f z -> ChannelOpt a a' f z
(<|) w (ChannelOpt ch _) = ChannelOpt ch w

useIO :: a ~ b => ChannelOpt a b IO () 
useIO = return ()
 
useMonad :: a ~ b => P.Proxy m -> ChannelOpt a b m ()
useMonad _ = return ()

data ReactiveF s r a = 
        forall b m. IORunnable m => Source 
              -- (ChannelOpt m ())
              (NonEmpty (Producer b (SafeT m) ())) 
              (Event s b -> a)
        | forall b b' m. IORunnable m => Sink 
              (ChannelOpt b b' m ())
              (NonEmpty (Consumer b' (SafeT m) ())) 
              (Event s b) a
        | forall i i' o m. IORunnable m => Transform 
              (ChannelOpt i i' m ())
              (NonEmpty (Pipe i' o (SafeT m) ())) 
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

class (MonadIO m,MonadMask m) => IORunnable m where
    runIO :: m a -> IO a

instance IORunnable IO where
    runIO = id

instance MonadIO (ReactPipe s r) where
    liftIO cmd = ReactPipe $ Free (LiftIO $ Pure <$> cmd)

instance Functor (ReactiveF s r) where
    fmap f (Source src g)  = Source src $ f . g
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
