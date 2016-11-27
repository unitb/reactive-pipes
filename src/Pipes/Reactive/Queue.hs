{-# LANGUAGE RecursiveDo,TemplateHaskell #-}
module Pipes.Reactive.Queue where

import Control.Lens
import Control.Monad
import Control.Monad.State
import Control.Monad.STM

import           Data.Bifunctor
import           Data.Functor.Compose
import           Data.Map (Map)
import qualified Data.Map as M

import qualified Pipes.Prelude as P
import           Pipes.Reactive
import           Pipes.Reactive.Discrete

data PoolOpt = PoolOpt 
      { _workerNum :: Int 
      , _queueLength :: Int }

data QueueBehavior s a w r = QueueBehavior
      { initState :: a 
      , stateUpdate :: Event s (a -> a) 
      , getWorkItem :: a -> Maybe (w,a)
      , handler :: w -> IO r }

makeLenses ''PoolOpt

workQueue :: MonadReact s z m
          => QueueBehavior s a w r
          -> m (Event s r,Event s a,Discrete s Int)
workQueue = workQueueWith $ return ()

workQueueWith :: MonadReact s z m
              => State PoolOpt k
              -> QueueBehavior s a w r
              -> m (Event s r,Event s a,Discrete s Int)
workQueueWith opt (QueueBehavior x add split handle) = do
        let (PoolOpt n ln) = execState opt (PoolOpt 5 5)
        (task,v) <- autonomousEventWith 
            (chanLen .= ln) x add 
            (maybe retry return . split)
        (r,upd) <- fmap (,v) $ pipePool task $ replicateM_ n $ worker $ P.mapM handle
        let qLen = accumD 0 $ unionWith (.) (pred <$ r) (succ <$ task)
        return (r,upd,qLen)

workPool :: (Ord k,Eq a,MonadReact s r m)
         => (k -> a -> IO out)
         -> Discrete s (Map k a)
         -> m (Discrete s (Map k (a,out)),Discrete s Int)
workPool = workPoolWith (return ())

workPoolWith :: (Ord k,Eq a,MonadReact s r m)
             => State PoolOpt z
             -> (k -> a -> IO out)
             -> Discrete s (Map k a)
             -> m (Discrete s (Map k (a,out)),Discrete s Int)
workPoolWith opt f b = mdo
        let w0 = valueD b
            updateQueue x = bimap 
                    (M.mapMaybe id . M.intersectionWith delNew x) 
                    (M.differenceWith keepNew x)
            keepNew x y | x == y    = Just x
                        | otherwise = Nothing
            delNew x (y,out) | x == y    = Just (y,out)
                             | otherwise = Nothing
        ws <- updates b
        (r,v,c) <- workQueueWith opt
            QueueBehavior 
              { initState = (M.empty,w0) 
              , stateUpdate = unionWith (.) (first <$> r) $ updateQueue <$> ws
              , getWorkItem = getCompose . _2 (Compose . M.minViewWithKey)
              , handler = \(k,a) -> M.insert k . (,) a <$> f k a }
        return (stepperD M.empty (fst <$> v),c)
