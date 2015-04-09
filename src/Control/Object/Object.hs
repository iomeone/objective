{-# LANGUAGE Rank2Types, CPP, TypeOperators, DataKinds, TupleSections, BangPatterns #-}
#if __GLASGOW_HASKELL__ >= 707
{-# LANGUAGE DeriveDataTypeable #-}
#endif
module Control.Object.Object where
import Data.Typeable
import Control.Monad.Trans.State.Strict
import Control.Monad.Free
import Control.Monad
import Control.Monad.Skeleton
import Data.Traversable as T
import Control.Monad.Trans.Writer.Strict
import Data.Monoid
import Data.Tuple (swap)

-- | The type @Object f g@ represents objects which can handle messages @f@, perform actions in the environment @g@.
-- It can be thought of as an automaton that converts effects.
-- 'Object's can be composed just like functions using '@>>@'; the identity element is 'echo'.
-- Objects are morphisms of the category of actions.
--
-- [/Naturality/]
--     @runObject obj . fmap f ≡ fmap f . runObject obj@
--
newtype Object f g = Object { runObject :: forall x. f x -> g (x, Object f g) }
#if __GLASGOW_HASKELL__ >= 707
  deriving (Typeable)
#else
instance (Typeable1 f, Typeable1 g) => Typeable (Object f g) where
  typeOf t = mkTyConApp objectTyCon [typeOf1 (f t), typeOf1 (g t)] where
    f :: Object f g -> f a
    f = undefined
    g :: Object f g -> g a
    g = undefined

objectTyCon :: TyCon
#if __GLASGOW_HASKELL__ < 704
objectTyCon = mkTyCon "Control.Object.Object"
#else
objectTyCon = mkTyCon3 "objective" "Control.Object" "Object"
#endif
{-# NOINLINE objectTyCon #-}
#endif
-- | An alias for 'runObject'
(@-) :: Object f g -> f x -> g (x, Object f g)
(@-) = runObject
{-# INLINE (@-) #-}
infixr 3 @-

infixr 1 ^>>@
infixr 1 @>>^

class HProfunctor k where
  (^>>@) :: Functor h => (forall x. f x -> g x) -> k g h -> k f h
  (@>>^) :: Functor h => k f g -> (forall x. g x -> h x) -> k f h

instance HProfunctor Object where
  m0 @>>^ g = go m0 where go (Object m) = Object $ fmap (fmap go) . g . m
  {-# INLINE (@>>^) #-}
  f ^>>@ m0 = go m0 where go (Object m) = Object $ fmap (fmap go) . m . f
  {-# INLINE (^>>@) #-}

-- | The trivial object
echo :: Functor f => Object f f
echo = Object $ fmap (,echo)

-- | Lift a natural transformation into an object.
liftO :: Functor g => (forall x. f x -> g x) -> Object f g
liftO f = go where go = Object $ fmap (\x -> (x, go)) . f
{-# INLINE liftO #-}

-- | Categorical object composition
(@>>@) :: Functor h => Object f g -> Object g h -> Object f h
Object m @>>@ Object n = Object $ fmap (\((x, m'), n') -> (x, m' @>>@ n')) . n . m
infixr 1 @>>@

-- | Reversed '(@>>@)'
(@<<@) :: Functor h => Object g h -> Object f g -> Object f h
(@<<@) = flip (@>>@)
{-# INLINE (@<<@) #-}
infixl 1 @<<@

-- | The unwrapped analog of 'stateful'
--     @unfoldO runObject = id@
--     @unfoldO iterObject = iterable@
unfoldO :: Functor g => (forall a. r -> f a -> g (a, r)) -> r -> Object f g
unfoldO h = go where go r = Object $ fmap (fmap go) . h r
{-# INLINE unfoldO #-}

-- | Same as 'unfoldO' but requires 'Monad' instead
unfoldOM :: Monad m => (forall a. r -> f a -> m (a, r)) -> r -> Object f m
unfoldOM h = go where go r = Object $ liftM (fmap go) . h r
{-# INLINE unfoldOM #-}

-- | Build a stateful object.
--
-- @stateful t s = t ^>>\@ variable s@
--
stateful :: Monad m => (forall a. t a -> StateT s m a) -> s -> Object t m
stateful h = go where
  go s = Object $ \f -> runStateT (h f) s >>= \(a, s') -> s' `seq` return (a, go s')
{-# INLINE stateful #-}

-- | Flipped 'stateful'
-- it is convenient to use with the LambdaCase extension.
(@~) :: Monad m => s -> (forall a. t a -> StateT s m a) -> Object t m
s @~ h = stateful h s
{-# INLINE (@~) #-}
infix 1 @~

-- | Cascading
iterObject :: Monad m => Object f m -> Free f a -> m (a, Object f m)
iterObject obj (Pure a) = return (a, obj)
iterObject obj (Free f) = runObject obj f >>= \(cont, obj') -> iterObject obj' cont

-- | Objects can consume free monads
iterative :: (Monad m) => Object f m -> Object (Free f) m
iterative = unfoldOM iterObject
{-# INLINE iterative #-}

-- | A mutable variable.
variable :: Monad m => s -> Object (StateT s m) m
variable = stateful id
{-# INLINE variable #-}

-- | Cascading
cascadeObject :: Monad m => Object t m -> Skeleton t a -> m (a, Object t m)
cascadeObject obj sk = case unbone sk of
  Return a -> return (a, obj)
  t :>>= k -> runObject obj t >>= \(a, obj') -> cascadeObject obj' (k a)

cascade :: (Monad m) => Object t m -> Object (Skeleton t) m
cascade = unfoldOM cascadeObject
{-# INLINE cascade #-}

-- | Send a message to objects in a container.
announcesOf :: (Monad m, Monoid r) => ((Object t m -> WriterT r m (Object t m)) -> s -> WriterT r m s)
  -> t a -> (a -> r) -> StateT s m r
announcesOf t f c = StateT $ liftM swap . runWriterT
  . t (\obj -> WriterT $ runObject obj f >>= \(x, obj') -> return (obj', c x))
{-# INLINABLE announcesOf #-}

-- | Send a message to objects in a container.
announce :: (T.Traversable t, Monad m) => f a -> StateT (t (Object f m)) m [a]
announce f = withBuilderM (announcesOf T.mapM f)
{-# INLINABLE announce #-}

withBuilder :: Functor f => ((a -> Endo [a]) -> f (Endo [a])) -> f [a]
withBuilder f = fmap (flip appEndo []) (f (Endo . (:)))
{-# INLINABLE withBuilder #-}

withBuilderM :: Monad f => ((a -> Endo [a]) -> f (Endo [a])) -> f [a]
withBuilderM f = liftM (flip appEndo []) (f (Endo . (:)))
{-# INLINABLE withBuilderM #-}
