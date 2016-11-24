{-# LANGUAGE UndecidableInstances #-}
module Pipes.Reactive.Implicit where

import Control.Applicative
import Control.Lens hiding (each)

import Data.Either.Combinators
import Data.List.NonEmpty
import Data.Semigroup

import           Pipes
import           Pipes.Lift
import qualified Pipes.Prelude as P
import           Pipes.Reactive
import           Pipes.Reactive.Implicit.Class
import           Pipes.Reactive.Animate

newtype IOPipe scope i o m a  = IOPipe (RWST () (Event scope (NonEmpty o)) (Event scope i) m a)
    deriving (Functor,Applicative,Monad,MonadTrans,MonadIO,MonadFix
             ,MonadState (Event scope i),MonadWriter (Event scope (NonEmpty o)))
newtype ReaderP scope r m a  = ReaderP (ReaderT (Event scope r) m a)
    deriving (Functor,Applicative,Monad,MonadTrans,MonadIO,MonadFix,MonadReader (Event scope r))
newtype StateP scope s m a   = StateP (StateT (Event scope s) m a)
    deriving (Functor,Applicative,Monad,MonadTrans,MonadIO,MonadFix,MonadState (Event scope s))
newtype WriterP scope w m a  = WriterP (WriterT (Event scope w) m a)
    deriving (Functor,Applicative,Monad,MonadTrans,MonadIO,MonadFix,MonadWriter (Event scope w))
newtype RWSP scope r w s m a = RWSP (RWST (Event scope r) (Event scope w) (Event scope s) m a)
    deriving (Functor,Applicative,Monad,MonadTrans,MonadIO,MonadFix
             ,MonadReader (Event scope r),MonadState (Event scope s),MonadWriter (Event scope w))

instance (MonadReact s r m,Semigroup o) => MonadReact s r (IOPipe s i o m) where
    liftReact  = IOPipe . lift . liftReact
    eThrow = lift . eThrow
    -- mapReact = _
instance (Reactimate s r m,Semigroup o) => Reactimate s r (IOPipe s i o m) where
    reactimate = IOPipe . lift . reactimate

instance MonadReact s r m => MonadReact s r (ReaderP s reader m) where
    liftReact  = ReaderP . lift . liftReact
    eThrow = lift . eThrow
    -- mapReact = _
instance Reactimate s r m => Reactimate s r (ReaderP s reader m) where
    reactimate = ReaderP . lift . reactimate

instance MonadReact s r m => MonadReact s r (StateP s state m) where
    liftReact  = StateP . lift . liftReact
    eThrow = lift . eThrow
    -- mapReact = _
instance Reactimate s r m => Reactimate s r (StateP s state m) where
    reactimate = StateP . lift . reactimate

instance (MonadReact s r m,Semigroup writer) => MonadReact s r (WriterP s writer m) where
    liftReact  = WriterP . lift . liftReact
    eThrow = lift . eThrow
    -- mapReact = _
instance (Reactimate s r m,Semigroup writer) => Reactimate s r (WriterP s writer m) where
    reactimate = WriterP . lift . reactimate

instance (MonadReact s r m,Semigroup writer) => MonadReact s r (RWSP s reader writer state m) where
    liftReact  = RWSP . lift . liftReact
    eThrow = lift . eThrow
    -- mapReact = _
instance (Reactimate s r m,Semigroup writer) => Reactimate s r (RWSP s reader writer state m) where
    reactimate = RWSP . lift . reactimate

    -- problem: buffering IO in Async queues: when the pipe system terminates,
    -- all the unused IO get discarded

selectInput' :: Monad m 
             => Prism' i a 
             -> IOPipe s i o m (Event s a)
selectInput' = selectInput . pure . Prism

selectInput :: Monad m 
            => Behavior s (ReifiedPrism' i a)
            -> IOPipe s i o m (Event s a)
selectInput p = IOPipe $ state $ splitEvent . (\e -> fmap swapEither . matching . runPrism <$> p <@> e)
takeInput :: Monad m 
          => IOPipe s i o m (Event s i)
takeInput = IOPipe $ liftA2 const get (put never)
readInput :: Monad m 
          => IOPipe s i o m (Event s i)
readInput = get
output :: Event s o
       -> IOPipe s i o (ReactPipe s r) ()
output = tell . fmap pure
runStdIOPipe :: Reactimate s () m
             => IOPipe s String String m a
             -> m a
runStdIOPipe = fromTo P.stdinLn P.stdoutLn

fromTo :: Reactimate s r m
       => Producer i IO ()
       -> Consumer o IO r
       -> IOPipe s i o m a
       -> m a
fromTo input out (IOPipe cmd) = do
        i <- spawnSource_ input
        (r,i',o) <- runRWST cmd () i
        spawnSink o $ P.concat >-> out
        reactimate $ putStrLn "unsupported input" <$ i'
        return r

runMockIOPipe :: Reactimate s [o] m
              => [i]
              -> IOPipe s i o m a
              -> m a
runMockIOPipe is = fromTo (each is) (execWriterP $ forever $ await >>= tell . pure)
