{-# LANGUAGE OverloadedStrings #-}

-- | Replay the wire protocol against the real event loop: a brain running
-- the default config in an isolated home, with this process in the
-- daemon's place on the other end of the socket.
module Replay
    ( replayMain
    , Brain
    , event
    , sendMessage
    , through
    , screenFrame
    , screenInfo
    , startEmpty
    ) where

import Control.Exception (bracket, finally)
import Control.Monad (unless, void)
import Data.Aeson
import Data.Aeson.Types (Pair, parseMaybe)
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

-- | The daemon's end of a connection to a running brain.
newtype Brain = Brain Handle

-- | Run a replay. The optional binary argument runs the same assertions
-- against the user's compiled config.
replayMain :: String -> (Brain -> IO ()) -> IO ()
replayMain name replay = getArgs >>= \args -> case args of
    ["--test-child"] -> mcmonad defaultConfig
    [] -> do
        self <- getExecutablePath
        isolated name replay (proc self ["--test-child"])
    [binary] -> isolated name replay (proc binary [])
    _ -> fail "Expected an optional compiled mcmonad binary to replay against."

isolated :: String -> (Brain -> IO ()) -> CreateProcess -> IO ()
isolated name replay child = do
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
                        bracket (socketToHandle client ReadWriteMode) hClose $ \h -> do
                            hSetBuffering h LineBuffering
                            replay (Brain h)
                    unless (result == Just ()) $ fail ("Brain timed out during the " ++ name ++ " replay.")

-- | Send one raw message to the brain.
sendMessage :: Brain -> [Pair] -> IO ()
sendMessage (Brain h) = BL.hPutStrLn h . encode . object

-- | Send one event to the brain.
event :: Brain -> Text -> [Pair] -> IO ()
event brain name fields = sendMessage brain (("event" .= name) : fields)

-- | Read the brain's commands up to and including the first that satisfies
-- the predicate, oldest first.
through :: FromJSON a => Brain -> (a -> Bool) -> IO [a]
through brain@(Brain h) wanted = do
    actual <- BS.hGetLine h >>= either fail pure . eitherDecodeStrict'
    if wanted actual then pure [actual] else (actual :) <$> through brain wanted

-- | The replay's one display.
screenFrame :: Value
screenFrame = object ["x" .= (0::Int), "y" .= (0::Int), "w" .= (1200::Int), "h" .= (800::Int)]

-- | How the daemon reports it.
screenInfo :: Value
screenInfo = object
    ["screenId" .= (0::Int), "role" .= ("primary"::Text), "frame" .= screenFrame]

-- | Answer the brain's startup handshake with one display and no windows.
-- Returns the commands it sent on the way, oldest first.
startEmpty :: Brain -> IO [Object]
startEmpty brain = do
    event brain "ready" []
    screens <- command "query-screens"
    event brain "screens-changed" ["screens" .= [screenInfo]]
    asked <- command "query-windows"
    sendMessage brain ["response" .= ("windows"::Text), "windows" .= ([]::[Value])]
    started <- command "set-debug-overlays"
    pure (screens ++ asked ++ started)
  where
    command :: Text -> IO [Object]
    command name = through brain (\o -> parseMaybe (.: "cmd") o == Just name)
