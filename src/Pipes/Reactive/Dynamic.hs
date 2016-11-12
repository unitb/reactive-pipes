module Pipes.Reactive.Dynamic where

import Control.Applicative
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception
import Control.Lens
import Control.Monad

import Data.Maybe
import Data.These

import           Pipes.Concurrent
import qualified Pipes.Prelude as P
import           Pipes.Reactive
import           Pipes.Reactive.Interpreter

newtype ReifiedReactPipe r a = ReifiedReactPipe 
          (forall s. ReactPipe s r (Event s a))

newtype ReifiedReactPipe' r a b = ReifiedReactPipe'
          (forall s. Event s a -> ReactPipe s r (Event s b))

waitForFirst :: (a -> STM b) -> [a] -> STM (b,[a])
waitForFirst = waitForFirst' []

waitForFirst' :: [a] -> (a -> STM b) -> [a] -> STM (b,[a])
waitForFirst' _ _ [] = retry
waitForFirst' ys f (x:xs) = 
            (, xs ++ reverse ys) <$> f x 
        <|> waitForFirst' (x:ys) f xs

waitThese :: (a -> STM a')
          -> (b -> STM b')
          -> (a,b) -> STM (These a' b')
waitThese f g (x,y) = 
            liftA2 (flip ($)) (f x) 
                   ((flip These <$> g y) <|> return This)
        <|> (That <$> g y)

execute' :: Event s1 a
         -> Event s1 (ReifiedReactPipe' r a b)
         -> ReactPipe s1 r1 (Event s1 (Either SomeException r),Event s1 b)
execute' e cmd = do
    e' <- spawnPipe cmd $ P.mapM $ \(ReifiedReactPipe' f) -> do
            (out',input) <- spawn $ bounded 10
            (out,input') <- spawn $ bounded 10
            pc <- async $ runReactive $ do
                e' <- f =<< spawnSource_ (fromInput input')
                reactimateSTM $ void . send out' <$> e'
            return (pc,input,out)
    (output,pool) <- autonomous [] ((:) <$> e') $ \xs ->
                (readOne xs & mapped._1 %~ Right) 
            <|> (awaitCompletion xs & mapped._1 %~ Left)
    let allOutput = fmap (foldMap $ view _3)
    reactimateSTM $ (send <$> allOutput pool <@> e) & mapped.mapped .~ ()
    finalize $ (mapM_._1) cancel <$> pool
    return $ splitEvent output & _2 %~ filterJust

execute :: Event s1 (ReifiedReactPipe r a)
        -> ReactPipe s1 r1 (Event s1 (Either SomeException r),Event s1 a)
execute e = do
    e' <- spawnPipe e $ P.mapM $ \(ReifiedReactPipe cmd) -> do
            (out,input) <- spawn $ bounded 10
            pc <- async $ runReactive $ do
                e' <- cmd
                reactimateSTM $ void . send out <$> e'
            return (pc,input,())
    (output,pool) <- autonomous [] ((:) <$> e') $ \xs ->
                (readOne xs & mapped._1 %~ Right) 
            <|> (awaitCompletion xs & mapped._1 %~ Left)
    finalize $ mapM_ (cancel.view _1) <$> pool
    return $ splitEvent output & _2 %~ filterJust

awaitCompletion :: [(Async a, b,k)]
                -> STM (Either SomeException a, [(Async a, b, k)])
awaitCompletion xs = do
        (y,ys) <- waitForFirst (_1 waitCatchSTM) xs
        return (y^._1,ys)

readOne :: [(a,Input c,k)] 
        -> STM (Maybe c,[(a,Input c,k)])
readOne xs = do
        let readInput i = fmap ((,) i) <$> recv i
        (y,ys) <- waitForFirst (_2 readInput) xs
        return (snd <$> y^._2,ys ++ maybeToList (y & _2 (fmap fst)))
