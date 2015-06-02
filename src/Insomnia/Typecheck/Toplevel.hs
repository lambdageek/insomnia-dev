{-# LANGUAGE OverloadedStrings #-}
module Insomnia.Typecheck.Toplevel (checkToplevel) where

import Data.Monoid (Monoid(..), (<>), Endo(..))

import qualified Unbound.Generics.LocallyNameless as U

import Insomnia.Identifier
import Insomnia.ModuleType (ToplevelSummary(..))
import Insomnia.Toplevel

import Insomnia.Typecheck.Env
import Insomnia.Typecheck.ModuleType (checkModuleType)
import Insomnia.Typecheck.ExtendModuleCtx (extendModuleCtxNF, extendToplevelDeclCtx)
import Insomnia.Typecheck.Module (inferModuleExpr)
import Insomnia.Typecheck.Query (checkQueryExpr)

checkToplevel :: Toplevel -> TC (Toplevel, ToplevelSummary)
checkToplevel (Toplevel items_) = do
  (items', summary) <- go items_ return
  return (Toplevel items', appEndo summary UnitTS )
  where
    go [] kont = kont (mempty, mempty)
    go (item:items) kont =
      checkToplevelItem item $ \item' f ->
      go items $ \(items', sum') ->
      kont (item':items', f <> sum')

checkToplevelItem :: ToplevelItem -> (ToplevelItem -> Endo ToplevelSummary -> TC a) -> TC a
checkToplevelItem item kont =
  case item of
    ToplevelModule moduleIdent me ->
      let pmod = IdP moduleIdent
      in (inferModuleExpr pmod me
          .??@ ("while infering the module type of " <> formatErr pmod))
         $ \me' sigNF ->
            (extendModuleCtxNF pmod sigNF
             .??@ ("while extending the context with module type of " <> formatErr pmod))
            $ let updSum = ModuleTS (U.name2String moduleIdent) . U.bind (moduleIdent, U.embed sigNF)
              in kont (ToplevelModule moduleIdent me') (Endo updSum)
    ToplevelModuleType modTypeIdent modType -> do
      (modType', sigV) <- checkModuleType modType
                          <??@ ("while checking module type "
                                <> formatErr modTypeIdent)
      extendModuleTypeCtx modTypeIdent sigV
        $ let updSum = SignatureTS (U.name2String modTypeIdent) . U.bind (modTypeIdent, U.embed sigV)
          in kont (ToplevelModuleType modTypeIdent modType') (Endo updSum)
    ToplevelImported fp tr tl -> do
      (tl', tsum) <- checkToplevel tl
                     <??@ ("while importing the toplevel from " <> formatErr fp
                           <> " as " <> formatErr tr)
      extendToplevelDeclCtx tr tsum $ extendToplevelSummaryCtx tr tsum $ kont (ToplevelImported fp tr tl') mempty
    ToplevelQuery qe -> do
      qe' <- checkQueryExpr qe
      kont (ToplevelQuery qe') mempty
  
