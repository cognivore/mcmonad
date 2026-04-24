module MCMonad.Main
    ( mcmonad
    , launch
    ) where

import Control.Monad (forever, when)
import Data.List (find)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word32)
import System.Directory (doesFileExist, removeFile)
import System.Environment (getArgs, lookupEnv)
import System.IO (hPutStrLn, stderr)
import qualified XMonad.StackSet as W

import MCMonad.Config
import MCMonad.Core
import MCMonad.IPC
import MCMonad.ManageHook (ManageHook)
import MCMonad.Operations

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
    let resuming = "--resume" `elem` args

    -- 1. Connect to mcmonad-core
    conn <- connectToCore

    -- 2. Wait for Ready event
    waitForReady conn

    -- 3. Query screen geometry
    sendCommand conn QueryScreens
    screens <- waitForScreens conn

    -- 4. Build the initial StackSet (fresh or from saved state)
    (ws0, mSavedState) <- if resuming
        then loadSavedState cfg screens
        else return (buildInitialWindowSet cfg screens, Nothing)

    -- 5. Build the hotkey map and register hotkeys
    let keyMap    = mcKeys cfg cfg
        keyList   = Map.toAscList keyMap
        hotkeySpecs = zipWith (\i ((mods, kc), _) -> HotkeySpec i kc mods)
                              [0 ..] keyList
        -- Map from hotkey ID to action, for dispatch in the event loop
        hotkeyIdMap = Map.fromList
                      $ zipWith (\i (_, action) -> (i, action)) [0 ..] keyList
    sendCommand conn (RegisterHotkeys hotkeySpecs)

    -- 6. Query existing windows
    sendCommand conn QueryWindows
    existingWindows <- waitForWindows conn

    -- 7. Check debug mode
    debug <- maybe False (const True) <$> lookupEnv "MCMONAD_DEBUG"
    when debug $ hPutStrLn stderr "mcmonad: debug logging enabled (MCMONAD_DEBUG)"

    -- 8. Run the M monad
    -- Restore affinities from saved state, or seed from initial screen layout
    let restoredAffinity = case mSavedState of
            Just saved -> Map.fromList [(tag, S n) | (tag, n) <- rsAffinity saved]
            Nothing    -> initialAffinities ws0

    let mconf = MConf { connection = conn }
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
                       }

    _ <- runM mconf mst0 $ do
        case mSavedState of
            Just saved -> do
                -- Resuming: reconcile saved state with live windows.
                -- Windows that still exist stay in their saved workspace;
                -- windows that are gone get removed; new windows get managed.
                reconcileState saved existingWindows (manageHook cfg)
                windows id
            Nothing -> do
                -- Fresh start: manage all existing windows.
                let hook = manageHook cfg
                mapM_ (\wi -> manageSilent wi hook) existingWindows
                windows id

        -- Run the startup hook (even on resume — user may want it)
        userCodeDef () (startupHook cfg)

        -- Enter the event loop
        eventLoop debug cfg hotkeyIdMap

    return ()

-- | Load saved state from disk. Returns a StackSet rebuilt from the saved
-- state (using the config's layout hook) and the raw 'RestartState' for
-- reconciliation with live windows.
loadSavedState :: MConfig Layout -> [ScreenInfo]
               -> IO (WindowSet, Maybe RestartState)
loadSavedState cfg screens = do
    sf <- getStateFile
    exists <- doesFileExist sf
    if not exists
        then do
            hPutStrLn stderr "mcmonad: --resume but no state file, fresh start"
            return (buildInitialWindowSet cfg screens, Nothing)
        else do
            contents <- readFile sf
            case reads contents of
                [(saved, _)] -> do
                    hPutStrLn stderr "mcmonad: restoring saved state"
                    removeFile sf
                    let ws = rebuildWindowSet cfg screens saved
                    return (ws, Just saved)
                _ -> do
                    hPutStrLn stderr "mcmonad: failed to parse state file, fresh start"
                    removeFile sf
                    return (buildInitialWindowSet cfg screens, Nothing)

-- | Rebuild a 'WindowSet' from saved state, the config's layout hook,
-- and current screen geometry.
rebuildWindowSet :: MConfig Layout -> [ScreenInfo] -> RestartState -> WindowSet
rebuildWindowSet cfg screens saved =
    W.StackSet
        { W.current  = currentSc
        , W.visible  = visibleScs
        , W.hidden   = hiddenWSs
        , W.floating = Map.fromList
              [ (w, W.RationalRect rx ry rw rh)
              | (w, (rx, ry, rw, rh)) <- rsFloating saved
              ]
        }
  where
    layout' = layoutHook cfg
    screenList = zip [0 :: Int ..] screens

    -- Rebuild workspace stacks from saved state, using saved tags
    savedMap = Map.fromList (rsStacks saved)

    -- All workspace tags from config (saved state may have different tags
    -- if config changed, but we use config as authoritative for the set of
    -- workspaces)
    allTags = mcWorkspaces cfg

    mkWorkspace tag =
        let mStack = case Map.lookup tag savedMap of
                Just (Just (SerStack f u d)) -> Just (W.Stack f u d)
                _ -> Nothing
        in W.Workspace tag layout' mStack

    -- Pair screens with workspaces, preferring the saved current tag
    -- for the first screen
    (visibleTags, hiddenTags) = splitAt (max 1 (length screenList)) orderedTags
    orderedTags = let cur = rsCurrentTag saved
                      rest = filter (/= cur) allTags
                  in if cur `elem` allTags then cur : rest else allTags

    currentSc = case (visibleTags, screenList) of
        (tag:_, (sid, si):_) ->
            W.Screen (mkWorkspace tag) (S sid) (SD (siFrame si))
        _ -> error "mcmonad: no workspaces or no screens"

    visibleScs =
        [ W.Screen (mkWorkspace tag) (S sid) (SD (siFrame si))
        | (tag, (sid, si)) <- zip (drop 1 visibleTags) (drop 1 screenList)
        ]

    hiddenWSs = map mkWorkspace hiddenTags

-- | Reconcile saved state with live windows. Remove windows that no longer
-- exist, and manage new windows that appeared during the restart.
reconcileState :: RestartState -> [WindowInfo] -> ManageHook -> M ()
reconcileState _saved liveWindows hook = do
    ws <- gets windowset

    -- Windows we know about from saved state
    let savedWindows = W.allWindows ws
    -- Windows that actually exist right now
        liveRefs = [ WindowRef (wiWindowId wi) (wiPid wi) | wi <- liveWindows ]

    -- Remove windows that no longer exist
    let gone = filter (`notElem` liveRefs) savedWindows
    mapM_ (\w -> modify $ \s -> s { windowset = W.delete' w (windowset s) }) gone
    when (not (null gone)) $
        io $ hPutStrLn stderr $ "mcmonad: removed " ++ show (length gone) ++ " stale windows"

    -- Manage new windows that appeared during restart
    let newWindows = filter (\wi ->
            let wr = WindowRef (wiWindowId wi) (wiPid wi)
            in wr `notElem` savedWindows) liveWindows
    mapM_ (\wi -> manageSilent wi hook) newWindows
    when (not (null newWindows)) $
        io $ hPutStrLn stderr $ "mcmonad: managed " ++ show (length newWindows) ++ " new windows"

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

        FrontAppChanged pid -> do
            -- User clicked a window — update StackSet focus WITHOUT sending
            -- FocusWindow back (macOS already focused it). Avoids feedback loop.
            ws <- gets windowset
            let mref = find (\w -> wrPid w == pid) (W.allWindows ws)
            case mref of
                Just wref | W.peek ws /= Just wref ->
                    modify $ \s -> s { windowset = W.focusWindow wref (windowset s) }
                _ -> return ()

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

        -- Events that arrive during init or are not actionable
        Ready                   -> return ()
        QueryWindowsResponse _  -> return ()
        QueryScreensResponse _  -> return ()

-- ---------------------------------------------------------------------------
-- Helpers

-- | Find a WindowRef by its CGWindowID in a list.
findByWindowId :: Word32 -> [WindowRef] -> Maybe WindowRef
findByWindowId wid = find (\w -> wrWindowId w == wid)
