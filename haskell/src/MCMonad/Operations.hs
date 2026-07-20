{-# LANGUAGE OverloadedStrings #-}

module MCMonad.Operations
    ( -- * Core state transition
      windows
    , reassertHiddenWindows
    , frameAtParkCorner
      -- * Window lifecycle
    , manage
    , manageSilent
    , unmanage
    , unmanagedOriginTTL
      -- * Overlay snapshot
    , buildOverlaySnapshot
    , pushOverlaySnapshot
      -- * Layout messages
    , sendMessage
    , sendMessageWithNoRefresh
      -- * Window actions
    , kill
    , withFocused
    , reveal
    , setFocus
    , jumpToActiveWindow
    , showWindowPicker
    , showSpotlight
      -- * Launching programs
    , spawn
      -- * Restart
    , restart
    , recompile
      -- * Timers
    , pushTimers
    , syncTimers
    , nowEpoch
      -- * Timer activity journal
    , journalStarted
    , journalSnoozed
    , journalFired
    , journalCancelled
    , journalDismissed
    , journalJumped
      -- * State persistence
    , saveStateIO
    , maybeSaveState
    , loadStateIO
    , getConfigDir
    , getStateFile
      -- * Screens
    , screenWorkspace
    , rescreen
    , reassignScreens
      -- * Utilities
    , whenJust
    , findScreenForWindow
    ) where

import Control.Concurrent (forkIO)
import Control.Exception (IOException, catch)
import Control.Monad (forM, void, unless, when)
import Data.Aeson ((.=))
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (Pair)
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int32)
import Data.List (find, sortBy)
import Data.Monoid (Endo(..))
import Data.Ord (Down(..), comparing)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Time.Clock (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime, posixSecondsToUTCTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import System.Directory (doesFileExist, getHomeDirectory, createDirectoryIfMissing)
import System.Environment (getExecutablePath, lookupEnv)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeDirectory)
import System.IO (hPutStrLn, stderr)
import System.Info (arch, os)
import qualified System.Posix.Files as Posix
import System.Posix.Process (executeFile)
import System.Process (createProcess, shell, readProcessWithExitCode, CreateProcess(..))
import qualified XMonad.StackSet as W

import MCMonad.Core
import MCMonad.IPC
import MCMonad.ManageHook (ManageHook, runManageHook)
import MCMonad.Persistence
    ( SerialState(..), persistenceVersion, windowSetToSerial
    )

-- ---------------------------------------------------------------------------
-- The windows function
--
-- This is the single point of truth for all state transitions. Same
-- architecture as xmonad's Operations.windows:
--
--   1. Apply the pure WindowSet transformation
--   2. Hide windows that are no longer visible
--   3. Show windows that became visible
--   4. Run layouts for each visible screen
--   5. Resolve floating window positions
--   6. Send frame assignments to the Swift daemon
--   7. Send focus command
--   8. Update the mapped set

-- | Apply a pure transformation to the 'WindowSet', then synchronise
-- all visible state with the Swift daemon.
windows :: (WindowSet -> WindowSet) -> M ()
windows f = do
    old <- gets windowset
    stickySet <- gets sticky

    -- Record which screen each sticky window is on BEFORE the transformation,
    -- so we can keep them on the same screen after workspace switches.
    let stickyScreenMap = if S.null stickySet then M.empty else M.fromList
            [ (w, W.screen scr)
            | w <- S.toList stickySet
            , Just tag <- [W.findTag w old]
            , scr <- W.current old : W.visible old
            , W.tag (W.workspace scr) == tag
            ]

    let ws = f old

    -- 1. Update state immediately + affinity bookkeeping
    modify $ \s -> s { windowset = ws
                     , affinity = updateAffinities ws (affinity s) }

    -- 1b. Sticky: keep sticky windows on their original screen.
    -- Sticky windows must be floating (same as Sway). When the workspace
    -- a sticky window was on goes hidden, shift it to whatever workspace
    -- is now on that screen. Preserve focus if a sticky window was focused.
    unless (S.null stickySet) $ do
        ws' <- gets windowset
        let screenToTag = M.fromList
                [ (W.screen scr, W.tag (W.workspace scr))
                | scr <- W.current ws' : W.visible ws'
                ]
            ws'' = S.foldl' (\acc w ->
                case W.findTag w acc of
                    Just tag
                        -- Window's workspace is still visible: leave it
                        | any ((== tag) . W.tag . W.workspace)
                              (W.current acc : W.visible acc) -> acc
                        -- Workspace went hidden: move to same screen's new workspace
                        | otherwise ->
                            case M.lookup w stickyScreenMap >>= \sid -> M.lookup sid screenToTag of
                                Just targetTag -> W.shiftWin targetTag w acc
                                Nothing -> acc  -- screen gone (unplugged), leave hidden
                    Nothing -> acc
                ) ws' stickySet
            -- Preserve focus: if the old focus was a sticky window, re-focus it
            ws''' = case W.peek old of
                Just w | S.member w stickySet, W.member w ws'' ->
                    W.focusWindow w ws''
                _ -> ws''
        modify $ \s -> s { windowset = ws''' }

    -- Recompute visibility AFTER sticky adjustments
    currentAfterSticky <- gets windowset
    let oldVisible = allVisibleWindows old
        newVisible = allVisibleWindows currentAfterSticky

    conn <- asks connection
    prevMapped <- gets mapped

    -- 2. Hide every window that should NOT be visible — declaratively, across
    --    ALL workspaces, not just the ones that were visible last cycle. A
    --    window parked on a hidden workspace that drifted back on-screen (a
    --    prior off-screen clamp, or an app re-asserting its own position) is
    --    therefore re-parked on the next switch, instead of being remembered
    --    as "already hidden" forever (the bug behind the stuck background).
    --    Never hide sticky windows. Fire only when the visible set actually
    --    changed, so pure focus-follows-mouse churn doesn't re-issue hides on
    --    every event.
    let visibleChanged = S.fromList newVisible /= prevMapped
        toHide = filter (\w -> w `notElem` newVisible && not (S.member w stickySet))
                        (allManagedWindows currentAfterSticky)
    io $ hPutStrLn stderr $ "WINDOWS: visibleChanged=" ++ show visibleChanged
        ++ " newVisible=" ++ show (length newVisible)
        ++ " toHide=" ++ show (map wrWindowId toHide)
    when (visibleChanged && not (null toHide)) $
        io $ sendCommand conn (HideWindows (map wrWindowId toHide))

    -- 3. Show windows that became visible
    let toShow = filter (`notElem` oldVisible) newVisible
    unless (null toShow) $
        io $ sendCommand conn (ShowWindows (map wrWindowId toShow))

    -- 4. Run layouts for each visible screen. Lay out
    --    'currentAfterSticky', not the raw @f old@: step 1b may have
    --    shifted sticky windows onto the workspaces now displayed, and
    --    laying out the pre-sticky value would compute frames for a
    --    stack the state no longer has.
    allRects <- fmap concat $ forM (screensOf currentAfterSticky) $ \scr -> do
        currentWS <- gets windowset
        let wsp  = W.workspace scr
            tag  = W.tag wsp
            rect = screenRect (W.screenDetail scr)
        case W.stack wsp of
            Nothing -> return []
            Just st -> do
                -- Filter out floating windows from the tiled layout
                let isTiled w = not (M.member w (W.floating currentWS))
                    tiledStack = W.filter isTiled st
                case tiledStack of
                    Nothing -> return []
                    Just t  -> do
                        (rects, ml') <- runLayout (wsp { W.stack = Just t }) rect
                        -- Update layout in the WindowSet if it changed
                        whenJust ml' $ \l' -> modify $ \s ->
                            let wset = windowset s
                                updateWsp w
                                    | W.tag w == tag = w { W.layout = l' }
                                    | otherwise      = w
                                updateScr sc = sc { W.workspace = updateWsp (W.workspace sc) }
                            in s { windowset = wset
                                { W.current = updateScr (W.current wset)
                                , W.visible = map updateScr (W.visible wset)
                                } }
                        return rects

    -- 5. Resolve floating window positions
    currentWS <- gets windowset
    let floatRects = resolveFloating currentWS

    -- 6. Send frame assignments
    let allPositions = allRects ++ floatRects
        frames = map toFrameAssignment allPositions
    io $ hPutStrLn stderr $ "FRAMES: " ++ show [(wrWindowId w, rect_x r, rect_y r, rect_w r, rect_h r) | (w, r) <- allPositions]
    unless (null frames) $
        io $ sendCommand conn (SetFrames frames)

    -- 6b. Store window positions for directional focus navigation
    modify $ \s -> s { windowRects = M.fromList allPositions }

    -- 7. Focus the top window (only if focus actually changed) and arm
    --    'focusIntent' so the event-handler path treats mcmonad's
    --    StackSet as the source of truth for focus state until macOS
    --    settles — see the 'FocusIntent' note in 'MCMonad.Core'. We
    --    overwrite 'focusIntent' unconditionally: a 'Just newFocus' arms
    --    fresh suppression for the new target; a 'Nothing' (empty
    --    workspace) correctly clears any stale arming from a prior
    --    transition.
    currentWS' <- gets windowset
    let oldFocus = W.peek old
        newFocus = W.peek currentWS'
    when (newFocus /= oldFocus) $
        case newFocus of
            Just w  -> io $ sendCommand conn (FocusWindow (wrWindowId w) (wrPid w))
            Nothing -> return ()
    modify $ \s -> s { focusIntent = armingIntent newFocus }

    -- 8. Send workspace indicator update (with mode indicator)
    mode <- gets inputMode
    let currentTag = W.tag . W.workspace . W.current $ currentWS'
        indicator = if mode /= "default"
                    then currentTag ++ " \x2020"  -- † dagger for non-default mode
                    else currentTag
    io $ sendCommand conn (SetWorkspaceIndicator indicator)

    -- 9. Warp mouse to center of focused window when screen/workspace changed
    doWarp <- gets warpOnSwitch
    when doWarp $ do
        let oldScreen = W.screen (W.current old)
            newScreen = W.screen (W.current currentWS')
            oldTag = W.tag (W.workspace (W.current old))
            newTag = W.tag (W.workspace (W.current currentWS'))
        when (oldScreen /= newScreen || oldTag /= newTag) $
            case newFocus of
                Just w -> case lookup w allPositions of
                    Just (Rectangle rx ry rw rh) ->
                        io $ sendCommand conn (WarpMouse (rx + rw / 2) (ry + rh / 2))
                    Nothing -> return ()
                Nothing -> return ()

    -- 10. Update mapped set
    modify $ \s -> s { mapped = S.fromList newVisible }

    -- 10b. Push overlay/menu snapshot to mcmonad-core. Carries the
    --      full workspace tree (visible + hidden), each window's
    --      metadata, the focus indicator, and the current debug
    --      overlay flag. mcmonad-core caches it for the menubar
    --      dropdown and — if debug is on — repaints the overlay
    --      from it.
    snap <- buildOverlaySnapshot
    io $ sendCommand conn (SetOverlayState snap)

    -- 11. Persist state so a later restart can restore it.
    --     Throttled to once per 'saveThrottleSeconds': bursts of
    --     focus-follows-mouse or rapid keypresses shouldn't fan
    --     out to a disk write per call. 'restart' bypasses this
    --     by calling 'saveStateIO' directly before 'exec'.
    --     Errors inside saveStateIO are caught and logged, so a
    --     transient disk hiccup never reaches the event loop.
    maybeSaveState

-- | Persist the current state, at most once per 'saveThrottleSeconds'.
--
-- Called at the end of 'windows', and also from the focus-resolution
-- path in "MCMonad.Main", which mutates the windowset directly (a
-- focus change across already-displayed workspaces moves no frames, so
-- it deliberately skips the whole 'windows' cycle — but it *does*
-- change which workspace is current, and that has to survive a
-- restart).
maybeSaveState :: M ()
maybeSaveState = do
    now <- io getCurrentTime
    last' <- gets lastSaveAt
    let shouldSave = case last' of
            Nothing -> True
            Just t  -> diffUTCTime now t >= saveThrottleSeconds
    when shouldSave $ do
        ws' <- gets windowset
        aff' <- gets affinity
        ts' <- gets timers
        nid' <- gets nextTimerId
        modify $ \s -> s { lastSaveAt = Just now }
        io $ saveStateIO ws' aff' ts' nid'

-- | Maximum frequency for 'windows'-driven persistence writes. The
-- 'restart' path bypasses this — the final snapshot before Mod-q's
-- 'exec' is always written immediately.
saveThrottleSeconds :: NominalDiffTime
saveThrottleSeconds = 0.25

-- | Every screen that is currently displaying a workspace: the focused
-- one first, then the secondary monitors.
screensOf :: W.StackSet i l a sid sd -> [W.Screen i l a sid sd]
screensOf ws = W.current ws : W.visible ws

-- | All windows visible on any screen (current + visible), including
-- floating windows.
allVisibleWindows :: WindowSet -> [WindowRef]
allVisibleWindows ws =
    concatMap (W.integrate' . W.stack . W.workspace) (screensOf ws)

-- | Every managed window across all workspaces — current, visible, and
-- hidden. Used to hide declaratively: anything here that is not in
-- 'allVisibleWindows' should be parked off-screen.
allManagedWindows :: WindowSet -> [WindowRef]
allManagedWindows ws =
    concatMap (W.integrate' . W.stack)
              (map W.workspace (W.current ws : W.visible ws) ++ W.hidden ws)

-- | Re-send the park command for every managed window that should not be
-- on screen. macOS un-parks hidden windows in bulk during native-fullscreen
-- Space transitions: each corner-parked window is silently re-constrained
-- fully on-screen at (screenRight - width, menubar bottom), with no
-- per-window move event for the sweep itself — the "background flood" on
-- every workspace after a fullscreen round-trip. Since there is no event
-- for the sweep, the heal is declarative re-assertion from whatever
-- signals do arrive afterwards (front-app changes, a straggler's own
-- frame event). Safe to call liberally: mcmonad-core skips the AX write
-- for windows already at the park corner, so a re-assert where nothing
-- drifted costs one IPC message and a SkyLight read per hidden window.
reassertHiddenWindows :: M ()
reassertHiddenWindows = do
    ws <- gets windowset
    stickySet <- gets sticky
    let visible = allVisibleWindows ws
        toHide = filter (\w -> w `notElem` visible && not (S.member w stickySet))
                        (allManagedWindows ws)
    unless (null toHide) $ do
        conn <- asks connection
        io $ sendCommand conn (HideWindows (map wrWindowId toHide))

-- | Is this frame at (or clamped near) some screen's park corner? Parks
-- pin the origin's x to screenRight - 1, and macOS' ordinary titlebar
-- clamp only pulls y back on-screen — x is the discriminator. The
-- fullscreen-transition sweep instead re-fits windows fully on-screen
-- (x = screenRight - width), which this rejects.
--
-- The right-edge test alone is not enough on multi-monitor: side-by-side
-- displays share a boundary, so the right screen's left edge *is* the left
-- screen's @screenRight@, and every ordinary window tiled there would read
-- as parked. Require in addition that the frame expose no more than a
-- sliver on any display — a real park leaves ~1px. Mirrors
-- @isAlreadyParked@ in mcmonad-core; the two must agree or a window is
-- either re-parked forever or never re-parked at all.
--
-- Generic in everything but 'ScreenDetail': only the screen rectangles are
-- read, and keeping it that way lets the properties exercise it directly.
frameAtParkCorner :: Rectangle -> W.StackSet i l a sid ScreenDetail -> Bool
frameAtParkCorner r ws = any nearRightEdge screenRects && widestExposure <= 2
  where
    screenRects = map (screenRect . W.screenDetail) (screensOf ws)
    nearRightEdge sr = rect_x r >= rect_x sr + rect_w sr - 2
    widestExposure = maximum (0 : map overlapWidth screenRects)
    -- Width of the 2D intersection: a park sits *below* a neighbouring
    -- display as well as to its right, so the vertical span has to be
    -- taken into account or the neighbour reads as fully exposed.
    overlapWidth sr
        | span_ (rect_y r) (rect_h r) (rect_y sr) (rect_h sr) <= 0 = 0
        | otherwise = span_ (rect_x r) (rect_w r) (rect_x sr) (rect_w sr)
    span_ a la b lb = max 0 (min (a + la) (b + lb) - max a b)

-- | Convert a (WindowRef, Rectangle) pair to a FrameAssignment.
toFrameAssignment :: (WindowRef, Rectangle) -> FrameAssignment
toFrameAssignment (wr, rect) = FrameAssignment (wrWindowId wr) (wrPid wr) rect

-- | Resolve floating window positions. Converts RationalRect (0..1 fractions)
-- to absolute screen coordinates based on the screen the window is on.
resolveFloating :: WindowSet -> [(WindowRef, Rectangle)]
resolveFloating ws =
    [ (w, absoluteRect)
    | (w, W.RationalRect rx ry rw rh) <- M.toList (W.floating ws)
    -- Only include floating windows that are visible on some screen
    , w `elem` allVisibleWindows ws
    , let screenR = findScreenForWindow w ws
          absoluteRect = Rectangle
              { rect_x = fromRational rx * rect_w screenR + rect_x screenR
              , rect_y = fromRational ry * rect_h screenR + rect_y screenR
              , rect_w = fromRational rw * rect_w screenR
              , rect_h = fromRational rh * rect_h screenR
              }
    ]

-- ---------------------------------------------------------------------------
-- Overlay / menubar snapshot
--
-- Snapshot of the WindowSet pushed to mcmonad-core on every 'windows'
-- call. The core daemon caches it for the menubar workspace tree and,
-- when 'debugOverlays' is on, repaints the per-screen overlay layer
-- from it.

-- | Build a fresh 'OverlaySnapshot' from the current 'MState'. Pure
-- with respect to IPC — emits no commands; the caller decides where
-- to send the result.
--
-- Note: window titles and other AX metadata live in 'windowMetadata'.
-- They cross the IPC boundary as plaintext here because the consumer
-- is on the user's own screen (menu rendering, overlay rendering).
-- We do not log them to disk; that path runs through
-- mcmonad-core's salted 'TitleHash'.
buildOverlaySnapshot :: M OverlaySnapshot
buildOverlaySnapshot = do
    ws    <- gets windowset
    meta  <- gets windowMetadata
    rects <- gets windowRects
    dbg   <- gets debugOverlays
    let focused = W.peek ws
        mkScreen scr = OverlayScreenEntry
            { oseScreenId     = let S s = W.screen scr in s
            , oseFrame        = screenRect (W.screenDetail scr)
            , oseWorkspaceTag = W.tag (W.workspace scr)
            , oseWindows      = workspaceWindows ws meta rects focused (W.workspace scr)
            }
        mkHidden wsp = OverlayHiddenWorkspace
            { ohwTag     = W.tag wsp
            , ohwWindows = workspaceWindows ws meta rects focused wsp
            }
        screens = map mkScreen (W.current ws : W.visible ws)
        hidden  = map mkHidden (W.hidden ws)
    return OverlaySnapshot
        { osDebugOverlays    = dbg
        , osScreens          = screens
        , osHiddenWorkspaces = hidden
        }

-- | Build a snapshot of the current state and push it to mcmonad-core
-- as a single 'SetOverlayState' command. Use this from focus-event
-- handlers that update 'windowset' via 'modify' (and therefore bypass
-- 'windows', which is the regular snapshot push site at step 10b):
-- without it, the debug overlay's blue focused-label and the menubar
-- workspace tree stay stuck on the previous focus.
pushOverlaySnapshot :: M ()
pushOverlaySnapshot = do
    snap <- buildOverlaySnapshot
    conn <- asks connection
    io $ sendCommand conn (SetOverlayState snap)

-- | Build the per-window entries for one workspace.
workspaceWindows
    :: WindowSet
    -> M.Map WindowRef WindowMetadata
    -> M.Map WindowRef Rectangle
    -> Maybe WindowRef
    -> WindowSpace
    -> [OverlayWindowEntry]
workspaceWindows ws meta rects focused wsp =
    [ OverlayWindowEntry
        { oweWindowId     = wrWindowId w
        , owePid          = wrPid w
        , oweAppName      = wmAppName  =<< M.lookup w meta
        , oweTitle        = wmTitle    =<< M.lookup w meta
        , oweBundleId     = wmBundleId =<< M.lookup w meta
        , oweWorkspaceTag = Just tag
        , oweFrame        = M.findWithDefault zeroRect w rects
        , oweIsFocused    = Just w == focused
        , oweIsFloating   = M.member w floatingMap
        }
    | w <- W.integrate' (W.stack wsp)
    ]
  where
    tag         = W.tag wsp
    floatingMap = W.floating ws
    zeroRect    = Rectangle 0 0 0 0

-- | Find the screen rectangle for a given window. Falls back to the current
-- screen if the window is not found on any screen.
findScreenForWindow :: WindowRef -> WindowSet -> Rectangle
findScreenForWindow w ws =
    case find (windowOnScreen w) (W.current ws : W.visible ws) of
        Just scr -> screenRect (W.screenDetail scr)
        Nothing  -> screenRect (W.screenDetail (W.current ws))
  where
    windowOnScreen win scr =
        win `elem` W.integrate' (W.stack (W.workspace scr))

-- ---------------------------------------------------------------------------
-- Window lifecycle

-- | How long a destroyed last-window's workspace stays authoritative for
-- the pid's next window (see 'unmanagedOrigin'). A native-fullscreen
-- session spans the whole destroy→recreate gap — Gecko kills the normal
-- window on ENTER and only recreates it on exit — so this must be hours,
-- not seconds. It is still bounded so a browser whose last window was
-- closed on workspace X today doesn't teleport a fresh window there
-- tomorrow.
unmanagedOriginTTL :: NominalDiffTime
unmanagedOriginTTL = 4 * 3600

-- | Upper bound on remembered destroy-origins; pathological churn of
-- single-window apps must not grow the map without limit.
unmanagedOriginCap :: Int
unmanagedOriginCap = 64

-- | Drop expired origin entries and enforce the size cap (newest kept).
pruneOrigins
    :: UTCTime
    -> M.Map Int32 (String, UTCTime)
    -> M.Map Int32 (String, UTCTime)
pruneOrigins now m
    | M.size fresh <= unmanagedOriginCap = fresh
    | otherwise = M.fromList
        . take unmanagedOriginCap
        . sortBy (comparing (Down . snd . snd))
        . M.toList $ fresh
  where
    fresh = M.filter (\(_, at) -> diffUTCTime now at <= unmanagedOriginTTL) m

-- | Manage a new window: run the manage hook, insert it into the current
-- workspace, and apply any hook-specified transformations (float, shift, etc.).
manage :: WindowInfo -> ManageHook -> M ()
manage wi hook = do
    let wr = WindowRef (wiWindowId wi) (wiPid wi)
    -- Don't manage if already managed
    ws <- gets windowset
    when (not (W.member wr ws)) $ do
        Endo transform <- userCodeDef (Endo id) (runManageHook hook wi)
        -- Destroy/recreate affinity: if this pid's last window was
        -- destroyed recently ('unmanagedOrigin'), this window is its
        -- replacement — Gecko destroys and recreates the NSWindow
        -- across a native-fullscreen round-trip — so route it back to
        -- the workspace the destroyed window lived on. The route runs
        -- before the manage hook's transform, so an explicit doShift
        -- in the user's config still wins.
        now <- io getCurrentTime
        origins <- gets unmanagedOrigin
        let allTags = map W.tag (W.workspace (W.current ws)
                                 : map W.workspace (W.visible ws)
                                 ++ W.hidden ws)
            originTag = case M.lookup (wiPid wi) origins of
                Just (tag, at)
                    | diffUTCTime now at <= unmanagedOriginTTL
                    , tag `elem` allTags -> Just tag
                _ -> Nothing
            route = maybe id (`W.shiftWin` wr) originTag
        modify $ \s -> s
            { windowMetadata  = M.insert wr (metadataFromInfo wi) (windowMetadata s)
            , unmanagedOrigin = M.delete (wiPid wi) (unmanagedOrigin s)
            }
        windows (transform . route . W.insertUp wr)
        -- A window routed to a hidden workspace never enters the
        -- visible set, so the 'windows' call above did not change it
        -- and issued no hides — the new window would sit on screen at
        -- whatever frame its app chose. Park it (and any other
        -- straggler) explicitly.
        whenJust originTag $ \_ -> reassertHiddenWindows

-- | Insert a window into the StackSet without triggering layout.
-- Used during startup to batch-insert all existing windows.
manageSilent :: WindowInfo -> ManageHook -> M ()
manageSilent wi hook = do
    let wr = WindowRef (wiWindowId wi) (wiPid wi)
    ws <- gets windowset
    when (not (W.member wr ws)) $ do
        Endo transform <- userCodeDef (Endo id) (runManageHook hook wi)
        modify $ \s -> s
            { windowset = transform (W.insertUp wr (windowset s))
            , windowMetadata = M.insert wr (metadataFromInfo wi) (windowMetadata s)
            }

-- | Remove a window from management. Called when a window is destroyed.
unmanage :: WindowRef -> M ()
unmanage w = do
    ws <- gets windowset
    when (W.member w ws) $ do
        -- Remember where the pid's LAST window lived so 'manage' can
        -- route a destroy/recreate replacement (Gecko's fullscreen
        -- round-trip) back to it. Multi-window apps skip this: the
        -- surviving windows make "which workspace" ambiguous, and a
        -- genuinely new window of a running app belongs on the current
        -- workspace anyway.
        now <- io getCurrentTime
        let lastOfPid = not (any (\o -> o /= w && wrPid o == wrPid w)
                                 (W.allWindows ws))
        case W.findTag w ws of
            Just tag | lastOfPid -> modify $ \s -> s
                { unmanagedOrigin =
                    M.insert (wrPid w) (tag, now)
                             (pruneOrigins now (unmanagedOrigin s))
                }
            _ -> return ()
        -- Clean from sticky, scratchpads, and metadata before removing
        modify $ \s -> s
            { sticky         = S.delete w (sticky s)
            , scratchpads    = M.filter (/= w) (scratchpads s)
            , windowMetadata = M.delete w (windowMetadata s)
            }
        -- W.delete, not W.delete': delete' deliberately leaves the
        -- floating entry behind (xmonad keeps it for temporary
        -- removals), but a destroyed CGWindowID never comes back —
        -- the leaked entries accumulated in mcmonad.state by the
        -- hundreds before this used the full delete.
        windows (W.delete w)

-- ---------------------------------------------------------------------------
-- Layout messages

-- | Send a message to the layout on the current workspace. If the layout
-- handles it (returns a new layout), trigger a re-layout via 'windows'.
sendMessage :: Message a => a -> M ()
sendMessage m = do
    ws <- gets windowset
    let wsp = W.workspace (W.current ws)
        lay = W.layout wsp
    ml' <- userCodeDef Nothing $ handleMessage lay (someMessage m)
    whenJust ml' $ \l' -> do
        let wsp' = wsp { W.layout = l' }
            cur' = (W.current ws) { W.workspace = wsp' }
        modify $ \s -> s { windowset = (windowset s) { W.current = cur' } }
        windows id  -- trigger relayout

-- | Send a message to the current layout without refreshing the screen.
-- Useful for batching multiple messages before a single refresh.
sendMessageWithNoRefresh :: Message a => a -> M ()
sendMessageWithNoRefresh m = do
    ws <- gets windowset
    let wsp = W.workspace (W.current ws)
        lay = W.layout wsp
    ml' <- userCodeDef Nothing $ handleMessage lay (someMessage m)
    whenJust ml' $ \l' -> do
        let wsp' = wsp { W.layout = l' }
            cur' = (W.current ws) { W.workspace = wsp' }
        modify $ \s -> s { windowset = (windowset s) { W.current = cur' } }

-- ---------------------------------------------------------------------------
-- Window actions

-- | Close the focused window by asking the Swift daemon to close it.
kill :: M ()
kill = withFocused $ \w -> do
    conn <- asks connection
    io $ sendCommand conn (CloseWindow (wrWindowId w) (wrPid w))

-- | Perform an action on the focused window, if there is one.
withFocused :: (WindowRef -> M ()) -> M ()
withFocused f = do
    ws <- gets windowset
    whenJust (W.peek ws) f

-- | Make a window visible by sending a ShowWindows command.
reveal :: WindowRef -> M ()
reveal w = do
    conn <- asks connection
    io $ sendCommand conn (ShowWindows [wrWindowId w])

-- | Set focus to a specific window.
setFocus :: WindowRef -> M ()
setFocus w = do
    conn <- asks connection
    io $ sendCommand conn (FocusWindow (wrWindowId w) (wrPid w))

-- | Jump to the workspace holding the window macOS currently considers
-- focused, and focus it. Useful after clicking a Dock icon for an app
-- whose window sits on an off-screen workspace: mcmonad's StackSet focus
-- does not follow such activations (the AX\/NSWorkspace resolve helpers
-- only act on the current workspace), so we ask the daemon where focus
-- actually landed and follow it.
--
-- Asynchronous: this only fires the 'QueryFocusedWindow' query. The
-- actual workspace switch happens when the 'FocusedWindowQueryResponse'
-- event arrives — see the handler in "MCMonad.Main".
jumpToActiveWindow :: M ()
jumpToActiveWindow = do
    conn <- asks connection
    io $ sendCommand conn QueryFocusedWindow

-- | Open the fuzzy window-search dropdown. The daemon owns the picker
-- UI; a selection returns as a 'MCMonad.IPC.MenuFocusWindow' event,
-- which reuses the menubar dropdown's focus-and-jump path.
showWindowPicker :: M ()
showWindowPicker = do
    conn <- asks connection
    io $ sendCommand conn ShowWindowPicker

-- | Open the Spotlight launcher in a given mode: @"command"@ (the command
-- runner + app launcher + voice) or @"window"@ (fuzzy window search). The
-- daemon owns the UI and cycles modes on @Tab@; a window selection comes
-- back as a 'MCMonad.IPC.MenuFocusWindow' event (same focus-and-jump path
-- as 'showWindowPicker'), while app launch and timers are handled entirely
-- daemon-side.
showSpotlight :: String -> M ()
showSpotlight mode = do
    conn <- asks connection
    io $ sendCommand conn (ShowSpotlight mode)

-- ---------------------------------------------------------------------------
-- Launching programs

-- | Spawn an external process. The process is fully detached from the
-- window manager.
spawn :: String -> M ()
spawn cmd = io $ void $ forkIO $ void $
    createProcess (shell cmd)
        { close_fds = True
        , create_group = True
        }

-- ---------------------------------------------------------------------------
-- Timers
--
-- Timers are owned by the brain (state of record) but rendered + clocked
-- by mcmonad-core. The brain holds the canonical list in 'MState.timers';
-- whenever it changes, 'pushTimers' ships the full list to the daemon (which
-- redraws the menubar countdown and re-arms its 1-second fire tick) and
-- 'syncTimers' additionally persists it so the timers survive a Mod-q /
-- launchd restart. The daemon detects fire from its own wall clock and
-- reports it back as a 'MCMonad.IPC.TimerFired' event; the handler in
-- "MCMonad.Main" then drops the timer and re-syncs.

-- | Current wall-clock time as POSIX epoch seconds (UTC). Matches the
-- daemon's @Date().timeIntervalSince1970@ exactly, so a 'Timer.tmFireAt'
-- computed here lines up with mcmonad-core's countdown.
nowEpoch :: IO Double
nowEpoch = realToFrac <$> getPOSIXTime

-- | Ship the current timer list to mcmonad-core for rendering and firing.
-- Called on startup (to resume restored timers) and after every timer
-- mutation. Sends the full list — the daemon treats it as authoritative.
pushTimers :: M ()
pushTimers = do
    conn <- asks connection
    ts   <- gets timers
    io $ sendCommand conn (SetTimers ts)

-- | Persist the timer list right now, alongside window state. Unthrottled
-- (unlike the 'windows' save path): timer edits are infrequent and must
-- survive an immediate crash or restart.
saveTimersIO :: M ()
saveTimersIO = do
    ws  <- gets windowset
    aff <- gets affinity
    ts  <- gets timers
    nid <- gets nextTimerId
    io $ saveStateIO ws aff ts nid

-- | Resync after a timer mutation: push the new list to the daemon and
-- persist it. The single funnel every timer event handler calls.
syncTimers :: M ()
syncTimers = pushTimers >> saveTimersIO

-- ---------------------------------------------------------------------------
-- Timer activity journal
--
-- An append-only JSONL log of every timer lifecycle event, written to
-- @~/.local/state/mcmonad/timers.jsonl@. Unlike the state file (a snapshot,
-- overwritten on each save) this is a permanent history, so the user can
-- reconstruct what they were doing at the computer after the fact. One
-- self-contained JSON object per line: a UTC @ts@, the @event@ name, and
-- the event-specific fields (label, workspace, durations). Best-effort —
-- a write failure is logged but never raised, so journalling can't take
-- down the WM (same discipline as 'saveStateIO').

-- | Path to the timer activity journal (XDG state dir).
getTimerJournalFile :: IO FilePath
getTimerJournalFile = do
    home <- getHomeDirectory
    return (home </> ".local" </> "state" </> "mcmonad" </> "timers.jsonl")

-- | Format an absolute POSIX-epoch-seconds timestamp (as carried by
-- 'MCMonad.Core.Timer.tmFireAt') as an ISO-8601 UTC string.
isoFromEpoch :: Double -> String
isoFromEpoch = iso8601Show . posixSecondsToUTCTime . realToFrac

-- | Append one timer event to the journal: a UTC @ts@, the @event@ name,
-- then the supplied fields. The single low-level writer the typed
-- @journal*@ helpers funnel through.
journalTimer :: String -> [Pair] -> M ()
journalTimer event extra = io $ do
    now <- getCurrentTime
    let obj  = Aeson.object (("ts" .= iso8601Show now) : ("event" .= event) : extra)
        line = Aeson.encode obj <> LBS.singleton 0x0A  -- one object per line
    (do f <- getTimerJournalFile
        createDirectoryIfMissing True (takeDirectory f)
        LBS.appendFile f line)
        `catch` \e ->
            hPutStrLn stderr $ "mcmonad: timer journal write failed: "
                ++ show (e :: IOException)

-- | Common identity fields shared by most journal events.
timerIdentity :: Timer -> [Pair]
timerIdentity t =
    [ "id" .= tmId t, "label" .= tmLabel t, "workspace" .= tmWorkspace t ]

-- | A fresh countdown was set from Spotlight. Carries the requested
-- duration and the absolute fire time.
journalStarted :: Double -> Timer -> M ()
journalStarted secs t = journalTimer "started" $
    timerIdentity t ++
    [ "durationSec" .= (round secs :: Int), "fireAt" .= isoFromEpoch (tmFireAt t) ]

-- | A fired timer was re-armed from its reminder card.
journalSnoozed :: Double -> Timer -> M ()
journalSnoozed secs t = journalTimer "snoozed" $
    timerIdentity t ++
    [ "durationSec" .= (round secs :: Int), "fireAt" .= isoFromEpoch (tmFireAt t) ]

-- | A timer reached its deadline.
journalFired :: Timer -> M ()
journalFired t = journalTimer "fired" (timerIdentity t)

-- | A still-running timer was cancelled; records how much time was left.
journalCancelled :: Timer -> M ()
journalCancelled t = do
    now <- io nowEpoch
    journalTimer "cancelled" $
        timerIdentity t ++ [ "remainingSec" .= (round (max 0 (tmFireAt t - now)) :: Int) ]

-- | A reminder card was dismissed (the timer had already fired).
journalDismissed :: String -> String -> M ()
journalDismissed lbl ws =
    journalTimer "dismissed" [ "label" .= lbl, "workspace" .= ws ]

-- | The user jumped to a timer's origin workspace from its reminder card.
journalJumped :: String -> String -> M ()
journalJumped lbl ws =
    journalTimer "jumped" [ "label" .= lbl, "workspace" .= ws ]

-- ---------------------------------------------------------------------------
-- State persistence

-- | Atomically write the current 'WindowSet' (plus affinity) to
-- @~\/.config\/mcmonad\/mcmonad.state@.
--
-- Called automatically by 'windows' (throttled — see
-- 'saveThrottleSeconds') and explicitly by 'restart' before @exec@.
-- Write is atomic via tempfile + rename. File mode is 0600.
-- Errors are logged but never raised; a transient disk hiccup must
-- not crash the WM.
saveStateIO
    :: WindowSet
    -> M.Map String ScreenId
    -> [Timer]
    -> Int
    -> IO ()
saveStateIO ws aff timers' nextTimerId' = do
    let snapshot = windowSetToSerial ws aff timers' nextTimerId'
    sf <- getStateFile
    let tmp = sf ++ ".tmp"
    (do writeFile tmp (show snapshot)
        Posix.setFileMode tmp 0o600
        Posix.rename tmp sf)
        `catch` \e ->
            hPutStrLn stderr $ "mcmonad: state save failed: " ++ show (e :: IOException)

-- | Read the saved state from disk, if any. Returns 'Nothing' when:
--
--   * the file doesn't exist (first-ever run on this user);
--   * the file fails to parse (older format, hand-edited, corrupt);
--   * the @ssVersion@ field doesn't match 'persistenceVersion'.
--
-- In the failure cases, the stale file is moved aside to
-- @mcmonad.state.bak@ so the next 'saveStateIO' doesn't overwrite
-- what might be the only copy the user has — they can recover it
-- manually if they want.
loadStateIO :: IO (Maybe (SerialState WindowRef))
loadStateIO = do
    sf <- getStateFile
    exists <- doesFileExist sf
    if not exists
        then return Nothing
        else (do
            contents <- readFile sf
            case reads contents of
                [(saved, _)]
                    | ssVersion saved == persistenceVersion -> do
                        hPutStrLn stderr $
                            "mcmonad: loaded saved state from " ++ sf
                        return (Just saved)
                _ -> do
                    hPutStrLn stderr $
                        "mcmonad: saved state at " ++ sf
                        ++ " is unreadable or has wrong version; moving to .bak"
                    Posix.rename sf (sf ++ ".bak")
                    return Nothing)
            `catch` \e -> do
                hPutStrLn stderr $
                    "mcmonad: state load failed: " ++ show (e :: IOException)
                return Nothing

-- | The mcmonad config directory: @~\/.config\/mcmonad@.
getConfigDir :: IO FilePath
getConfigDir = do
    home <- getHomeDirectory
    return (home </> ".config" </> "mcmonad")

-- | Path to the user's custom config source.
getConfigSource :: IO FilePath
getConfigSource = (</> "mcmonad.hs") <$> getConfigDir

-- | Path to the compiled custom binary.
getCustomBinary :: IO FilePath
getCustomBinary = (</> ("mcmonad-" ++ arch ++ "-" ++ os)) <$> getConfigDir

-- | Path to the serialised state file for transparent restart.
getStateFile :: IO FilePath
getStateFile = (</> "mcmonad.state") <$> getConfigDir

-- | Recompile the user's @mcmonad.hs@.  Returns 'True' on success (or if
-- no custom config exists).
--
-- Requires @$MCMONAD_GHC@ to point to a GHC that has the mcmonad library
-- in its package database.  The home-manager module and app bundle both
-- set this automatically.
recompile :: IO Bool
recompile = do
    src <- getConfigSource
    exists <- doesFileExist src
    if not exists
        then return True
        else do
            mGhc <- lookupEnv "MCMONAD_GHC"
            case mGhc of
                Nothing -> do
                    hPutStrLn stderr $ unlines
                        [ "mcmonad: MCMONAD_GHC is not set."
                        , "  Set MCMONAD_GHC to a ghc that has the mcmonad library"
                        , "  in its package database. The home-manager module and"
                        , "  .app bundle set this automatically."
                        ]
                    return False
                Just ghc -> do
                    bin <- getCustomBinary
                    hPutStrLn stderr $ "mcmonad: recompiling " ++ src ++ " with " ++ ghc
                    (exit, _, err) <- readProcessWithExitCode ghc
                        ["--make", src, "-o", bin, "-v0"] ""
                    case exit of
                        ExitSuccess -> do
                            -- Stamp the binary with our protocol version. The
                            -- launcher reads this sidecar and refuses to use
                            -- the custom binary if its stamp doesn't match
                            -- the bundle's protocol-version resource — that
                            -- prevents the crash-loop when the IPC has moved
                            -- on but the user's Mod-q-compiled binary hasn't.
                            writeFile (bin ++ ".proto") (show protocolVersion)
                            hPutStrLn stderr "mcmonad: recompile succeeded"
                            return True
                        _ -> do
                            hPutStrLn stderr $ "mcmonad: recompile FAILED:\n" ++ err
                            return False

-- | Recompile and restart the Haskell process.  The Swift daemon stays
-- running and the new process reconnects.
--
-- 1. Serialise 'WindowSet' + 'StableWindowId' state to disk
-- 2. Recompile @~\/.config\/mcmonad\/mcmonad.hs@ (if it exists)
-- 3. @exec@ the new binary (or self) with @--resume@
--
-- The @--resume@ flag is kept for backwards compatibility but is now
-- vestigial: every mcmonad startup checks for the saved state file and
-- restores from it when present, regardless of how it was launched.
restart :: M ()
restart = do
    -- 1. Serialise state
    ws <- gets windowset
    aff <- gets affinity
    ts <- gets timers
    nid <- gets nextTimerId
    io $ do
        sf <- getStateFile
        saveStateIO ws aff ts nid
        hPutStrLn stderr $ "mcmonad: state written to " ++ sf

    -- 2. Recompile
    ok <- io recompile
    unless ok $ io $ hPutStrLn stderr "mcmonad: recompile failed, restarting with old binary"

    -- 3. Determine which binary to exec.
    --    Use the custom binary only when its protocol-version stamp
    --    matches ours; otherwise fall back to self (the bundled
    --    binary). Without this check, a failed Mod-q recompile (or a
    --    stale binary left over from an mcmonad upgrade) would exec a
    --    binary that speaks the wrong IPC and crash-loop.
    io $ do
        customBin <- getCustomBinary
        hasCustom <- doesFileExist customBin
        customStampOk <- if hasCustom then checkProtoStamp customBin else return False
        self <- getExecutablePath
        let bin = if hasCustom && customStampOk then customBin else self
        when (hasCustom && not customStampOk) $
            hPutStrLn stderr $
                "mcmonad: custom binary " ++ customBin
                ++ " has missing/mismatched protocol stamp; using bundled"
        hPutStrLn stderr $ "mcmonad: exec " ++ bin ++ " --resume"
        executeFile bin False ["--resume"] Nothing
  where
    checkProtoStamp customBin = do
        let stamp = customBin ++ ".proto"
        exists <- doesFileExist stamp
        if not exists
            then return False
            else do
                contents <- readFile stamp
                case reads contents :: [(Int, String)] of
                    [(n, _)] -> return (n == protocolVersion)
                    _        -> return False

-- ---------------------------------------------------------------------------
-- Screens

-- | Get the workspace tag visible on a given screen.
screenWorkspace :: ScreenId -> M (Maybe String)
screenWorkspace sc = do
    ws <- gets windowset
    return $ W.lookupWorkspace sc ws

-- | Handle a change in screen configuration. Redistributes workspaces
-- across the new set of screens, preserving as much state as possible.
--
-- Screen *identity* is what gets preserved, not list position. An
-- earlier version rebuilt the assignment from
-- @current : visible ++ hidden@ and handed the head to @S 0@, which
-- meant that whenever the focused screen was not @S 0@, every
-- @didChangeScreenParameters@ notification swapped the monitors'
-- workspaces — and that notification fires for far more than
-- plug/unplug (resolution changes, display sleep, menu-bar geometry).
-- The visible symptom was windows ping-ponging between displays.
--
-- The rule now: a screen id that still exists keeps whatever workspace
-- it was showing, and the focused screen stays focused if it survived.
-- Only genuinely orphaned workspaces (their monitor went away) get
-- redistributed, and they fill vacancies before the hidden pool does,
-- so unplugging a display doesn't strand its workspace.
rescreen :: [ScreenInfo] -> M ()
rescreen newScreens = do
    ws <- gets windowset
    let newDetails = zipWith (\i si -> (S i, SD (siFrame si)))
                             [0 :: Int ..] newScreens
        liveSids   = S.fromList (map fst newDetails)
    case reassignScreens newDetails ws of
        Nothing  -> return ()   -- no screens at all: nothing sensible to do
        Just ws' -> do
            modify $ \s -> s
                { windowset = ws'
                -- Drop affinities pointing at screens that no longer exist.
                , affinity  = M.filter (`S.member` liveSids) (affinity s)
                }
            windows id  -- trigger relayout

-- | The pure half of 'rescreen': map the new @(ScreenId, ScreenDetail)@
-- list onto the existing workspaces. 'Nothing' when there are no
-- screens to assign to.
--
-- Generic over the workspace/window types so the properties can drive
-- it directly.
reassignScreens
    :: (Eq i, Eq sid, Ord sid)
    => [(sid, sd)]
    -> W.StackSet i l a sid sd
    -> Maybe (W.StackSet i l a sid sd)
reassignScreens newDetails ws = case assigned of
    []           -> Nothing
    (firstScr:_) ->
        let newCurrent = case find ((== oldCurrentSid) . W.screen) assigned of
                Just scr -> scr
                Nothing  -> firstScr   -- focused monitor was unplugged
        in Just ws { W.current = newCurrent
                   , W.visible = filter ((/= W.screen newCurrent) . W.screen)
                                        assigned
                   , W.hidden  = newHidden
                   }
  where
    liveSids      = S.fromList (map fst newDetails)
    oldScreens    = screensOf ws
    oldCurrentSid = W.screen (W.current ws)
    heldBySid     = M.fromList [ (W.screen s, W.workspace s) | s <- oldScreens ]

    -- Workspaces whose monitor disappeared, then the hidden pool.
    -- Orphans first: they were on a screen a moment ago, so they are the
    -- better candidates for a newly-appeared one.
    orphans = [ W.workspace s | s <- oldScreens
              , not (W.screen s `S.member` liveSids) ]
    pool    = orphans ++ W.hidden ws

    -- Walk the new screen list, giving each id back its own workspace
    -- where possible and drawing from the pool otherwise.
    (assigned, newHidden) = assign newDetails pool
    assign []               leftover = ([], leftover)
    assign ((sid, sd):rest) leftover =
        case M.lookup sid heldBySid of
            Just wsp ->
                let (done, rest') = assign rest leftover
                in (W.Screen wsp sid sd : done, rest')
            Nothing -> case leftover of
                (wsp:leftover') ->
                    let (done, rest') = assign rest leftover'
                    in (W.Screen wsp sid sd : done, rest')
                [] -> assign rest []   -- no workspace to spare

-- ---------------------------------------------------------------------------
-- Utilities

-- | Perform an action if the value is 'Just'.
whenJust :: Monad m => Maybe a -> (a -> m ()) -> m ()
whenJust Nothing  _ = return ()
whenJust (Just a) f = f a
