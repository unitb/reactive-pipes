{-# LANGUAGE LambdaCase,QuasiQuotes #-}
module Pipes.Reactive.Async where

import Control.Applicative
import Control.Concurrent.Async hiding (waitEither)
import Control.Concurrent.STM
import Control.Exception
import Control.Lens hiding ((...))
import Control.Monad

import Data.Either
import Data.List.NonEmpty hiding (length)

import           Pipes
import qualified Pipes.Prelude as P

import           Prelude hiding (zipWith,zipWith3)

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

collectAll :: STM r
           -> ([Async a] -> STM ())
           -> [Async a] 
           -> IO (Either (NonEmpty SomeException) (r,[a]))
collectAll _ _ [] = fail "thread pool terminated without result"
collectAll out reg (x:xs) = do
    atomically (do
            y <- (Left <$> out) <|> (Right <$> waitOne (x :| xs))
            y & (_Right._1) (liftA2 (liftA2 const) return reg) )
                >>= \case
        Right (xs',rs) -> do
            let (es,rs') = partitionEithers $ toList rs
            case nonEmpty es of
                Just es' -> do
                    forOf_ traverse xs' cancel
                    return $ Left es'
                Nothing  -> (mapped._2 %~ (rs' ++)) <$> collectAll out reg xs'
        Left r -> do
            forOf_ traverse (x:xs) cancel
            return $ Right (r,[])

data TerminationWithoutResult = TerminationWithoutResult
    deriving (Show)

instance Exception TerminationWithoutResult where
    displayException _ = "thread pool terminated without result"

class AsNoResultException t where
    _TerminationWithoutResult :: Prism' t TerminationWithoutResult
instance AsNoResultException SomeException where
    _TerminationWithoutResult = prism' toException fromException
instance AsNoResultException TerminationWithoutResult where
    _TerminationWithoutResult = id

collectAll_ :: STM r
            -> ([Async a] -> STM ())
            -> [Async a] 
            -> IO (Either (NonEmpty SomeException) r)
collectAll_ _ _ [] = throw TerminationWithoutResult
collectAll_ out reg (x:xs) = do
    atomically (
            (Left <$> out) <|> 
            (fmap Right $ waitOne (x :| xs) 
                >>= _1 (\xs' -> reg xs' >> return xs')) )
        >>= \case
            Right (xs',rs) -> do
                let es = lefts $ toList rs
                case nonEmpty es of
                    Just es' -> do
                        forOf_ traverse xs' cancel
                        return $ Left es'
                    Nothing  -> collectAll_ out reg xs'
            Left r -> do
                mapMOf_ traverse cancel (x:xs) 
                return $ Right r

waitEither :: Async a 
           -> STM (Either (Async a) (Either SomeException a))
waitEither a = (Right <$> waitCatchSTM a) <|> return (Left a)

waitOne :: NonEmpty (Async a) -> STM ([Async a],NonEmpty (Either SomeException a))
waitOne = _2 (maybe retry return . nonEmpty) 
                . partitionEithers 
            <=< traverse waitEither . toList
