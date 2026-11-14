module MCMonad.Main
    ( mcmonad
    , launch
    , onHiddenWorkspace
    , pairBurst
    ) where

import Control.Concurrent (myThreadId, threadDelay)
import Control.Exception (finally, throwTo)
import Control.Monad (forever, unless, void, when)
import Data.IORef (IORef, newIORef, readIORef)
import Data.List (find)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Int (Int32)
import Data.Word (Word32)
import Data.Time.Clock (getCurrentTime)
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode(..), exitSuccess)
import System.Posix.Signals (Handler(..), installHandler, sigINT, sigTERM)
import qualified XMonad.StackSet as W

import MCMonad.Affinity (placeForRoles)
import MCMonad.Config
import MCMonad.Core
import MCMonad.Debug (toggleDebugOverlays, setDebugOverlays)
import MCMonad.IPC
import MCMonad.Operations
import MCMonad.Persistence
    ( SerialState(..), serialToWindowSet, partitionPending
    , StateExtras(..), noExtras, encodeExtras, decodeExtras, pruneExtras
    )

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

    -- 2. Wait for Ready event. Whatever else arrives during the startup
    --    handshake is kept and replayed once state exists — see
    --    'waitForEvent'.
    ((), deferred1) <- waitForEvent conn $ \ev -> case ev of
        Ready -> Just ()
        _     -> Nothing

    -- 3. Query screen geometry
    sendCommand conn QueryScreens
    (screens, deferred2) <- waitForEvent conn $ \ev -> case ev of
        ScreensChanged scs -> Just scs
        _                  -> Nothing

    -- 4. Build the hotkey map and register hotkeys
    let keyMap    = mcKeys cfg cfg
        keyList   = Map.toAscList keyMap
        hotkeySpecs = zipWith (\i ((mods, kc), _) -> HotkeySpec i kc mods)
                              [0 ..] keyList
        -- Map from hotkey ID to action, for dispatch in the event loop
        hotkeyIdMap = Map.fromList
                      $ zipWith (\i (_, action) -> (i, action)) [0 ..] keyList
    sendCommand conn (RegisterHotkeys hotkeySpecs)
    -- The OCR index is the daemon's to run; the config only says whether
    -- (on unless the user opted out).
    sendCommand conn (SetOcrIndex (ocrIndex cfg))

    -- 5. Query existing windows
    sendCommand conn QueryWindows
    (existingWindows, deferred3) <- waitForEvent conn $ \ev -> case ev of
        QueryWindowsResponse ws -> Just ws
        _                       -> Nothing

    -- 6. Check debug mode
    debug <- maybe False (const True) <$> lookupEnv "MCMONAD_DEBUG"
    when debug $ logTS "mcmonad: debug logging enabled (MCMONAD_DEBUG)"

    -- 7. Try to restore from the persisted snapshot. This runs on
    --    EVERY startup (not just --resume), so windows return to
    --    their workspaces across any mcmonad-side restart as long
    --    as the WindowServer is still alive (i.e. the user hasn't
    --    logged out). After logout / reboot, identities don't
    --    match anything and every window goes through the manage
    --    hook — see 'MCMonad.Persistence' for the design. Saved
    --    windows the daemon did not enumerate are held pending, not
    --    dropped (see 'rsPending').
    mSaved <- restoreSnapshot cfg screens existingWindows
    let restored = case mSaved of
            Just r  -> r
            Nothing ->
                let ws = buildInitialWindowSet cfg screens
                in Restored
                    { rsWindowSet   = ws
                    , rsAffinity    = initialAffinities ws
                    , rsUnmatched   = existingWindows
                    , rsTimers      = []
                    , rsNextTimerId = 1
                    , rsPending     = Map.empty
                    , rsExtras      = noExtras
                    }
        -- Roles come with the geometry; give each role's screen a
        -- workspace of its own before the first layout.
        roles0 = Map.fromList [ (S i, siRole si) | (i, si) <- zip [0 :: Int ..] screens ]
        ws0 = case viewMode cfg of
            Affine  -> placeForRoles (affinity cfg) roles0 Map.empty (mcWorkspaces cfg)
                                     (rsWindowSet restored)
            Classic -> rsWindowSet restored
        unmatchedLives = rsUnmatched restored

    logTS $ "mcmonad: screens "
        ++ unwords [ show i ++ "=" ++ roleName (siRole si) | (i, si) <- zip [0 :: Int ..] screens ]
        ++ (case viewMode cfg of Affine -> " (affine)"; Classic -> " (classic)")

    snapRef  <- newIORef Nothing
    armedRef <- newIORef False
    let mconf = MConf { connection     = conn
                      , latestSnapshot = snapRef
                      , saveArmed      = armedRef
                      }
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
                       -- What each screen shows now wins over what was
                       -- learned before; the rest is the learned history.
                       , learnedAffinity = Map.union (rsAffinity restored)
                                               (seLearnedAffinity (rsExtras restored))
                       , inputMode = "default"
                       , sticky = Set.empty
                       , scratchpads = Map.empty
                       , scratchpadRects = Map.empty
                       , pendingScratchpad = Nothing
                       , windowRects = Map.empty
                       , warpOnSwitch = mouseWarping cfg
                       , focusFollows = focusFollowsMouse cfg
                       , affinityRules = affinity cfg
                       , workspaceViewMode = viewMode cfg
                       , workspaceOrder = mcWorkspaces cfg
                       , screenRoles = roles0
                       , lastOnRole = Map.empty
                       , windowMetadata = seededMetadata
                       , debugOverlays = False
                       , ignoredWindows = Set.empty
                       , frameRepairs = Map.empty
                       , nativeFloats = Map.keysSet (seNativeFloats (rsExtras restored))
                       , nativeFloatRects = seNativeFloats (rsExtras restored)
                       , lastSaveAt = Nothing
                       , timers = rsTimers restored
                       , nextTimerId = rsNextTimerId restored
                       , focusIntent = Nothing
                       , pendingFocusQueries = []
                       , suppressFrontAppUntil = Nothing
                       , emptyWorkspaceGuardUntil = Nothing
                       , unmanagedOrigin = Map.empty
                       , reclaimOrigin  = Map.empty
                       , pendingRestore = rsPending restored
                       }

    -- Stop requests (the launcher's SIGTERM on every deploy, Ctrl-C when
    -- run by hand) are delivered to the main thread as an 'ExitSuccess'
    -- so the event loop unwinds through the 'finally' below and the last
    -- snapshot is written before the process ends. Until now the brain
    -- died on the spot, and the throttled save could be a state change
    -- behind.
    mainThread <- myThreadId
    let stopOnSignal = throwTo mainThread ExitSuccess
    _ <- installHandler sigTERM (Catch stopOnSignal) Nothing
    _ <- installHandler sigINT  (Catch stopOnSignal) Nothing

    let deferred = deferred1 ++ deferred2 ++ deferred3
    (`finally` flushSnapshot snapRef) $ void $ runM mconf mst0 $ do
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
        eventLoop debug cfg hotkeyIdMap deferred

-- | Write the mirrored snapshot one last time. Runs on every way out of
-- the event loop: a stop signal (see 'launch'), the daemon's socket
-- closing under us, an uncaught error. The launcher stops the daemon
-- first and the brain second on every deploy, so the socket-closed
-- path is the common one.
flushSnapshot :: IORef (Maybe StateSnapshot) -> IO ()
flushSnapshot ref = do
    m <- readIORef ref
    case m of
        Nothing   -> return ()
        Just snap -> do
            saveStateIO snap
            logTS "mcmonad: final state written"

-- | What 'restoreSnapshot' rebuilds from the saved state.
data Restored = Restored
    { rsWindowSet   :: WindowSet
      -- ^ The saved layout, holding exactly the saved windows the daemon
      -- confirmed alive.
    , rsAffinity    :: Map.Map String ScreenId
    , rsUnmatched   :: [WindowInfo]
      -- ^ Live windows that appear nowhere in the saved state — they go
      -- through the manage hook.
    , rsTimers      :: [Timer]
    , rsNextTimerId :: Int
    , rsPending     :: Map.Map WindowRef (PendingWindow WindowRef)
      -- ^ Saved windows the daemon did not enumerate but whose process
      -- is still running. Held out of the 'WindowSet' with their saved
      -- placement, and put back the moment the daemon reports them
      -- ('MCMonad.Operations.restorePending').
    , rsExtras      :: StateExtras
      -- ^ State saved beside the main file, cut down to the workspaces and
      -- windows this restore produced (confirmed or pending).
    }

-- | Try to restore a previous snapshot. Returns 'Nothing' when no save
-- file exists (or it is unreadable — see 'loadStateIO').
--
-- Identity is exact 'WindowRef' equality: a saved window is live iff
-- its @(wid, pid)@ pair appears in the window list mcmonad-core just
-- enumerated. This is correct for every mcmonad-side restart (Mod-q,
-- daemon kick, launchd restart) and intentionally collapses to "fresh
-- start" after logout / reboot, where no IDs match by construction and
-- the manage hook does all the work.
--
-- A saved window that is /absent/ from the enumeration is not thereby
-- dead. The enumeration is one instant's answer from SkyLight and AX,
-- and it has been empty for a daemon restarted while the display was
-- asleep (2026-08-28) — under the old "absent means stale" rule that
-- one answer erased every workspace assignment. The only positive
-- evidence available here is process liveness: a window cannot outlive
-- its process, so saved windows whose pid is gone are dropped, and all
-- others are held pending with their saved placement until the daemon
-- reports them or reports them destroyed.
restoreSnapshot
    :: MConfig Layout
    -> [ScreenInfo]
    -> [WindowInfo]
    -> IO (Maybe Restored)
restoreSnapshot cfg screens existingWindows = do
    mSaved <- loadStateIO
    case mSaved of
        Nothing -> return Nothing
        Just savedRaw -> do
            extrasRaw <- loadExtrasIO
            -- A saved workspace this config does not have cannot be
            -- rebuilt, and its windows are about to be treated as new and
            -- placed on the current workspace. That is right after a
            -- deliberate rename and a disaster when the wrong config is
            -- running (the bundled default started in place of the
            -- user's own). Either way the first save replaces the file,
            -- so keep what it said.
            let lost = [ tag | (tag, Just _) <- ssStacks savedRaw
                             , tag `notElem` mcWorkspaces cfg ]
            unless (null lost) $ do
                logTS $ "mcmonad: WARNING: the saved state has windows on "
                    ++ show (length lost) ++ " workspace(s) this config does not define; "
                    ++ "their windows will be placed as new"
                keepStateCopy ".unknown-workspaces"
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
                -- Confirmed windows stay; the rest leave the WindowSet
                -- (the full 'W.delete', so their floating entries go
                -- too) and are remembered with their placement.
                (ws, absent) = partitionPending liveSet ws0
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
            -- One liveness check per distinct pid among the absent
            -- windows; a dead pid retires all of its windows.
            let pids = Set.toList (Set.fromList (map wrPid (Map.keys absent)))
            liveness <- Map.fromList <$> mapM (\p -> (,) p <$> pidAlive p) pids
            let alive w  = Map.findWithDefault False (wrPid w) liveness
                pending  = Map.filterWithKey (\w _ -> alive w) absent
                dead     = Map.size absent - Map.size pending
            logTS $
                "mcmonad: restored "
                ++ show (length (W.allWindows ws))
                ++ " window(s); " ++ show (Map.size pending)
                ++ " pending (saved, not enumerated yet); "
                ++ show dead ++ " dead (process gone); "
                ++ show (length unmatched) ++ " new"
            when (null (W.allWindows ws) && not (Map.null pending)) $
                logTS
                    "mcmonad: the daemon enumerated none of the saved \
                    \windows; holding every placement until they are reported"
            return $ Just Restored
                { rsWindowSet   = ws
                , rsAffinity    = aff
                , rsUnmatched   = unmatched
                , rsTimers      = ssTimers saved
                , rsNextTimerId = ssNextTimerId saved
                , rsPending     = pending
                , rsExtras      = pruneExtras validTags
                    (Set.fromList (W.allWindows ws) `Set.union` Map.keysSet pending)
                    extrasRaw
                }
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

-- | Block until an event the projection accepts arrives. Every other
-- event that arrived first is returned too, in order, so the caller can
-- replay it once state exists. The old per-message waiters discarded
-- those: a 'ScreensChanged' or a sweep-adopted 'WindowCreated' landing
-- during the startup handshake was simply lost.
waitForEvent :: Connection -> (Event -> Maybe a) -> IO (a, [Event])
waitForEvent conn pick = go []
  where
    go acc = do
        ev <- readEvent conn
        case pick ev of
            Just x  -> return (x, reverse acc)
            Nothing -> go (ev : acc)

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

-- | The main event loop: replay the events deferred during startup,
-- then read events from the Swift daemon and dispatch forever.
eventLoop :: Bool -> MConfig Layout -> Map.Map Int (M ()) -> [Event] -> M ()
eventLoop debug cfg hotkeyIdMap deferred = do
    mapM_ (userCodeDef () . handleEvent debug cfg hotkeyIdMap) deferred
    forever $ do
        evt <- withConnection $ \conn -> io $ readEvent conn
        dispatchFresh debug cfg hotkeyIdMap evt

-- | How long to wait, after a 'WindowCreated' or 'WindowDestroyed' for
-- a tracked pid, to see whether the complementary half of a same-pid
-- pair is arriving right behind it (an app swapping a window's
-- identity under the hood — observed both destroy-first and
-- create-first) before treating the trigger on its own. Comfortably
-- covers the single/low-double-digit millisecond gap observed between
-- such a pair. Every other event is dispatched immediately as before.
burstDrainDelayMicros :: Int
burstDrainDelayMicros = 30000

-- | The pid a create or destroy event belongs to, resolved against a
-- single 'WindowSet' snapshot taken before anything in the current
-- batch has been dispatched — valid for the trigger event and
-- everything drained behind it alike, whichever type arrived first.
eventPid :: W.StackSet String l WindowRef ScreenId ScreenDetail -> Event -> Maybe Int32
eventPid _  (WindowCreated wi)  = Just (wiPid wi)
eventPid ws (WindowDestroyed w) = wrPid <$> findByWindowId w (W.allWindows ws)
eventPid _  _                   = Nothing

-- | Entry point for a just-read event, before ordinary dispatch. A
-- 'WindowCreated' or 'WindowDestroyed' for a resolvable pid gets a
-- chance to pair with the complementary half of the same pid's burst
-- — whichever of the two arrives first — and collapse into one
-- relayout instead of two; everything else (and a trigger that
-- doesn't pair) goes through 'handleEvent' exactly as before.
dispatchFresh :: Bool -> MConfig Layout -> Map.Map Int (M ()) -> Event -> M ()
dispatchFresh debug cfg hotkeyIdMap evt = do
    rest <- tryCollapseBurst evt
    mapM_ (userCodeDef () . handleEvent debug cfg hotkeyIdMap) rest

-- | Look for a pairing for 'evt' and, if found, act on it directly via
-- 'handleManagedReplacement'. Returns the events that still need
-- ordinary dispatch: empty when a pairing fully handled things, or
-- 'evt' plus everything drained while looking for one (in original
-- order) when nothing paired — including when 'evt' itself has no
-- resolvable pid, in which case nothing is drained at all.
tryCollapseBurst :: Event -> M [Event]
tryCollapseBurst evt = do
    ws <- gets windowset
    case eventPid ws evt of
        Nothing  -> return [evt]
        Just pid -> do
            batch <- withConnection $ \conn -> io $ do
                threadDelay burstDrainDelayMicros
                drainReadyEvents conn
            case pairBurst ws pid (evt : batch) of
                Just (oldRef, winfo, leftover) -> do
                    userCodeDef () $ handleManagedReplacement oldRef winfo
                    return leftover
                Nothing -> return (evt : batch)

-- | Pair up a same-pid burst. Given the pid and the trigger followed by
-- everything drained behind it, returns the old window and the new
-- window's info when exactly one create and one destroy for that pid are
-- present and the destroyed window is known, together with the events
-- not consumed by the pairing.
pairBurst :: W.StackSet String l WindowRef ScreenId ScreenDetail -> Int32 -> [Event] -> Maybe (WindowRef, WindowInfo, [Event])
pairBurst ws pid events =
    case (creates, destroys) of
        ([WindowCreated winfo], [WindowDestroyed wid]) -> do
            oldRef <- findByWindowId wid (W.allWindows ws)
            return (oldRef, winfo, filter (not . isPaired) events)
        _ -> Nothing
  where
    isCreateForPid e = case e of
        WindowCreated wi -> wiPid wi == pid
        _                -> False
    isDestroyForPid e = case e of
        WindowDestroyed{} -> eventPid ws e == Just pid
        _                 -> False
    isPaired e = isCreateForPid e || isDestroyForPid e
    creates  = filter isCreateForPid events
    destroys = filter isDestroyForPid events

-- | Whether a window is managed but on no screen, i.e. it sits on a hidden
-- workspace.
onHiddenWorkspace :: W.StackSet i l WindowRef sid sd -> WindowRef -> Bool
onHiddenWorkspace ws w = W.member w ws && w `notElem` visibleScreenWindows ws

-- | Dispatch a single event from the Swift daemon.
handleEvent :: Bool -> MConfig Layout -> Map.Map Int (M ()) -> Event -> M ()
handleEvent debug cfg hotkeyIdMap evt = do
    when debug $ io $ logTS $ "EVENT: " ++ eventLogSummary evt
    case evt of
        WindowCreated winfo -> do
            -- Whatever 'emptyWorkspaceGuardUntil' was waiting for has
            -- shown up; a 'FrontAppChanged' bounce no longer needs the
            -- extra scrutiny (see 'handleFrontAppChanged').
            modify $ \s -> s { emptyWorkspaceGuardUntil = Nothing }
            -- A saved window the daemon is only reporting now goes back
            -- to its own workspace; only genuinely new windows meet the
            -- manage hook.
            restored <- restorePending winfo
            unless restored $ do
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

        WindowTitleChanged wid pid title -> do
            let wr = WindowRef wid pid
            meta <- gets windowMetadata
            when (maybe False ((/= title) . wmTitle) (Map.lookup wr meta)) $ do
                modify $ \s -> s { windowMetadata = Map.adjust (\m -> m { wmTitle = title }) wr (windowMetadata s) }
                pushOverlaySnapshot

        WindowDestroyed wid -> do
            forgetPending wid
            modify $ \s -> s { frameRepairs = Map.delete wid (frameRepairs s) }
            ws <- gets windowset
            ignored <- gets ignoredWindows
            -- An ignored window is never in 'W.allWindows', so it has to
            -- be searched for separately or its destroy is silently
            -- dropped and 'unmanage' never runs to clear it.
            let mref = findByWindowId wid (W.allWindows ws ++ Set.toList ignored)
            whenJust mref $ \wref -> unmanage wref

        WindowFrameDefied wid pid want actual ->
            repairFrame wid pid want actual

        WindowFrameChanged wid rect -> do
            -- A window still awaiting a size repair re-checks on each frame change.
            reps <- gets frameRepairs
            whenJust (Map.lookup wid reps) $ \r ->
                repairFrame wid (frPid r) (frWant r) rect
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
            natives <- gets nativeFloats
            case findByWindowId wid (W.allWindows ws) of
                Just wref | not (Set.member wref mappedSet)
                          , not (frameIsParked (map (screenRect . W.screenDetail) (W.screens ws)) rect)
                    -> reassertHiddenWindows
                Just wref | Set.member wref mappedSet
                          , Set.member wref natives
                    -> do
                        -- Native floats never get a SetFrames from us, so
                        -- this is the only record of where it actually is
                        -- -- used to restore it on the next show (see
                        -- 'nativeFloatRects').
                        modify $ \s -> s
                            { nativeFloatRects = Map.insert wref rect (nativeFloatRects s) }
                        -- A native float is a real native window: the user
                        -- drags it by its own title bar, no Option held, so
                        -- 'WindowDragCompleted' (Option-drag only) never
                        -- fires for it. This is the only signal that it
                        -- landed on another screen -- reassign it to that
                        -- screen's current workspace so it isn't left a
                        -- member of a workspace it's no longer visually on.
                        whenJust (crossedScreenTag wref rect ws) $ \dropTag ->
                            windows (W.shiftWin dropTag wref)
                _   -> return ()

        WindowDragCompleted wid pid rect -> do
            -- User finished an Option+drag move/resize. Auto-float the
            -- window at its new absolute position, and -- if the drop
            -- landed on a different screen -- reassign it to that
            -- screen's current workspace. Without the reassignment, a
            -- window dragged across screens stayed a member of its old
            -- (now not-shown-there) workspace: visually on the new
            -- screen, but absent from that workspace's window list and
            -- confusing every subsequent focus/workspace-switch command
            -- that keys off 'windowset' membership.
            let wr = WindowRef wid pid
            ws <- gets windowset
            when (W.member wr ws) $ do
                let dropScreen = screenAt rect ws
                    dropTag    = W.tag (W.workspace dropScreen)
                    screenR    = screenRect (W.screenDetail dropScreen)
                    rx = toRational ((rect_x rect - rect_x screenR) / rect_w screenR)
                    ry = toRational ((rect_y rect - rect_y screenR) / rect_h screenR)
                    rw = toRational (rect_w rect / rect_w screenR)
                    rh = toRational (rect_h rect / rect_h screenR)
                windows (W.float wr (W.RationalRect rx ry rw rh) . W.shiftWin dropTag wr)

        FocusedWindowChanged wid pid -> do
            -- A window on a screen goes through the focus-intent
            -- classifier. A window on a hidden workspace would bring that
            -- workspace on screen, which needs more than the event's word.
            ws0 <- gets windowset
            let wr0 = WindowRef wid pid
            if onHiddenWorkspace ws0 wr0
                then followHiddenIfConfirmed wr0
                else handleFocusedWindowChanged wid pid
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
            -- Answer to our own 'QueryFocusedWindow'; run whatever the
            -- caller (e.g. 'MCMonad.Operations.jumpToActiveWindow',
            -- 'MCMonad.Operations.kill', or this module's own
            -- 'confirmFrontAppChange') queued for it.
            answerFocusQuery (Just (WindowRef wid pid))

        FocusedWindowQueryEmpty ->
            -- macOS has no focused window to report. The caller that asked
            -- gets no answer, and its place in the queue is released.
            answerFocusQuery Nothing

        FrontAppChanged pid -> handleFrontAppChanged pid

        MouseEnteredWindow wid pid ->
            when (focusFollowsMouse cfg) $ do
                ws <- gets windowset
                fi <- gets focusIntent
                now <- io getCurrentTime
                -- A layout pass rearranges windows UNDER a stationary
                -- cursor, which fires enter events indistinguishable
                -- from real mouse motion. Same discriminator as the AX
                -- path: an enter for a window we just moved, within the
                -- settle grace, is our own doing — not the user's hand.
                let settlingEnter = case fi of
                        Just i  -> withinSettleWindow now i
                                       && isSettlingEcho wid pid i
                        Nothing -> False
                unless settlingEnter $ do
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
            -- 'resolveFocusedWindow' / 'resolveFrontApp' normally. Same
            -- reasoning disarms 'emptyWorkspaceGuardUntil': an actual
            -- click always wins over the extra scrutiny it adds.
            modify $ \s -> s { focusIntent = Nothing, emptyWorkspaceGuardUntil = Nothing }

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
            when (W.member wr ws) $ focusWindowAnywhere wr

        MenuViewWorkspace tag -> do
            ws <- gets windowset
            -- Only switch if this is actually a known workspace tag.
            let allTags = map W.tag (W.workspace (W.current ws)
                                     : map W.workspace (W.visible ws)
                                     ++ W.hidden ws)
            when (tag `elem` allTags) $ viewWorkspace tag

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
            when (workspace `elem` allTags) $ viewWorkspace workspace

        IgnoredAttributionQuery frame facts -> do
            -- The per-screen query asked where the ignored windows are.
            -- Swift sent their live frames; the brain answers the attribution.
            ws <- gets windowset
            ignored <- gets ignoredWindows
            let wids = attributeIgnoredWindows ignored ws frame facts
            withConnection $ \conn -> io $ sendCommand conn (IgnoredAttributionReply frame wids)

        -- Events that arrive during init or are not actionable
        Ready                   -> return ()
        QueryWindowsResponse _  -> return ()
        QueryScreensResponse _  -> return ()

        IgnoredEvent _ ->
            -- IPC protocol skew: a wire message we couldn't decode.
            -- Logged once per occurrence so the user notices, but
            -- does not crash the loop. Most often hit when a
            -- Mod-q-compiled binary is older than the running
            -- mcmonad-core; the launcher's protocol-version stamp
            -- check should normally prevent that pairing, but this
            -- is the defence-in-depth.
            io $ logTS $
                "mcmonad: ignoring unknown wire message (peer text withheld for privacy)"

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
--   * a window this pass just laid out, inside the settle window — our
--     own echo, no-op.
--   * anything else on a screen — macOS has focused another window;
--     follow it and clear the intent.
--
-- Windows on hidden workspaces never reach this function; see
-- 'followHiddenIfConfirmed'.
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
            -- own AX, not the user. No-op: a secondary monitor's worth
            -- of settling echoes must not be able to flip the current
            -- screen. Past the
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
        Just i | Just _ <- fiTarget i ->
            -- Cross-app divergence: a different app's window, on a
            -- screen, reported focus while mcmonad had a target armed and
            -- the settle window has passed. macOS has moved on (a
            -- keyboard app switch, a link opening elsewhere); follow it.
            applyAndClearIntent
        Just _ ->
            -- Target-less intent (the user is deliberately viewing an
            -- empty workspace) and the event is neither a settling echo
            -- nor inside the grace. There is no window to push macOS
            -- back onto and no reason left to distrust the event — a
            -- genuine later switch (Cmd-Tab, Dock click) must be free
            -- to move the current screen. Follow it.
            applyAndClearIntent
        Nothing ->
            -- No intent armed. AX is authoritative.
            applyClean
  where
    -- Every candidate 'resolveFocusedWindow' can return is already
    -- displayed and just needs its focus (and, for a focus-dependent
    -- layout, its frame) brought in line, so this goes through 'windows'.
    applyClean = do
        ws <- gets windowset
        whenJust (resolveFocusedWindow wid pid ws) (windows . const)
    applyAndClearIntent = do
        modify $ \s -> s { focusIntent = Nothing }
        applyClean

-- | A window on a hidden workspace reported focus. Following it brings
-- that workspace on screen, so the event alone is not enough:
--
--   * inside the settle window it is the echo of our own park (parked
--     windows are part of the settling set) and is ignored;
--   * otherwise macOS is asked which window is focused, and the workspace
--     is brought up only if it names this one. Applications re-announce
--     windows that are nowhere near the front; a genuine switch (an app
--     switch landing on a parked window, a link opening in a browser on
--     another workspace) is confirmed by the same question.
--
-- The workspace comes up on its own screen ('focusWindowAnywhere').
followHiddenIfConfirmed :: WindowRef -> M ()
followHiddenIfConfirmed wr = do
    fi  <- gets focusIntent
    now <- io getCurrentTime
    let ourEcho = case fi of
            Just i  -> withinSettleWindow now i && isSettlingEcho (wrWindowId wr) (wrPid wr) i
            Nothing -> False
    unless ourEcho $ queryFocusedWindow $ \focused -> do
        ws <- gets windowset
        when (focused == wr && W.member wr ws) $ focusWindowAnywhere wr

-- | Hand the daemon's answer to the oldest outstanding
-- 'queryFocusedWindow' caller. Answers arrive one per query, in order.
answerFocusQuery :: Maybe WindowRef -> M ()
answerFocusQuery answer = do
    pending <- gets pendingFocusQueries
    case pending of
        []       -> return ()
        (f:rest) -> do
            modify $ \s -> s { pendingFocusQueries = rest }
            whenJust answer f

handleFrontAppChanged :: Int32 -> M ()
handleFrontAppChanged pid = do
    now <- io getCurrentTime
    suppressUntil <- gets suppressFrontAppUntil
    modify $ \s -> s { suppressFrontAppUntil = Nothing }
    guardUntil <- gets emptyWorkspaceGuardUntil
    if shouldSuppressFrontApp now suppressUntil
        then
            -- 'MCMonad.Operations.kill' just closed the last window on a
            -- workspace; this is macOS's own choice of what to activate
            -- next, not a deliberate switch. Consumed either way (above),
            -- so a later genuine switch to this same app isn't eaten too.
            return ()
        else if shouldSuppressFrontApp now guardUntil
            then
                -- 'MCMonad.Operations.windows' just left the current
                -- workspace empty and is still waiting for whatever gets
                -- spawned on it (or a real click) to show up; unlike the
                -- guard above, not consumed here — see
                -- 'emptyWorkspaceGuardUntil'.
                return ()
            else handleFrontAppChangedGenuine pid

handleFrontAppChangedGenuine :: Int32 -> M ()
handleFrontAppChangedGenuine pid = do
    fi <- gets focusIntent
    now <- io getCurrentTime
    case fi of
        Just i | isIntentTargetPid pid i ->
            -- App-level confirmation. No-op; keep intent armed.
            return ()
        Just i | withinSettleWindow now i && isSettlingPidEcho pid i ->
            -- Front-app echo for an app we just moved a window of — our
            -- own AX write settling, not a genuine app switch. No-op
            -- (see 'handleFocusedWindowChanged').
            -- Time-bounded, so a real Cmd-Tab later still follows.
            return ()
        Just _ -> do
            -- No longer checking for a target: follow any app switch as user intent.
            modify $ \s -> s { focusIntent = Nothing }
            confirmFrontAppChange pid
        Nothing ->
            confirmFrontAppChange pid

-- | Ask whether macOS genuinely has an AX-focused window for @pid@ right
-- now before following its 'FrontAppChanged' — mirrors AeroSpace's own
-- 'getNativeFocusedWindow', which requires the same before following a
-- focus change. NSWorkspace can report an app as frontmost moments
-- before that app actually has a focused window (most visibly during a
-- slow app launch, where frontmost briefly reverts to whatever was
-- active before); following the bare notification reads that as a
-- deliberate switch. Reuses 'MCMonad.Operations.queryFocusedWindow'
-- (also used by 'MCMonad.Operations.kill' and
-- 'MCMonad.Operations.jumpToActiveWindow') rather than a second
-- query/response channel; only follows if the confirmed window's pid
-- still matches the one that was reported.
--
-- Also re-checks both suppression guards at response time, not only at
-- the 'handleFrontAppChanged' dispatch that triggered this query: an app
-- quitting on its own (not via 'MCMonad.Operations.kill') can report
-- 'FrontAppChanged' for the previous app an instant *before* its window
-- actually closes, so the guard a closing-to-empty 'windows' call arms
-- may only land while this query is still in flight. Without this
-- recheck, the query resolves after that -- genuinely confirming the
-- previous app's window, since it really is frontmost by then -- and
-- follows it anyway, missing the guard entirely.
confirmFrontAppChange :: Int32 -> M ()
confirmFrontAppChange pid = queryFocusedWindow $ \wr -> do
    now <- io getCurrentTime
    suppressUntil <- gets suppressFrontAppUntil
    guardUntil <- gets emptyWorkspaceGuardUntil
    let suppressed = shouldSuppressFrontApp now suppressUntil
                   || shouldSuppressFrontApp now guardUntil
    unless suppressed $ when (wrPid wr == pid) (applyFrontAppChange wr)

-- | Follow a confirmed app switch: @focused@ is the window macOS says is
-- focused, and it belongs to the app that came to the front.
applyFrontAppChange :: WindowRef -> M ()
applyFrontAppChange focused = do
    ws <- gets windowset
    case resolveFrontApp (wrPid focused) ws of
        Just ws' ->
            -- Must go through 'windows', not a bare 'modify': for a
            -- focus-dependent layout (e.g. 'Full'), which window
            -- gets a rect depends on which one is focused, so a
            -- pure state update leaves frames stale.
            windows (const ws')
        Nothing ->
            -- The app has no window on any screen. If the window macOS
            -- focused is one of ours on a hidden workspace, bring that
            -- workspace up on its own screen. (This is the only signal
            -- for apps whose AX focus notifications do not fire.)
            when (W.member focused ws) $ focusWindowAnywhere focused
    -- The first front-app change after a native-fullscreen Space
    -- transition is the earliest reliable moment to heal the silent
    -- un-park sweep (see the WindowFrameChanged handler) — the sweep
    -- itself emits nothing. Only reached on a genuine external app
    -- switch (the echo of mcmonad's own focus command short-circuits
    -- above), so this no longer fires on every ordinary switch: one
    -- that already just ran its own hide pass a moment earlier, whose
    -- windows have not always finished settling into their parked
    -- frame yet, making the "already parked" skip in executeHideWindows
    -- miss and re-send a real, visible second park sweep for no reason.
    reassertHiddenWindows

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
                  , tmFireAt = now + seconds, tmWorkspace = ws
                  , tmDurationSec = Just seconds }
    modify $ \s -> s { timers = timers s ++ [t], nextTimerId = nid + 1 }
    syncTimers
    return t
