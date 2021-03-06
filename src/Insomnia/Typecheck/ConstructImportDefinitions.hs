module Insomnia.Typecheck.ConstructImportDefinitions (constructImportDefinitions) where

import Data.Monoid (Monoid(..), (<>), Endo(..))

import qualified Unbound.Generics.LocallyNameless as U

import Insomnia.Common.Stochasticity
import Insomnia.Identifier (Path(..), lastOfPath)
import Insomnia.Expr (QVar(..), Expr(..))
import Insomnia.Types (TypeConstructor(..), Type(..), TypePath(..))
import Insomnia.TypeDefn (TypeAlias(..))
import Insomnia.ModuleType (TypeSigDecl(..))
import Insomnia.Module

import Insomnia.Typecheck.Env
import Insomnia.Typecheck.SelfSig

type Decls = Endo [Decl] 

singleDecl :: Decl -> Decls
singleDecl d = Endo (d:)

constructImportDefinitions :: SelfSig -> Stochasticity -> TC Decls
constructImportDefinitions (ValueSelfSig q ty rest) stoch = do
  d <- importValue q ty stoch
  ds <- constructImportDefinitions rest stoch
  return (d <> ds)
constructImportDefinitions (TypeSelfSig tp tsd rest) stoch = do
  d <- importType tp tsd
  ds <- constructImportDefinitions rest stoch
  return (d <> ds)
constructImportDefinitions (SubmoduleSelfSig p _ rest) stoch = do
  d <- importSubmodule p
  ds <- constructImportDefinitions rest stoch
  return (d <> ds)
constructImportDefinitions (GenerativeSelfSig p _ rest) stoch = do
  d <- importSubmodule p
  ds <- constructImportDefinitions rest stoch
  return (d <> ds)
constructImportDefinitions UnitSelfSig _ = return mempty

importSubmodule :: Path -> TC Decls
importSubmodule pSub = do
  let f = lastOfPath pSub
  return $ singleDecl $ SubmoduleDefn f (ModuleId pSub)

importValue :: QVar -> Type -> Stochasticity -> TC Decls
importValue q@(QVar _ f) ty stoch = do
  let
    -- sig f : T
    -- val f = p.f
    dSig = singleDecl $ ValueDecl f $ SigDecl DeterministicParam ty
    dVal = singleDecl
           $ ValueDecl f
           $ case stoch of
              DeterministicParam -> ParameterDecl (Q q)
              RandomVariable -> SampleDecl (Return (Q q))
  return (dSig <> dVal)

importType :: TypePath -> TypeSigDecl -> TC Decls
importType tp@(TypePath _ f) tsd = do
  -- TODO: for polymorphic types this doesn't kindcheck.
  let gcon = TCGlobal tp
      manifestAlias = ManifestTypeAlias (U.bind [] (TC gcon))
      -- if this is an alias for an abstract type or for another
      -- manifest alias, just alias it.  If this is an alias for a
      -- data type, make a datatype copy; if it's an alias for a
      -- datatype copy, propagate the copy.
      alias = case tsd of
        AbstractTypeSigDecl _k ->
          manifestAlias
        AliasTypeSigDecl (ManifestTypeAlias _rhs) ->
          manifestAlias
        AliasTypeSigDecl copy@(DataCopyTypeAlias {}) ->
          copy
        ManifestTypeSigDecl defn ->
          DataCopyTypeAlias tp defn
  return $ singleDecl $ TypeAliasDefn f alias
   
