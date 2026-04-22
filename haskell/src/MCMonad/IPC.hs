{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

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
      -- * Event types (Swift -> Haskell)
    , Event(..)
    , WindowInfo(..)
    , ScreenInfo(..)
    ) where

import Control.Concurrent.MVar (withMVar, newMVar)
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
import System.IO (hSetBuffering, BufferMode(..), hFlush, IOMode(..))

import MCMonad.Core (Connection(..), Rectangle(..))

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
    deriving (Show, Generic)

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
        [ "cmd"     .= ("hide-windows" :: Text)
        , "windows" .= wids
        ]
    toJSON (ShowWindows wids) = Aeson.object
        [ "cmd"     .= ("show-windows" :: Text)
        , "windows" .= wids
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

-- ---------------------------------------------------------------------------
-- Events (Swift -> Haskell)

-- | Events received from the Swift daemon.
data Event
    = WindowCreated WindowInfo
    | WindowDestroyed !Word32
    | WindowFrameChanged !Word32 !Rectangle
    | FrontAppChanged !Int32
    | ScreensChanged [ScreenInfo]
    | HotkeyPressed !Int
    | MouseEnteredWindow !Word32 !Int32
    | Ready
    | QueryWindowsResponse [WindowInfo]
    | QueryScreensResponse [ScreenInfo]
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
                "screens-changed"      -> ScreensChanged     <$> v .: "screens"
                "hotkey-pressed"       -> HotkeyPressed      <$> v .: "hotkeyId"
                "mouse-entered-window" -> MouseEnteredWindow <$> v .: "windowId" <*> v .: "pid"
                "ready"                -> pure Ready
                other                  -> fail $ "Unknown event type: " ++ show other
            (_, Just resp) -> case resp of
                "windows" -> QueryWindowsResponse <$> v .: "windows"
                "screens" -> QueryScreensResponse <$> v .: "screens"
                other     -> fail $ "Unknown response type: " ++ show other
            _ -> fail "Message has neither 'event' nor 'response' key"

-- ---------------------------------------------------------------------------
-- Connection management

-- | Connect to the mcmonad-core Unix domain socket at
-- @~\/.config\/mcmonad\/core.sock@.
connectToCore :: IO Connection
connectToCore = do
    home <- getHomeDirectory
    let sockPath = home </> ".config" </> "mcmonad" </> "core.sock"
    sock <- socket AF_UNIX Stream defaultProtocol
    connect sock (SockAddrUnix sockPath)
    hdl <- socketToHandle sock ReadWriteMode
    hSetBuffering hdl LineBuffering
    lock <- newMVar ()
    return $ Connection hdl lock

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

