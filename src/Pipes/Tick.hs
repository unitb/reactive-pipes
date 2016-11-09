module Pipes.Tick where

import Control.Concurrent.STM
import Control.Monad
import Data.Time
import Pipes

tick :: MonadIO m 
     => Int 
     -> Producer UTCTime m r
tick n = do
        r <- liftIO $ registerDelay n
        yield =<< liftIO getCurrentTime 
        liftIO $ atomically $ guard =<< readTVar r
        tick n

