module Pipes.FileWatcher where

import Control.Monad
import Data.Time

import           Pipes
import           Pipes.Safe
import           Pipes.Tick

import System.Directory
import System.IO

-- | Like getModificationTime but handles the case where 
-- the file does not exist.
getModificationTime' :: FilePath -> IO (Maybe UTCTime)
getModificationTime' fp = do
    exists <- doesFileExist fp
    if exists then Just <$> getModificationTime fp
              else return Nothing

-- | `fileChanges n fp` pools the file system every `n` microseconds
-- and produces a stream of modification times (when the file exists)
-- or Nothing (when the file does not exist)
fileChanges :: MonadIO m
            => Int 
            -> FilePath 
            -> Producer (Maybe UTCTime) m r 
fileChanges n fp = onTick n $ liftIO (getModificationTime' fp) >>= loop
    where
        loop t = do
                t' <- liftIO $ getModificationTime' fp
                when (t' /= t) $ yield t'
                loop t'

onFileChange :: (MonadIO m,MonadSafe m)
             => Int                         -- ^ Polling period
             -> FilePath                    -- ^ File name
             -> Producer a m ()             -- ^ What to do when the file is deleted
             -> (Handle -> Producer a m ()) -- ^ How to use the file
             -> Producer a m r
onFileChange n fp del h = for (fileChanges n fp) $ 
        maybe
        del
        (const $ withFile' fp ReadMode h)

withFile' :: MonadSafe m
          => FilePath 
          -> IOMode 
          -> (Handle -> m a) 
          -> m a
withFile' fp m = bracket 
            (liftIO $ openFile fp m) 
            (liftIO . hClose) 

-- | 
monitorFile :: (MonadIO m,MonadSafe m)
            => Int 
            -> FilePath 
            -> Producer a m ()
            -> (Handle -> Producer a m ())
            -> Producer a m r
monitorFile n fp del h = 
            liftIO (getModificationTime' fp)
                >>= maybe
                        del
                        (const $ withFile' fp ReadMode h)
            >> onFileChange n fp del h
