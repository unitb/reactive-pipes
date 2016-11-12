{-# LANGUAGE LambdaCase,TemplateHaskell,QuasiQuotes #-}
module Pipes.Reactive.Interpreter 
    ( runMachine, runReactive, compile )
where

import Control.Applicative
import Control.Concurrent.Async hiding (waitEither)
import Control.Concurrent.STM as S
import Control.Exception.Lens
import Control.Lens hiding ((...))
import Control.Lens.Internal.Zoom hiding (Effect)
import Control.Monad.Catch hiding (onException,finally)
import Control.Monad.Free
import Control.Monad.RWS

import Data.Bifunctor
import Data.Either
import Data.List.NonEmpty hiding (zipWith)
import qualified Data.Map as Map
import Data.Maybe
import Data.Monoid.Monad

import           Prelude hiding (zipWith,zipWith3)
import           Pipes
import           Pipes.Concurrent 
import           Pipes.Reactive hiding (reactimateSTM)
import           Pipes.Reactive.Async
import           Pipes.Safe hiding (register,bracket)

import Text.Printf.TH

type M s r = RWST ()
            [ReactHandle s r]
            SenderId 
            IO

newtype ReceiverId = ReceiverId Int
    deriving (Enum,Eq,Ord)

data ReactHandle s r = 
            Thread (IO (Effect (SafeT IO) ()))
            | Init (STM ())
            | ReactEvent (Event s (IO ()))
            | Finalizer  (Behavior s (IO ()))
            | Result (Event s r)

makePrisms ''ReactHandle

mySpawn :: IO (Output' a,Input a)
mySpawn = do
    let n = 1
    writers <- newTVarIO 0
    (out,input,_seal) <- spawn' $ bounded n
    let getOut = do
                modifyTVar writers succ
                return (out,decAndSeal)
        sealIf = do
                c <- readTVar writers
                check $ c == 0
                return Nothing
        decAndSeal = do
              modifyTVar writers pred
        sealAfterLast (Input i) = Input $ i `orElse` sealIf
    return (Output' getOut,sealAfterLast input)

splitHandles :: [ReactHandle s r] 
             -> ( [IO (Effect (SafeT IO) ())]
                , [STM ()]
                , [Event s (IO ())]
                , [Event s r]
                , [Behavior s (IO ())]) 
splitHandles = foldMap $ \case 
            Thread ts -> ([ts],[],[],[],[])
            Init proc -> ([],[proc],[],[],[])
            ReactEvent e -> ([],[],[e],[],[])
            Result e -> ([],[],[],[e],[])
            Finalizer final -> ([],[],[],[],[final])

newThread :: Show a
          => Restart a
          -> IO (Effect (SafeT IO) ()) 
          -> M s r ()
newThread n t = tell [Thread $ onException' 
                        (filtered $ isn't _ThreadKilled) 
                        (liftIO . [sP|failed because of: %?|]) . restart n <$> t]

onException' :: MonadCatch m
             => Prism' SomeException e
             -> (e -> m b)
             -> m a
             -> m a
onException' pr f = handleJust (preview pr) (liftA2 (>>) f $ throwM . review pr)

liftSTMLater :: STM () -> M s r ()
liftSTMLater cmd = tell [Init cmd]

readEvent :: Event s a -> M s r (Producer a (SafeT IO) ())
readEvent Never = return $ return ()
readEvent (Event f _) = do
        (out,input) <- lift mySpawn
        liftSTMLater $ registerSet f out
        return $ fromInput input

conditional :: (a -> STM (Maybe b))
            -> Output b -> Output a
conditional f (Output out) = Output $ maybe (return True) out <=< f

register :: Channel s a -> Output' a -> STM ()
register (Channel b f) (Output' out) = b $ Output' $ out & mapped._1 %~ conditional f

registerSet :: ChannelSet s a -> Output' a -> STM ()
registerSet (ChannelSet m) = forM_ m . flip register

reactimateSTM :: Event s (STM ()) -> M s r ()
reactimateSTM Never = return ()
reactimateSTM (Event _ f) = do
        liftSTMLater $ registerSet f $ Output' $ return (Output (True <$),return ())

allocate :: (Zoom m n a s,Enum a) 
         => LensLike' (Zoomed m a) s a -> n a
allocate ln = zoom ln $ state $ liftA2 (,) id succ

catOutput :: Output (Maybe a) -> Output a
catOutput = contramap Just

makeChannel :: M s r (ChannelSet s a,Output' a)
makeChannel = do 
        n <- allocate id
        v <- lift $ newTVarIO []
        let ch (Output' out) = modifyTVar v . (:) =<< out
            chSet = ChannelSet $ Map.singleton n $ Channel ch pure
            get = Output' $ bimap catOutput run . foldMap (second Cons) <$> readTVar v
        return (chSet,get)

withChannel :: MonadSafe m
            => Output' a -> (Output a -> STM (m r)) -> STM (m r)
withChannel (Output' cmd) f = do
        (out,final) <- cmd
        prog <- f out
        return $ prog `finally` liftIO (atomically final)

makeEvent :: Show e
          => Restart e
          -> NonEmpty (Producer a (SafeT IO) ())
          -> M s r (Event s a)
makeEvent n sources = do
        es <- forM sources $ \s -> do
          (v,getV) <- makeChannel
          (u,getU) <- makeChannel
          newThread n $ atomically $
                withChannel getV $ \out -> 
                withChannel getU $ \upd -> 
                    return $ s >-> toOutput (out <> upd)
          return $ Event v u
        return $ unionsWith const es

    -- Idea: 
    --  put the Map as part of channels
    --  add SendId to events too?

runReactive' :: ReactPipe s r a -> M s r a
runReactive' (Pure x) = return x
runReactive' (Free (Source n source f)) = do
        e <- makeEvent n source
        runReactive' $ f e
runReactive' (Free (Transform n pipe e f)) = do
        input <- readEvent e
        e' <- makeEvent n $ (input >->) <$> pipe
        runReactive' $ f e'
runReactive' (Free (Sink n sinks e cmd)) = do
        input <- readEvent e
        forM_ sinks $ \s ->
          newThread n $ return $ input >-> s
        runReactive' cmd
runReactive' (Free (MkBehavior x e f)) = do
        ref <- liftIO $ newTVarIO x
        reactimateSTM $ modifyTVar ref <$> e
        runReactive' $ f ref
runReactive' (Free (AccumEvent x e f)) = do
        ref <- liftIO $ newTVarIO x
        reactimateSTM $ modifyTVar ref <$> e
        runReactive' $ f (Behavior (readTVar ref) <@ e)
runReactive' (Free (Reactimate e f)) = do
        tell [ReactEvent e]
        runReactive' f
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

data Machine r = Machine (STM r) [Effect (SafeT IO) ()] (STM (IO ()))

unwrapBehavior :: Behavior s a -> STM a
unwrapBehavior (Behavior v) = v

compile :: (forall s. ReactPipe s r a) -> IO (a,Machine r)
compile pipe = do 
        ((r,x),_,(ts,is,_react,_return,final)) <- (_3 %~ splitHandles) <$> runRWST 
                (do (x,(_,_,react,ret,_final)) <- listens 
                            splitHandles 
                            (runReactive' pipe)
                    r <- liftIO newEmptyTMVarIO 
                    reactimateSTM $ putTMVar r <$> unionsWith const ret
                    case unionsWith (>>) react of
                        Never  -> return ()
                        react' -> do
                            runReactive' 
                                $ spawnSink 
                                      react' 
                                      (for cat lift)
                    return (takeTMVar r,x) ) 
                () 
                (SenderId 0)
        mapM_ atomically is
        ts' <- sequence ts
        return (x,Machine r ts' $ fmap sequence_ . traverse unwrapBehavior $ final)

runReactive :: (forall s. ReactPipe s r a) -> IO r
runReactive prg = compile prg >>= fmap snd . _2 runMachine

runMachine :: Machine r -> IO r
runMachine (Machine result ts' final) = do
        let wrapup r = do
                mapM_ cancel <=< atomically . readTVar $ r
                join $ atomically final
        bracket (newTVarIO []) 
          wrapup
          (\r -> do
            hs  <- mapM (async.runEffect.runSafeP) ts'
            atomically $ writeTVar r hs
            collectAll_ result (writeTVar r) hs >>= \case 
                Right x -> return x
                Left (e :| _) -> throwM e)

