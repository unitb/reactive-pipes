{-# LANGUAGE  ExistentialQuantification
            , DataKinds
            , KindSignatures #-}
module Pipes.Reactive.Category where

import Control.Category
import Control.Monad

import Data.Profunctor

import           Prelude hiding (id,(.))

import           Pipes
import qualified Pipes.Prelude as P
import           Pipes.Reactive

data CPipe s r a b = 
    CPipe (Pipe a b IO ())
    | forall a' b'. React 
        (Pipe a a' IO ()) 
        (Event s a' -> ReactPipe s r (Event s b'))
        (Pipe b' b IO ())
          -- -> CPipe s r (a0,a) (b0,b)

arr :: (Profunctor arr,Category arr) 
    => (a -> b) -> arr a b
arr f = rmap f id
        -- rmap f id = lmap f id
        -- x.lmap f y = rmap f x.y

instance Functor (CPipe s r a) where
    fmap = rmap

instance Profunctor (CPipe s r) where
    dimap f g x = CPipe (P.map f) >>> x >>> CPipe (P.map g)
        -- lmap f = dimap f id
        -- rmap f = dimap id f
        -- dimap id id = id
        -- dimap (f0.f1) (g0.g1) = dimap f0 g1.dimap f1 g0

instance Category (CPipe s r) where
    id = CPipe cat
    CPipe x . CPipe y = CPipe $ x <-< y
    CPipe x . React y p z = React y p (z >-> x)
    React x p y . CPipe z = React (z >-> x) p y
    React x p y . React z q w = React z (q >=> flip spawnPipe (w >-> x) >=> p) y

