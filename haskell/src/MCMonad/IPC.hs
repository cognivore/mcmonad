{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module MCMonad.IPC
    ( -- * Connection
      Connection(..)
    , connectToCore
      -- * Sending and receiving
    , sendCommand
    , readEvent
      -- * Command types (Haskell -> Swift)
    , Command(..)
    , FrameAssignment(..)
    , HotkeySpec(..)
      -- * Overlay/menu snapshot
    , OverlaySnapshot(..)
    , OverlayScreenEntry(..)
    , OverlayHiddenWorkspace(..)
    , OverlayWindowEntry(..)
      -- * Event types (Swift -> Haskell)
    , Event(..)
    , WindowInfo(..)
    , ScreenInfo(..)
      -- * Metadata helpers
    , metadataFromInfo
      -- * Protocol versioning
    , protocolVersion
    ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (withMVar, newMVar)
import Control.Exception (IOException, catch)
import Data.Aeson ((.=), (.:), (.:?), (.!=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int32)
import Data.Text (Text)
import Data.Word (Word32, Word8)
import GHC.Generics (Generic)
import Network.Socket
import System.Directory (getHomeDirectory)
import System.FilePath ((</>))
import System.IO (hSetBuffering, BufferMode(..), hFlush, hPutStrLn, IOMode(..), stderr)

import MCMonad.Core (Connection(..), Rectangle(..), WindowMetadata(..), Timer(..))

-- ---------------------------------------------------------------------------
-- Protocol version

-- | IPC protocol version. Bump in lock-step with any wire-level change to
-- 'Event' or 'Command' (new variants, renamed fields, removed fields).
--
-- The launcher reads this from the bundled binary's
-- @Contents/Resources/protocol-version@ and from the custom binary's
-- @<binary>.proto@ sidecar (written by 'MCMonad.Operations.recompile')
-- and refuses to run a custom binary whose stamp does not match. That
-- guard prevents the crash-loop that happens when a Mod-q-compiled
-- binary lingers across an mcmonad upgrade and speaks the old protocol.
protocolVersion :: Int
protocolVersion = 10

-- ---------------------------------------------------------------------------
-- Commands (Haskell -> Swift)

-- | Commands sent from the Haskell brain to the Swift daemon.
data Command
    = SetFrames [FrameAssignment]
    | FocusWindow !Word32 !Int32
    | HideWindows [Word32]
    | ShowWindows [Word32]
    | QueryWindows
    | QueryScreens
    | RegisterHotkeys [HotkeySpec]
    | CloseWindow !Word32 !Int32
    | SetWorkspaceIndicator !String
    | WarpMouse !Double !Double
    | SetDebugOverlays !Bool
    | SetOverlayState !OverlaySnapshot
    | QueryFocusedWindow
      -- ^ Ask the daemon which window macOS currently considers focused
      -- (the frontmost app's AX focused window). Answered asynchronously
      -- with a 'FocusedWindowQueryResponse' event. Used by the
      -- "jump to the active window's workspace" hotkey: after a Dock
      -- click activates an app whose window lives on an off-screen
      -- workspace, mcmonad's StackSet focus has not followed (the
      -- resolve* helpers only act on the current workspace), so we have
      -- to ask macOS where focus actually is.
    | ShowWindowPicker
      -- ^ Ask the daemon to open the fuzzy window-search dropdown. The
      -- daemon owns the UI; selection comes back as a 'MenuFocusWindow'
      -- event, reusing the menubar dropdown's focus path.
    | ShowSpotlight !String
      -- ^ Ask the daemon to open the Spotlight launcher in a given mode
      -- (@"command"@ or @"window"@). Command mode runs the app launcher,
      -- timer, and voice input entirely inside mcmonad-core; window mode
      -- behaves like 'ShowWindowPicker'. @Tab@ cycles modes once open.
      -- Window selection returns as a 'MenuFocusWindow' event; app launch
      -- and timers are handled daemon-side and need no reply.
    | SetTimers [Timer]
      -- ^ Authoritative list of running countdown timers. The brain owns
      -- timer state and resends the whole list whenever it changes (and
      -- once on startup, to resume restored timers); the daemon renders
      -- the menubar countdown from it and fires reminders off its own
      -- clock. See 'MCMonad.Core.Timer' and 'MCMonad.Operations.pushTimers'.
    deriving (Show, Generic)

-- | One window entry in the menubar / debug overlay snapshot.
-- 'oweFrame' is the intended frame (top-left origin, same convention
-- as 'wiFrame').
data OverlayWindowEntry = OverlayWindowEntry
    { oweWindowId     :: !Word32
    , owePid          :: !Int32
    , oweAppName      :: !(Maybe Text)
    , oweTitle        :: !(Maybe Text)
    , oweBundleId     :: !(Maybe Text)
    , oweWorkspaceTag :: !(Maybe String)
    , oweFrame        :: !Rectangle
    , oweIsFocused    :: !Bool
    , oweIsFloating   :: !Bool
    } deriving (Show, Generic)

-- | A workspace visible on a specific screen.
data OverlayScreenEntry = OverlayScreenEntry
    { oseScreenId     :: !Int
    , oseFrame        :: !Rectangle
    , oseWorkspaceTag :: !String
    , oseWindows      :: ![OverlayWindowEntry]
    } deriving (Show, Generic)

-- | A workspace not currently displayed on any screen.
data OverlayHiddenWorkspace = OverlayHiddenWorkspace
    { ohwTag     :: !String
    , ohwWindows :: ![OverlayWindowEntry]
    } deriving (Show, Generic)

-- | Snapshot of the WindowSet, sent on every 'windows' call. Drives
-- both the menubar workspace tree and the debug overlay.
data OverlaySnapshot = OverlaySnapshot
    { osDebugOverlays    :: !Bool
    , osScreens          :: ![OverlayScreenEntry]
    , osHiddenWorkspaces :: ![OverlayHiddenWorkspace]
    } deriving (Show, Generic)

instance Aeson.ToJSON OverlayWindowEntry where
    toJSON OverlayWindowEntry{..} = Aeson.object
        [ "windowId"     .= oweWindowId
        , "pid"          .= owePid
        , "appName"      .= oweAppName
        , "title"        .= oweTitle
        , "bundleId"     .= oweBundleId
        , "workspaceTag" .= oweWorkspaceTag
        , "frame"        .= oweFrame
        , "isFocused"    .= oweIsFocused
        , "isFloating"   .= oweIsFloating
        ]

instance Aeson.ToJSON OverlayScreenEntry where
    toJSON OverlayScreenEntry{..} = Aeson.object
        [ "screenId"     .= oseScreenId
        , "frame"        .= oseFrame
        , "workspaceTag" .= oseWorkspaceTag
        , "windows"      .= oseWindows
        ]

instance Aeson.ToJSON OverlayHiddenWorkspace where
    toJSON OverlayHiddenWorkspace{..} = Aeson.object
        [ "tag"     .= ohwTag
        , "windows" .= ohwWindows
        ]

instance Aeson.ToJSON OverlaySnapshot where
    toJSON OverlaySnapshot{..} = Aeson.object
        [ "debugOverlays"    .= osDebugOverlays
        , "screens"          .= osScreens
        , "hiddenWorkspaces" .= osHiddenWorkspaces
        ]

-- | A frame assignment: position a specific window at a specific rectangle.
data FrameAssignment = FrameAssignment
    { faWindowId :: !Word32
    , faPid      :: !Int32
    , faFrame    :: !Rectangle
    } deriving (Show, Generic)

-- | A hotkey registration specification.
data HotkeySpec = HotkeySpec
    { hsId        :: !Int
    , hsKeyCode   :: !Word32
    , hsModifiers :: !Word32
    } deriving (Show, Generic)

instance Aeson.ToJSON FrameAssignment where
    toJSON (FrameAssignment wid pid frame) = Aeson.object
        [ "windowId" .= wid
        , "pid"      .= pid
        , "frame"    .= frame
        ]

instance Aeson.ToJSON HotkeySpec where
    toJSON (HotkeySpec hid kc mods) = Aeson.object
        [ "id"        .= hid
        , "keyCode"   .= kc
        , "modifiers" .= mods
        ]

instance Aeson.ToJSON Command where
    toJSON (SetFrames frames) = Aeson.object
        [ "cmd"    .= ("set-frames" :: Text)
        , "frames" .= frames
        ]
    toJSON (FocusWindow wid pid) = Aeson.object
        [ "cmd"      .= ("focus-window" :: Text)
        , "windowId" .= wid
        , "pid"      .= pid
        ]
    toJSON (HideWindows wids) = Aeson.object
        [ "cmd"       .= ("hide-windows" :: Text)
        , "windowIds" .= wids
        ]
    toJSON (ShowWindows wids) = Aeson.object
        [ "cmd"       .= ("show-windows" :: Text)
        , "windowIds" .= wids
        ]
    toJSON QueryWindows = Aeson.object
        [ "cmd" .= ("query-windows" :: Text)
        ]
    toJSON QueryScreens = Aeson.object
        [ "cmd" .= ("query-screens" :: Text)
        ]
    toJSON (RegisterHotkeys specs) = Aeson.object
        [ "cmd"     .= ("register-hotkeys" :: Text)
        , "hotkeys" .= specs
        ]
    toJSON (CloseWindow wid pid) = Aeson.object
        [ "cmd"      .= ("close-window" :: Text)
        , "windowId" .= wid
        , "pid"      .= pid
        ]
    toJSON (SetWorkspaceIndicator tag) = Aeson.object
        [ "cmd" .= ("set-workspace-indicator" :: Text)
        , "tag" .= tag
        ]
    toJSON (WarpMouse x y) = Aeson.object
        [ "cmd" .= ("warp-mouse" :: Text)
        , "x"   .= x
        , "y"   .= y
        ]
    toJSON (SetDebugOverlays on) = Aeson.object
        [ "cmd" .= ("set-debug-overlays" :: Text)
        , "on"  .= on
        ]
    toJSON (SetOverlayState snap) = Aeson.object
        [ "cmd"      .= ("set-overlay-state" :: Text)
        , "snapshot" .= snap
        ]
    toJSON QueryFocusedWindow = Aeson.object
        [ "cmd" .= ("query-focused-window" :: Text)
        ]
    toJSON ShowWindowPicker = Aeson.object
        [ "cmd" .= ("show-window-picker" :: Text)
        ]
    toJSON (ShowSpotlight mode) = Aeson.object
        [ "cmd"  .= ("show-spotlight" :: Text)
        , "mode" .= mode
        ]
    toJSON (SetTimers ts) = Aeson.object
        [ "cmd"    .= ("set-timers" :: Text)
        , "timers" .= map timerJSON ts
        ]

-- | Wire encoding of one 'Timer'. 'tmFireAt' is absolute POSIX epoch
-- seconds so the daemon's countdown matches @Date().timeIntervalSince1970@.
timerJSON :: Timer -> Aeson.Value
timerJSON t = Aeson.object
    [ "id"        .= tmId t
    , "label"     .= tmLabel t
    , "fireAt"    .= tmFireAt t
    , "workspace" .= tmWorkspace t
    ]

-- ---------------------------------------------------------------------------
-- Events (Swift -> Haskell)

-- | Events received from the Swift daemon.
data Event
    = WindowCreated WindowInfo
    | WindowDestroyed !Word32
    | WindowFrameChanged !Word32 !Rectangle
    | FrontAppChanged !Int32
    | FocusedWindowChanged !Word32 !Int32
    | FocusedWindowQueryResponse !Word32 !Int32
      -- ^ Reply to 'QueryFocusedWindow': the window macOS currently
      -- considers focused. Distinct from 'FocusedWindowChanged' so it
      -- bypasses the 'focusIntent' bounce-suppression dispatch and is
      -- always acted on (it is a direct answer to our own question).
    | ScreensChanged [ScreenInfo]
    | HotkeyPressed !Int
    | MouseEnteredWindow !Word32 !Int32
    | WindowDragCompleted !Word32 !Int32 !Rectangle
    | UserMouseDown
      -- ^ A global mouse-down event fired somewhere on the system.
      -- Surfaced by 'MouseDownMonitor' in mcmonad-core. Used by the
      -- focus-event dispatch as a "user intent has just happened"
      -- signal: any 'focusIntent' in flight is cleared so the AX /
      -- NSWorkspace notification that follows the click is treated as
      -- authoritative rather than a bounce echo.
    | MenuToggleDebug
    | MenuFocusWindow !Word32 !Int32
    | MenuViewWorkspace !String
    | TimerStart !Double !String
      -- ^ Start a fresh countdown from the Spotlight launcher: @seconds@,
      -- @label@. The brain stamps the current workspace as the origin and
      -- journals a @started@ event.
    | TimerSnooze !Double !String !String
      -- ^ Re-arm a fired timer from its reminder card: @seconds@, @label@,
      -- and the original origin @workspace@ (carried forward, not the
      -- current one). Journals a @snoozed@ event. Split from 'TimerStart'
      -- so the journal can tell a fresh timer from a snooze.
    | TimerFired !Int
      -- ^ The daemon's clock reached a timer's deadline (by id). The brain
      -- journals @fired@ and drops it from state so it can't resurrect.
    | TimerCancel !Int
      -- ^ The user cancelled a still-running timer from the menubar (by id).
      -- Journals @cancelled@.
    | TimerCancelAll
      -- ^ The user cancelled every running timer from the menubar. Journals
      -- one @cancelled@ per timer.
    | TimerDismiss !String !String
      -- ^ The user clicked Dismiss on a reminder card: @label@, @workspace@.
      -- The timer is already gone from state (it fired), so the card carries
      -- its own data. Journals @dismissed@; no state change.
    | TimerJump !String !String
      -- ^ The user clicked "Jump to workspace" on a reminder card: @label@,
      -- origin @workspace@. The brain switches to that workspace and journals
      -- @jumped@. (Distinct from 'MenuViewWorkspace' so the journal can
      -- attribute the switch to a timer.)
    | Ready
    | QueryWindowsResponse [WindowInfo]
    | QueryScreensResponse [ScreenInfo]
    | IgnoredEvent !Text
      -- ^ A wire message we cannot decode as a known event or response.
      -- Produced by the parser instead of failing, so an IPC version
      -- skew (or a future event variant a stale binary doesn't know
      -- about) drops a single message rather than killing the loop.
    deriving (Show, Generic)

-- | Information about a window, received from the Swift daemon.
data WindowInfo = WindowInfo
    { wiWindowId            :: !Word32
    , wiPid                 :: !Int32
    , wiTitle               :: !(Maybe Text)
    , wiAppName             :: !(Maybe Text)
    , wiBundleId            :: !(Maybe Text)
    , wiSubrole             :: !(Maybe Text)
    , wiIsDialog            :: !Bool
    , wiIsFixedSize         :: !Bool
    , wiHasCloseButton      :: !Bool
    , wiHasFullscreenButton :: !Bool
    , wiFrame               :: !Rectangle
    } deriving (Show, Generic)

-- | Information about a screen/display.
data ScreenInfo = ScreenInfo
    { siScreenId :: !Int
    , siFrame    :: !Rectangle
    } deriving (Show, Generic)

-- | Project the metadata subset of a 'WindowInfo' for caching in the
-- 'MCMonad.Core.MState' window-metadata map.
metadataFromInfo :: WindowInfo -> WindowMetadata
metadataFromInfo wi = WindowMetadata
    { wmAppName  = wiAppName wi
    , wmTitle    = wiTitle wi
    , wmBundleId = wiBundleId wi
    , wmSubrole  = wiSubrole wi
    }

instance Aeson.FromJSON WindowInfo where
    parseJSON = Aeson.withObject "WindowInfo" $ \v -> WindowInfo
        <$> v .:  "windowId"
        <*> v .:  "pid"
        <*> v .:? "title"
        <*> v .:? "appName"
        <*> v .:? "bundleId"
        <*> v .:? "subrole"
        <*> v .:? "isDialog"    .!= False
        <*> v .:? "isFixedSize" .!= False
        <*> v .:? "hasCloseButton"      .!= True
        <*> v .:? "hasFullscreenButton" .!= True
        <*> v .:  "frame"

instance Aeson.FromJSON ScreenInfo where
    parseJSON = Aeson.withObject "ScreenInfo" $ \v -> ScreenInfo
        <$> v .: "screenId"
        <*> v .: "frame"

instance Aeson.FromJSON Event where
    parseJSON = Aeson.withObject "Event" $ \v -> do
        -- Swift sends events with "event" key and query responses with "response" key
        let tryEvent = v .:? "event" :: Aeson.Parser (Maybe Text)
            tryResponse = v .:? "response" :: Aeson.Parser (Maybe Text)
        mEvt <- tryEvent
        mResp <- tryResponse
        case (mEvt, mResp) of
            (Just evt, _) -> case evt of
                "window-created"       -> WindowCreated      <$> Aeson.parseJSON (Aeson.Object v)
                "window-destroyed"     -> WindowDestroyed    <$> v .: "windowId"
                "window-frame-changed" -> WindowFrameChanged <$> v .: "windowId" <*> v .: "frame"
                "front-app-changed"    -> FrontAppChanged    <$> v .: "pid"
                "focused-window-changed" -> FocusedWindowChanged <$> v .: "windowId" <*> v .: "pid"
                "focused-window-query-response" -> FocusedWindowQueryResponse <$> v .: "windowId" <*> v .: "pid"
                "screens-changed"      -> ScreensChanged     <$> v .: "screens"
                "hotkey-pressed"       -> HotkeyPressed      <$> v .: "hotkeyId"
                "mouse-entered-window" -> MouseEnteredWindow <$> v .: "windowId" <*> v .: "pid"
                "window-drag-completed" -> WindowDragCompleted <$> v .: "windowId" <*> v .: "pid" <*> v .: "frame"
                "user-mouse-down"      -> pure UserMouseDown
                "menu-toggle-debug"    -> pure MenuToggleDebug
                "menu-focus-window"    -> MenuFocusWindow <$> v .: "windowId" <*> v .: "pid"
                "menu-view-workspace"  -> MenuViewWorkspace <$> v .: "tag"
                "timer-start"          -> TimerStart <$> v .: "seconds" <*> v .: "label"
                "timer-snooze"         -> TimerSnooze <$> v .: "seconds" <*> v .: "label" <*> v .: "workspace"
                "timer-fired"          -> TimerFired <$> v .: "id"
                "timer-cancel"         -> TimerCancel <$> v .: "id"
                "timer-cancel-all"     -> pure TimerCancelAll
                "timer-dismiss"        -> TimerDismiss <$> v .: "label" <*> v .: "workspace"
                "timer-jump"           -> TimerJump <$> v .: "label" <*> v .: "workspace"
                "ready"                -> pure Ready
                other                  -> pure (IgnoredEvent other)
            (_, Just resp) -> case resp of
                "windows" -> QueryWindowsResponse <$> v .: "windows"
                "screens" -> QueryScreensResponse <$> v .: "screens"
                other     -> pure (IgnoredEvent ("response:" <> other))
            _ -> pure (IgnoredEvent "<no event or response key>")

-- ---------------------------------------------------------------------------
-- Connection management

-- | Connect to the mcmonad-core Unix domain socket at
-- @~\/.config\/mcmonad\/core.sock@.  Retries with exponential backoff
-- (up to ~30 s between attempts) so the Haskell side can start before
-- mcmonad-core has created its socket.
connectToCore :: IO Connection
connectToCore = do
    home <- getHomeDirectory
    let sockPath = home </> ".config" </> "mcmonad" </> "core.sock"
    go sockPath (500 * 1000)  -- start at 500 ms
  where
    maxDelay = 30 * 1000 * 1000  -- 30 s ceiling

    go sockPath delay = do
        result <- tryConnect sockPath
        case result of
            Right conn -> return conn
            Left err   -> do
                hPutStrLn stderr $
                    "mcmonad: waiting for core socket (" ++ show err ++ "), retrying in "
                    ++ show (delay `div` 1000000) ++ "s"
                threadDelay delay
                go sockPath (min (delay * 2) maxDelay)

    tryConnect :: FilePath -> IO (Either IOException Connection)
    tryConnect sockPath =
        (do sock <- socket AF_UNIX Stream defaultProtocol
            connect sock (SockAddrUnix sockPath)
            hdl <- socketToHandle sock ReadWriteMode
            hSetBuffering hdl LineBuffering
            lock <- newMVar ()
            return $ Right $ Connection hdl lock
        ) `catch` (\e -> return (Left e))

-- | Send a command to the Swift daemon as a JSON line.
sendCommand :: Connection -> Command -> IO ()
sendCommand conn cmd = do
    let encoded = LBS.toStrict (Aeson.encode cmd) <> BS.singleton newline
    withMVar (connLock conn) $ \() -> do
        -- We use the handle for sending as well to keep things simple.
        -- The lock ensures only one writer at a time.
        BS.hPut (connHandle conn) encoded
        hFlush (connHandle conn)
  where
    newline :: Word8
    newline = 0x0A

-- | Read one event from the Swift daemon. Blocks until a complete JSON line
-- is available. Throws on parse failure or connection loss.
readEvent :: Connection -> IO Event
readEvent conn = do
    line <- BS8.hGetLine (connHandle conn)
    case Aeson.eitherDecodeStrict' line of
        Left err  -> fail $ "Failed to decode event: " ++ err
                            ++ "\nRaw: " ++ show line
        Right evt -> return evt

