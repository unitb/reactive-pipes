{-# LANGUAGE UndecidableInstances #-}
module Pipes.Reactive.Animate.Class where

import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer
import Control.Monad.RWS
import Control.Monad.Except
import Control.Monad.Trans.Maybe
import Control.Monad.Trans.Either

import Pipes.Reactive.Class
import Pipes.Reactive.Event

class MonadReact s r m => Reactimate s r m | m -> s where
    reactimate :: Event s (IO ()) -> m ()
    default reactimate :: (t m' ~ m,MonadTrans t,Reactimate s r m')
                       => Event s (IO ()) -> m ()
    reactimate = lift . reactimate


instance Reactimate s r m => Reactimate s r (ReaderT reader m) where
instance (Reactimate s r m,Monoid writer) => Reactimate s r (WriterT writer m) where
instance Reactimate s r m => Reactimate s r (StateT reader m) where
instance (Reactimate s r m,Monoid writer) => Reactimate s r (RWST reader writer state m) where
instance (Reactimate s r m) => Reactimate s r (ExceptT e m) where
instance (Reactimate s r m) => Reactimate s r (EitherT e m) where
instance (Reactimate s r m) => Reactimate s r (MaybeT m) where

