{-
Copyright 2012-2013 Google Inc. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-}

{-# LANGUAGE ForeignFunctionInterface, OverloadedStrings #-}

module Plush.Main (plushMain) where

import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.Monoid (mconcat)
import System.Console.Haskeline
import System.Environment (getArgs, getProgName)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hIsTerminalDevice, stdin)

import Plush.ArgParser
import Plush.DocTest
import Plush.Run
import Plush.Server
import Plush.Utilities


data Options = Options
                { optMode :: Options -> [String] -> IO ()
                , optRunner :: Runner
                }

optionsDescr :: [OptionSpec Options]
optionsDescr =
    [ OptionSpec ['?'] ["help"] (NoArg setHelp)
    , OptionSpec [] ["version"] (NoArg setVersion)
    , OptionSpec ['c'] [] (NoArg setReadArgMode)
    , OptionSpec ['s'] [] (NoArg setReadStdinMode)
    , OptionSpec ['w'] ["webserver"] (NoArg setWebServerMode)
    , OptionSpec ['d'] ["debug"] (NoArg setDebugMode)
    , OptionSpec ['t'] ["test"] (NoArg setTestExec)
    ]
  where
    setHelp opts = opts { optMode = (\_ _ -> usage) }
    setVersion opts = opts { optMode = (\_ _ -> version) }
    setReadStdinMode opts = opts { optMode = processStdin }
    setReadArgMode opts = opts { optMode = processArg }
    setWebServerMode opts = opts { optMode = runWebServer }
    setDebugMode opts = opts { optMode = debugOptions }
    setTestExec opts = opts { optRunner = runnerInTest }

parseOptions :: [String] -> IO (Options, [String])
parseOptions argv =
    case mconcat $ processArgs optionsDescr argv of
        (OA (Right (f, args))) -> return (f defaultOpts, args)
        (OA (Left err)) -> usageFailure err
  where
    defaultOpts =
        Options { optMode = processFile, optRunner = runnerInIO }

usage :: IO ()
usage = do
    prog <- getProgName
    putStrLn "Usage:"
    putStr $ unlines . map (("  "++prog)++) . lines $
        "                    -- read commands from stdin\n\
        \ -s                 -- read commands from stdin\n\
        \ <file>             -- read commands from file\n\
        \ -c <commands>      -- read commands from argument\n\
        \ -w [<port>]        -- run web server\n\
        \ -d doctest <file>* -- run doctest over the files\n\
        \ -d shelltest shell <file>* -- run doctest via the given shell\n"

usageFailure :: String -> IO a
usageFailure msg = do
    mapM_ (putStrLn . ("*** " ++)) $ lines msg
    usage
    exitFailure

version :: IO ()
version = putStrLn $ "Plush, the comfy shell, version " ++ displayVersion


foreign export ccall plushMain :: IO ()

plushMain :: IO ()
plushMain = do
    (opts, args) <- getArgs >>= parseOptions
    optMode opts opts args
    exitSuccess

processFile :: Options -> [String] -> IO ()
processFile opts [] = processStdin opts []
processFile opts (fp:args) = readUtf8File fp >>= processArg opts . (:(fp:args))

processArg :: Options -> [String] -> IO ()
processArg _ [] = return ()
processArg opts (cmds:_nameAndArgs) = runCommands cmds (optRunner opts)

processStdin :: Options -> [String] -> IO ()
processStdin opts _args = do
    isTerm <- hIsTerminalDevice stdin
    if isTerm
        then runRepl (optRunner opts)
        else getContents >>= (\cmds -> runCommands cmds (optRunner opts))


runWebServer :: Options -> [String] -> IO ()
runWebServer opts args = case args of
    [] -> serve Nothing
    [port] -> maybe badArgs (serve . Just) $ readMaybe port
    _ -> badArgs
  where
    serve = server (optRunner opts)
    badArgs = usage >> exitFailure

debugOptions :: Options -> [String] -> IO ()
debugOptions _ ("doctest":fps) = runDocTests fps
debugOptions _ ("shelltest":shell:fps) = shellDocTests shell fps
debugOptions _ _ = usage >> exitFailure

runRepl :: Runner -> IO ()
runRepl = runInputT defaultSettings . repl
    -- TODO(mzero): This opens a FD on /dev/tty which then leaks thru every
    -- fork and exec. This is a potential resource leak and security risk.
    -- Haskeline has no way to work around this.
    -- See http://trac.haskell.org/haskeline/ticket/123
  where
    repl runner = do
        l <- getInputLine "# "
        case l of
            Nothing -> return ()
            Just input -> do
                (leftOver, runner') <- liftIO (runCommand input runner)
                when (not $ null leftOver) $
                    outputStrLn ("Didn't use whole input: " ++ leftOver)
                repl runner'

runCommands :: String -> Runner -> IO ()
runCommands "" _ = return ()
runCommands cmds runner = runCommand cmds runner >>= uncurry runCommands

runCommand :: String -> Runner -> IO (String, Runner)
runCommand cmds r0 = do
    (pr, r1) <- run (parseInput cmds) r0
    case pr of
        Left errs -> putStrLn errs >> return ("", r1)
        Right (cl, rest) -> run (execute cl) r1
                                >>= return . (\(_,r2) -> (rest, r2))


