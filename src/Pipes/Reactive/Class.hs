module Pipes.Reactive.Class where

import Control.Concurrent.STM
import Control.Exception
import Control.Monad.Fix
import Control.Monad.Free
import Control.Monad.IO.Class

import Pipes.Reactive.Event
import Pipes.Reactive.Types

class (MonadFix m,MonadIO m) => MonadReact s r m | m -> s, m -> r where
    liftReact :: ReactPipe s r a -> m a
    eThrow :: Exception e => Event s e -> m ()
    -- mapReact :: (forall b. ReactPipe s r (a,b) -> ReactPipe s r (a,b)) -> m a -> m a

instance MonadReact s r (ReactPipe s r) where
    {-# INLINE liftReact #-}
    liftReact = id
    eThrow e = reactimateSTM $ throw <$> e
    -- mapReact f = fmap fst . f . fmap (,())

reactimateSTM :: MonadReact s r m
              => Event s (STM ()) 
              -> m ()
reactimateSTM e = liftReact $ ReactPipe $ Free $ ReactimateSTM e $ Pure ()
