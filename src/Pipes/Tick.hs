module Pipes.Tick where

import Control.Concurrent.STM
import Control.Lens
import Control.Monad
import Data.Time

import           Pipes
import           Pipes.Internal
import qualified Pipes.Prelude as P

tick :: MonadIO m 
     => Int 
     -> Producer UTCTime m r
tick n = do
        r <- liftIO $ registerDelay n
        yield =<< liftIO getCurrentTime 
        liftIO $ atomically $ guard =<< readTVar r
        tick n
 
tickSec :: MonadIO m 
        => Producer UTCTime m r
tickSec = tick 1000000

onTick :: MonadIO m
       => Int 
       -> Producer a m r
       -> Producer a m r
onTick t = P.zipWith (const id) (tick t)


onTickSec :: MonadIO m
          => Producer a m r
          -> Producer a m r
onTickSec = P.zipWith (const id) tickSec

poll :: MonadIO m => Int -> m a -> Producer a m r
poll n m = for (tick n) $ const $ lift m >>= yield

run :: Monad m
    => Pipe a b m r 
    -> m ([b], Either r (Pipe a b m r))
run (Pure r) = return $ ([],Left r)
run (Respond x f)  = (_1 %~ (x:)) <$> run (f ())
run p@(Request () _) = return ([], Right p)
run (M m) = m >>= run

step :: Monad m 
     => a 
     -> Pipe a b m r 
     -> m ([b], Either r (Pipe a b m r))
step _ (Pure r) = return $ ([],Left r)
step a (Respond x f)  = (_1 %~ (x:)) <$> step a (f ())
step a (Request () f) = run $ f a
step a (M m) = m >>= step a

broadcast :: Monad m
          => [Pipe a b m r] 
          -> Pipe a b m r 
broadcast xs = do
    x <- await
    xs' <- forM xs $ \p -> do
        (ys,e) <- lift $ step x p
        mapM_ yield ys
        return e
    either return broadcast $ sequence xs'

interleave :: Monad m
           => [Pipe a b m r] 
           -> Pipe a b m r  
interleave xs = do
    xs' <- forM xs $ \p -> do
        x <- await
        (ys,e) <- lift $ step x p
        mapM_ yield ys
        return e
    either return interleave $ sequence xs'
