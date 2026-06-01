module MCMonad.Main
    ( mcmonad
    , launch
    ) where

import Control.Monad (forever, when)
import Data.List (find)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Word (Word32)
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
    let (ws0, restoredAffinity, unmatchedLives) = case mSaved of
            Just (ws, aff, leftovers) ->
                (ws, aff, leftovers)
            Nothing ->
                let ws = buildInitialWindowSet cfg screens
                in  (ws, initialAffinities ws, existingWindows)

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
                       }

    _ <- runM mconf mst0 $ do
        -- Live windows that didn't match a saved entry go through the
        -- usual manage hook (default workspace placement, ManageHook
        -- rules, etc.). On a fresh start that's every window; on a
        -- restore it's just the windows that opened since save.
        let hook = manageHook cfg
        mapM_ (\wi -> manageSilent wi hook) unmatchedLives
        windows id

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
-- Returns the rebuilt 'WindowSet', the restored affinity map, and
-- the list of live windows that did NOT appear in the saved state
-- (those go through the manage hook). Returns 'Nothing' when no
-- save file exists.
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
    -> IO (Maybe (WindowSet, Map.Map String ScreenId, [WindowInfo]))
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
                -- — these died while mcmonad was down. Drop them.
                staleSaved = filter (`Set.notMember` liveSet) (W.allWindows ws0)
                ws = foldr W.delete' ws0 staleSaved
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
            return $ Just (ws, aff, unmatched)
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

        WindowFrameChanged _wid _rect ->
            -- SkyLight frame-change events fire constantly (including from our
            -- own SetFrames). Ignore them — drag completion is handled by the
            -- explicit WindowDragCompleted event below.
            return ()

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
            -- AX reported the exact focused window of an app. Trust this:
            -- it is the only signal that distinguishes between multiple
            -- windows of the same PID. Do NOT echo a FocusWindow back to
            -- Swift — macOS already focused it; we'd just feedback-loop.
            ws <- gets windowset
            whenJust (resolveFocusedWindow wid pid ws) $ \ws' ->
                modify $ \s -> s { windowset = ws' }

        FrontAppChanged pid -> do
            -- App-level activation (NSWorkspace / SkyLight 1508). Carries
            -- no windowId, so we only act when the user actually switched
            -- *across* apps. Within an app, the precise AX-driven
            -- FocusedWindowChanged is authoritative — letting this path
            -- run would clobber it with "first window of this PID".
            ws <- gets windowset
            whenJust (resolveFrontApp pid ws) $ \ws' ->
                modify $ \s -> s { windowset = ws' }

        MouseEnteredWindow wid _pid ->
            when (focusFollowsMouse cfg) $ do
                ws <- gets windowset
                let mref = findByWindowId wid (W.allWindows ws)
                whenJust mref $ \wref ->
                    -- Only change focus, don't relayout (avoid feedback loop)
                    when (W.peek ws /= Just wref) $
                        windows (W.focusWindow wref)

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
-- Helpers

-- | Find a WindowRef by its CGWindowID in a list.
findByWindowId :: Word32 -> [WindowRef] -> Maybe WindowRef
findByWindowId wid = find (\w -> wrWindowId w == wid)
