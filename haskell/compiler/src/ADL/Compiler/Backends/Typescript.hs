{-|
Module : ADL.Compiler.Backends.Typescript
Description: Typescript backend for ADL

This module contains that necessary functions to generate
a typescript backend from an ADL file.
-}
{-# LANGUAGE OverloadedStrings #-}
module ADL.Compiler.Backends.Typescript(
 generate,
  TypescriptFlags(..),
  ) where

import           ADL.Compiler.AST
import           ADL.Compiler.Primitive
import           ADL.Utils.FileDiff                         (dirContents)
import           ADL.Utils.Format(template,formatText)
import qualified Data.ByteString.Lazy                       as LBS
import qualified Data.Map                                   as Map
import qualified Data.Text                                  as T
import qualified Data.Text.Encoding                         as T

import           ADL.Compiler.EIO
import           ADL.Compiler.Processing
import           ADL.Compiler.Utils
import           ADL.Utils.IndentedCode
import           Control.Monad                              (when)
import           Control.Monad.Trans                        (liftIO)
import           Control.Monad.Trans.State.Strict
import           Data.Foldable                              (for_)
import           Data.List                                  (intersperse)
import           Data.Monoid
import           Data.Traversable                           (for)
import           System.FilePath                            (joinPath,
                                                             takeDirectory,
                                                             (<.>), (</>))

import           ADL.Compiler.Backends.Typescript.Internal
import           ADL.Compiler.DataFiles

-- | Run this backend on a list of ADL modules. Check each module
-- for validity, and then generate the code for it.
generate :: AdlFlags -> TypescriptFlags -> FileWriter -> [FilePath] -> EIOT ()
generate af tf fileWriter modulePaths = catchAllExceptions  $ do
  for modulePaths $ \modulePath -> do
    m <- loadAndCheckModule af modulePath
    let m' = fullyScopedModule m
    generateModule tf fileWriter m'
  when (tsIncludeRuntime tf) (generateRuntime af tf fileWriter modulePaths)

-- JS.generate af (JS.JavascriptFlags {}) fileWriter
generateRuntime :: AdlFlags -> TypescriptFlags -> FileWriter -> [FilePath] -> EIOT ()
generateRuntime af tf fileWriter modulePaths = do
    files <- liftIO $ dirContents runtimeLibDir
    liftIO $ for_ files $ \inpath -> do
      content <- LBS.readFile (runtimeLibDir </> inpath)
      fileWriter (tsRuntimeDir tf </> inpath) content
    where
      runtimeLibDir = typescriptRuntimeDir (tsLibDir tf)

-- | Generate and the typescript code for a single ADL module, and
-- save the resulting code to the apppropriate file
generateModule :: TypescriptFlags ->
                  FileWriter ->
                  RModule ->
                  EIO T.Text ()
generateModule tf fileWriter m0 = do
  let moduleName = m_name m
      m = associateCustomTypes getCustomType moduleName m0
      cgp = CodeGenProfile {
        cgp_includeAst = not (tsExcludeAst tf)
      }
      mf = execState (genModule m) (emptyModuleFile (m_name m) cgp)
  liftIO $ fileWriter (moduleFilePath (unModuleName moduleName) <.> "ts") (genModuleCode mf)

genModule :: CModule -> CState ()
genModule m = do
  includeAst <- fmap (cgp_includeAst . mfCodeGenProfile) get
  when includeAst $ do
    addImport "ADL" (TSImport "ADL" ["runtime","adl"])

  -- Generate each declaration
  for_ (getOrderedDecls m) $ \decl ->
    case d_type decl of
     (Decl_Struct struct)   -> genStruct m decl struct
     (Decl_Union union)     -> genUnion m decl union
     (Decl_Typedef typedef) -> genTypedef m decl typedef
     (Decl_Newtype ntype)   -> genNewtype m decl ntype

  when includeAst $ do
    addAstMap m

genModuleCode :: ModuleFile -> LBS.ByteString
genModuleCode mf = LBS.fromStrict (T.encodeUtf8 (T.unlines (codeText 10000 code)))
  where
    code
      =  cline "/* Automatically generated by adlc */"
      <> cline ""
      <> mconcat [genImport (mfModuleName mf) i | i <- Map.elems (mfImports mf)]
      <> cline ""
      <> mconcat (intersperse (cline "") (reverse (mfDeclarations mf)))

genImport :: ModuleName -> TSImport -> Code
genImport intoModule TSImport{iAsName=asName, iModulePath=importPath} = ctemplate "import * as $1 from \'$2\';" [asName, mpath]
  where
    mpath = T.intercalate "/" (".":relativeImport)

    intoPath = unModuleName intoModule
    relativeImport = relativePath (init intoPath) (init importPath) ++ [last importPath]

    relativePath [] ps2 = ps2
    relativePath (p1:ps1) (p2:ps2) | p1 == p2 = relativePath ps1 ps2
    relativePath ps1 ps2 = (map (const "..") ps1) <> ps2

genStruct :: CModule -> CDecl -> Struct CResolvedType -> CState ()
genStruct m decl struct@Struct{s_typeParams=parameters} = do
  fds <- mapM genFieldDetails (s_fields struct)
  let structName = capitalise (d_name decl)

  addDeclaration $ renderCommentsForDeclaration decl <> renderInterface structName parameters fds False
  addDeclaration $ renderFactory structName (s_typeParams struct) fds
  addAstDeclaration m decl

genUnion :: CModule -> CDecl -> Union CResolvedType -> CState ()
genUnion  m decl union@Union{u_typeParams=parameters} = do
  genUnionWithDiscriminate m decl union
  addAstDeclaration m decl

genUnionWithDiscriminate :: CModule -> CDecl -> Union CResolvedType -> CState ()
genUnionWithDiscriminate  m decl union
  | isUnionEnum union = genUnionEnum m decl union
  | otherwise = genUnionInterface m decl union

genUnionEnum :: CModule -> CDecl -> Union CResolvedType -> CState ()
genUnionEnum _ decl enum = do
  fds <- mapM genFieldDetails (u_fields enum)
  let enumName = capitalise (d_name decl)
      enumFields = mconcat [ctemplate "$1," [fdName fd] | fd <- fds]
      enumDecl = cblock (template "export enum $1" [enumName]) enumFields
  addDeclaration enumDecl

genUnionInterface :: CModule -> CDecl -> Union CResolvedType -> CState ()
genUnionInterface _ decl union@Union{u_typeParams=parameters} = do
  fds <- mapM genFieldDetails (u_fields union)
  let unionName = d_name decl
  addDeclaration (renderUnionFieldsAsInterfaces unionName parameters fds)
  addDeclaration (renderUnionChoice decl unionName parameters fds)

renderUnionChoice :: CDecl -> T.Text -> [Ident] -> [FieldDetails] -> Code
renderUnionChoice decl unionName typeParams fds =
  CAppend renderedComments (ctemplate "export type $1$2 = $3;" [unionName, renderedParameters, T.intercalate " | " [getChoiceName fd | fd <- fds]])
  where
    getChoiceName fd = unionName <> "_" <> capitalise (fdName fd) <> renderedParameters
    renderedComments = renderCommentsForDeclaration decl
    renderedParameters = typeParamsExpr typeParams

renderUnionFieldsAsInterfaces :: T.Text -> [Ident] -> [FieldDetails] -> Code
renderUnionFieldsAsInterfaces unionName parameters (fd:xs) =
  CAppend renderedInterface (renderUnionFieldsAsInterfaces unionName parameters xs)
    where
      renderedInterface = CAppend (renderInterface interfaceName parameters fieldDetails False) CEmpty
      interfaceName = unionName <> "_" <> capitalise (fdName fd)
      fieldDetails = constructUnionFieldDetailsFromField fd
renderUnionFieldsAsInterfaces _ _ [] = CEmpty

constructUnionFieldDetailsFromField :: FieldDetails -> [FieldDetails]
constructUnionFieldDetailsFromField fd@FieldDetails{fdField=Field{f_type=(TypeExpr (RT_Primitive P_Void) _)}}
 = [FieldDetails{
  fdName="kind",
  fdField=Field{
    f_name="kind",
    f_serializedName="kind",
    f_type=TypeExpr (RT_Primitive P_String) [],
    f_default=Nothing,
    f_annotations=Map.empty},
  fdTypeExprStr="'" <> fdName fd <> "'",
  fdOptional=False,
  fdDefValue=Nothing}]
constructUnionFieldDetailsFromField fd = [FieldDetails{
  fdName="kind",
  fdField=Field{
    f_name="kind",
    f_serializedName="kind",
    f_type=TypeExpr (RT_Primitive P_String) [],
    f_default=Nothing,
    f_annotations=Map.empty},
  fdTypeExprStr="'" <> fdName fd <> "'",
  fdOptional=False,
  fdDefValue=Nothing},
  FieldDetails{fdName="value",
  fdField=Field{
    f_name="value",
    f_serializedName="value",
    f_type=TypeExpr (RT_Primitive P_String) [],
    f_default=Nothing,
    f_annotations=Map.empty},
  fdTypeExprStr=fdTypeExprStr fd,
  fdOptional=False,
  fdDefValue=Nothing}]

genNewtype :: CModule -> CDecl -> Newtype CResolvedType -> CState ()
genNewtype  m declaration ntype@Newtype{n_typeParams=typeParams} = do
  typeExprOutput <- genTypeExpr (n_typeExpr ntype)
  let
    typeDecl = ctemplate "export type $1$2 = $3;" [d_name declaration, typeParamsExpr typeParams, typeExprOutput]
  addDeclaration typeDecl
  addAstDeclaration m declaration

genTypedef :: CModule -> CDecl -> Typedef CResolvedType -> CState ()
genTypedef m declaration typedef@Typedef{t_typeParams=typeParams} = do
  typeExprOutput <- genTypeExpr (t_typeExpr typedef)
  let
    typeDecl = ctemplate "export type $1$2 = $3;" [d_name declaration, typeParamsExpr typeParams, typeExprOutput]
  addDeclaration typeDecl
  addAstDeclaration m declaration

emptyModuleFile :: ModuleName -> CodeGenProfile -> ModuleFile
emptyModuleFile mn cgp = ModuleFile mn Map.empty [] cgp

getCustomType :: ScopedName -> RDecl -> Maybe CustomType
getCustomType _ _ = Nothing

moduleFilePath  :: [Ident] -> FilePath
moduleFilePath path = joinPath (map T.unpack path)
