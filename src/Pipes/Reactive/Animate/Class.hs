module Pipes.Reactive.Animate.Class where

import Pipes.Reactive.Class
import Pipes.Reactive.Event

class MonadReact s r m => Reactimate s r m | m -> s where
    reactimate :: Event s (IO ()) -> m ()
