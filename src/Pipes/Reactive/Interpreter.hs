{-# LANGUAGE LambdaCase,TemplateHaskell,QuasiQuotes #-}
module Pipes.Reactive.Interpreter 
    ( runMachine, runReactive, compile )
where

import Control.Applicative
import Control.Concurrent.Async hiding (waitEither)
import Control.Concurrent.STM as S
import Control.Exception.Lens
import Control.Lens hiding ((...))
import Control.Monad.Catch hiding (onException,finally)
import Control.Monad.Free
import Control.Monad.RWS
import Control.Monad.State

import Data.Bifunctor
import Data.Either
import Data.List.NonEmpty as N hiding (length,zipWith,head,last)
import qualified Data.Map as Map
import Data.Maybe
import Data.Monoid.Monad

import           Prelude hiding (zipWith,zipWith3)
import           Pipes
import           Pipes.Concurrent hiding (Unbounded,Bounded)
import           Pipes.Reactive   hiding (reactimateSTM)
import           Pipes.Reactive.Async
import           Pipes.Safe       hiding (register,bracket)

import Text.Printf.TH

type M s r = RWST ()
            [ReactHandle s r]
            SenderId 
            IO

newtype ReceiverId = ReceiverId Int
    deriving (Enum,Eq,Ord)

data ReactHandle s r = 
            Thread (IO (IO ()))
            | Init (STM ())
            --   | ReactEvent (Event s (IO ()))
            | Finalizer  (Behavior s (IO ()))
            | Result (Event s r)

makePrisms ''ReactHandle

waitRead :: Wait a b -> Input a -> IO (Maybe b)
waitRead (Bounded t) input = do
            timer <- registerDelay t
            S.atomically $ (Just <$> recv input) <|> 
                (do check =<< readTVar timer ; return $ Just Nothing)
waitRead NoWait input = do
            S.atomically $ (Just <$> recv input) <|> 
                return (Just Nothing)
waitRead Unbounded input = S.atomically $ recv input

fromInput' :: (MonadIO m) 
           => Wait a b
           -> Input a
           -> Producer' b m ()
fromInput' w input = loop
  where
    loop = do
        ma <- liftIO $ waitRead w input
        case ma of
            Nothing -> return ()
            Just a  -> do
                yield a
                loop



mySpawn :: MonadIO m
        => ChannelOpt a a' f z
        -> IO (Output' a,Producer a' m ())
mySpawn (ChannelOpt opt w) = do
    let (ChannelLength n) = execState opt $ ChannelLength 10
    writers <- newTVarIO 0
    let _ = writers :: TVar Int
    q <- newTBQueueIO n
    let input  = Input $ Just <$> readTBQueue q
        out    = Output $ fmap (const True) . writeTBQueue q 
        getOut = do
                modifyTVar' writers succ
                return (out,decAndSeal)
        sealIf = do
                c <- readTVar writers
                check $ c == 0
                return Nothing
        decAndSeal = do
              modifyTVar' writers pred
              readTVar writers
        sealAfterLast (Input i) = Input $ i `orElse` sealIf
    return (Output' getOut,fromInput' w $ sealAfterLast input)

splitHandles :: [ReactHandle s r] 
             -> ( [IO (IO ())]
                , [STM ()]
                , [Event s r]
                , [Behavior s (IO ())]) 
splitHandles = flip foldr mempty $ \case 
            Thread ts    -> _1 <>~ [ts]
            Init proc    -> _2 <>~ [proc]
            Result e     -> _3 <>~ [e] 
            Finalizer final -> _4 <>~ [final] 

newThread :: IORunnable m
          => IO (Effect (SafeT m) ()) 
          -> M s r ()
newThread t = tell [Thread $ runIO . runSafeT . runEffect <$> onException' 
                        (filtered $ isn't _ThreadKilled) 
                        (liftIO . [sP|failed because of: %?|]) <$> t]

onException' :: MonadCatch m
             => Prism' SomeException e
             -> (e -> m b)
             -> m a
             -> m a
onException' pr f = handleJust (preview pr) (liftA2 (>>) f $ throwM . review pr)


readEvent :: MonadIO m
          => ChannelOpt a a' f z
          -> Event s a 
          -> M s r (Producer a' m ())
readEvent opt e = do
        (out,input) <- lift $ mySpawn opt
            -- Super duper important: the pattern matchings below must be
            --   separated so that, instead of having a lazy pairs which forces
            --   the evaluation of `e`, we have a pair whose component forces
            --   the evaluation of `e`.
            -- 
            --   In the first case, the Writer monad, when separating the output
            --   and the result will cause `e` to be evaluated. In the other
            --   case, the writer can build a string of lazy  concatenation of
            --   lists and a network of events, neither of which needs to be
            --   evaluated before
        tell $ case e of
                Never -> []
                Event f _ -> 
                    [Init $ registerSet f out]
        return $ case e of
                Never -> return ()
                Event _ _ -> input

conditional :: (a -> STM (Maybe b))
            -> Output b -> Output a
conditional f (Output out) = Output $ maybe (return True) out <=< f

register :: Channel s a -> Output' a -> STM ()
register (Channel b f) (Output' out) = b $ Output' $ out & mapped._1 %~ conditional f

registerSet :: ChannelSet s a -> Output' a -> STM ()
registerSet (ChannelSet m) out = do
    forM_ m . flip register $ out

runOutput :: Output' (STM ())
runOutput = Output' $ return (Output (True <$),return 1)

reactimateSTM :: Event s (STM ()) -> M s r ()
reactimateSTM e = do
        tell $ case e of
                Never -> []
                Event _ f -> [Init $ registerSet f runOutput]

allocate :: (Enum a,Monad m,Monoid w) 
         => Lens' s a -> RWST r w s m a
allocate ln = zoom ln $ state $ liftA2 (,) id succ

catOutput :: Output (Maybe a) -> Output a
catOutput = contramap Just

compileOut :: [(Output (Maybe a), STM Int)] -> (Output a, STM Int)
compileOut = bimap catOutput (fmap getSum . run) . foldMap (second $ Cons . fmap Sum)

makeChannel :: M s r (ChannelSet s a,Output' a)
makeChannel = do 
        n <- allocate id
        v <- lift $ newTVarIO []
        let ch (Output' out') = modifyTVar' v . (:) =<< out'
            chSet = ChannelSet $ Map.singleton n $ Channel ch pure
            out = Output' $ do
                evts <- readTVar v
                return $ compileOut $ evts
        return (chSet,out)

withChannel :: MonadSafe m
            => Output' a -> (Output a -> STM (m r)) -> STM (m r)
withChannel (Output' cmd) f = do
        (out,final) <- cmd
        prog <- f out
        return $ prog `finally` liftIO (atomically final)

makeEvent :: IORunnable m
          => NonEmpty (Producer a (SafeT m) ())
          -> M s r (Event s a)
makeEvent sources = do
        es <- forM sources $ \src -> do
            (v,getV) <- makeChannel
            (u,getU) <- makeChannel
            newThread $ atomically $
                withChannel getV $ \out -> 
                withChannel getU $ \upd -> do
                    return $ src >-> toOutput (out <> upd)
            return $ Event v u
        return $ unionsWith const es

    -- Idea: 
    --  put the Map as part of channels
    --  add SendId to events too?

runReactive' :: Free (ReactiveF s r) a -> M s r a
runReactive' (Pure x) = return x
runReactive' (Free (Source source f)) = do
        e <- makeEvent source
        runReactive' $ f e
runReactive' (Free (Transform n pipe e f)) = do
        input <- readEvent n e
        e' <- makeEvent $ (input >->) <$> pipe
        runReactive' $ f e'
runReactive' (Free (Sink n sinks e cmd)) = do
        input <- readEvent n e
        forM_ sinks $ \snk ->
          newThread $ return $ input >-> snk
        runReactive' cmd 
runReactive' (Free (MkBehavior x e f)) = do
        ref <- liftIO $ newTVarIO x
        reactimateSTM $ modifyTVar' ref <$> e
        runReactive' $ f ref
runReactive' (Free (AccumEvent x e f)) = do
        ref <- liftIO $ newTVarIO x
        let e' = flip ($) <$> Behavior (readTVar ref) <@> e
        reactimateSTM $ (writeTVar ref $!) <$> e'
        runReactive' $ f e'
runReactive' (Free (MFix e f)) = do
        mfix (runReactive' . e)
            >>= runReactive' . f
runReactive' (Free (LiftIO x)) = do
        lift x >>= runReactive'
runReactive' (Free (ReactimateSTM e f)) = do
        reactimateSTM e
        runReactive' f
runReactive' (Free (Return e f)) = do
        tell [Result e]
        runReactive' f
runReactive' (Free (Finalize e f)) = do
        tell [Finalizer e]
        runReactive' f

data Machine r = Machine 
        (STM r) 
        [IO ()] 
        (STM (IO ()))

unwrapBehavior :: Behavior s a -> STM a
unwrapBehavior (Behavior v) = v

compile :: (forall s. ReactPipe s r a) -> IO (a,Machine r)
compile (ReactPipe pipe) = do 
        ((r,x),_,(ts,is,_return,final)) <- (_3 %~ splitHandles) <$> runRWST 
                (do r <- liftIO newEmptyTMVarIO 
                    (x,(_,_,ret,_final)) <- listens 
                            splitHandles 
                            (runReactive' $ do
                                pipe
                                )
                    reactimateSTM $ void . tryPutTMVar r <$> unionsWith const ret
                    return (takeTMVar r,x) ) 
                () 
                (SenderId 0)
        mapM_ atomically is
        ts' <- sequence ts
        return (x,Machine r ts' $ fmap sequence_ . traverse unwrapBehavior $ final)

runReactive :: (forall s. ReactPipe s r a) -> IO r
runReactive prg = compile prg >>= fmap snd . _2 runMachine

runMachine :: Machine r -> IO r
runMachine (Machine res ts' final) = do
        let wrapup r = do
                mapM_ cancel <=< atomically . readTVar $ r
                join $ atomically final
        [sP| Threads: %d - ... |] $ length ts'
        bracket (newTVarIO []) 
          wrapup
          (\r -> do
            hs  <- mapM async ts'
            atomically $ writeTVar r hs
            collectAll_ res (writeTVar r) hs >>= \case 
                Right x -> return x
                Left (e :| _) -> throwM e)

