{-# LANGUAGE UndecidableInstances #-}
module Pipes.Reactive.Class where

import Control.Concurrent.STM
import Control.Exception
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer
import Control.Monad.RWS
import Control.Monad.Except
import Control.Monad.Free
import Control.Monad.Trans.Maybe
import Control.Monad.Trans.Except

import Pipes.Reactive.Event
import Pipes.Reactive.Types

class (MonadFix m,MonadIO m) => MonadReact s r m | m -> s, m -> r where
    liftReact :: ReactPipe s r a -> m a
    default liftReact :: (m ~ t m', MonadTrans t,MonadReact s r m')
                      => ReactPipe s r a -> m a
    liftReact  = lift . liftReact
    eThrow :: Exception e => Event s e -> m ()
    default eThrow :: (m ~ t m', MonadTrans t,MonadReact s r m'
                      ,Exception e)
                   => Event s e
                   -> m ()
    eThrow = lift . eThrow
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

instance MonadReact s r m => MonadReact s r (ReaderT reader m) where
instance (MonadReact s r m,Monoid writer) => MonadReact s r (WriterT writer m) where
instance MonadReact s r m => MonadReact s r (StateT reader m) where
instance (MonadReact s r m,Monoid writer) => MonadReact s r (RWST reader writer state m) where
instance (MonadReact s r m) => MonadReact s r (ExceptT e m) where
instance (MonadReact s r m) => MonadReact s r (MaybeT m) where
