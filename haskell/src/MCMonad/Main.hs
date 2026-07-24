module MCMonad.Main
    ( mcmonad
    , launch
    ) where

import Control.Monad (forever, when)
import Data.List (find)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Int (Int32)
import Data.Word (Word32)
import Data.Time.Clock (getCurrentTime)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitSuccess)
import System.IO (hPutStrLn, stderr)
import qualified XMonad.StackSet as W

import MCMonad.Config
import MCMonad.Core
import MCMonad.Debug (toggleDebugOverlays, setDebugOverlays)
import MCMonad.IPC
import MCMonad.Operations
import MCMonad.Persistence (SerialState(..), serialToWindowSet)

-- | Main entry point. Connect to the Swift daemon, initialise state, and
-- run the event loop. This is what users call from their @mcmonad.hs@:
--
-- @
-- main = mcmonad def { terminal = "ghostty", ... }
-- @
mcmonad :: MConfig Layout -> IO ()
mcmonad = launch

-- | Connect to mcmonad-core, build initial state, and enter the event loop.
launch :: MConfig Layout -> IO ()
launch cfg = do
    args <- getArgs

    -- Print the IPC protocol version and exit. Handled before any IO so
    -- the launcher can probe a binary's protocol stamp without it
    -- attempting to start the WM. Old binaries that don't recognise the
    -- flag will not match the launcher's stamp file check anyway, so
    -- the launcher just falls back to the bundled binary in that case.
    when ("--protocol-version" `elem` args) $ do
        putStrLn (show protocolVersion)
        exitSuccess

    -- 1. Connect to mcmonad-core
    conn <- connectToCore

    -- 2. Wait for Ready event
    waitForReady conn

    -- 3. Query screen geometry
    sendCommand conn QueryScreens
    screens <- waitForScreens conn

    -- 4. Build the hotkey map and register hotkeys
    let keyMap    = mcKeys cfg cfg
        keyList   = Map.toAscList keyMap
        hotkeySpecs = zipWith (\i ((mods, kc), _) -> HotkeySpec i kc mods)
                              [0 ..] keyList
        -- Map from hotkey ID to action, for dispatch in the event loop
        hotkeyIdMap = Map.fromList
                      $ zipWith (\i (_, action) -> (i, action)) [0 ..] keyList
    sendCommand conn (RegisterHotkeys hotkeySpecs)

    -- 5. Query existing windows
    sendCommand conn QueryWindows
    existingWindows <- waitForWindows conn

    -- 6. Check debug mode
    debug <- maybe False (const True) <$> lookupEnv "MCMONAD_DEBUG"
    when debug $ hPutStrLn stderr "mcmonad: debug logging enabled (MCMONAD_DEBUG)"

    -- 7. Try to restore from the persisted snapshot. This runs on
    --    EVERY startup (not just --resume), so windows return to
    --    their workspaces across any mcmonad-side restart as long
    --    as the WindowServer is still alive (i.e. the user hasn't
    --    logged out). After logout / reboot, identities don't
    --    match anything and every window goes through the manage
    --    hook — see 'MCMonad.Persistence' for the design.
    mSaved <- restoreSnapshot cfg screens existingWindows
    let (ws0, restoredAffinity, unmatchedLives, restoredTimers, restoredNextTimerId) =
            case mSaved of
                Just (ws, aff, leftovers, tms, nid) ->
                    (ws, aff, leftovers, tms, nid)
                Nothing ->
                    let ws = buildInitialWindowSet cfg screens
                    in  (ws, initialAffinities ws, existingWindows, [], 1)

    let mconf = MConf { connection = conn }
        -- Seed the metadata cache from the daemon's enumeration of
        -- live windows. After a Haskell-only restart, this covers
        -- both restored windows (already in ws0) and new windows that
        -- will go through the manage hook a few lines below — the
        -- manage hook re-inserts but it's idempotent.
        seededMetadata = Map.fromList
            [ (WindowRef (wiWindowId wi) (wiPid wi), metadataFromInfo wi)
            | wi <- existingWindows
            ]
        mst0  = MState { windowset = ws0
                       , mapped = Set.empty
                       , affinity = restoredAffinity
                       , inputMode = "default"
                       , sticky = Set.empty
                       , scratchpads = Map.empty
                       , scratchpadRects = Map.empty
                       , pendingScratchpad = Nothing
                       , windowRects = Map.empty
                       , warpOnSwitch = mouseWarping cfg
                       , windowMetadata = seededMetadata
                       , debugOverlays = False
                       , lastSaveAt = Nothing
                       , timers = restoredTimers
                       , nextTimerId = restoredNextTimerId
                       , focusIntent = Nothing
                       , unmanagedOrigin = Map.empty
                       , reclaimOrigin  = Map.empty
                       }

    _ <- runM mconf mst0 $ do
        -- Live windows that didn't match a saved entry go through the
        -- usual manage hook (default workspace placement, ManageHook
        -- rules, etc.). On a fresh start that's every window; on a
        -- restore it's just the windows that opened since save.
        let hook = manageHook cfg
        mapM_ (\wi -> manageSilent wi hook) unmatchedLives
        windows id

        -- Resume any restored countdown timers: push the persisted list
        -- to mcmonad-core so the menubar countdown and reminder firing
        -- pick up where they left off across a Mod-q / launchd restart.
        -- On a fresh start this sends an empty list, which is a harmless
        -- no-op (the daemon tears down its timer status item).
        pushTimers

        -- Push the initial debug-overlay state to mcmonad-core. The
        -- daemon defaults to "overlay off" but we send the explicit
        -- value so a daemon that *was* showing overlays from a
        -- previous Haskell-side session clears them on reconnect.
        setDebugOverlays False

        -- Run the startup hook (every launch — user may want it)
        userCodeDef () (startupHook cfg)

        -- Enter the event loop
        eventLoop debug cfg hotkeyIdMap

    return ()

-- | Try to restore a previous snapshot.
--
-- Returns the rebuilt 'WindowSet', the restored affinity map, the
-- list of live windows that did NOT appear in the saved state (those
-- go through the manage hook), the restored timer list, and the saved
-- monotonic timer-id counter. Returns 'Nothing' when no save file exists.
--
-- Identity is exact 'WindowRef' equality: a saved window survives
-- restore iff its @(wid, pid)@ pair appears in the live window list
-- that mcmonad-core just enumerated. This is correct for every
-- mcmonad-side restart (Mod-q, daemon kick, launchd restart) and
-- intentionally collapses to "fresh start" after logout / reboot,
-- where no IDs match by construction and the manage hook does all
-- the work.
restoreSnapshot
    :: MConfig Layout
    -> [ScreenInfo]
    -> [WindowInfo]
    -> IO (Maybe (WindowSet, Map.Map String ScreenId, [WindowInfo], [Timer], Int))
restoreSnapshot cfg screens existingWindows = do
    mSaved <- loadStateIO
    case mSaved of
        Nothing -> return Nothing
        Just savedRaw -> do
            let validTags = Set.fromList (mcWorkspaces cfg)
                saved     = filterToValidTags validTags savedRaw
                screenTuples =
                    [ (S i, SD (siFrame si))
                    | (i, si) <- zip [0 :: Int ..] screens
                    ]
                ws0 = serialToWindowSet
                        (layoutHook cfg)
                        (mcWorkspaces cfg)
                        screenTuples
                        saved
                liveSet = Set.fromList
                    [ WindowRef (wiWindowId wi) (wiPid wi)
                    | wi <- existingWindows
                    ]
                -- Saved windows whose (wid, pid) isn't in the live set
                -- — these died while mcmonad was down. Drop them with
                -- the full 'W.delete' (not 'W.delete''), which also
                -- clears their floating entries — dead windows never
                -- come back under the same id, and 'delete'' here was
                -- one of the leaks that bloated mcmonad.state.
                staleSaved = filter (`Set.notMember` liveSet) (W.allWindows ws0)
                ws = foldr W.delete ws0 staleSaved
                -- Live windows we don't have in the saved set go
                -- through the manage hook.
                inWs wi =
                    let wr = WindowRef (wiWindowId wi) (wiPid wi)
                    in W.member wr ws
                unmatched = filter (not . inWs) existingWindows
                aff = Map.fromList
                        [ (tag, S n)
                        | (tag, n) <- ssAffinity saved
                        , Set.member tag validTags
                        ]
            hPutStrLn stderr $
                "mcmonad: restored "
                ++ show (length (W.allWindows ws))
                ++ " window(s); " ++ show (length staleSaved) ++ " stale; "
                ++ show (length unmatched) ++ " new"
            return $ Just (ws, aff, unmatched, ssTimers saved, ssNextTimerId saved)
  where
    -- A saved snapshot may carry workspace tags that don't exist in
    -- the current config (the user renamed a workspace). Drop them
    -- so 'serialToWindowSet' doesn't try to materialise a workspace
    -- it can't sensibly produce.
    filterToValidTags
        :: Set.Set String
        -> SerialState WindowRef
        -> SerialState WindowRef
    filterToValidTags valid saved = saved
        { ssStacks =
            [ entry
            | entry@(tag, _) <- ssStacks saved
            , Set.member tag valid
            ]
        , ssCurrentTag =
            if Set.member (ssCurrentTag saved) valid
                then ssCurrentTag saved
                else case [ t | (t, _) <- ssStacks saved, Set.member t valid ] of
                    (t:_) -> t
                    []    -> ssCurrentTag saved   -- empty WindowSet anyway
        , ssAffinity =
            [ pair | pair@(tag, _) <- ssAffinity saved, Set.member tag valid ]
        }

-- ---------------------------------------------------------------------------
-- Initialisation helpers

-- | Block until a Ready event arrives, discarding anything else.
waitForReady :: Connection -> IO ()
waitForReady conn = do
    ev <- readEvent conn
    case ev of
        Ready -> return ()
        _     -> waitForReady conn

-- | Block until a ScreensChanged event arrives after QueryScreens.
waitForScreens :: Connection -> IO [ScreenInfo]
waitForScreens conn = do
    ev <- readEvent conn
    case ev of
        ScreensChanged scs -> return scs
        _ -> waitForScreens conn  -- skip unexpected events, keep waiting

-- | Block until a QueryWindowsResponse event arrives after QueryWindows.
waitForWindows :: Connection -> IO [WindowInfo]
waitForWindows conn = do
    ev <- readEvent conn
    case ev of
        QueryWindowsResponse ws -> return ws
        _ -> waitForWindows conn  -- skip unexpected events, keep waiting

-- | Build the initial 'WindowSet' from config and screen info.
buildInitialWindowSet :: MConfig Layout -> [ScreenInfo] -> WindowSet
buildInitialWindowSet cfg screens =
    W.StackSet
        { W.current  = currentSc
        , W.visible  = visibleScs
        , W.hidden   = hiddenWSs
        , W.floating = Map.empty
        }
  where
    workspaces' = mcWorkspaces cfg
    layout'     = layoutHook cfg
    screenList  = zip [0 :: Int ..] screens

    -- Pair each screen with a workspace; remaining workspaces are hidden
    (visibleWS, hiddenWS) = splitAt (max 1 (length screenList)) workspaces'

    mkWorkspace tag = W.Workspace tag layout' Nothing

    -- Current (focused) screen -- always the first
    currentSc = case (visibleWS, screenList) of
        (tag:_, (sid, si):_) ->
            W.Screen (mkWorkspace tag) (S sid) (SD (siFrame si))
        _ -> error "mcmonad: no workspaces or no screens — cannot start"

    -- Other visible screens
    visibleScs =
        [ W.Screen (mkWorkspace tag) (S sid) (SD (siFrame si))
        | (tag, (sid, si)) <- zip (drop 1 visibleWS) (drop 1 screenList)
        ]

    -- Hidden workspaces (not displayed on any screen)
    hiddenWSs = map mkWorkspace hiddenWS

-- | Seed the affinity map from the initial screen assignments.
initialAffinities :: WindowSet -> Map.Map String ScreenId
initialAffinities ws = Map.fromList
    [ (W.tag (W.workspace scr), W.screen scr)
    | scr <- W.current ws : W.visible ws
    ]

-- ---------------------------------------------------------------------------
-- Event loop

-- | The main event loop: read events from the Swift daemon and dispatch.
eventLoop :: Bool -> MConfig Layout -> Map.Map Int (M ()) -> M ()
eventLoop debug cfg hotkeyIdMap = forever $ do
    evt <- withConnection $ \conn -> io $ readEvent conn
    userCodeDef () $ handleEvent debug cfg hotkeyIdMap evt

-- | Dispatch a single event from the Swift daemon.
handleEvent :: Bool -> MConfig Layout -> Map.Map Int (M ()) -> Event -> M ()
handleEvent debug cfg hotkeyIdMap evt = do
    when debug $ io $ hPutStrLn stderr $ "EVENT: " ++ show evt
    case evt of
        WindowCreated winfo -> do
            manage winfo (manageHook cfg)
            -- Register as named scratchpad if one is pending
            pending <- gets pendingScratchpad
            whenJust pending $ \name -> do
                let wr = WindowRef (wiWindowId winfo) (wiPid winfo)
                modify $ \s -> s
                    { scratchpads = Map.insert name wr (scratchpads s)
                    , pendingScratchpad = Nothing
                    }
                -- Float the scratchpad window
                windows (W.float wr (W.RationalRect 0.1 0.05 0.8 0.6))

        WindowDestroyed wid -> do
            ws <- gets windowset
            let mref = findByWindowId wid (W.allWindows ws)
            whenJust mref $ \wref -> unmanage wref

        WindowFrameChanged wid rect -> do
            -- SkyLight frame-change events fire constantly (including from our
            -- own SetFrames); drag completion is handled by the explicit
            -- WindowDragCompleted event below. The one report we act on: a
            -- window that should be parked showing up with an on-screen
            -- frame. macOS un-parks every hidden window in one silent sweep
            -- during native-fullscreen Space transitions (no move events for
            -- the sweep itself), so a single straggler's drift report
            -- triggers a full re-park, not a one-window fix.
            ws <- gets windowset
            mappedSet <- gets mapped
            case findByWindowId wid (W.allWindows ws) of
                Just wref | not (Set.member wref mappedSet)
                          , not (frameAtParkCorner rect ws)
                    -> reassertHiddenWindows
                _   -> return ()

        WindowDragCompleted wid pid rect -> do
            -- User finished an Option+drag move/resize. Auto-float the window
            -- at its new absolute position (convert to RationalRect).
            let wr = WindowRef wid pid
            ws <- gets windowset
            when (W.member wr ws) $ do
                let screenR = findScreenForWindow wr ws
                    rx = toRational ((rect_x rect - rect_x screenR) / rect_w screenR)
                    ry = toRational ((rect_y rect - rect_y screenR) / rect_h screenR)
                    rw = toRational (rect_w rect / rect_w screenR)
                    rh = toRational (rect_h rect / rect_h screenR)
                windows (W.float wr (W.RationalRect rx ry rw rh))

        FocusedWindowChanged wid pid -> do
            handleFocusedWindowChanged wid pid
            -- A should-be-hidden window receiving AX focus means the
            -- user reached it on screen — it drifted (fullscreen-
            -- transition sweep, app self-move) and is lying around as
            -- a "background". FrontAppChanged below heals cross-app
            -- clicks; this covers a drifted window of the app that is
            -- already frontmost. Also fires on macOS' post-switch
            -- focus bounces for freshly hidden windows, where it is a
            -- cheap no-op (the daemon skips windows already parked).
            ws <- gets windowset
            mappedSet <- gets mapped
            case findByWindowId wid (W.allWindows ws) of
                Just wref | not (Set.member wref mappedSet) ->
                    reassertHiddenWindows
                _ -> return ()

        FocusedWindowQueryResponse wid pid -> do
            -- Answer to our own 'QueryFocusedWindow' (the Mod-Cmd-Shift-J
            -- "jump to the active window's workspace" hotkey). The window
            -- may be on any workspace, including a hidden one or the other
            -- screen; 'W.focusWindow' brings its workspace to the current
            -- screen and focuses it. Bypasses the 'focusIntent' dispatch
            -- entirely — this is a direct, user-requested jump.
            ws <- gets windowset
            let wr = WindowRef wid pid
            when (W.member wr ws) $ windows (W.focusWindow wr)

        FrontAppChanged pid -> do
            handleFrontAppChanged pid
            -- The first front-app change after a native-fullscreen Space
            -- transition is the earliest reliable moment to heal the silent
            -- un-park sweep (see WindowFrameChanged above) — the sweep
            -- itself emits nothing. Idempotent-cheap: mcmonad-core skips
            -- windows already at the park corner.
            reassertHiddenWindows

        MouseEnteredWindow wid _pid ->
            when (focusFollowsMouse cfg) $ do
                ws <- gets windowset
                -- Scoped to displayed workspaces, same rule as the AX
                -- focus path: 'W.allWindows' would let the cursor
                -- brushing a parked window's 1px corner sliver drag its
                -- whole hidden workspace onto this screen.
                let mref = findByWindowId wid (visibleScreenWindows ws)
                whenJust mref $ \wref ->
                    -- Only change focus, don't relayout (avoid feedback loop)
                    when (W.peek ws /= Just wref) $
                        windows (W.focusWindow wref)

        UserMouseDown ->
            -- A physical click happened somewhere on the system. This
            -- is the only signal that reliably distinguishes user
            -- intent from macOS' AX bounce echoes after a 'FocusWindow'
            -- IPC command, so disarm 'focusIntent' unconditionally and
            -- let the next AX / NSWorkspace event flow through to
            -- 'resolveFocusedWindow' / 'resolveFrontApp' normally.
            modify $ \s -> s { focusIntent = Nothing }

        ScreensChanged scs ->
            rescreen scs

        HotkeyPressed hid ->
            case Map.lookup hid hotkeyIdMap of
                Just action -> action
                Nothing     -> return ()

        -- Menubar actions. The dropdown's "Debug frame overlays" item,
        -- workspace rows, and per-window rows all dispatch here.
        MenuToggleDebug -> toggleDebugOverlays

        MenuFocusWindow wid pid -> do
            ws <- gets windowset
            let wr = WindowRef wid pid
            when (W.member wr ws) $ windows (W.focusWindow wr)

        MenuViewWorkspace tag -> do
            ws <- gets windowset
            -- Only switch if this is actually a known workspace tag.
            let allTags = map W.tag (W.workspace (W.current ws)
                                     : map W.workspace (W.visible ws)
                                     ++ W.hidden ws)
            when (tag `elem` allTags) $ windows (W.greedyView tag)

        -- Timers. The brain owns timer state; mcmonad-core renders + clocks
        -- it. State mutations funnel through 'syncTimers' (push to the daemon
        -- + persist) so the list survives a Mod-q / launchd restart, and
        -- every lifecycle event is appended to the activity journal.
        TimerStart seconds label -> do
            -- Fresh timer from Spotlight: origin = whatever is current now,
            -- so "Jump to workspace" later returns here.
            ws <- gets windowset
            let curTag = W.tag (W.workspace (W.current ws))
            t <- addTimer seconds label curTag
            journalStarted seconds t

        TimerSnooze seconds label workspace -> do
            -- Re-arm from a reminder card: keep the original origin workspace.
            t <- addTimer seconds label workspace
            journalSnoozed seconds t

        TimerFired tid -> do
            ts <- gets timers
            whenJust (find ((== tid) . tmId) ts) journalFired
            modify $ \s -> s { timers = filter ((/= tid) . tmId) (timers s) }
            syncTimers

        TimerCancel tid -> do
            ts <- gets timers
            whenJust (find ((== tid) . tmId) ts) journalCancelled
            modify $ \s -> s { timers = filter ((/= tid) . tmId) (timers s) }
            syncTimers

        TimerCancelAll -> do
            ts <- gets timers
            mapM_ journalCancelled ts
            modify $ \s -> s { timers = [] }
            syncTimers

        -- Reminder-card actions for an already-fired timer: no state change
        -- (it left 'timers' on fire), just a journal entry — and, for jump,
        -- the workspace switch.
        TimerDismiss label workspace ->
            journalDismissed label workspace

        TimerJump label workspace -> do
            ws <- gets windowset
            let allTags = map W.tag (W.workspace (W.current ws)
                                     : map W.workspace (W.visible ws)
                                     ++ W.hidden ws)
            journalJumped label workspace
            when (workspace `elem` allTags) $ windows (W.greedyView workspace)

        -- Events that arrive during init or are not actionable
        Ready                   -> return ()
        QueryWindowsResponse _  -> return ()
        QueryScreensResponse _  -> return ()

        IgnoredEvent name ->
            -- IPC protocol skew: a wire message we couldn't decode.
            -- Logged once per occurrence so the user notices, but
            -- does not crash the loop. Most often hit when a
            -- Mod-q-compiled binary is older than the running
            -- mcmonad-core; the launcher's protocol-version stamp
            -- check should normally prevent that pairing, but this
            -- is the defence-in-depth.
            io $ hPutStrLn stderr $
                "mcmonad: ignoring unknown wire message: " ++ T.unpack name

-- ---------------------------------------------------------------------------
-- Focus event dispatch
--
-- 'FocusedWindowChanged' (from AX) and 'FrontAppChanged' (from NSWorkspace
-- / SkyLight 1508) are normally followed because they are the only signals
-- that distinguish multi-window-per-app focus changes, but they fire just
-- as readily for macOS' internal focus-settling bounces as for legitimate
-- user intent. While 'focusIntent' is armed, mcmonad's StackSet is the
-- source of truth and these events are classified against the intent:
--
--   * exact match (wid + pid) — confirmation, no-op.
--   * same app, different window — intra-app focus change (user clicking
--     another window of the target's app); accept it and clear intent.
--   * anything else — bounce or spurious cross-app divergence; re-issue
--     'FocusWindow' to push macOS back to the target and decrement the
--     budget. When the budget exhausts the intent clears so user-
--     initiated cross-app focus changes eventually take effect.
--
-- See the 'MCMonad.Core.FocusIntent' note for the full rationale.

handleFocusedWindowChanged :: Word32 -> Int32 -> M ()
handleFocusedWindowChanged wid pid = do
    fi <- gets focusIntent
    now <- io getCurrentTime
    case fi of
        Just i | isFocusIntentTarget wid pid i ->
            -- Exact match: AX is confirming our command. StackSet is
            -- already on this window. Leave intent armed in case more
            -- divergences follow.
            return ()
        Just i | withinSettleWindow now i && isSettlingEcho wid pid i ->
            -- A window this layout pass moved is reporting focus, and it's
            -- soon enough after the write to be macOS settling around our
            -- own AX, not the user. No-op, and (unlike the cross-app
            -- branch) do NOT spend the budget: a secondary monitor's worth
            -- of settling echoes must not be able to exhaust suppression
            -- and let a later echo flip the current screen. Past the
            -- settle deadline this guard lapses, so a genuine later switch
            -- to one of these windows still follows. A real click clears
            -- the intent outright.
            return ()
        Just i | isIntentTargetPid pid i ->
            -- Same app, different window (the exact-match guard above
            -- excluded the target's wid). A different window of the
            -- target's app gained focus — almost certainly the user
            -- clicking another window in the same app. Accept it and
            -- clear the intent.
            applyAndClearIntent
        Just i ->
            -- Cross-app divergence: bounce or spurious AX event from a
            -- third app. mcmonad's view stands; push macOS back to the
            -- target and decrement the budget.
            pushBackFocus i
        Nothing ->
            -- No intent armed. AX is authoritative.
            applyClean
  where
    -- No 'windows' call: every candidate 'resolveFocusedWindow' can
    -- return is already displayed, on this screen or a secondary one,
    -- so nothing needs laying out or re-parking. What *can* change is
    -- which screen is current — hence the explicit save.
    applyClean = do
        ws <- gets windowset
        whenJust (resolveFocusedWindow wid pid ws) $ \ws' -> do
            modify $ \s -> s { windowset = ws' }
            pushOverlaySnapshot
            maybeSaveState
    applyAndClearIntent = do
        modify $ \s -> s { focusIntent = Nothing }
        applyClean

handleFrontAppChanged :: Int32 -> M ()
handleFrontAppChanged pid = do
    fi <- gets focusIntent
    now <- io getCurrentTime
    case fi of
        Just i | isIntentTargetPid pid i ->
            -- App-level confirmation. No-op; keep intent armed.
            return ()
        Just i | withinSettleWindow now i && isSettlingPidEcho pid i ->
            -- Front-app echo for an app we just moved a window of — our
            -- own AX write settling, not a genuine app switch. No-op
            -- without spending the budget (see 'handleFocusedWindowChanged').
            -- Time-bounded, so a real Cmd-Tab later still follows.
            return ()
        Just i ->
            -- Different app activated — bounce or spurious. Push back.
            pushBackFocus i
        Nothing ->
            applyClean
  where
    applyClean = do
        ws <- gets windowset
        whenJust (resolveFrontApp pid ws) $ \ws' -> do
            modify $ \s -> s { windowset = ws' }
            pushOverlaySnapshot
            maybeSaveState

-- | An event arrived that contradicts our 'FocusIntent'. macOS' focus
-- has drifted from where mcmonad put it; push focus back onto the
-- intended target by re-issuing the 'FocusWindow' IPC, and decrement
-- the budget so a pathological loop self-terminates.
pushBackFocus :: FocusIntent -> M ()
pushBackFocus i = do
    conn <- asks connection
    let t = fiTarget i
    io $ sendCommand conn (FocusWindow (wrWindowId t) (wrPid t))
    modify $ \s -> s { focusIntent = consumeIntent i }

-- ---------------------------------------------------------------------------
-- Helpers

-- | Find a WindowRef by its CGWindowID in a list.
findByWindowId :: Word32 -> [WindowRef] -> Maybe WindowRef
findByWindowId wid = find (\w -> wrWindowId w == wid)

-- | Insert a new timer (fireAt = now + seconds, with the given label and
-- origin workspace), push it to the daemon + persist, and return it so the
-- caller can write the matching journal entry. Shared by the 'TimerStart'
-- and 'TimerSnooze' handlers.
addTimer :: Double -> String -> String -> M Timer
addTimer seconds label ws = do
    now <- io nowEpoch
    nid <- gets nextTimerId
    let t = Timer { tmId = nid, tmLabel = label
                  , tmFireAt = now + seconds, tmWorkspace = ws }
    modify $ \s -> s { timers = timers s ++ [t], nextTimerId = nid + 1 }
    syncTimers
    return t
