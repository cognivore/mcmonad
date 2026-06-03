{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

module MCMonad.Core
    ( -- * The M monad
      M(..), MState(..), MConf(..)
    , runM, catchM, userCode, userCodeDef
    , io, withConnection, withWindowSet
      -- * Re-exports for convenience
    , gets, modify, asks, MonadIO(..)
      -- * Window and screen types
    , WindowRef(..), ScreenId(..), ScreenDetail(..)
    , WindowSet, WindowSpace
      -- * Window metadata cache
    , WindowMetadata(..)
      -- * Layout system
    , Layout(..)
    , LayoutClass(..)
    , SomeMessage, Message, fromMessage, someMessage
      -- * Layout messages (re-exported from xmonad)
    , Resize(..), IncMasterN(..)
    , ChangeLayout(..)
      -- * Geometry
    , Rectangle(..)
      -- * IPC connection (opaque)
    , Connection(..)
      -- * Affinity
    , updateAffinities
      -- * Focus resolution
    , resolveFocusedWindow
    , resolveFrontApp
      -- * Bounce suppression
    , Refocus(..)
    , armingRefocus
    , isFocusBounce
    , isFrontAppBounce
    , consumeRefocus
    ) where

import Control.Concurrent.MVar
import Control.Exception (SomeException, catch)
import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.Aeson (FromJSON(..), ToJSON(..), (.=), (.:))
import qualified Data.Aeson as Aeson
import Data.Int (Int32)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.Typeable (Typeable, cast)
import Data.Word (Word8, Word32)
import GHC.Generics (Generic)
import System.IO (Handle)
import qualified XMonad.Core as XMonad
import qualified XMonad.Layout as XMonad (Resize(..), IncMasterN(..), ChangeLayout(..))
import qualified XMonad.StackSet as W

-- ---------------------------------------------------------------------------
-- Window identifier for macOS

-- | A reference to a macOS window, identified by its CGWindowID and owning PID.
--
-- This is the *only* identity mcmonad uses. The CGWindowID is assigned by
-- macOS's WindowServer and is stable for the lifetime of the WindowServer
-- session — which spans Mod-q recompiles, mcmonad-core daemon restarts,
-- launchd kicks, and any other restart of mcmonad's own processes. The
-- PID is stable for the lifetime of the owning app. Together they
-- uniquely identify a live window.
--
-- On logout / reboot, the WindowServer dies and the apps die with it.
-- The windows that come back after login are *new* objects in new
-- processes with new identities. mcmonad does not attempt to bridge
-- across that gap; the manage hook is the sole mechanism for placing
-- newly-created windows on workspaces.
data WindowRef = WindowRef
    { wrWindowId :: !Word32
    , wrPid      :: !Int32
    } deriving (Eq, Ord, Show, Read, Generic)

-- | Cached subset of 'MCMonad.IPC.WindowInfo' kept per managed window,
-- so 'MCMonad.Operations.windows' can build snapshots without making
-- the daemon re-query AX for every layout pass. Updated by the
-- 'WindowCreated' event handler and torn down by 'WindowDestroyed'.
data WindowMetadata = WindowMetadata
    { wmAppName  :: !(Maybe Text)
    , wmTitle    :: !(Maybe Text)
    , wmBundleId :: !(Maybe Text)
    , wmSubrole  :: !(Maybe Text)
    } deriving (Eq, Show, Read, Generic)

instance FromJSON WindowRef where
    parseJSON = Aeson.withObject "WindowRef" $ \v ->
        WindowRef <$> v .: "windowId" <*> v .: "pid"

instance ToJSON WindowRef where
    toJSON (WindowRef wid pid) =
        Aeson.object ["windowId" .= wid, "pid" .= pid]

-- Hashable-like hashing for use as Map keys. WindowRef already derives Ord,
-- which is sufficient for Map/Set usage.

-- ---------------------------------------------------------------------------
-- Screen types

-- | Screen identifier.
newtype ScreenId = S Int
    deriving (Eq, Ord, Show, Read, Enum, Num, Integral, Real)

-- | Physical screen geometry.
data ScreenDetail = SD { screenRect :: !Rectangle }
    deriving (Eq, Show, Read)

-- ---------------------------------------------------------------------------
-- Geometry

-- | A rectangle in macOS screen coordinates (origin top-left, doubles).
data Rectangle = Rectangle
    { rect_x :: !Double
    , rect_y :: !Double
    , rect_w :: !Double
    , rect_h :: !Double
    } deriving (Eq, Show, Read, Generic)

instance FromJSON Rectangle where
    parseJSON = Aeson.withObject "Rectangle" $ \v ->
        Rectangle <$> v .: "x" <*> v .: "y" <*> v .: "w" <*> v .: "h"

instance ToJSON Rectangle where
    toJSON (Rectangle x y w h) =
        Aeson.object ["x" .= x, "y" .= y, "w" .= w, "h" .= h]

-- ---------------------------------------------------------------------------
-- Message system

-- | Message system: reuse xmonad's directly so xmonad-contrib layouts work.
type Message = XMonad.Message
type SomeMessage = XMonad.SomeMessage
type Resize = XMonad.Resize
type IncMasterN = XMonad.IncMasterN
type ChangeLayout = XMonad.ChangeLayout

fromMessage :: XMonad.Message a => SomeMessage -> Maybe a
fromMessage = XMonad.fromMessage

someMessage :: XMonad.Message a => a -> SomeMessage
someMessage = XMonad.SomeMessage

-- ---------------------------------------------------------------------------
-- Layout system

-- | The layout typeclass. Mirrors xmonad's LayoutClass but uses 'M' instead of 'X'.
class (Show (layout a), Typeable layout) => LayoutClass layout a where

    -- | Run the layout on a workspace. Default delegates to 'doLayout' or
    -- 'emptyLayout' depending on whether the stack is empty.
    runLayout :: W.Workspace String (layout a) a -> Rectangle
              -> M ([(a, Rectangle)], Maybe (layout a))
    runLayout (W.Workspace _ l s) r = maybe (emptyLayout l r) (doLayout l r) s

    -- | Lay out windows given a stack. Default wraps 'pureLayout'.
    doLayout :: layout a -> Rectangle -> W.Stack a
             -> M ([(a, Rectangle)], Maybe (layout a))
    doLayout l r s = return (pureLayout l r s, Nothing)

    -- | Pure version of layout. Default gives every window the full rectangle.
    pureLayout :: layout a -> Rectangle -> W.Stack a -> [(a, Rectangle)]
    pureLayout _ r s = [(W.focus s, r)]

    -- | Handle the case when the workspace is empty. Default returns no windows.
    emptyLayout :: layout a -> Rectangle
                -> M ([(a, Rectangle)], Maybe (layout a))
    emptyLayout _ _ = return ([], Nothing)

    -- | Handle a message. Default wraps 'pureMessage'.
    handleMessage :: layout a -> SomeMessage -> M (Maybe (layout a))
    handleMessage l m = return (pureMessage l m)

    -- | Pure version of message handling. Default ignores all messages.
    pureMessage :: layout a -> SomeMessage -> Maybe (layout a)
    pureMessage _ _ = Nothing

    -- | Human-readable description of the layout.
    description :: layout a -> String
    description = show

-- | Existential wrapper for layouts, allowing different layout types to be
-- stored in the same StackSet.
data Layout a = forall l. (LayoutClass l a, Read (l a)) => Layout (l a)

instance Show (Layout a) where
    show (Layout l) = show l

instance LayoutClass Layout WindowRef where
    runLayout (W.Workspace tag (Layout l) s) r =
        fmap (fmap (fmap Layout)) $ runLayout (W.Workspace tag l s) r
    doLayout (Layout l) r s = fmap (fmap (fmap Layout)) $ doLayout l r s
    pureLayout (Layout l) = pureLayout l
    emptyLayout (Layout l) r = fmap (fmap (fmap Layout)) $ emptyLayout l r
    handleMessage (Layout l) m = fmap (fmap Layout) $ handleMessage l m
    pureMessage (Layout l) m = Layout <$> pureMessage l m
    description (Layout l) = description l

-- We need a Read instance for Layout to satisfy StackSet constraints.
-- In practice it is never used (state is not serialized via Read/Show).
instance Read (Layout a) where
    readsPrec _ _ = []

-- ---------------------------------------------------------------------------
-- The WindowSet — xmonad's StackSet instantiated with our types

-- | The complete window manager state: all workspaces, screens, and windows.
type WindowSet = W.StackSet String (Layout WindowRef) WindowRef ScreenId ScreenDetail

-- | A single workspace.
type WindowSpace = W.Workspace String (Layout WindowRef) WindowRef

-- ---------------------------------------------------------------------------
-- IPC connection

-- | A connection to the mcmonad-core Swift daemon over a Unix socket.
data Connection = Connection
    { connHandle :: !Handle
    , connLock   :: !(MVar ())
    }

-- ---------------------------------------------------------------------------
-- The M monad

-- | Mutable window manager state.
data MState = MState
    { windowset         :: !WindowSet
    , mapped            :: !(Set WindowRef)
    , affinity          :: !(Map.Map String ScreenId)
    , inputMode         :: !String
      -- ^ Current input mode (\"default\", \"resize\", etc.).
    , sticky            :: !(Set WindowRef)
      -- ^ Windows that follow focus across workspace switches.
    , scratchpads       :: !(Map.Map String WindowRef)
      -- ^ Named scratchpad windows (name -> window ref).
    , scratchpadRects   :: !(Map.Map String W.RationalRect)
      -- ^ Last known geometry of each scratchpad, saved on hide so it
      -- can be restored on the next show (preserves user resizes).
    , pendingScratchpad :: !(Maybe String)
      -- ^ When set, the next window created is registered as this scratchpad.
    , windowRects      :: !(Map.Map WindowRef Rectangle)
      -- ^ Last known positions of all visible windows (from the most recent
      -- layout pass). Used for directional focus navigation.
    , warpOnSwitch     :: !Bool
      -- ^ Whether to warp the mouse cursor to the focused window on
      -- workspace\/screen changes. Set from config at startup.
    , windowMetadata   :: !(Map.Map WindowRef WindowMetadata)
      -- ^ Cached app/title/bundle metadata for every managed window.
      -- Populated by 'WindowCreated' (and the startup window-enumeration
      -- path), torn down by 'WindowDestroyed'. Used by 'windows' to
      -- build the OverlaySnapshot that drives the menubar workspace
      -- tree and the debug overlay. Without this cache the snapshot
      -- could only carry @(wid, pid)@; 'WindowInfo' is discarded by
      -- 'manage' after the manage hook runs.
    , debugOverlays    :: !Bool
      -- ^ Whether to draw debug frame overlays. Off by default. Toggled
      -- by 'MCMonad.Debug.toggleDebugOverlays' (either from xmonad.hs
      -- or the menubar's "Debug frame overlays" item).
    , lastSaveAt       :: !(Maybe UTCTime)
      -- ^ Wall clock of the most recent 'MCMonad.Operations.saveStateIO'
      -- call. The 'windows' transition skips its post-mutation save when
      -- this is set and less than the throttle window has elapsed, so a
      -- burst of focus-follows-mouse or other rapid state changes
      -- doesn't fan out to a save per call. 'restart' bypasses the
      -- throttle so a Mod-q reload still writes the freshest snapshot
      -- before 'exec'.
    , recentRefocus    :: !(Maybe Refocus)
      -- ^ Bounce-suppression state. Set by 'MCMonad.Operations.windows'
      -- after every inter-app focus change to the @(from, to)@ pair plus
      -- a small countdown; cleared by the event-handler path once the
      -- expected AX + NSWorkspace echo has been absorbed (or once any
      -- non-bounce focus event arrives). See the 'Refocus' note above.
    }

-- | Read-only environment for the M monad. Parameterised over the config's
-- layout type, but the connection and resolved config are always present.
data MConf = MConf
    { connection :: !Connection
    }

-- | The M monad: ReaderT for config/connection, StateT for window manager state,
-- IO at the bottom. This mirrors xmonad's X monad but communicates with a
-- Swift daemon instead of X11.
newtype M a = M (ReaderT MConf (StateT MState IO) a)
    deriving (Functor, Applicative, Monad, MonadIO,
              MonadState MState, MonadReader MConf)

-- | Run an M action with the given config and initial state.
runM :: MConf -> MState -> M a -> IO (a, MState)
runM conf st (M m) = runStateT (runReaderT m conf) st

-- | Exception isolation: try the first action, fall back to the second.
-- Same pattern as xmonad's catchX.
catchM :: M a -> M a -> M a
catchM (M primary) (M fallback) = M $ ReaderT $ \conf -> StateT $ \st -> do
    runStateT (runReaderT primary conf) st
        `catch` \(_ :: SomeException) ->
            runStateT (runReaderT fallback conf) st

-- | Run user code, catching any exceptions. Returns Nothing on failure.
userCode :: M a -> M (Maybe a)
userCode act = catchM (Just <$> act) (return Nothing)

-- | Run user code with a default value on failure.
userCodeDef :: a -> M a -> M a
userCodeDef defVal act = catchM act (return defVal)

-- | Convenient alias for 'liftIO'.
io :: MonadIO m => IO a -> m a
io = liftIO

-- | Access the IPC connection.
withConnection :: (Connection -> M a) -> M a
withConnection f = asks connection >>= f

-- | Access the current window set.
withWindowSet :: (WindowSet -> M a) -> M a
withWindowSet f = gets windowset >>= f

-- ---------------------------------------------------------------------------
-- Affinity tracking

-- | Record current workspace-to-screen associations. Visible workspaces
-- get their screen recorded; hidden workspaces retain their previous affinity.
updateAffinities :: Ord i => W.StackSet i l a sid sd -> Map.Map i sid -> Map.Map i sid
updateAffinities ws existing =
    Map.union current existing
  where
    current = Map.fromList
        [ (W.tag (W.workspace scr), W.screen scr)
        | scr <- W.current ws : W.visible ws
        ]

-- ---------------------------------------------------------------------------
-- Focus resolution
--
-- These pure helpers translate a focus-change *signal* from Swift (either
-- a precise AX-derived (wid, pid) or a PID-only NSWorkspace/SkyLight
-- frontmost-app change) into a state transition on the 'WindowSet'. They
-- live here so the bug-prone PID-only path can be exercised by tests
-- alongside the precise per-window path.

-- | Windows on the current workspace's stack — and *only* the
-- current workspace.
--
-- macOS-originated focus events fire for an enormous number of
-- reasons we can't disambiguate from the user's intent: a background
-- tab repaint, a network callback, an app deactivating as a side
-- effect of *our own* 'FocusWindow' command. The 'NSWorkspace'
-- frontmost-app notification fires when an app activates, including
-- as the immediate side effect of macOS opening a new window of
-- that app.
--
-- An earlier version of these helpers used 'W.allWindows', which let
-- a hidden-workspace window claim focus and silently dragged the
-- current screen there via 'W.focusWindow''s implicit 'view' call.
-- The next iteration used a 'visibleWindows' helper that included
-- the secondary screen's workspace — still wrong, because the same
-- spurious AX events still pulled focus onto the *other* monitor
-- (the Mod-j-cycles-out-to-the-other-screen bug; the
-- new-Ghostty-tab-lands-on-the-wrong-screen bug, where 'resolveFrontApp'
-- ran first on a hidden Ghostty and swapped screens before the
-- 'windowCreated' arrived and inserted the new tab on the now-current
-- workspace).
--
-- Restricting to the current workspace is the safe rule: AX can fire
-- for whatever, we only act when the implied focus target is already
-- on the screen the user is looking at. Cross-screen focus follows
-- through 'MouseEnteredWindow' instead — that's bounded to actual
-- mouse-enter events, not AX cascades.
currentWorkspaceWindows :: W.StackSet i l a sid sd -> [a]
currentWorkspaceWindows ws =
    W.integrate' (W.stack (W.workspace (W.current ws)))

-- | Resolve focus from a precise AX focused-window-changed event.
--
-- Returns the updated StackSet when the target window is on the
-- *current* workspace and isn't already focused; 'Nothing' otherwise
-- (no-op).
--
-- This is the path that fixes the multi-window-per-app focus bug
-- within a workspace: the AX observer reports the *exact* CGWindowID
-- the user activated, so we never have to guess among windows that
-- share a PID on the focused workspace.
--
-- The current-workspace restriction (see 'currentWorkspaceWindows')
-- means AX events never cause cross-screen swaps. Cross-screen focus
-- is the job of 'MouseEnteredWindow'.
--
-- Polymorphic in the StackSet type parameters so the test suite (which
-- uses @Int@ for the layout slot) can exercise this directly.
resolveFocusedWindow
    :: (Eq i, Eq sid)
    => Word32 -> Int32
    -> W.StackSet i l WindowRef sid sd
    -> Maybe (W.StackSet i l WindowRef sid sd)
resolveFocusedWindow wid pid ws =
    case find match (currentWorkspaceWindows ws) of
        Just wr | W.peek ws /= Just wr -> Just (W.focusWindow wr ws)
        _                              -> Nothing
  where
    match w = wrWindowId w == wid && wrPid w == pid

-- | Resolve focus from a PID-only front-app-changed event.
--
-- Returns the updated StackSet only when the user actually switched to
-- a *different* app *and* that app has a window on the current
-- workspace. When focus is already inside that app, we leave it
-- alone. When the app's windows are all on other workspaces (hidden
-- or visible-secondary), we no-op — same reason as
-- 'resolveFocusedWindow'.
resolveFrontApp
    :: (Eq i, Eq sid)
    => Int32
    -> W.StackSet i l WindowRef sid sd
    -> Maybe (W.StackSet i l WindowRef sid sd)
resolveFrontApp pid ws = case W.peek ws of
    Just w | wrPid w == pid -> Nothing
    _ -> case find ((== pid) . wrPid) (currentWorkspaceWindows ws) of
        Just wr -> Just (W.focusWindow wr ws)
        Nothing -> Nothing

-- ---------------------------------------------------------------------------
-- AX/NSWorkspace bounce suppression
--
-- When 'MCMonad.Operations.windows' issues a cross-app focus change, macOS
-- reliably fires a transient second wave of focus notifications for the
-- previously-focused window of the previously-focused app, even though the
-- four-step SLPS focus protocol on mcmonad-core just succeeded for the new
-- target. AX delivers a 'kAXFocusedWindowChangedNotification' for the old
-- window; NSWorkspace delivers a 'didActivateApplicationNotification' for
-- the old app. Both fire within a runloop tick of mcmonad's command. The
-- root cause is macOS' internal focus-settling: the previous app briefly
-- regains focus before macOS finalises on the new target. AX does not
-- distinguish "user intent" from "internal bounce echo" — every focus
-- transition is reported.
--
-- A naive "follow AX" policy walks the StackSet's focus straight back onto
-- the previously-focused window. The user's next 'Mod-J' / 'Mod-K' then
-- cycles from the wrong starting point, which manifests as "focus
-- switching stops working for a little bit".
--
-- The fix is single-shot bounce suppression. 'windows' arms 'Refocus'
-- describing the inter-app focus change it just performed; the event
-- handlers test arriving AX/NSWorkspace events against that signature and
-- drop matching ones, re-issuing the 'FocusWindow' command so macOS is
-- pushed back onto the target rather than left in its bounced state.
-- A small countdown guards against pathological multi-bounce behaviour
-- (the empirically-observed pair is one AX + one NSWorkspace event).
--
-- Intra-app focus changes do not arm 'Refocus': AX is per-PID and does
-- not fire echo events when the focused window of an app changes within
-- the app, so there is nothing to suppress.

-- | What kind of focus change 'windows' just performed, recorded so the
-- next AX\/NSWorkspace event burst can be filtered. 'rfFrom' is the
-- previous focus (the window AX is about to echo for); 'rfTo' is the
-- new focus (the window we want macOS to land on).
data Refocus = Refocus
    { rfFrom              :: !WindowRef
    , rfTo                :: !WindowRef
    , rfPendingBounces    :: !Word8
    } deriving (Eq, Show, Read, Generic)

-- | Number of bounce events expected per cross-app refocus: one
-- 'kAXFocusedWindowChangedNotification' from the previous app's AX
-- observer, plus one 'didActivateApplicationNotification' from
-- NSWorkspace. Initial 'rfPendingBounces' is set to this.
defaultBounceBudget :: Word8
defaultBounceBudget = 2

-- | Build a 'Refocus' from the focus state before and after a 'windows'
-- transition. Returns 'Just' only for inter-app changes (the only case
-- where macOS bounces); returns 'Nothing' for intra-app changes,
-- focus-cleared transitions, and no-op transitions. Callers should
-- overwrite 'recentRefocus' with this value unconditionally — passing
-- 'Nothing' through 'modify' correctly clears any stale arming from a
-- previous transition.
armingRefocus :: Maybe WindowRef -> Maybe WindowRef -> Maybe Refocus
armingRefocus (Just from) (Just to)
    | wrPid from /= wrPid to = Just (Refocus from to defaultBounceBudget)
armingRefocus _ _ = Nothing

-- | Does an incoming @FocusedWindowChanged wid pid@ event match the
-- bounce signature for the given 'Refocus'? AX bounces back to the
-- previously-focused window, so we test against 'rfFrom' exactly.
isFocusBounce :: Word32 -> Int32 -> Refocus -> Bool
isFocusBounce wid pid r =
    wrWindowId (rfFrom r) == wid && wrPid (rfFrom r) == pid

-- | Does an incoming @FrontAppChanged pid@ event match the bounce
-- signature for the given 'Refocus'? NSWorkspace re-activates the
-- previously-focused app, which has only PID-level granularity.
isFrontAppBounce :: Int32 -> Refocus -> Bool
isFrontAppBounce pid r = wrPid (rfFrom r) == pid

-- | Decrement the bounce budget after a bounce event has been
-- suppressed. Returns 'Nothing' when the budget is exhausted so the
-- next event flows through the normal resolution path.
consumeRefocus :: Refocus -> Maybe Refocus
consumeRefocus r
    | rfPendingBounces r > 1 =
        Just r { rfPendingBounces = rfPendingBounces r - 1 }
    | otherwise = Nothing
