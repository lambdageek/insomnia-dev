{-# LANGUAGE OverloadedStrings #-}
module Insomnia.Main.InsomniaStages where

import Control.Monad.Reader
import Data.Monoid (Monoid(..), (<>))

import qualified Data.Format as F

import Insomnia.Main.Config
import Insomnia.Main.Monad
import Insomnia.Main.Stage

import Insomnia.Toplevel (Toplevel)
import Insomnia.Typecheck as TC 
import Insomnia.Pretty
import qualified Insomnia.IReturn as IReturn
import qualified Insomnia.ToF as ToF
import qualified FOmega.Syntax as FOmega
import qualified FOmega.Check as FCheck
import qualified FOmega.Eval as FOmega

import qualified Gambling.FromF as ToGamble
import qualified Gambling.Emit as EmitGamble
import qualified Gambling.Racket

import Insomnia.Main.ParsingStage (parsingStage)
import Insomnia.Main.SaveFinalProductStage (saveFinalProductStage)

parseAndCheck' :: Stage FilePath FOmega.Command
parseAndCheck' =
  parsingStage
  ->->- desugaring
  ->->- checking
  ->->- toFOmega
  ->->- checkFOmega
  ->->- conditionalStage (asks ismCfgEvaluateFOmega) runFOmega

parseAndCheck :: FilePath -> InsomniaMain ()
parseAndCheck fp =
  startingFrom fp $ 
  parseAndCheck'
  ->->- compilerDone

parseAndCheckAndGamble :: FilePath -> InsomniaMain ()
parseAndCheckAndGamble fp =
  startingFrom fp $
  parseAndCheck'
  ->->- translateToGamble
  ->->- prettyPrintGamble
  ->->- (saveFinalProductStage "Gamble code")
  ->->- compilerDone

desugaring :: Stage Toplevel Toplevel
desugaring = Stage {
  bannerStage = "Desugaring"
  , performStage = \t ->
     let t' = IReturn.toplevel t
     in return t'
  , formatStage = F.format . ppDefault
  }

checking :: Stage Toplevel Toplevel
checking = Stage {
  bannerStage = "Typechecking"
  , performStage = \ast -> do
    let tc = TC.runTC $ TC.checkToplevel ast
    (elab, unifState) <- case tc of
      Left err -> showErrorAndDie "typechecking" err
      Right ((elab, _tsum), unifState) -> return (elab, unifState)
    putDebugStrLn "Typechecked OK."
    putDebugStrLn "Unification state:"
    putDebugDoc (F.format (ppDefault unifState)
                 <> F.newline)
    return elab
  , formatStage = F.format . ppDefault
  }

toFOmega :: Stage Toplevel FOmega.Command
toFOmega = Stage {
  bannerStage = "Convert to FΩ"
  , performStage = \pgm ->
    let (_sigSummary, tm) = ToF.runToFM $ ToF.toplevel pgm
    in return tm
  , formatStage = F.format . ppDefault
}

checkFOmega :: Stage FOmega.Command FOmega.Command
checkFOmega = Stage {
  bannerStage = "Typechecking FΩ"
  , performStage = \m -> do
    mty <- FCheck.runTC (FCheck.inferCmdTy m)
    case mty of
      Left err -> showErrorAndDie "typechecking FOmega" (show err)
      Right ty -> do
        putDebugStrLn "FOmega type is: "
        putDebugDoc (F.format $ ppDefault ty)
        putDebugStrLn "\n"
    return m
  , formatStage = const mempty
  }

runFOmega :: Stage FOmega.Command FOmega.Command
runFOmega = Stage {
  bannerStage = "Running FΩ"
  , performStage = \m -> do
    mv <- FOmega.runEvalCommand m
    case mv of
     Left err -> showErrorAndDie "running FOmega" (show err)
     Right v -> do
       putDebugDoc (F.format $ ppDefault v)
    return m
  , formatStage = const mempty
  }

translateToGamble :: Stage  FOmega.Command Gambling.Racket.Module
translateToGamble = Stage {
  bannerStage = "Translating to Gamble"
  , performStage = return . ToGamble.fomegaToGamble "<unnamed>"
  , formatStage = const mempty
  }

prettyPrintGamble :: Stage Gambling.Racket.Module F.Doc
prettyPrintGamble = Stage {
  bannerStage = "Pretty-printing Gamble code"
  , performStage = return . EmitGamble.emitIt
  , formatStage = id
  }

