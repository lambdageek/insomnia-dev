{-# LANGUAGE
      MultiParamTypeClasses,
      FlexibleInstances, FlexibleContexts,
      DeriveDataTypeable, DeriveGeneric
  #-}
module Insomnia.Types where

import Control.Applicative
import Control.Lens

import qualified Data.Map as M
import Data.Typeable(Typeable)

import Data.Format (Format(..))
import GHC.Generics (Generic)

import Unbound.Generics.LocallyNameless
import qualified Unbound.Generics.LocallyNameless.Unsafe as UU

import Insomnia.Unify (UVar, Unifiable(..),
                    HasUVars(..),
                    Partial(..),
                    MonadUnify(..),
                    MonadUnificationExcept(..),
                    UnificationFailure(..))

-- At the term level, value constructor names.
-- At the type level, type constructor names.
newtype Con = Con { unCon :: String }
              deriving (Show, Eq, Ord, Typeable, Generic)
                       

type TyVar = Name Type
type KindedTVar = (TyVar, Kind)

type Nat = Integer

data Rows = Rows -- TODO


data Kind = KType -- ^ the kind of types
--          | KROW -- ^ the kind ROW of rows. users can't write it directly
          | KArr !Kind !Kind
            deriving (Show, Typeable, Generic)
infixr 6 `KArr`

data Type = TV TyVar
          | TUVar (UVar Type) -- invariant: unification variables should be fully applied
          | TC !Con
          | TAnn Type !Kind
          | TApp Type Type
          | TForall (Bind (TyVar, Kind) Type)
            deriving (Show, Typeable, Generic)

infixl 6 `TApp`

-- Formatted output
instance Format Con
instance Format Kind
instance Format Type

-- Alpha equivalence

instance Alpha Con
instance Alpha Type
instance Alpha Kind

-- Substitution

-- Capture avoiding substitution of type variables in types and terms.
instance Subst Type Type where
  isvar (TV v) = Just (SubstName v)
  isvar _ = Nothing

instance Subst Type Kind where
  subst _ _ = id
  substs _ = id
instance Subst Type Con where
  subst _ _ = id
  substs _ = id
-- unification variables are opaque boxes that can't be substituted into.
instance Subst Type (UVar a) where
  subst _ _ = id
  substs _ = id



-- Unification

instance Partial Type where
  _UVar = let
    pick (TUVar u) = Just u
    pick _ = Nothing
    in prism' TUVar pick

instance HasUVars Type Type where
  allUVars f t =
    case t of
      TV {} -> pure t
      TUVar {} -> f t
      TC {} -> pure t
      TAnn t1 k -> TAnn <$> allUVars f t1 <*> pure k
      TApp t1 t2 -> TApp <$> allUVars f t1 <*> allUVars f t2
      TForall bnd -> let
        (vk, t1) = UU.unsafeUnbind bnd
        in (TForall . bind vk) <$> allUVars f t1

-- | Make a fresh unification variable
freshUVarT :: MonadUnify e Type m => m Type
freshUVarT = TUVar <$> unconstrained

-- | Construct a fresh type expression composed of a unification var
-- of the given kind applied to sufficiently many ground arguments
-- such that the whole type expression has of kind ⋆.
--
-- @      
--   ⌞⋆⌟ = u   - u fresh
--   ⌞k1 → ⋯ → kN → ⋆⌟ = apply u (map ⌞·⌟ ks)  - u fresh
-- @
--  for example: @⌞a -> (b -> ⋆)⌟ = (u·⌞a⌟)·⌞b⌟@
groundUnificationVar :: MonadUnify TypeUnificationError Type m => Kind -> m Type
groundUnificationVar = \ k -> do
  tu <- freshUVarT
  go k tu
  where
    go KType thead = return thead
    go (KArr kdom kcod) thead = do
      targ <- groundUnificationVar kdom
      go kcod (thead `TApp` targ)

data TypeUnificationError =
  SimplificationFail (M.Map (UVar Type) Type) !Type !Type -- the two given types could not be simplified under the given constraints

instance (MonadUnify TypeUnificationError Type m,
          MonadUnificationExcept TypeUnificationError Type m,
          LFresh m)
         => Unifiable Type TypeUnificationError m Type where
  t1 =?= t2 =
    case (t1, t2) of
      (TForall bnd1, TForall bnd2) ->
        lunbind2 bnd1 bnd2 $ \opn -> 
        case opn of
          Just ((_, _), t1', (_, _), t2') ->
            t1' =?= t2'
          Nothing -> do
            constraintMap <- reflectCollectedConstraints
            throwUnificationFailure
              $ Unsimplifiable (SimplificationFail constraintMap t1 t2)
      (TForall bnd1, _) ->
        lunbind bnd1 $ \ ((v1, _), t1_) -> do
          tu1 <- freshUVarT
          let t1' = subst v1 tu1 t1_
          t1' =?= t2
      (_, TForall {}) -> t2 =?= t1
      (TUVar u1, TUVar u2) | u1 == u2 -> return ()
      (TUVar u1, _)                   -> u1 -?= t2
      (_, TUVar u2)                   -> u2 -?= t1
      (TAnn t1' _, TAnn t2' _)        -> t1' =?= t2'
      (TAnn t1' _, _)                 -> t1' =?= t2
      (_, TAnn t2' _)                 -> t1 =?= t2'
      (TV v1, TV v2) | v1 == v2       -> return ()
      (TC c1, TC c2) | c1 == c2       -> return ()
      (TApp t11 t12, TApp t21 t22) -> do
        t11 =?= t21
        t12 =?= t22
      _ -> do
        constraintMap <- reflectCollectedConstraints
        throwUnificationFailure
           $ Unsimplifiable (SimplificationFail constraintMap t1 t2)

-- | note that this 'Traversal'' does NOT guarantee freshness of
-- names. The passed in applicative functor should ensure freshness.
instance Plated Type where
  plate _ (t@TUVar {}) = pure t
  plate _ (t@TV {}) = pure t
  plate _ (t@TC {}) = pure t
  plate f (TAnn t k) = TAnn <$> f t <*> pure k
  plate f (TApp t1 t2) = TApp <$> f t1 <*> f t2
  plate f (TForall bnd) =
    let (vk, t) = UU.unsafeUnbind bnd
    in (TForall . bind vk) <$> f t

-- | Traverse the types in the given container
class TraverseTypes s t where
  traverseTypes :: Traversal s t Type Type

instance TraverseTypes Type Type where
  traverseTypes = plate

transformEveryTypeM :: (TraverseTypes a a, Plated a, Monad m) => (Type -> m Type) -> a -> m a
transformEveryTypeM f = transformM (transformMOn traverseTypes f)
