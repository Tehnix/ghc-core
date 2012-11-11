{-# LANGUAGE PatternGuards, ScopedTypeVariables #-}
--------------------------------------------------------------------
-- |
-- Module    : ghc-core
-- Copyright : (c) Galois, Inc. 2008
-- License   : BSD3
--
-- Maintainer: Don Stewart <dons@galois.com>
-- Stability : provisional
-- Portability: Needs a few libraries from hackage.
--
--------------------------------------------------------------------
--
-- Inspect the optimised core and assembly produce by GHC.
--
-- Examples:
--
-- > ghc-core zipwith
--
-- > ghc-core -fvia-C zipwith
--

------------------------------------------------------------------------

import Control.Applicative
import Control.Exception as E
import Data.Maybe
import System.Console.GetOpt
import System.Directory
import System.Environment
import System.Exit
import System.FilePath
import System.IO
import System.Process

import Text.Regex.PCRE.Light.Char8

-- BSD-licensed Haskell syntax highlighting, based on Programmatica
import Language.Haskell.Colorize

------------------------------------------------------------------------
--
-- Command line parsing
--

data Options = Options
  { optHelp   :: Bool
  , optGhcExe :: String
  , optAsm    :: Bool
  , optSyntax :: Bool
  , optCast   :: Bool
  } deriving (Eq, Show)

defaultOptions :: Options
defaultOptions = Options
  { optHelp    = False
  , optGhcExe  = "ghc"
  , optAsm     = True
  , optSyntax  = True
  , optCast    = True
  }

options :: [OptDescr (Options -> Options)]
options =
    [ Option ['h'] ["help"]
         (NoArg (\opts -> opts { optHelp = True }))
         "Print this help message."
    , Option ['w'] ["with-ghc"]
         (ReqArg (\x opts -> opts { optGhcExe = x }) "PROGRAM")
         "Ghc executable to use."
    , Option [] ["no-asm"]
         (NoArg (\opts -> opts { optAsm = False }))
         "Don't output generated assembly code."
    , Option [] ["no-syntax"]
         (NoArg (\opts -> opts { optSyntax = False }))
         "Don't colorize generated code."
    , Option [] ["no-cast"]
         (NoArg (\opts -> opts { optCast = False }))
         "Don't output calls to cast in generated code."
    ]
    where

parseOptions :: [String] -> IO (Options, [String])
parseOptions argv =
    case getOpt RequireOrder options argv of
        (o, n, []) -> let o' = foldl (flip ($)) defaultOptions o in
                        if optHelp o'
                            then do hPutStr stderr (usageInfo header options)
                                    exitWith ExitSuccess
                            else return (o', n)
        (_, _, es) -> ioError (userError (concat es ++ usageInfo header options))
    where header = "Usage: ghc-core [OPTION...] [--] [GHC_OPTION...] [files...]"

isExtCoreFile :: FilePath -> Bool
isExtCoreFile = (== ".hcr") . takeExtension
------------------------------------------------------------------------

main :: IO ()
main = do
    -- Parse command line
    (opts, args) <- getArgs >>= parseOptions

    mv <- getEnvMaybe "PAGER"
    let pager = fromMaybe "less" mv
        pagerOpts = if pager == "less" then ["-f"] else []

    code <- case args of
        [fp] | isExtCoreFile fp -> readFile fp
        _ -> do
            strs <- compileWithCore (optGhcExe opts)
                        args (optAsm opts) (not (optCast opts))
            return (polish strs)

    let niceCode | optSyntax opts = render ansiLight code []
                 | otherwise      = code

    bracket
        (openTempFile "/tmp" "ghc-core-XXXX.hcr")
        (\(f,h) -> hClose h >> removeFile f)
        (\(f,h) -> do
            hPutStrLn h niceCode >> hFlush h
            e <- rawSystem pager (pagerOpts ++ ["-r",  f])
            exitWith e)

--
-- Clean up the output with some regular expressions.
--
polish :: String -> String
polish = unlines . dups . map polish' . lines
    where
        polish' [] = []
        polish' s
            | Just [_,a,b] <- match name  s [] = polish' (a ++ b)
            | Just [_,a,b] <- match local s [] = polish' (a ++ b)
            | isJunk s                         = ""
            | otherwise                        = s

        -- simplify some qualified names
        name  = compile
                 "^(.*)GHC\\.[^\\.]*\\.(.*)$"
                 [ungreedy]

        local = compile
                 "^(.*)Main\\.(.*)$"
                 [ungreedy]

        isJunk s = any (\r -> isJust (match r s [])) junks

        junks  = map (\r -> compile r [])
                    [ "^.GlobalId"
                    , "^.Arity .*"
                    , "^Rec {|^end Rec"
                    , "DmdType"
                    , "NoCafRefs"
                    , "^\\[\\]$"
                    ]

        -- remove duplicate blank lines
        dups []         = []
        dups ([]:[]:xs) = dups ([]:xs)
        dups (x:xs) = x : dups xs

------------------------------------------------------------------------

compileWithCore :: String -> [String] -> Bool -> Bool -> IO String
compileWithCore ghc opts asm suppressCasts = do
    -- TODO: Show generated assembly for -fllvm (previously implemented with -keep-tmp-files)
    let args = words "-O2 -ddump-simpl -ddump-simpl-stats -fforce-recomp --make"
                ++ (if asm then ["-ddump-asm"] else [])
                ++ (if suppressCasts then ["-dsuppress-coercions"] else [])

    x <- readProcessWithExitCode ghc (args ++ opts) []
    case x of
         (err@(ExitFailure _),str,std) -> do
            mapM_ putStrLn (lines str)
            mapM_ putStrLn (lines std)
            hPutStrLn stderr ("GHC failed to compile " ++ show err)
            exitWith (ExitFailure 1) -- fatal

         (ExitSuccess, str, _)      -> return str

------------------------------------------------------------------------

-- Safe wrapper for getEnv
getEnvMaybe :: String -> IO (Maybe String)
getEnvMaybe name = handle (\(_::SomeException) -> return Nothing) (Just <$> getEnv name)
