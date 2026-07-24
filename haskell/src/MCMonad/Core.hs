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
      -- * Timers
    , Timer(..)
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
    , visibleScreenWindows
      -- * Focus authority
    , FocusIntent(..)
    , armingIntent
    , isFocusIntentTarget
    , isIntentTargetPid
    , isSettlingEcho
    , isSettlingPidEcho
    , consumeIntent
    , defaultFocusBudget
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
import qualified Data.Set as Set
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

-- ---------------------------------------------------------------------------
-- Timers
--
-- A countdown reminder owned by the Haskell brain (not the Swift daemon).
-- The brain is the source of truth: it assigns ids, stamps the origin
-- workspace, persists the list across Mod-q\/launchd restarts, and tells
-- mcmonad-core what to render. The daemon keeps the wall clock (a 1-second
-- tick) and the UI (menubar countdown + reminder HUD); when a timer's
-- 'tmFireAt' passes it fires a reminder and reports the fire back so the
-- brain drops it from state. See 'MCMonad.Operations.pushTimers' and the
-- timer event handlers in "MCMonad.Main".

-- | One running countdown timer.
data Timer = Timer
    { tmId        :: !Int
      -- ^ Monotonic id assigned by the brain ('MCMonad.Core.nextTimerId').
      -- Never reused, so the daemon's fired-id guard can't collide.
    , tmLabel     :: !String
      -- ^ User-authored reminder text, shown in the menubar dropdown and
      -- the \"time's up\" HUD. This is deliberate display text (not a
      -- sniffed window title), so it is persisted verbatim.
    , tmFireAt    :: !Double
      -- ^ Absolute fire time as POSIX epoch seconds (UTC), matching the
      -- daemon's @Date().timeIntervalSince1970@. Absolute (not a
      -- remaining-duration) so a timer fires at the right wall-clock
      -- moment regardless of how long a restart took.
    , tmWorkspace :: !String
      -- ^ Tag of the workspace that was current when the timer was
      -- started. Drives the reminder HUD's \"Jump to workspace\" button.
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
    , timers           :: ![Timer]
      -- ^ All running countdown timers. Owned here (the brain is the
      -- source of truth), persisted across restart via
      -- 'MCMonad.Persistence.SerialState', and pushed to mcmonad-core
      -- for rendering by 'MCMonad.Operations.pushTimers'. See 'Timer'.
    , nextTimerId      :: !Int
      -- ^ Monotonic counter for the next 'Timer' id. Persisted alongside
      -- 'timers' so ids never repeat across a restart — the daemon's
      -- fired-id guard relies on uniqueness.
    , focusIntent      :: !(Maybe FocusIntent)
      -- ^ The window 'MCMonad.Operations.windows' most-recently told
      -- macOS to focus. While set, mcmonad's StackSet is the source of
      -- truth for focus: AX\/NSWorkspace events that match this target
      -- are confirmations (no-op), events for a different window of
      -- the same app are intra-app focus changes (accepted and clear
      -- the intent), and any other divergent event triggers a re-issue
      -- of 'FocusWindow' to push macOS back to the target. A bounded
      -- countdown on 're-issues remaining' prevents the algorithm from
      -- looping forever in a pathological case and lets user-initiated
      -- focus changes from outside mcmonad eventually take effect.
      -- See the 'FocusIntent' note at the end of this module.
    , unmanagedOrigin  :: !(Map.Map Int32 (String, UTCTime))
      -- ^ pid → (workspace tag, time) of the pid's most recently
      -- destroyed *last* window. Some apps (Gecko\/LibreWolf) destroy
      -- and recreate their NSWindow across a native-fullscreen
      -- round-trip, so the replacement arrives as a brand-new
      -- CGWindowID; 'MCMonad.Operations.manage' consults this map to
      -- route it back to the workspace the destroyed window lived on
      -- instead of dropping it on whatever workspace happens to be
      -- current. Recorded only when the destroyed window was the pid's
      -- last (multi-window apps keep the plain current-workspace
      -- placement), consumed on first use, and entries expire after
      -- 'MCMonad.Operations.unmanagedOriginTTL'. Deliberately not
      -- persisted: pids don't survive the reboots that persistence
      -- exists for, and a Mod-q mid-fullscreen is a corner we accept.
    , reclaimOrigin    :: !(Map.Map WindowRef (String, UTCTime))
      -- ^ Exact window → (workspace tag, time) for /every/ window that
      -- leaves management, not just a pid's last one.
      --
      -- mcmonad-core's reconcile sweep re-offers any live, manageable
      -- window the brain isn't holding, which closes the hole where a
      -- window lost to a bogus destroy stayed on screen forever with
      -- nobody to park it. But a re-offer arrives as a plain
      -- 'WindowCreated', so without this map the window would come back
      -- on whatever workspace happens to be current — the same window,
      -- same CGWindowID, teleported. 'unmanagedOrigin' can't cover it:
      -- that one is keyed by pid and deliberately skips multi-window
      -- apps, because a genuinely new window of a running app does
      -- belong on the current workspace.
      --
      -- Keyed by 'WindowRef', so a hit means /this exact window/ came
      -- back, which is only possible when it never really died. Short
      -- TTL ('MCMonad.Operations.reclaimOriginTTL') — the sweep runs
      -- every 2s, so a real reclaim lands almost immediately, and a tight
      -- window bounds any chance of a recycled CGWindowID matching a
      -- stale entry. Consumed on first use. Not persisted, for the same
      -- reason as 'unmanagedOrigin'.
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
-- The conservative end of the scope scale, used by 'resolveFrontApp'
-- as its first choice: a PID-only signal cannot say *which* window of
-- a multi-window app the user meant, so when the app has a window on
-- the screen the user is already looking at, that is the answer.
currentWorkspaceWindows :: W.StackSet i l a sid sd -> [a]
currentWorkspaceWindows ws =
    W.integrate' (W.stack (W.workspace (W.current ws)))

-- | Windows on every screen's workspace — current *and* secondary
-- monitors — but never a hidden workspace.
--
-- macOS-originated focus events fire for an enormous number of reasons
-- we can't disambiguate from the user's intent: a background tab
-- repaint, a network callback, an app deactivating as a side effect of
-- *our own* 'FocusWindow' command. The 'NSWorkspace' frontmost-app
-- notification fires when an app activates, including as the immediate
-- side effect of macOS opening a new window of that app.
--
-- The hidden-workspace exclusion is load-bearing and permanent: an
-- early version used 'W.allWindows', which let a window on a hidden
-- workspace claim focus and silently dragged that whole workspace onto
-- the current screen via 'W.focusWindow''s implicit 'view' call.
-- Nothing about a spurious AX event should be able to change *what is
-- displayed*.
--
-- Including the secondary screens, by contrast, cannot rearrange
-- anything: those workspaces are already on those monitors, so
-- 'W.focusWindow' only moves which screen is 'W.current'. That is
-- precisely "the active workspace follows window focus" — click a
-- window on the other monitor and mcmonad's notion of "here" follows
-- your eyes.
--
-- This scope was tried once before and reverted, because AX bounce
-- cascades used to be indistinguishable from user intent and would
-- yank the current screen across monitors (the
-- Mod-j-cycles-out-to-the-other-screen bug; the
-- new-Ghostty-tab-lands-on-the-wrong-screen bug). 'FocusIntent' is
-- what makes it safe now: while mcmonad has an outstanding
-- 'FocusWindow' command, contradicting events are pushed back rather
-- than believed, and the intent is only disarmed by 'UserMouseDown' —
-- an actual physical click — or by the command settling.
visibleScreenWindows :: W.StackSet i l a sid sd -> [a]
visibleScreenWindows ws =
    concatMap (W.integrate' . W.stack . W.workspace)
              (W.current ws : W.visible ws)

-- | Resolve focus from a precise AX focused-window-changed event.
--
-- Returns the updated StackSet when the target window is on some
-- screen's workspace and isn't already focused; 'Nothing' otherwise
-- (no-op).
--
-- This is the path that fixes the multi-window-per-app focus bug: the
-- AX observer reports the *exact* CGWindowID the user activated, so we
-- never have to guess among windows that share a PID. Because the
-- signal is exact, it is also the path allowed to move the current
-- screen — clicking a window on the secondary monitor makes that
-- monitor current. See 'visibleScreenWindows' for why hidden
-- workspaces stay out of reach.
--
-- Polymorphic in the StackSet type parameters so the test suite (which
-- uses @Int@ for the layout slot) can exercise this directly.
resolveFocusedWindow
    :: (Eq i, Eq sid)
    => Word32 -> Int32
    -> W.StackSet i l WindowRef sid sd
    -> Maybe (W.StackSet i l WindowRef sid sd)
resolveFocusedWindow wid pid ws =
    case find match (visibleScreenWindows ws) of
        Just wr | W.peek ws /= Just wr -> Just (W.focusWindow wr ws)
        _                              -> Nothing
  where
    match w = wrWindowId w == wid && wrPid w == pid

-- | Resolve focus from a PID-only front-app-changed event.
--
-- Returns the updated StackSet only when the user actually switched to
-- a *different* app. When focus is already inside that app, we leave
-- it alone.
--
-- The candidate search is deliberately two-tiered. A PID says nothing
-- about *which* window of a multi-window app was activated, so a
-- same-app window on the current screen wins outright — otherwise
-- activating LibreWolf would fling the current screen to whichever
-- monitor happened to hold the first LibreWolf window in stack order.
-- Only when the app has no window here at all do we look at the other
-- screens, which is the case that genuinely means "the user is now
-- working over there".
--
-- Either way the precise 'resolveFocusedWindow' event follows within
-- milliseconds (macOS emits NSWorkspace activation first, then the AX
-- focused-window change) and corrects any within-app mis-pick.
resolveFrontApp
    :: (Eq i, Eq sid)
    => Int32
    -> W.StackSet i l WindowRef sid sd
    -> Maybe (W.StackSet i l WindowRef sid sd)
resolveFrontApp pid ws = case W.peek ws of
    Just w | wrPid w == pid -> Nothing
    _ -> case find ofApp (currentWorkspaceWindows ws) of
        Just wr -> Just (W.focusWindow wr ws)
        Nothing -> case find ofApp (visibleScreenWindows ws) of
            Just wr -> Just (W.focusWindow wr ws)
            Nothing -> Nothing
  where
    ofApp = (== pid) . wrPid

-- ---------------------------------------------------------------------------
-- macOS focus authority
--
-- When 'MCMonad.Operations.windows' commits a focus change, it tells
-- mcmonad-core which window macOS should focus by sending a 'FocusWindow'
-- IPC command. macOS then runs the four-step SLPS focus protocol and may
-- fire any number of follow-up notifications:
--
--   * AX 'kAXFocusedWindowChangedNotification' for the new window
--     (confirmation),
--   * AX 'kAXFocusedWindowChangedNotification' for the *previously*-focused
--     window because the previous app briefly regains focus during macOS'
--     own focus-settling (bounce),
--   * AX 'kAXFocusedWindowChangedNotification' for an unrelated third-app
--     window because some other AX observer fired during the settling
--     cascade (spurious cross-app divergence),
--   * NSWorkspace 'didActivateApplicationNotification' for the new app
--     (confirmation),
--   * NSWorkspace 'didActivateApplicationNotification' for the previously-
--     focused app (bounce).
--
-- Cases 2, 3, and 5 are all macOS-side noise: mcmonad already told macOS
-- exactly which window we want focused. The 'follow whatever AX says' rule
-- treats this noise as user intent and walks the StackSet focus straight
-- onto whichever bounce-target arrived last, which manifests to the user
-- as "focus blinks onto the new window then snaps back to the previous one".
--
-- The fix: while a 'FocusIntent' is armed, mcmonad's StackSet is the
-- source of truth. Three dispatch arms:
--
--   * Exact target match (wid + pid) — AX is confirming our command.
--     No-op; keep the intent armed in case more bounces follow.
--   * Same app, different window (wid mismatch, pid match) — almost
--     certainly the user clicking another window of the target's app.
--     Accept the change and clear the intent; this preserves the
--     multi-window-per-app precision the AX path exists for.
--   * Any other divergence — almost certainly a bounce or spurious AX
--     event from outside the target's app. Re-issue 'FocusWindow' so
--     macOS is pushed back onto the target, decrement the budget, and
--     keep the intent armed for any further bounces.
--
-- The budget bounds the number of re-issues so a pathological macOS
-- state cannot pin mcmonad in an infinite re-issue loop, and so user-
-- initiated cross-app focus changes (clicking a window in a different
-- app) eventually take effect rather than being fought indefinitely.
-- 'FrontAppChanged' uses the same logic but without the intra-app arm
-- (NSWorkspace doesn't carry a window id, so there's no "same app
-- different window" to recognise).
--
-- LOAD-BEARING ESCAPE HATCH. The budget alone is not sufficient. AX
-- cannot tell a legitimate mouse click on another app's window apart
-- from a focus-settling bounce echo for the previously-focused app —
-- both arrive at the handler as cross-app divergent 'FocusedWindowChanged'
-- \/ 'FrontAppChanged' events. Without a separate channel, every mouse
-- click on a third-app window costs (budget + 1) physical clicks before
-- it takes effect, which is unservicable. The disambiguator is the
-- physical mouse-down event surfaced over IPC as 'UserMouseDown'
-- (CGEventTap on .leftMouseDown\/.rightMouseDown\/.otherMouseDown in
-- core; the handler in 'MCMonad.Main' clears 'focusIntent'
-- unconditionally on receipt, so the very next AX\/NSWorkspace event
-- flows through 'resolveFocusedWindow' \/ 'resolveFrontApp' as
-- authoritative). DO NOT remove the 'UserMouseDown' arm without
-- supplying an equivalent out-of-band physical-input channel — without
-- one, the "mouse clicks need to be repeated" regression returns.

-- | The focus mcmonad most recently told macOS to land on, plus the
-- budget for how many divergent AX\/NSWorkspace events we will fight
-- before giving up and letting macOS' view win.
data FocusIntent = FocusIntent
    { fiTarget             :: !WindowRef
    , fiReissuesRemaining  :: !Word8
    , fiSettling           :: !(Set WindowRef)
      -- ^ Every window the 'MCMonad.Operations.windows' pass that armed
      -- this intent wrote a frame for — the whole visible set across
      -- *all* screens, not just 'fiTarget'.
      --
      -- Those AX writes make macOS emit 'FocusedWindowChanged' \/
      -- 'FrontAppChanged' echoes for windows on the *other* monitor. With
      -- only 'fiTarget' to check against, each echo read as a cross-app
      -- divergence: it burned a re-issue from the budget, and once the
      -- budget drained the next echo flowed through to 'resolveFocusedWindow'
      -- and dragged the current screen onto the other monitor — the
      -- Opt-h\/l\/j "focus jumps to the wrong screen while I resize" bug.
      -- An event whose window is in this set is our own settling echo:
      -- no-op it, and crucially do not spend the budget on it. A genuine
      -- click on any of these windows still lands, because a physical
      -- 'UserMouseDown' clears the whole intent first (see the note below).
    } deriving (Eq, Show, Read)

-- | Initial budget for re-issues per intent. Empirically a single user
-- action triggers at most 3 cross-app divergent events (AX bounce for
-- previous window, NSWorkspace bounce for previous app, and a spurious
-- AX event for some third app during the focus-settling cascade); we
-- allow a little headroom.
defaultFocusBudget :: Word8
defaultFocusBudget = 4

-- | Build a fresh intent from the focus 'MCMonad.Operations.windows'
-- just committed, plus the set of windows it wrote frames for (for
-- 'fiSettling'). 'Nothing' for an empty workspace clears any prior
-- arming and disables suppression entirely until the next focus change.
armingIntent :: Set WindowRef -> Maybe WindowRef -> Maybe FocusIntent
armingIntent settling (Just w) = Just (FocusIntent w defaultFocusBudget settling)
armingIntent _        Nothing  = Nothing

-- | Does an incoming @FocusedWindowChanged wid pid@ exactly match the
-- intent's target? Used to recognise AX confirmation echoes.
isFocusIntentTarget :: Word32 -> Int32 -> FocusIntent -> Bool
isFocusIntentTarget wid pid i =
    wrWindowId (fiTarget i) == wid && wrPid (fiTarget i) == pid

-- | Does an incoming event's PID match the intent's target PID? Used
-- two ways: to recognise NSWorkspace confirmation echoes (target's app
-- is re-activated), and to recognise intra-app AX divergence (the
-- target's app is reporting focus on a *different* window of itself,
-- which we treat as a user click and accept).
isIntentTargetPid :: Int32 -> FocusIntent -> Bool
isIntentTargetPid pid i = wrPid (fiTarget i) == pid

-- | Is an incoming @FocusedWindowChanged wid pid@ an echo of a window
-- this layout pass just moved? Such an event is macOS settling around
-- our own AX write — never user intent — so the handler no-ops it
-- without spending the re-issue budget. This is what stops a
-- secondary-monitor window's settling echo from dragging the current
-- screen across displays.
isSettlingEcho :: Word32 -> Int32 -> FocusIntent -> Bool
isSettlingEcho wid pid i = Set.member (WindowRef wid pid) (fiSettling i)

-- | Is an incoming @FrontAppChanged pid@ an echo of an app we just
-- moved a window of? The PID-only signal can't name a window, so match
-- on any settling window sharing the pid.
isSettlingPidEcho :: Int32 -> FocusIntent -> Bool
isSettlingPidEcho pid i = any ((== pid) . wrPid) (Set.toList (fiSettling i))

-- | Decrement the re-issue budget after a divergent event has triggered
-- a push-back. Returns 'Nothing' when the budget is exhausted so the
-- next event flows through the normal resolution path — this is how
-- legitimate user-initiated cross-app focus changes (e.g. clicking a
-- window in a third app while macOS is still bouncing the previous
-- intent) eventually take effect.
consumeIntent :: FocusIntent -> Maybe FocusIntent
consumeIntent i
    | fiReissuesRemaining i > 1 =
        Just i { fiReissuesRemaining = fiReissuesRemaining i - 1 }
    | otherwise = Nothing
