{-# LANGUAGE RecursiveDo #-}
module Pipes.Reactive.Seq where

import Control.Lens hiding ((<|))
import Control.Monad.Fix
import Control.Monad.RWS

import           Data.List as L
import           Data.Map (Map)
import qualified Data.Map as M
import           Data.Maybe
import           Data.Vault.Lazy

import           Pipes
import           Pipes.Reactive

type Server t t' out res s r = ServerT t t' out res s r (ReactPipe s r)

newtype ServerT t t' out res s r m a = ServerT { unServerT :: RWST 
        (Event s Locker,Event s out)
        [( t res
         , Event s (t' Locker))] 
        () m a }
    deriving (Functor,Applicative,Monad,MonadIO,MonadFix,MonadTrans)

class MonadReact s r m => MonadServer s r m | m -> s r where

instance MonadReact s r m => MonadReact s r (ServerT t t' out res s r m) where


eventTable :: [Event s a] -> Event s (Map Int a)
eventTable = fmap M.fromList 
        . unionsWith (++) 
        . zipWith (fmap . fmap pure . (,)) [0 :: Int ..]

runServerT :: (MonadReact s r m,IORunnable t)
           => Int
           -> t ()
           -> t (Maybe i)
           -> (forall k. res -> t' k -> t k)
           -> t ()
           -> ServerT t t' i res s r m a 
           -> m a
runServerT t initAll poll h refresh (ServerT cmd) = mdo
        (x,(),rs) <- runRWST cmd (splitEvent e) ()
        let w = eventTable $ L.map snd rs
            initM = M.fromList . zip [0..] $ L.map fst rs
        e <- spawnPipeWith 
                    (Bounded t <| return ())
                    w $ do
                lift initAll
                r <- lift $ sequence initM
                forever $ do 
                    y <- await
                    (mapM_.mapM_) (yield . Left) <=< lift . sequence
                        $ sequence . M.intersectionWith h r <$> y
                    unless (isNothing y) $ lift refresh
                    mapM_ (yield . Right) =<< lift poll
        return x

output :: Monad m => ServerT t t' i res s r m (Event s i)
output = ServerT $ asks snd

handler :: (MonadIO m,Functor t')
        => t res 
        -> Event s (t' a)
        -> ServerT t t' i res s r m (Event s a)
handler alloc e0 = ServerT $ do
        k <- liftIO newKey
        e1 <- asks fst 
        tell [(alloc,fmap (lock k) <$> e0)]
        return $ filterPrism (folding $ unlock k) e1

