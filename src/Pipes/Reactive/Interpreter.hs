{-# LANGUAGE LambdaCase,TemplateHaskell,QuasiQuotes #-}
module Pipes.Reactive.Interpreter where

import Control.Applicative
-- import Control.Exception.Lens
-- import Control.Concurrent
import Control.Lens hiding ((...))
-- import Control.Lens.Type
import Control.Lens.Internal.Zoom hiding (Effect)
import Control.Monad.Catch hiding (onException,finally)
import Control.Monad.Free
import Control.Monad.RWS
-- import Control.Monad.Writer
import Control.Concurrent.Async hiding (waitEither)
import Control.Concurrent.STM as S

import Data.Bifunctor
import Data.Either
-- import Data.Functor.Apply
import Data.List.NonEmpty hiding (zipWith)
-- import           Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe
import Data.Monoid.Monad

import           Prelude hiding (zipWith,zipWith3)
import           Pipes
import           Pipes.Concurrent -- (Buffer)
import qualified Pipes.Prelude as P
import           Pipes.Reactive
import           Pipes.Safe hiding (register,bracket)

-- import Unsafe.Coerce
import Text.Printf.TH

type M s r = RWST ()
            [ReactHandle s]
            (SenderId,()) 
            IO

newtype ReceiverId = ReceiverId Int
    deriving (Enum,Eq,Ord)

data ReactHandle s = 
            Thread (IO (Effect (SafeT IO) ()))
            | Init (STM ())
            | ReactEvent (Event s (IO ()))
            -- | Result (Event s r)

makePrisms ''ReactHandle

spawn'' :: Int -> IO (Output a, Input a)
spawn'' n = do
    -- (write, read) <- case buffer of
    --     Bounded n -> do
    q <- S.newTBQueueIO n
        --     return ()
        -- Unbounded -> do
        --     q <- S.newTQueueIO
        --     return (S.writeTQueue q, S.readTQueue q)
        -- Single    -> do
        --     m <- S.newEmptyTMVarIO
        --     return (S.putTMVar m, S.takeTMVar m)
        -- Latest a  -> do
        --     t <- S.newTVarIO a
        --     return (S.writeTVar t, S.readTVar t)
        -- New       -> do
        --     m <- S.newEmptyTMVarIO
        --     return (\x -> S.tryTakeTMVar m *> S.putTMVar m x, S.takeTMVar m)
        -- Newest n  -> do
        --     q <- S.newTBQueueIO n
        --     let write x = S.writeTBQueue q x <|> (S.tryReadTBQueue q *> write x)
        --     return (write, S.readTBQueue q)

    -- sealed <- S.newTVarIO False
    -- let seal = S.writeTVar sealed True

    {- Use weak TVars to keep track of whether the 'Input' or 'Output' has been
       garbage collected.  Seal the mailbox when either of them becomes garbage
       collected.
    -}
    -- rSend <- newTVarIO ()
    -- void $ mkWeakTVar rSend (S.atomically seal)
    -- rRecv <- newTVarIO ()
    -- void $ mkWeakTVar rRecv (S.atomically seal)

    -- let sendOrEnd a = do
    --         -- b <- S.readTVar sealed
    --         -- if b
    --         --     then return False
    --         --     else do
    --                 write a
    --                 return True
    --     -- readOrEnd = (Just <$> read)
    let _send a = do
                    S.writeTBQueue q a
                    return True
        -- _send a = sendOrEnd a -- <* readTVar rSend
           -- <* readTVar rRecv
        _recv   = Just <$> S.readTBQueue q
    return (Output _send, Input _recv)

mySpawn :: IO (Output' a,Input a)
mySpawn = do
    let n = 1
    -- q <- S.newTBQueueIO n
    -- q <- S.newEmptyTMVarIO
    -- readers <- newTVarIO 0
    writers <- newTVarIO 0
    (out,input,_seal) <- spawn' $ bounded n
    let 
        -- out = Output $ \a -> do
        --             S.writeTBQueue q $ fromDelimitor a
        --             -- S.putTMVar q $ fromDelimitor a
        --             return True
        -- -- input = Input $ (Just <$> S.readTBQueue q) `orElse` sealIf
        -- -- input = Input $ (Just <$> S.takeTMVar q) `orElse` sealIf
        -- input = Input $ do
        --             x <- S.readTBQueue q
        --             unless (isJust x) $ S.unGetTBQueue q x
        --             -- x <- S.takeTMVar q
        --             -- unless (isJust x) $ S.putTMVar q x
        --             return x
        getOut = do
                modifyTVar writers succ
                -- n <- readTVar counter
                return (out,decAndSeal)
        sealIf = do
                c <- readTVar writers
                -- empty <- S.isEmptyTBQueue q
                -- empty <- S.isEmptyTMVar q
                check $ c == 0
                return Nothing
                -- if c == 0 then
                --   seal >> return Nothing
                -- else retry
        decAndSeal = do
              modifyTVar writers pred
              -- c <- readTVar writers
              -- when (c == 0) $ void $ send out Terminator
              -- readTVar counter
        sealAfterLast (Input i) = Input $ i `orElse` sealIf
    return (Output' getOut,sealAfterLast input)

-- delimitorOf :: Maybe a -> Delimitor a
-- delimitorOf = maybe Terminator Value

-- fromDelimitor :: Delimitor a -> Maybe a
-- fromDelimitor = delimitor Nothing Just

-- delimitor :: r -> (a -> r) -> Delimitor a -> r
-- delimitor r _ Terminator = r
-- delimitor _ f (Value x)  = f x

splitHandles :: [ReactHandle s] 
             -> ([IO (Effect (SafeT IO) ())],[STM ()],[Event s (IO ())])
             -- ([IO (Effect IO ())],[STM ()],[Event s (IO ())],[Event s r]) 
splitHandles = foldMap $ \case 
            Thread ts -> ([ts],[],[])
            Init proc -> ([],[proc],[])
            ReactEvent e -> ([],[],[e])

newThread :: Show a
          => Restart a
          -> IO (Effect (SafeT IO) ()) 
          -> M s r ()
newThread n t = tell [Thread $ onException' id (liftIO . [sP|failed because of: %?|]) . restart n <$> t]

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

-- asOutput :: [STM k] -> Output a
-- asOutput = Output . const . fmap (const True) . sequence_

conditional :: (a -> STM (Maybe b))
            -> Output b -> Output a
-- conditional f (Output out) = Output $ maybe (return True) (out._) <=< mapped f
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

-- catOutput' :: Output (Delimitor (Maybe a)) -> Output (Delimitor a)
-- catOutput' = contramapped.mapped %~ Just

makeChannel :: M s r (ChannelSet s a,Output' a)
makeChannel = do 
        n <- allocate _1
        v <- lift $ newTVarIO []
        let ch (Output' out) = modifyTVar v . (:) =<< out
            chSet = ChannelSet $ Map.singleton n $ Channel ch pure
            -- get = Output' $ bimap catOutput run . foldMap (second Cons) <$> readTVar v
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
          -- newThread n $ atomically $ liftA2 
          --         (\(out,relO) (upd,relU) -> finally 
          --                 ( s >-> toOutput (out <> upd) ) 
          --                 ( do
          --                   -- threadDelay 3000000
          --                   putStrLn "about to finalize"
          --                   atomically $ relO >> relU 
          --                   putStrLn "finalized"
          --                   ) )
          --             -- liftIO $ putStrLn "foo"
          --             -- liftIO $ atomically $ relO >> relU) 
                  -- getV 
                  -- getU
          return $ Event v u
        return $ unionsWith const es

infix ...

(...) :: (c -> d) -> (a -> b -> c) -> (a -> b -> d)
(...) = (.) . (.)

(....) :: (d -> e) -> (a -> b -> c -> d) -> (a -> b -> c -> e)
(....) = (.) . (.) . (.)

zipWith3 :: Monad m
         => (a -> b -> c -> d)
         -> Producer a m r
         -> Producer b m r
         -> Producer c m r
         -> Producer d m r
zipWith3 f = P.zipWith id ... P.zipWith f

zipWith4 :: Monad m
         => (a -> b -> c -> d -> e)
         -> Producer a m r
         -> Producer b m r
         -> Producer c m r
         -> Producer d m r
         -> Producer e m r
zipWith4 f = P.zipWith id .... zipWith3 f

    -- Idea: 
    --  put the Map as part of channels
    --  add SendId to events too?

runReactive' :: ReactPipe s r a -> M s r a
runReactive' (Pure x) = return x
-- runReactive' (Free (Return e f)) = do
--         runReactive' f
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
        runReactive' $ f (Behavior $ readTVar ref)
runReactive' (Free (AccumEvent x e f)) = do
        ref <- liftIO $ newTVarIO x
        reactimateSTM $ modifyTVar ref <$> e
        runReactive' $ f (Behavior (readTVar ref) <@ e)
runReactive' (Free (Reactimate e f)) = do
        tell [ReactEvent e]
        runReactive' f

-- activate :: Int -> Effect (SafeT IO) a -> IO (Activation a)
-- activate n eff = do
--         putStrLn "activate"
--         a <- async $ runSafeP eff
--         return $ Activation a n eff

-- waitCatchSTM' :: Activation a 
--               -> STM (Either (Either SomeException (Seed a)) a)
-- waitCatchSTM' (Activation a n eff) = waitCatchSTM a & mapped._Left %~ if n <= 0
--                             then Left
--                             else const $ Right $ Right $ activate (n - 1) eff

shuffleL :: Either a (Either b c) -> Either (Either a b) c
shuffleL = either (Left . Left) (either (Left . Right) Right)

shuffleR :: Either (Either a b) c -> Either a (Either b c)
shuffleR = either (either Left (Right . Left)) (Right . Right)

waitEither :: Async a 
           -> STM (Either (Async a) (Either SomeException a))
waitEither a = (Right <$> waitCatchSTM a) <|> return (Left a)

waitOne :: NonEmpty (Async a) -> STM ([Async a],NonEmpty (Either SomeException a))
waitOne = _2 (maybe retry return . nonEmpty) 
                . partitionEithers 
            <=< traverse waitEither . toList
-- waitOne = _2 (maybe retry _ . nonEmpty) . partitionEithers <=< traverse waitEither . toList

-- type Seed a = Either (Activation a) (IO (Activation a))

-- cancel' :: Activation a -> IO ()
-- cancel' (Activation a _ _) = cancel a

collectAll :: ([Async a] -> STM ())
           -> [Async a] 
           -> IO (Either (NonEmpty SomeException) [a])
collectAll _ [] = return $ Right []
collectAll reg (x:xs) = do
    (xs',rs) <- atomically $ do
        y <- waitOne $ x :| xs
        y & _1 (liftA2 (liftA2 const) return reg)
    let (es,rs') = partitionEithers $ toList rs
    case nonEmpty es of
        Just es' -> do
            forOf_ traverse xs' cancel
            return $ Left es'
        Nothing  -> fmap (rs' ++) <$> collectAll reg xs'

collectAll_ :: ([Async a] -> STM ())
            -> [Async a]
            -> IO (Either (NonEmpty SomeException) ())
collectAll_ _ [] = return $ Right ()
collectAll_ reg (x:xs) = do
    (xs',rs) <- atomically $ do
        y <- waitOne $ x :| xs
        y & _1 (liftA2 (liftA2 const) return reg)
    let (es,_rs) = partitionEithers $ toList rs
    case nonEmpty es of
        Just es' -> do
            forOf_ traverse xs' cancel
            return $ Left es'
        Nothing  -> collectAll_ reg xs'

newtype Machine r = Machine [Effect (SafeT IO) ()]

-- data Activation a = Activation (Async a) Int (Effect IO a)

compile :: (forall s. ReactPipe s r a) -> IO (a,Machine r)
compile pipe = do 
        (x,_,(ts,is,_react)) <- (_3 %~ splitHandles) <$> runRWST 
                (do (x,react) <- listens 
                            (view . partsOf $ traverse._ReactEvent) 
                            (runReactive' pipe)
                    runReactive' 
                        $ spawnSink 
                              (unionsWith (>>) react) 
                              (for cat lift)
                    return x ) 
                () 
                (SenderId 0,())
        mapM_ atomically is
        ts' <- sequence ts
        return (x,Machine ts')

runReactive :: (forall s. ReactPipe s r a) -> IO ()
runReactive prg = compile prg >>= fmap snd . _2 runMachine

runMachine :: Machine r -> IO ()
runMachine (Machine ts') = do
        -- hs  <- mapM (uncurry activate) ts'
        bracket (newTVarIO []) 
          (\r -> do
            hs  <- mapM (async.runEffect.runSafeP) ts'
            atomically $ writeTVar r hs
            collectAll_ (writeTVar r) hs >>= \case 
                Right () -> return ()
                Left (e :| _) -> throwM e)
          (mapM_ cancel <=< atomically . readTVar)

