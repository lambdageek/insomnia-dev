-- | Encoding of the Insomnia module calculus in System FΩ ala "F-ing
-- Modules".
--
-- We proceed in two steps: we translate module types into "semantic
-- signatures" which we then embed in FΩ.  Modules turn out to be
-- terms of the embedded types corresponding to their signatures.  The
-- key "trick" is that generativity is modeled by packing existential
-- types, and dependency (of later module components on prior ones) is
-- modeled by hoisting the scope of the existentials to enclose the
-- definition and the subsequent dependencies.
--
-- In this encoding, models end up encoding as something like "Dist
-- (∃α. τ)" where Dist is the probability distribution monad and τ is
-- the encoding of the underlying structure.  (One could also imagine
-- "∃α. Dist τ" which would correspond to all samples from a
-- distribution sharing the identity of their abstract types.  That is
-- not what we do in Insomnia, however.)
{-# LANGUAGE ViewPatterns, TemplateHaskell,
      FlexibleContexts, FlexibleInstances, TypeSynonymInstances
  #-}
module Insomnia.ToF where

import Control.Lens
import Control.Monad.Reader
import Control.Monad.Except (ExceptT, runExceptT)
import qualified Data.List as List
import Data.Monoid (Monoid(..), (<>), Endo(..))
import Data.Typeable (Typeable)
import qualified Data.Map as M

import Unbound.Generics.LocallyNameless (LFresh, Embed)
import qualified Unbound.Generics.LocallyNameless as U

import qualified FOmega.Syntax as F
import qualified FOmega.SemanticSig as F
import qualified FOmega.MatchSigs as F
import qualified FOmega.SubSig as F

import Insomnia.Common.ModuleKind
import Insomnia.Common.Telescope
import Insomnia.Identifier
import Insomnia.Types
import Insomnia.TypeDefn
import Insomnia.ModuleType
import Insomnia.Module
import Insomnia.Expr
  
data Env = Env { _tyConEnv :: M.Map TyConName F.SemanticSig
               , _sigEnv   :: M.Map SigIdentifier F.AbstractSig
               , _modEnv   :: M.Map Identifier (F.SemanticSig, F.Var)
               , _tyVarEnv :: M.Map TyVar (F.TyVar, F.Kind)
               , _valEnv    :: M.Map Var (F.Var, F.Type)
               }

$(makeLenses ''Env)

emptyToFEnv :: Env
emptyToFEnv = Env initialTyConEnv mempty mempty mempty mempty

initialTyConEnv :: M.Map TyConName F.SemanticSig
initialTyConEnv = M.fromList [(U.s2n "->",
                               F.TypeSem arrowLam ([F.KType, F.KType] `F.kArrs` F.KType))
                             , (U.s2n "Real", F.TypeSem (F.TV $ U.s2n "Real") F.KType)
                             , (U.s2n "Int", F.TypeSem (F.TV $ U.s2n "Int") F.KType) 
                             ]
  where
    arrowLam = F.TLam $ U.bind (alpha, U.embed F.KType) $
               F.TLam $ U.bind (beta, U.embed F.KType) $
               F.TArr (F.TV alpha) (F.TV beta)
    alpha = U.s2n "α"
    beta = U.s2n "β"

class (Functor m, LFresh m, MonadReader Env m, MonadPlus m) => ToF m

type ToFM = ExceptT String (ReaderT Env U.LFreshM)

instance ToF ToFM

runToFM :: ToFM a -> a
runToFM m =
  case U.runLFreshM (runReaderT (runExceptT m) emptyToFEnv) of
   Left s -> error $ "unexpected failure in ToF.runToFM: " ++ s
   Right a -> a

---------------------------------------- Module Types


moduleType :: ToF m => ModuleType -> m F.AbstractSig
moduleType modTy_ =
  case modTy_ of
   SigMT (SigV s ModuleMK) ->
     signature s
   SigMT (SigV s ModelMK) ->
     model s
   IdentMT sigId -> do
     ma <- view $ sigEnv . at sigId
     case ma of
      Nothing -> fail "unexpected ToF.moduleTyp' sig lookup returned Nothing"
      Just absSig -> return absSig
   WhereMT modTy whereClause -> do
     abstr <- moduleType modTy
     patchWhereClause abstr whereClause
   FunMT bnd -> do
     functor bnd

-- ∃ αs:κs . fs:Σs
type SigSummary = ([(F.TyVar, Embed F.Kind)], [(F.Field, F.SemanticSig)])

functor :: ToF m
           => (U.Bind (Telescope (FunctorArgument ModuleType)) ModuleType)
           -> m F.AbstractSig
functor bnd =
  U.lunbind bnd $ \(teleArgs, body) ->
  withFunctorArguments teleArgs $ \(abstr, sigArgs) -> do
    abstrSigBody <- moduleType body
    let
      fctr = F.SemanticFunctor (map snd sigArgs) abstrSigBody
      s =  F.FunctorSem $ U.bind abstr fctr
    return $ F.AbstractSig $ U.bind [] s

withFunctorArguments :: ToF m =>
                        Telescope (FunctorArgument ModuleType)
                        -> (([(F.TyVar, Embed F.Kind)],
                             [(F.Var, F.SemanticSig)])
                            -> m r)
                        -> m r
withFunctorArguments tele kont =
  case tele of
   NilT -> kont mempty
   ConsT (U.unrebind -> (arg, teleArgs)) ->
     withFunctorArgument arg $ \(abstArg, argSem) ->
     withFunctorArguments teleArgs $ \(abstArgs, argsSem) ->
     kont (abstArg <> abstArgs, argSem:argsSem)

withFunctorArgument :: ToF m
                       => FunctorArgument ModuleType
                       -> (([(F.TyVar, Embed F.Kind)],
                            (F.Var, F.SemanticSig))
                           -> m r)
                       -> m r
withFunctorArgument (FunctorArgument argId _modK (U.unembed -> modTy)) kont =
  withFreshName (U.name2String argId) $ \modVar -> do
    (F.AbstractSig bnd) <- moduleType modTy
    U.lunbind bnd $ \(abstrs, modSig) ->
      local (modEnv %~ M.insert argId (modSig, modVar))
      $ kont (abstrs, (modVar, modSig))
  

patchWhereClause :: ToF m => F.AbstractSig -> WhereClause -> m F.AbstractSig
patchWhereClause (F.AbstractSig bnd) (WhereTypeCls path rhsTy) = do
  (rhsTy', _k) <- type' rhsTy
  U.lunbind bnd $ \(abstr, modSem) -> do
    tSem <- followTypePath modSem path
    case tSem of
     (F.TypeSem (F.TV a) _k') -> do
       abstrRest <- dropVarFromAbstrList abstr a
       let modSem' = U.subst a rhsTy' modSem'
       return $ F.AbstractSig $ U.bind abstrRest modSem'
     _ -> fail ("patchWhereClause: expected where clause to pick out "
                ++ " a type variable in the semantic sig")

dropVarFromAbstrList :: (U.Alpha a, Monad m) => [(a, b)] -> a -> m [(a, b)]
dropVarFromAbstrList vs v =
  case List.partition (\(v',_) -> U.aeq v v') vs of
   ([_], rest) -> return rest
   _ -> fail "dropVarFromAbstrList expected exactly one type variable to match"

followTypePath :: ToF m => F.SemanticSig -> (U.Bind Identifier TypePath) -> m F.SemanticSig
followTypePath mod0 bnd =
  U.lunbind bnd $ \(dkId, TypePath modsPath typeField) ->
  withFreshName (U.name2String dkId) $ \x ->
    liftM fst $ followUserPathAnything (const $ return (mod0, F.V x)) (ProjP modsPath typeField)

followUserPathAnything :: Monad m =>
                          (Identifier -> m (F.SemanticSig, F.Term))
                          -> Path -> m (F.SemanticSig, F.Term)
followUserPathAnything rootLookup (IdP ident) = rootLookup ident
followUserPathAnything rootLookup (ProjP path f) = do
  (mod1, m) <- followUserPathAnything rootLookup path
  case mod1 of
   (F.ModSem flds) -> do
     let p (F.FUser f', _) | f == f' = True
         p _ = False
     case List.find p flds of
      Just (_, mod2) -> return (mod2, F.Proj m (F.FUser f))
      Nothing -> fail "unexpectd failure in followUserPathAnything: field not found"
   _ -> fail "unexpected failure in followUserPathAnything: not a module record"
  
mkAbstractModuleSig :: SigSummary
                       -> F.AbstractSig
mkAbstractModuleSig (tvks, sig) =
  F.AbstractSig $ U.bind tvks $ F.ModSem sig

signature :: ToF m => Signature -> m F.AbstractSig
signature = liftM mkAbstractModuleSig . signature'

model :: ToF m => Signature -> m F.AbstractSig
model sig = do
  abstr <- signature sig
  let s = F.ModelSem abstr
  return $ F.AbstractSig $ U.bind [] s

signature' :: ToF m => Signature -> m SigSummary
signature' UnitSig = return mempty
signature' (ValueSig f t rest) = do
  (t', _) <- type' t
  let s = ([], [(F.FUser f, F.ValSem t')])
  rest' <- signature' rest
  return $ s <> rest'
signature' (TypeSig f bnd) =
  U.lunbind bnd $ \((con, U.unembed -> tsd), rest) ->
  typeSigDecl f tsd $ \sig -> local (tyConEnv %~ M.insert con sig) (signature' rest)
signature' (SubmoduleSig f bnd) =
  withFreshName f $ \x -> 
  U.lunbind bnd $ \((subModId, U.unembed -> modTy), rest) ->
  submodule f modTy $ \subSig -> local (modEnv %~ M.insert subModId (subSig, x)) (signature' rest)

submodule :: ToF m => Field -> ModuleType -> (F.SemanticSig -> m SigSummary) -> m SigSummary
submodule f modTy kont = do
  (F.AbstractSig bnd) <- moduleType modTy
  U.lunbind bnd $ \(abstr, sig) -> do
    let s = (abstr, [(F.FUser f, sig)])
    rest' <- kont sig
    return $ s <> rest'

typeSigDecl :: ToF m
               => Field
               -> TypeSigDecl
               -> (F.SemanticSig -> m SigSummary)
               -> m SigSummary
typeSigDecl f tsd kont = do           
  case tsd of
   AliasTypeSigDecl alias -> do
     sig <- typeAlias alias
     rest' <- kont sig
     let
       s = ([], [(F.FUser f, sig)])
     return $ s <> rest'
   AbstractTypeSigDecl k ->
     withFreshName f $ \tv -> do
       k' <- kind k
       let sig = F.TypeSem (F.TV tv) k'
       rest' <- kont sig
       let
         s = ([(tv, U.embed k')], [(F.FUser f, sig)])
       return $ s <> rest'
   ManifestTypeSigDecl td -> do
     (abstr, sig) <- typeDefn td
     rest' <- kont sig
     let
       s = (abstr, [(F.FUser f, sig)])
     return $ s <> rest'

typeDefn :: ToF m =>  TypeDefn -> m ([(F.TyVar, Embed F.Kind)], F.SemanticSig)
typeDefn td_ =
  case td_ of
   EnumDefn _n -> fail "unimplemented ToF.typeDefn EnumDefn"
   DataDefn bnd ->
     U.lunbind bnd $ \(tvks, constrs) ->
     withTyVars tvks $ \tvks' ->
     withFreshName "<datatype>" $ \tv -> do
       let kdoms = map snd tvks'
           k = kdoms `F.kArrs` F.KType
           abstr = [(tv, U.embed k)]
           -- fully apply data type abstract var to parameter vars
           tCod = (F.TV tv) `F.tApps` map (F.TV . fst) tvks'
       constrSigs <- mapM (mkConstr tvks' tCod) constrs
       let sig = F.ModSem ([(F.FData, F.TypeSem (F.TV tv) k)]
                           ++ constrSigs)
       return (abstr, sig)
  where
    mkConstr :: ToF m => [(F.TyVar, F.Kind)] -> F.Type -> ConstructorDef -> m (F.Field, F.SemanticSig)
    mkConstr tvks tCod (ConstructorDef cname tDoms) = do
      (tDoms', _) <- liftM unzip $ mapM type' tDoms
      let f = U.name2String cname
          t = F.tForalls tvks $ tDoms' `F.tArrs` tCod
      return (F.FCon f, F.ConSem t)
    
typeAlias :: ToF m => TypeAlias -> m F.SemanticSig
typeAlias (TypeAlias bnd) =
  U.lunbind bnd $ \(tvks, t) ->
  withTyVars tvks $ \tvks' -> do
    (t', kcod) <- type' t
    let kdoms = map snd tvks'
        k = kdoms `F.kArrs` kcod
    return $ F.TypeSem t' k

withFreshName :: (Typeable a, ToF m) => String -> (U.Name a -> m r) -> m r
withFreshName s kont = do
  n' <- U.lfresh $ U.s2n s
  U.avoid [U.AnyName n'] $ kont n'

withTyVars :: ToF m => [KindedTVar] -> ([(F.TyVar, F.Kind)] -> m r) -> m r
withTyVars [] kont = kont []
withTyVars (tvk:tvks) kont =
  withTyVar tvk $ \tvk' -> 
  withTyVars tvks $ \tvks' ->
  kont $ tvk':tvks'

withTyVar :: ToF m => KindedTVar -> ((F.TyVar, F.Kind) -> m r) -> m r
withTyVar (tv, k) kont = do
  k' <- kind k
  withFreshName (U.name2String tv) $ \tv' -> 
    local (tyVarEnv %~ M.insert tv (tv', k'))
    $ kont $ (tv', k')

kind :: Monad m => Kind -> m F.Kind
kind KType = return F.KType
kind (KArr k1 k2) = do
  k1' <- kind k1
  k2' <- kind k2
  return $ F.KArr k1' k2'

type' :: ToF m => Type -> m (F.Type, F.Kind)
type' t_ =
  case t_ of
   TV tv -> do
     mv <- view (tyVarEnv . at tv)
     case mv of
      Just (tv', k') -> return (F.TV tv', k')
      Nothing -> do
        env <- view tyVarEnv
        env' <- view valEnv
        fail ("ToF.type' internal error: type variable " <> show tv
              <> " not in environment " <> show env
              <> " and value env " <> show env')
   TUVar _ -> fail "ToF.type' internal error: unexpected unification variable"
   TC tc -> typeConstructor tc
   TAnn t k -> do
     (t', _) <- type' t
     k' <- kind k
     return (t', k')
   TApp t1 t2 -> do
     (t1', karr) <- type' t1
     (t2', _) <- type' t2
     case karr of
      (F.KArr _ k2) -> return (F.TApp t1' t2', k2)
      F.KType -> fail "ToF.type' internal error: unexpected KType in function position of type application"
   TForall bnd ->
     U.lunbind bnd $ \((tv, k), tbody) -> 
     withTyVar (tv,k) $ \(tv', k') -> do
       (tbody', _) <- type' tbody
       let
         tall = F.TForall $ U.bind (tv', U.embed k') $ tbody'
       return (tall, F.KType)
   TRecord (Row lts) -> do
     fts <- forM lts $ \(l, t) -> do
       (t', _) <- type' t
       return (F.FUser $ labelName l, t')
     return (F.TRecord fts, F.KType)

typeConstructor :: ToF m => TypeConstructor -> m (F.Type, F.Kind)
typeConstructor (TCLocal tc) = do
  ma <- view (tyConEnv . at tc)
  e <- view tyConEnv
  case ma of
   Just (F.TypeSem t k) -> return (t, k)
   Just f -> fail $ "ToF.typeConstructor: wanted a TypeSem, got a " ++ show f
   Nothing -> fail $ "ToF.typeConstructor: tyConEnv did not contain a TypeSem for a local type constructor: " ++ show tc ++ " in " ++ show e
typeConstructor (TCGlobal (TypePath p f)) = do
  let
    findIt ident = do
      ma <- view (modEnv . at ident)
      case ma of
       Just (sig, x) -> return (sig, F.V x)
       Nothing -> fail "ToF.typeConstructor: type path has unbound module identifier at the root"
  (s, _m) <- followUserPathAnything findIt (ProjP p f)
  case s of
   F.TypeSem t k -> return (t, k)
   _ -> fail "ToF.typeConstructor: type path maps to non-type semantic signature"
  
                      
---------------------------------------- Modules

moduleExpr :: ToF m => ModuleExpr -> m (F.AbstractSig, F.Term)
moduleExpr mdl_ =
  case mdl_ of
   ModuleStruct mdl -> structure mdl
   ModuleSeal me mt -> sealing me mt
   ModuleAssume {} -> fail "unimplemented ToF.moduleExpr ModuleAssume"
   ModuleId p -> do
     (sig, m) <- modulePath p
     return (F.AbstractSig $ U.bind [] sig, m)
   ModuleFun bnd ->
     U.lunbind bnd $ \(tele, bodyMe) ->
     moduleFunctor tele bodyMe
   ModuleApp pfun pargs -> moduleApp pfun pargs
   ModuleModel {} -> fail "unimplemented ToF.moduleExpr ModuleModel"

structure :: ToF m => Module -> m (F.AbstractSig, F.Term)
structure (Module decls) = do
  declarations decls $ \(summary@(tvks,sig), fields, termHole) -> do
    let semSig = F.ModSem sig
    ty <- F.embedSemanticSig semSig
    let r = F.Record fields
        m = F.packs (map (F.TV . fst) tvks) r (tvks, ty)
    return (mkAbstractModuleSig summary, appEndo termHole m)

-- | In the F-ing modules paper, (M:>S) is syntactic sugar, and only
-- (X :> S) is primitive.  But if we expand out the sugar and apply
-- some commuting conversions, we get something in nice form and we
-- choose to implement that nice form.
--
--    
--  〚(M :> S)〛 = 〚({ X = M ; X' = (X :> S) }.X')〛
--    = unpack (αs, y) = 〚{ X = M ; X' = (X :> S)}〛in pack (αs, y.lX')
--    = unpack (αs, y) = (unpack (βs, z1) = 〚M〛in unpack (γs, z2) = 〚(X :> S)〛[z1 / X] in pack (βs++γs, { lX = z1 ; lX' = z2 })) in pack (αs, y.lX')
--    = unpack (βs, z1) = 〚M〛in unpack (γs, z2) = 〚(X :> S)〛[z1/X] in unpack (αs,y) = pack (βs++γs, { lX = X ; lX' = z2 }) in pack (αs, y.lX')
--    = unpack (βs, z1) = 〚M〛 in unpack (γs, z2) = 〚(X :> S)〛[z1/X] in pack (βs++γs, z2)
--    = unpack (βs, z1) = 〚M〛 in unpack (γs, z2) = pack (τs, f z1) in pack (βs++γs, z2) where Σ₁ ≤ Ξ ↑ τs ⇝ f where Σ₁ is the type of z1 and Ξ is 〚S〛
--    = unpack (βs, z1) = 〚M〛 in pack (βs++τs, f z1)
--
-- In other words, elaborate M and S and construct the coercion f and
-- discover the sealed types τs, then pack anything that M abstracted
-- together with anything that S seals.  (The one missing bit is the
-- type annotation on the "pack" term, but it's easy.  Suppose Ξ is
-- ∃δs.Σ₂, then the result has type ∃βs,δs.Σ₂)
sealing :: ToF m => ModuleExpr -> ModuleType -> m (F.AbstractSig, F.Term)
sealing me mt = do
  xi@(F.AbstractSig xiBnd) <- moduleType mt
  (F.AbstractSig sigBnd, m) <- moduleExpr me
  U.lunbind sigBnd $ \(betas, sigma) -> do
    (taus, f) <- do
      (sig2, taus) <- F.matchSubst sigma xi
      coercion <- F.sigSubtyping sigma sig2
      return (taus, coercion)
    z1 <- U.lfresh (U.s2n "z")
    let
      packedTys = (map (F.TV . fst) betas)
                  ++ taus
    (xi', bdy) <- U.lunbind xiBnd $ \(deltas,sigma2) -> do
      sigma2emb <- F.embedSemanticSig sigma2
      let bdy = F.packs packedTys (F.App f $ F.V z1) (betas++deltas, sigma2emb)
          xi' = F.AbstractSig $ U.bind (betas++deltas) sigma2
      return (xi', bdy)
    term <- F.unpacks (map fst betas) z1 m bdy
    return (xi', term)

-- | (X1 : S1, ... Xn : Sn) -> { ... Xs ... }
-- translates to    Λα1s,...αns.λX1:Σ1,...,Xn:Σn. mbody : ∀αs.Σ1→⋯Σn→Ξ
-- where 〚Si〛= ∃αi.Σi and 〚{... Xs ... }〛= mbody : Ξ
moduleFunctor :: ToF m
                 => (Telescope (FunctorArgument ModuleType))
                 -> ModuleExpr
                 -> m (F.AbstractSig, F.Term)
moduleFunctor teleArgs bodyMe =
  withFunctorArguments teleArgs $ \(tvks, argSigs) -> do
    (resultAbs, mbody) <- moduleExpr bodyMe
    let funSig = F.SemanticFunctor (map snd argSigs) resultAbs
        s = F.FunctorSem $ U.bind tvks funSig
    args <- forM argSigs $ \(v,argSig) -> do
      argTy <- F.embedSemanticSig argSig
      return (v, argTy)
    let fnc = F.pLams' tvks $ F.lams args mbody
    return (F.AbstractSig $ U.bind [] s,
            fnc)

-- | p (p1, .... pn) becomes  m [τ1s,…,τNs] (f1 m1) ⋯ (fn mn) : Ξ[τs/αs]
-- where 〚p〛 = m : ∀αs.Σ1′→⋯→Σn′→Ξ and 〚pi〛 = mi : Σi  and (Σ1,…,Σn)≤∃αs.(Σ1′,…,Σn′) ↑ τs ⇝ fs
moduleApp :: ToF m
             => Path
             -> [Path]
             -> m (F.AbstractSig, F.Term)
moduleApp pfn pargs = do
  (semFn, mfn) <- modulePath pfn
  (argSigs, margs) <- mapAndUnzipM modulePath pargs
  case semFn of
   F.FunctorSem bnd ->
     U.lunbind bnd $ \(tvks, F.SemanticFunctor paramSigs sigResult) -> do
       let alphas = map fst tvks
       (paramSigs', taus) <- F.matchSubsts argSigs (alphas, paramSigs)
       coercions <- zipWithM F.sigSubtyping argSigs paramSigs'
       let
         m = (F.pApps mfn taus) `F.apps` (zipWith F.App coercions margs)
         s = U.substs (zip alphas taus) sigResult
       return (s, m)
   _ -> fail "internal failure: ToF.moduleApp expected a functor"

-- | Translation declarations.
-- This is a bit different from how F-ing modules does it in order to avoid producing quite so many
-- administrative redices, at the expense of being slightly more complex.
--
-- So the idea is that each declaration is going to produce two
-- things: A term with a hole and a description of the extra variable
-- bindings that it introduces in the scope of the hole.
--
-- For example, a type alias "type β = τ" will produce the term
--    let xβ = ↓[τ] in •   and the description {user field β : [τ]} ⇝ {user field β = xβ}
-- The idea is that the "SigSummary" part of the description is the abstract semantic signature of the
-- final structure in which this declaration appears, and the field↦term part is the record value that
-- will be produced.
--
-- For nested submodules we'll have to do a bit more work in order to
-- extrude the scope of the existential variables (ie, the term with
-- the hole is an "unpacks" instead of a "let"), but it's the same
-- idea.
--
-- For value bindings we go in two steps: the signature (which was inserted by the type checker if omitted)
-- just extends the SigSummary, while the actual definition extends the record.
-- TODO: (This gets mutually recursive functions wrong.  Need a letrec form in fomega)
declarations :: ToF m => [Decl] -> ((SigSummary, [(F.Field, F.Term)], Endo F.Term) -> m ans) -> m ans
declarations [] kont = kont mempty 
declarations (d:ds) kont = let
  kont1 out1 = declarations ds $ \outs -> kont $ out1 <> outs
  in case d of
      ValueDecl f vd -> valueDecl f vd kont1
      SubmoduleDefn f me -> submoduleDefn f me kont1
      SampleModuleDefn {} -> fail "unimplemented ToF.declarations SubmoduleDefn"
      TypeAliasDefn f al -> typeAliasDefn f al kont1
      ImportDecl {} -> fail "unimplemented ToF.declarations ImportDecl"
      TypeDefn {} -> fail "unimplemented ToF.declarations TypeDefn"
   
typeAliasDefn :: ToF m
                 => Field
                 -> TypeAlias
                 -> ((SigSummary, [(F.Field, F.Term)], Endo F.Term) -> m ans)
                 -> m ans
typeAliasDefn f (TypeAlias bnd) kont =
  U.lunbind bnd $ \ (tvks, rhs) -> do
    (tlam, tK) <- withTyVars tvks $ \tvks' -> do
      (rhs', kcod) <- type' rhs
      return (F.tLams tvks' rhs', F.kArrs (map snd tvks') kcod)
    let tsig = F.TypeSem tlam tK
        tc = U.s2n f :: TyConName
        xc = U.s2n f :: F.Var
    msig <- F.typeSemTerm tlam tK
    let
      mr = F.Record [(F.FType, msig)]
      mhole = Endo $ F.Let . U.bind (xc, U.embed mr)
      thisOne = ((mempty, [(F.FUser f, tsig)]),
                 [(F.FUser f, F.V xc)],
                 mhole)
    local (tyConEnv %~ M.insert tc tsig) $
      kont thisOne

submoduleDefn :: ToF m
                 => Field
                 -> ModuleExpr
                 -> ((SigSummary, [(F.Field, F.Term)], Endo F.Term) -> m ans)
                 -> m ans
submoduleDefn f me kont = do
  let modId = U.s2n f
  (F.AbstractSig bnd, msub) <- moduleExpr me
  U.lunbind bnd $ \(tvks, modsig) -> do
    let xv = U.s2n f
    local (modEnv %~ M.insert modId (modsig, xv)) $ do
      let tvs = map fst tvks
      munp <- F.unpacksM tvs xv
      let m = Endo $ munp msub
          thisOne = ((tvks, [(F.FUser f, modsig)]),
                     [(F.FUser f, F.V xv)],
                     m)
      kont thisOne

valueDecl :: ToF m => Field -> ValueDecl
             -> ((SigSummary, [(F.Field, F.Term)], Endo F.Term) -> m ans)
             -> m ans
valueDecl f vd kont =
  let v = U.s2n f :: Var
  in case vd of
   SigDecl _stoch ty -> do
     (ty', _k) <- type' ty
     let vsig = F.ValSem ty'
         xv = U.s2n f :: F.Var
     tr <- F.embedSemanticSig vsig
     let thisOne = ((mempty, [(F.FUser f, vsig)]),
                    mempty,
                    mempty)
     local (valEnv %~ M.insert v (xv, tr))
       $ U.avoid [U.AnyName v]
       $ kont thisOne
   FunDecl e -> do
     mt <- view (valEnv . at v)
     (xv, ty_) <- case mt of
       Nothing -> fail "internal error: ToF.valueDecl FunDecl did not find type declaration for field"
       Just xty -> return xty
     ty <- matchSemValRecord ty_
     m <- tyVarsAbstract ty $ \tvks _ty' -> do
       m_ <- expr e
       return $ F.pLams tvks m_
     let
       mr = F.Record [(F.FVal, m)]
       mhole = Endo $ F.Let . U.bind (xv, U.embed mr)
       thisOne = (mempty,
                  [(F.FUser f, F.V xv)],
                  mhole)
     kont thisOne
   _ -> fail "unimplemented ToF.valueDecl"

matchSemValRecord :: Monad m => F.Type -> m F.Type
matchSemValRecord (F.TRecord [(F.FVal, t)]) = return t
matchSemValRecord _ = fail "internal error: expected a record type encoding a value binding"

tyVarsAbstract :: ToF m => F.Type -> ([(F.TyVar, F.Kind)] -> F.Type -> m r) -> m r
tyVarsAbstract t_ kont_ = tyVarsAbstract' t_ (\tvks -> kont_ (appEndo tvks []))
  where
    tyVarsAbstract' :: ToF m => F.Type -> (Endo [(F.TyVar, F.Kind)] -> F.Type -> m r) -> m r
    tyVarsAbstract' t kont =
      case t of
       F.TForall bnd ->
         U.lunbind bnd $ \((tv', U.unembed -> k), t') -> do
           let tv = (U.s2n $ U.name2String tv') :: TyVar
           id {- U.avoid [U.AnyName tv] -}
             $ local (tyVarEnv %~ M.insert tv (tv', k))
             $ tyVarsAbstract' t' $ \tvks t'' ->
             kont (tvks <> Endo ((tv', k):)) t''
       _ -> kont mempty t
             

modulePath :: ToF m => Path
              -> m (F.SemanticSig, F.Term)
modulePath = let
  rootLookup modId = do
    ma <- view (modEnv . at modId)
    case ma of
     Nothing -> fail "unexpected failure in ToF.modulePath - unbound module identifier"
     Just (sig, x) -> return (sig, F.V x)
  in
   followUserPathAnything rootLookup


---------------------------------------- Core language

expr :: ToF m => Expr -> m F.Term
expr e_ =
  case e_ of
   V x -> do
     mx <- view (valEnv . at x)
     case mx of
      Nothing -> fail "unexpected failure: ToF.expr variable not in scope"
      Just (x',_t) -> return $ F.V x'
   L l -> return $ F.L l
   Q (QVar p f) -> do
     let
       findIt ident = do
         ma <- view (modEnv . at ident)
         case ma of
          Just (sig, x) -> return (sig, F.V x)
          Nothing -> fail "ToF.expr: type path has unbound module identifier at the root"
     (_sig, m) <- followUserPathAnything findIt (ProjP p f)
     -- assume _sig is a F.ValSem
     return $ F.Proj m F.FVal
   Lam bnd ->
     U.lunbind bnd $ \((x, U.unembed -> (Annot mt)), e) -> do
       t <- case mt of
        Nothing -> fail "unexpected failure: ToF.expr lambda without type annotation"
        Just t -> return t
       (t', _k) <- type' t
       withFreshName (U.name2String x) $ \x' ->
         local (valEnv %~ M.insert x (x', t')) $ do
           m <- expr e
           return $ F.Lam $ U.bind (x', U.embed t') m
   Instantiate e co -> do
     m <- expr e
     f <- instantiationCoercion co
     return $ F.App f m
   App e1 e2 -> do
     m1 <- expr e1
     m2 <- expr e2
     return $ F.App m1 m2
   Record les -> do
     fms <- forM les $ \(Label l, e) -> do
       m <- expr e
       return (F.FUser l, m)
     return $ F.Record fms
   Ann {} -> fail "unexpected failure: ToF.expr saw an Ann term"
   Return e -> liftM F.Return $ expr e
   
   _ -> fail "unimplemented ToF.expr"

-- | Given an instantiation coerction ∀αs.ρ ≤ [αs↦τs]ρ construct a function
-- of type  (∀αs.ρ) → [αs↦τs]ρ. Namely λx:(∀αs.ρ). x [τs]
instantiationCoercion :: ToF m => InstantiationCoercion -> m F.Term
instantiationCoercion (InstantiationSynthesisCoercion scheme args _result) = do
  (scheme', _) <- type' scheme
  args' <- mapM (liftM fst . type') args
  x <- U.lfresh $ U.s2n "x"
  let
    body = F.pApps (F.V x) args'
  return $ F.Lam $ U.bind (x, U.embed scheme') body
    
