{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies #-}

-- | Rendering of types.
module Ormolu.Printer.Meat.Type
  ( p_hsType,
    p_hsTypePostDoc,
    startTypeAnnotation,
    startTypeAnnotationDecl,
    hasDocStrings,
    p_hsContext,
    p_hsTyVarBndr,
    ForAllVisibility (..),
    p_forallBndrs,
    p_conDeclFields,
    p_lhsTypeArg,
    p_hsSigType,
    tyVarsToTyPats,
    hsOuterTyVarBndrsToHsType,
    lhsTypeToSigType,
  )
where

import Control.Monad
import GHC.Hs
import GHC.Types.Basic hiding (isPromoted)
import GHC.Types.SourceText
import GHC.Types.SrcLoc
import GHC.Types.Var
import Ormolu.Config
import Ormolu.Printer.Combinators
import Ormolu.Printer.Meat.Common
import {-# SOURCE #-} Ormolu.Printer.Meat.Declaration.OpTree (p_tyOpTree, tyOpTree)
import {-# SOURCE #-} Ormolu.Printer.Meat.Declaration.Value (p_hsSplice, p_stringLit)
import Ormolu.Printer.Operators
import Ormolu.Utils
import Ormolu.Printer.Internal (alignContext, align)

{-# ANN module ("Hlint: ignore Use camelCase" :: String) #-}

p_hsType :: HsType GhcPs -> R ()
p_hsType t = do
  s <-
    getPrinterOpt poFunctionArrows >>= \case
      TrailingArrows -> pure PipeStyle
      LeadingArrows -> pure CaretStyle
      LeadingArgsArrows -> pure CaretStyle
  layout <- getLayout
  p_hsType' (hasDocStrings t || layout == MultiLine) s t

p_hsTypePostDoc :: HsType GhcPs -> R ()
p_hsTypePostDoc t = p_hsType' (hasDocStrings t) CaretStyle t

-- | How to render Haddocks associated with a type.
data TypeDocStyle
  = PipeStyle
  | CaretStyle

p_hsType' :: Bool -> TypeDocStyle -> HsType GhcPs -> R ()
p_hsType' multilineArgs docStyle = \case
  HsForAllTy _ tele t -> do
    vis <-
      case tele of
        HsForAllInvis _ bndrs -> p_forallBndrsStart p_hsTyVarBndr bndrs >> pure ForAllInvis
        HsForAllVis _ bndrs -> p_forallBndrsStart p_hsTyVarBndr bndrs >> pure ForAllVis
    getPrinterOpt poFunctionArrows >>= \case
      LeadingArrows | multilineArgs -> interArgBreak >> txt " " >> p_forallBndrsEnd vis
      _ -> p_forallBndrsEnd vis >> interArgBreak
    p_hsTypeR (unLoc t)
  HsQualTy _ qs t -> do
    located qs p_hsContext
    getPrinterOpt poFunctionArrows >>= \case
      LeadingArrows -> interArgBreak >> token'darrow >> space
      TrailingArrows -> space >> token'darrow >> interArgBreak
      LeadingArgsArrows -> space >> token'darrow >> interArgBreak
    case unLoc t of
      HsQualTy {} -> p_hsTypeR (unLoc t)
      HsFunTy {} -> p_hsTypeR (unLoc t)
      _ -> located t p_hsTypeR
  HsTyVar _ p n -> do
    case p of
      IsPromoted -> do
        txt "'"
        case showOutputable (unLoc n) of
          _ : '\'' : _ -> space
          _ -> return ()
      NotPromoted -> return ()
    p_rdrName n
  HsAppTy _ f x -> do
    let -- In order to format type applications with multiple parameters
        -- nicer, traverse the AST to gather the function and all the
        -- parameters together.
        gatherArgs f' knownArgs =
          case f' of
            L _ (HsAppTy _ l r) -> gatherArgs l (r : knownArgs)
            _ -> (f', knownArgs)
        (func, args) = gatherArgs f [x]
    switchLayout (getLocA f : fmap getLocA args) . sitcc $ do
      located func p_hsType
      breakpoint
      inci $
        sep breakpoint (located' p_hsType) args
  HsAppKindTy _ ty kd -> sitcc $ do
    -- The first argument is the location of the "@..." part. Not 100% sure,
    -- but I think we can ignore it as long as we use 'located' on both the
    -- type and the kind.
    located ty p_hsType
    breakpoint
    inci $ do
      txt "@"
      located kd p_hsType
  HsFunTy _ arrow x y -> do
    let p_arrow =
          case arrow of
            HsUnrestrictedArrow _ -> token'rarrow
            HsLinearArrow _ -> token'lolly
            HsExplicitMult _ mult _ -> do
              txt "%"
              p_hsTypeR (unLoc mult)
              space
              token'rarrow
    located x p_hsType
    getPrinterOpt poFunctionArrows >>= \case
      LeadingArrows -> interArgBreak >> located y (\y' -> p_arrow >> space >> p_hsTypeR y')
      TrailingArrows -> space >> p_arrow >> interArgBreak >> located y p_hsTypeR
      LeadingArgsArrows -> interArgBreak >> located y (\y' -> p_arrow >> space >> p_hsTypeR y')
  HsListTy _ t ->
    located t (brackets N . p_hsType)
  HsTupleTy _ tsort xs ->
    let parens' =
          case tsort of
            HsUnboxedTuple -> parensHash N
            HsBoxedOrConstraintTuple -> parens N
     in parens' $ sep commaDel (sitcc . located' p_hsType) xs
  HsSumTy _ xs ->
    parensHash N $
      sep (space >> txt "|" >> breakpoint) (sitcc . located' p_hsType) xs
  HsOpTy _ _ x op y -> do
    fixityOverrides <- askFixityOverrides
    fixityMap <- askFixityMap
    let opTree = OpBranches [tyOpTree x, tyOpTree y] [op]
    p_tyOpTree
      (reassociateOpTree (Just . unLoc) fixityOverrides fixityMap opTree)
  HsParTy _ t ->
    parens N $ sitcc $ located t p_hsType
  HsIParamTy _ n t -> sitcc $ do
    located n atom
    inci $ startTypeAnnotation t p_hsType
  HsStarTy _ _ -> token'star
  HsKindSig _ t k -> sitcc $ do
    located t p_hsType
    inci $ startTypeAnnotation k p_hsType
  HsSpliceTy _ splice -> p_hsSplice splice
  HsDocTy _ t str ->
    case docStyle of
      PipeStyle -> do
        p_hsDoc Pipe True str
        located t p_hsType
      CaretStyle -> do
        located t p_hsType
        newline
        p_hsDoc Caret False str
  HsBangTy _ (HsSrcBang _ u s) t -> do
    case u of
      SrcUnpack -> txt "{-# UNPACK #-}" >> space
      SrcNoUnpack -> txt "{-# NOUNPACK #-}" >> space
      NoSrcUnpack -> return ()
    case s of
      SrcLazy -> txt "~"
      SrcStrict -> txt "!"
      NoSrcStrict -> return ()
    located t p_hsType
  HsRecTy _ fields ->
    p_conDeclFields fields
  HsExplicitListTy _ p xs -> do
    case p of
      IsPromoted -> txt "'"
      NotPromoted -> return ()
    brackets N $ do
      -- If both this list itself and the first element is promoted,
      -- we need to put a space in between or it fails to parse.
      case (p, xs) of
        (IsPromoted, L _ t : _) | isPromoted t -> space
        _ -> return ()
      sep commaDel (sitcc . located' p_hsType) xs
  HsExplicitTupleTy _ xs -> do
    txt "'"
    parens N $ do
      case xs of
        L _ t : _ | isPromoted t -> space
        _ -> return ()
      sep commaDel (located' p_hsType) xs
  HsTyLit _ t ->
    case t of
      HsStrTy (SourceText s) _ -> p_stringLit s
      a -> atom a
  HsWildCardTy _ -> txt "_"
  XHsType t -> atom t
  where
    isPromoted = \case
      HsAppTy _ (L _ f) _ -> isPromoted f
      HsTyVar _ IsPromoted _ -> True
      HsExplicitTupleTy {} -> True
      HsExplicitListTy {} -> True
      _ -> False
    interArgBreak =
      if multilineArgs
        then newline
        else breakpoint
    p_hsTypeR m = p_hsType' multilineArgs docStyle m

startTypeAnnotation ::
  (HasSrcSpan l) =>
  GenLocated l a ->
  (a -> R ()) ->
  R ()
startTypeAnnotation = startTypeAnnotation' breakpoint breakpoint

startTypeAnnotationDecl ::
  (HasSrcSpan l) =>
  GenLocated l a ->
  (a -> HsType GhcPs) ->
  (a -> R ()) ->
  R ()
startTypeAnnotationDecl lItem getType =
  startTypeAnnotation'
    ( if hasDocStrings $ getType $ unLoc lItem
        then newline
        else breakpoint
    )
    breakpoint
    lItem

startTypeAnnotation' ::
  (HasSrcSpan l) =>
  R () ->
  R () ->
  GenLocated l a ->
  (a -> R ()) ->
  R ()
startTypeAnnotation' breakTrailing breakLeading lItem renderItem =
  getPrinterOpt poFunctionArrows >>= \case
    TrailingArrows -> do
      space
      token'dcolon
      breakTrailing
      located lItem renderItem
    LeadingArrows -> do
      breakLeading
      located lItem $ \item -> do
        token'dcolon
        space
        renderItem item
    LeadingArgsArrows -> do
      space
      token'dcolon
      breakTrailing
      located lItem renderItem

-- | Return 'True' if at least one argument in 'HsType' has a doc string
-- attached to it.
hasDocStrings :: HsType GhcPs -> Bool
hasDocStrings = \case
  HsDocTy {} -> True
  HsFunTy _ _ (L _ x) (L _ y) -> hasDocStrings x || hasDocStrings y
  HsForAllTy _ _ (L _ x) -> hasDocStrings x
  HsQualTy _ _ (L _ x) -> hasDocStrings x
  _ -> False

p_hsContext :: HsContext GhcPs -> R ()
p_hsContext = \case
  [] -> txt "()"
  [x] -> located x p_hsType
  xs -> parens N $ sep commaDel (sitcc . located' p_hsType) xs

class IsInferredTyVarBndr flag where
  isInferred :: flag -> Bool

instance IsInferredTyVarBndr () where
  isInferred () = False

instance IsInferredTyVarBndr Specificity where
  isInferred = \case
    InferredSpec -> True
    SpecifiedSpec -> False

p_hsTyVarBndr :: (IsInferredTyVarBndr flag) => HsTyVarBndr flag GhcPs -> R ()
p_hsTyVarBndr = \case
  UserTyVar _ flag x ->
    (if isInferred flag then braces N else id) $ p_rdrName x
  KindedTyVar _ flag l k -> (if isInferred flag then braces else parens) N . sitcc $ do
    located l atom
    inci $ startTypeAnnotation k p_hsType

data ForAllVisibility = ForAllInvis | ForAllVis

-- | Render several @forall@-ed variables.
p_forallBndrs ::
  (HasSrcSpan l) =>
  ForAllVisibility ->
  (a -> R ()) ->
  [GenLocated l a] ->
  R ()
p_forallBndrs vis p tyvars = do
  p_forallBndrsStart p tyvars
  p_forallBndrsEnd vis

p_forallBndrsStart :: (HasSrcSpan l) => (a -> R ()) -> [GenLocated l a] -> R ()
p_forallBndrsStart _ [] = token'forall
p_forallBndrsStart p tyvars = do
  switchLayout (getLoc' <$> tyvars) $ do
    token'forall
    breakpoint
    inci $ do
      sitcc $ sep breakpoint (sitcc . located' p) tyvars

p_forallBndrsEnd :: ForAllVisibility -> R ()
p_forallBndrsEnd ForAllInvis = txt "." >> space
p_forallBndrsEnd ForAllVis = space >> token'rarrow

p_conDeclFields :: [LConDeclField GhcPs] -> R ()
p_conDeclFields xs =
  alignContext . braces N $ sep commaDel (sitcc . located' p_conDeclField) xs

p_conDeclField :: ConDeclField GhcPs -> R ()
p_conDeclField ConDeclField {..} = do
  commaStyle <- getPrinterOpt poCommaStyle
  when (commaStyle == Trailing) $
    mapM_ (p_hsDoc Pipe True) cd_fld_doc
  sitcc $
    sep
      commaDel
      (located' (p_rdrName . foLabel))
      cd_fld_names
  getPrinterOpt poFunctionArrows >>= \case
    LeadingArrows -> inci $ do
      breakpoint
      token'dcolon
      space
      p_hsType (unLoc cd_fld_type)
    TrailingArrows -> do
      space
      token'dcolon
      breakpoint
      sitcc . inci $ p_hsType (unLoc cd_fld_type)
    LeadingArgsArrows -> do
      space
      token'dcolon
      breakpoint
      sitcc . inci $ p_hsType (unLoc cd_fld_type)
  when (commaStyle == Leading) $
    mapM_ (inciByFrac (-1) . (newline >>) . p_hsDoc Caret False) cd_fld_doc

p_lhsTypeArg :: LHsTypeArg GhcPs -> R ()
p_lhsTypeArg = \case
  HsValArg ty -> located ty p_hsType
  -- first argument is the SrcSpan of the @,
  -- but the @ always has to be directly before the type argument
  HsTypeArg _ ty -> txt "@" *> located ty p_hsType
  -- NOTE(amesgen) is this unreachable or just not implemented?
  HsArgPar _ -> notImplemented "HsArgPar"

p_hsSigType :: HsSigType GhcPs -> R ()
p_hsSigType HsSig {..} =
  p_hsType $ hsOuterTyVarBndrsToHsType sig_bndrs sig_body

----------------------------------------------------------------------------
-- Conversion functions

tyVarToType :: HsTyVarBndr () GhcPs -> HsType GhcPs
tyVarToType = \case
  UserTyVar _ () tvar -> HsTyVar EpAnnNotUsed NotPromoted tvar
  KindedTyVar _ () tvar kind ->
    -- Note: we always add parentheses because for whatever reason GHC does
    -- not use HsParTy for left-hand sides of declarations. Please see
    -- <https://gitlab.haskell.org/ghc/ghc/issues/17404>. This is fine as
    -- long as 'tyVarToType' does not get applied to right-hand sides of
    -- declarations.
    HsParTy EpAnnNotUsed . noLocA $
      HsKindSig EpAnnNotUsed (noLocA (HsTyVar EpAnnNotUsed NotPromoted tvar)) kind

tyVarsToTyPats :: LHsQTyVars GhcPs -> HsTyPats GhcPs
tyVarsToTyPats HsQTvs {..} = HsValArg . fmap tyVarToType <$> hsq_explicit

-- could be generalized to also handle () instead of Specificity
hsOuterTyVarBndrsToHsType ::
  HsOuterTyVarBndrs Specificity GhcPs ->
  LHsType GhcPs ->
  HsType GhcPs
hsOuterTyVarBndrsToHsType obndrs ty = case obndrs of
  HsOuterImplicit NoExtField -> unLoc ty
  HsOuterExplicit _ bndrs ->
    HsForAllTy NoExtField (mkHsForAllInvisTele EpAnnNotUsed bndrs) ty

lhsTypeToSigType :: LHsType GhcPs -> LHsSigType GhcPs
lhsTypeToSigType ty =
  reLocA . L (getLocA ty) . HsSig NoExtField (HsOuterImplicit NoExtField) $ ty
