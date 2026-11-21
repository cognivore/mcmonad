{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket, finally)
import Control.Monad (unless, void)
import Data.Aeson
import Data.Aeson.Types (Pair)
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Text (Text)
import MCMonad (mcmonad, defaultConfig)
import Network.Socket
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removeDirectoryRecursive)
import System.Environment (getArgs, getEnvironment, getExecutablePath)
import System.FilePath ((</>))
import System.IO
import System.Posix.Temp (mkdtemp)
import System.Process
import System.Timeout (timeout)

-- Replay the wire protocol against the real event loop. The optional binary
-- argument runs the same assertions against the user's compiled config.
main :: IO ()
main = getArgs >>= \args -> case args of
    ["--test-child"] -> mcmonad defaultConfig
    [] -> do
        self <- getExecutablePath
        isolated (proc self ["--test-child"])
    [binary] -> isolated (proc binary [])
    _ -> fail "Expected an optional compiled mcmonad binary to replay against."

isolated :: CreateProcess -> IO ()
isolated child = do
    tmp <- getTemporaryDirectory
    env0 <- getEnvironment
    bracket (mkdtemp (tmp </> "mcf")) removeDirectoryRecursive $ \home -> do
        let dir = home </> ".config" </> "mcmonad"
        createDirectoryIfMissing True dir
        bracket (socket AF_UNIX Stream defaultProtocol) close $ \server -> do
            bind server (SockAddrUnix (dir </> "core.sock"))
            listen server 1
            let testEnv = ("HOME",home) : filter ((/= "HOME") . fst) env0
            withCreateProcess child { env = Just testEnv, cwd = Just home } $ \_ _ _ ph ->
                flip finally (terminateProcess ph >> void (waitForProcess ph)) $ do
                    result <- timeout 15000000 $ do
                        (client,_) <- accept server
                        bracket (socketToHandle client ReadWriteMode) hClose replay
                    unless (result == Just ()) $ fail "Brain timed out during the focus/close replay."

data Effect = Focus Int | Workspace Text | Cmd Text deriving (Show, Eq)

instance FromJSON Effect where
    parseJSON = withObject "command" $ \o -> o .: "cmd" >>= \case
        "focus-window" -> Focus <$> o .: "windowId"
        "set-workspace-indicator" -> Workspace <$> o .: "tag"
        cmd -> pure (Cmd cmd)

replay :: Handle -> IO ()
replay h = do
    hSetBuffering h LineBuffering
    let send = BL.hPutStrLn h . encode . object
        event :: Text -> [Pair] -> IO ()
        event name fields = send (("event" .= name) : fields)
        through wanted = do
            actual <- BS.hGetLine h >>= either fail pure . eitherDecodeStrict'
            if actual == wanted then pure [] else (actual :) <$> through wanted
        wait = void . through
        frame = object ["x" .= (0::Int), "y" .= (0::Int), "w" .= (1200::Int), "h" .= (800::Int)]
        create w p = event "window-created" ["windowId" .= (w::Int), "pid" .= (p::Int),
                                              "frame" .= frame, "appName" .= ("Ghostty"::Text)]
        destroy w = event "window-destroyed" ["windowId" .= (w::Int)]
        focusEvent name = event name ["windowId" .= (11::Int), "pid" .= (101::Int)]
        query = Cmd "query-focused-window"
        answer = focusEvent "focused-window-query-response"
        overlay = Cmd "set-overlay-state"
        quiet = do
            event "menu-toggle-debug" []
            effects <- through (Cmd "set-debug-overlays")
            unless (all (\case Cmd "hide-windows" -> True; _ -> False) effects) $
                fail ("An unsolicited focus change produced " ++ show effects)
    event "ready" []
    wait (Cmd "query-screens")
    event "screens-changed" ["screens" .= [object ["screenId" .= (0::Int), "role" .= ("primary"::Text), "frame" .= frame]]]
    wait (Cmd "query-windows")
    send ["response" .= ("windows"::Text), "windows" .= ([]::[Value])]
    wait (Cmd "set-debug-overlays")
    create 11 101 >> wait overlay
    event "menu-view-workspace" ["tag" .= ("r1"::Text)]
    wait (Workspace "r1") >> wait overlay
    create 12 101 >> wait overlay
    create 13 102 >> wait (Focus 13) >> wait overlay
    threadDelay 750000

    -- macOS has already handed focus to 11, on workspace 1. Window 12
    -- shares its PID and survives the close on r1.
    event "front-app-changed" ["pid" .= (101::Int)]
    wait query >> answer
    threadDelay 80000
    destroy 13
    effects <- through overlay
    unless (Focus 12 `elem` effects && Workspace "r1" `elem` effects &&
            Focus 11 `notElem` effects && Workspace "1" `notElem` effects) $
        fail ("Closing 13 should focus survivor 12 on r1. Observed " ++ show effects)
    threadDelay 300000
    quiet

    -- With the same two surviving windows, a deliberate app switch should
    -- still reach 11, even though 12 belongs to the same process on r1.
    event "user-mouse-down" []
    event "front-app-changed" ["pid" .= (101::Int)]
    wait query >> answer
    wait query >> answer
    wait (Focus 11) >> wait (Workspace "1") >> wait overlay
    event "menu-view-workspace" ["tag" .= ("r1"::Text)]
    wait (Focus 12) >> wait (Workspace "r1") >> wait overlay

    destroy 12
    wait (Workspace "r1") >> wait overlay
    threadDelay 750000
    focusEvent "focused-window-changed"
    threadDelay 300000
    quiet

    -- A physical click releases the empty-workspace guard. The first
    -- confirmation is empty, then a fresh activation succeeds.
    event "user-mouse-down" []
    focusEvent "focused-window-changed"
    wait query >> event "focused-window-query-empty" []
    quiet
    event "front-app-changed" ["pid" .= (101::Int)]
    wait query >> answer
    wait query >> answer
    wait (Focus 11) >> wait (Workspace "1") >> wait overlay
    putStrLn "Focus replay passed: local survivor, empty workspace, and deliberate activation."
