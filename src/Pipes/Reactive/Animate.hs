{-# LANGUAGE UndecidableInstances #-}
module Pipes.Reactive.Animate 
    ( module Pipes.Reactive.Animate 
    , module Pipes.Reactive.Animate.Class )
where

import Control.Lens
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Writer

import Pipes
import Pipes.Reactive
import Pipes.Reactive.Animate.Class

newtype ReactimateT s m a = ReactimateT { runReactimateT :: WriterT [Event s (IO ())] m a }
    deriving (Functor,Applicative,Monad, MonadTrans,MonadFix,MonadIO)

instance MonadReact s r m => MonadReact s r (ReactimateT s m) where
    -- mapReact f (ReactimateT (WriterT cmd)) = ReactimateT $ WriterT $ mapReact (over (mapping regroup) f) cmd

regroup :: Iso' ((a,b),c) (a,(b,c))
regroup = iso shiftR shiftL
    where
        shiftR ((x,y),z) = (x,(y,z))
        shiftL (x,(y,z)) = ((x,y),z)

instance MonadReact s r m => Reactimate s r (ReactimateT s m) where
    reactimate e = ReactimateT $ tell [e]
instance MonadReader reader m => MonadReader reader (ReactimateT s m) where
    reader = lift . reader
    local f (ReactimateT cmd) = ReactimateT $ local f cmd
instance MonadState state m => MonadState state (ReactimateT s m) where
    state = lift . state
instance MonadWriter writer m => MonadWriter writer (ReactimateT s m) where
    writer = lift . writer
    listen (ReactimateT (WriterT cmd)) = ReactimateT $ WriterT $ shuffle <$> listen cmd
        where shuffle ((x,y),z) = ((x,z),y)
    pass (ReactimateT (WriterT cmd)) = ReactimateT $ WriterT $ pass (shuffle <$> cmd)
        where shuffle ((x,y),z) = ((x,z),y)

runReactimate :: MonadReact s r m
              => ReactimateT s m a 
              -> m a
runReactimate (ReactimateT cmd) = do
        (x,react) <- runWriterT cmd
        case unionsWith (>>) react of
                Never  -> return ()
                react' -> do
                    spawnSink 
                          react' 
                          (for cat lift)
        return x
                    
