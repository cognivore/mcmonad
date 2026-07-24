module Properties where

import Test.QuickCheck
import qualified XMonad.StackSet as W
import MCMonad.Core
    ( WindowRef(..), ScreenId(..), ScreenDetail(..), Rectangle(..)
    , updateAffinities, resolveFocusedWindow, resolveFrontApp
    , FocusIntent(..), armingIntent, isFocusIntentTarget
    , isIntentTargetPid, isSettlingEcho, isSettlingPidEcho
    , withinSettleWindow, consumeIntent
    )
import MCMonad.IPC (WindowInfo(..))
import MCMonad.Persistence
    ( SerialState(..), SerStack(..), persistenceVersion, serialToWindowSet
    , windowSetToSerial
    )
import MCMonad.Operations
    ( frameAtParkCorner, reassignScreens
    , chooseOriginTag, pruneReclaims, reclaimOriginTTL, reclaimOriginCap
    )
import MCMonad.Sway (viewOnScreen)
import qualified Data.List as L
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Maybe (isNothing)
import Data.Time.Clock (UTCTime, addUTCTime, diffUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Int (Int32)
import Data.Word (Word32)
import Control.Monad (foldM)

-- Simplified layout for testing (no need for real LayoutClass)
type TestLayout = Int  -- just a placeholder
type TestStackSet = W.StackSet String TestLayout WindowRef ScreenId ScreenDetail

-- Arbitrary instances
instance Arbitrary WindowRef where
    arbitrary = WindowRef <$> arbitrary <*> arbitrary

instance Arbitrary ScreenId where
    arbitrary = S <$> choose (0, 3)

instance Arbitrary ScreenDetail where
    arbitrary = SD <$> (Rectangle <$> arbitrary <*> arbitrary <*> (abs <$> arbitrary) <*> (abs <$> arbitrary))

instance Arbitrary TestStackSet where
    arbitrary = do
        numWS <- choose (1, 20)
        numSc <- choose (1, min numWS 4)
        numWin <- choose (0, 40)
        let tags = map show [1..numWS]
            layout = 0 :: TestLayout
        -- Generate unique windows
        wins <- vectorOf numWin (WindowRef <$> choose (1, 10000) <*> choose (1, 1000))
        let uniqueWins = L.nubBy (\a b -> wrWindowId a == wrWindowId b) wins
        scDetails <- vectorOf numSc arbitrary
        let ss0 = W.new layout tags scDetails
        -- Insert windows into random workspaces
        foldM (\ss w -> do
            tag <- elements tags
            return $ W.insertUp w (W.view tag ss)
            ) ss0 uniqueWins

-- INVARIANT: helper
invariant :: TestStackSet -> Bool
invariant ss =
    let allWins = W.allWindows ss
    in length allWins == length (L.nub allWins)  -- no duplicates

-- === STRUCTURAL INVARIANTS ===

prop_invariant :: TestStackSet -> Bool
prop_invariant = invariant

-- === FOCUS OPERATIONS ===

prop_focusUp_focusDown :: TestStackSet -> Bool
prop_focusUp_focusDown x = W.focusUp (W.focusDown x) == x

prop_focusDown_focusUp :: TestStackSet -> Bool
prop_focusDown_focusUp x = W.focusDown (W.focusUp x) == x

prop_focusMaster_idem :: TestStackSet -> Bool
prop_focusMaster_idem x = W.focusMaster (W.focusMaster x) == x

prop_focusUp_invariant :: TestStackSet -> Bool
prop_focusUp_invariant x = invariant (W.focusUp x)

prop_focusDown_invariant :: TestStackSet -> Bool
prop_focusDown_invariant x = invariant (W.focusDown x)

prop_focusMaster_invariant :: TestStackSet -> Bool
prop_focusMaster_invariant x = invariant (W.focusMaster x)

prop_focusUp_local :: TestStackSet -> Bool
prop_focusUp_local x = W.hidden (W.focusUp x) == W.hidden x

prop_focusDown_local :: TestStackSet -> Bool
prop_focusDown_local x = W.hidden (W.focusDown x) == W.hidden x

prop_focus_all_l :: TestStackSet -> Bool
prop_focus_all_l x =
    let n = length (W.index x)
    in foldr (const W.focusUp) x [1..n] == x

prop_focus_all_r :: TestStackSet -> Bool
prop_focus_all_r x =
    let n = length (W.index x)
    in foldr (const W.focusDown) x [1..n] == x

-- focusWindow
prop_focusWindow_works :: TestStackSet -> Bool
prop_focusWindow_works x = case W.peek x of
    Nothing -> True
    Just w -> W.peek (W.focusWindow w x) == Just w

prop_focusWindow_invariant :: TestStackSet -> Property
prop_focusWindow_invariant x = case W.peek x of
    Nothing -> property True
    Just w -> property $ invariant (W.focusWindow w x)

-- === VIEW OPERATIONS ===

prop_view_current :: TestStackSet -> Property
prop_view_current x = forAll (elements (map W.tag $ W.workspaces x)) $ \t ->
    W.currentTag (W.view t x) == t

prop_view_idem :: TestStackSet -> Property
prop_view_idem x = forAll (elements (map W.tag $ W.workspaces x)) $ \t ->
    W.view t (W.view t x) == W.view t x

prop_view_reversible :: TestStackSet -> Property
prop_view_reversible x =
    let t = W.currentTag x
    in forAll (elements (map W.tag $ W.workspaces x)) $ \t' ->
        W.view t (W.view t' x) == x || W.currentTag (W.view t (W.view t' x)) == t

prop_view_invariant :: TestStackSet -> Property
prop_view_invariant x = forAll (elements (map W.tag $ W.workspaces x)) $ \t ->
    invariant (W.view t x)

-- greedyView
prop_greedyView_current :: TestStackSet -> Property
prop_greedyView_current x = forAll (elements (map W.tag $ W.workspaces x)) $ \t ->
    W.currentTag (W.greedyView t x) == t

prop_greedyView_invariant :: TestStackSet -> Property
prop_greedyView_invariant x = forAll (elements (map W.tag $ W.workspaces x)) $ \t ->
    invariant (W.greedyView t x)

-- === INSERT / DELETE ===

prop_insertUp_invariant :: WindowRef -> TestStackSet -> Property
prop_insertUp_invariant w x = not (W.member w x) ==> invariant (W.insertUp w x)

prop_insert_delete :: WindowRef -> TestStackSet -> Property
prop_insert_delete w x = not (W.member w x) ==> W.delete w (W.insertUp w x) == x

prop_delete_invariant :: TestStackSet -> Property
prop_delete_invariant x = case W.peek x of
    Nothing -> property True
    Just w -> property $ invariant (W.delete w x)

prop_delete_member :: TestStackSet -> Property
prop_delete_member x = case W.peek x of
    Nothing -> property True
    Just w -> property $ not (W.member w (W.delete w x))

prop_insert_member :: WindowRef -> TestStackSet -> Property
prop_insert_member w x = not (W.member w x) ==> W.member w (W.insertUp w x)

prop_size_insert :: WindowRef -> TestStackSet -> Property
prop_size_insert w x = not (W.member w x) ==>
    length (W.allWindows (W.insertUp w x)) == length (W.allWindows x) + 1

prop_insert_local :: WindowRef -> TestStackSet -> Property
prop_insert_local w x = not (W.member w x) ==>
    W.hidden (W.insertUp w x) == W.hidden x

-- === SWAP OPERATIONS ===

prop_swapMaster_invariant :: TestStackSet -> Bool
prop_swapMaster_invariant x = invariant (W.swapMaster x)

prop_swapUp_invariant :: TestStackSet -> Bool
prop_swapUp_invariant x = invariant (W.swapUp x)

prop_swapDown_invariant :: TestStackSet -> Bool
prop_swapDown_invariant x = invariant (W.swapDown x)

prop_swapMaster_focus :: TestStackSet -> Bool
prop_swapMaster_focus x = W.peek (W.swapMaster x) == W.peek x

prop_swapUp_focus :: TestStackSet -> Bool
prop_swapUp_focus x = W.peek (W.swapUp x) == W.peek x

prop_swapDown_focus :: TestStackSet -> Bool
prop_swapDown_focus x = W.peek (W.swapDown x) == W.peek x

prop_swapMaster_idem :: TestStackSet -> Bool
prop_swapMaster_idem x = W.swapMaster (W.swapMaster x) == W.swapMaster x

prop_swapMaster_local :: TestStackSet -> Bool
prop_swapMaster_local x = W.hidden (W.swapMaster x) == W.hidden x

-- === SHIFT ===

prop_shift_invariant :: TestStackSet -> Property
prop_shift_invariant x = forAll (elements (map W.tag $ W.workspaces x)) $ \t ->
    invariant (W.shift t x)

prop_shift_reversible :: TestStackSet -> Property
prop_shift_reversible x = case W.peek x of
    Nothing -> property True
    Just _ ->
        let t = W.currentTag x
            otherTags = filter (/= t) (map W.tag $ W.workspaces x)
        in  case otherTags of
            [] -> property True  -- only one workspace, nothing to shift to
            _  -> forAll (elements otherTags) $ \t' ->
                let shifted = W.shift t' x
                in case W.peek shifted of
                    Nothing -> property True  -- focus moved, can't trivially reverse
                    Just _ -> property $ invariant shifted

-- === FLOAT ===

prop_float_invariant :: TestStackSet -> Property
prop_float_invariant x = case W.peek x of
    Nothing -> property True
    Just w -> property $ invariant (W.float w (W.RationalRect 0 0 0.5 0.5) x)

prop_float_sink :: TestStackSet -> Property
prop_float_sink x = case W.peek x of
    Nothing -> property True
    Just w -> property $ W.sink w (W.float w (W.RationalRect 0 0 1 1) x) == x

-- === QUERY ===

prop_member_peek :: TestStackSet -> Bool
prop_member_peek x = case W.peek x of
    Nothing -> True
    Just w -> W.member w x

prop_allWindows_member :: TestStackSet -> Bool
prop_allWindows_member x = all (`W.member` x) (W.allWindows x)

prop_currentTag :: TestStackSet -> Bool
prop_currentTag x = W.currentTag x == W.tag (W.workspace (W.current x))

-- === SCREENS ===

prop_screens_current :: TestStackSet -> Bool
prop_screens_current x = W.current x `elem` W.screens x

-- === WORKSPACE MAPPING ===

prop_mapLayout_id :: TestStackSet -> Bool
prop_mapLayout_id x = W.mapLayout id x == x

-- === AFFINITY ===

prop_updateAffinities_records_visible :: TestStackSet -> Bool
prop_updateAffinities_records_visible ss =
    let aff = updateAffinities ss Map.empty
        visibleTags = map (W.tag . W.workspace) (W.current ss : W.visible ss)
    in all (`Map.member` aff) visibleTags

prop_updateAffinities_preserves_hidden :: TestStackSet -> Bool
prop_updateAffinities_preserves_hidden ss =
    let hiddenTags = map W.tag (W.hidden ss)
        -- Seed: pretend all hidden workspaces were on screen S 99
        seed = Map.fromList [(t, S 99) | t <- hiddenTags]
        aff = updateAffinities ss seed
    in all (\t -> Map.lookup t aff == Just (S 99)) hiddenTags

prop_viewOnScreen_invariant :: TestStackSet -> Property
prop_viewOnScreen_invariant ss =
    let screens = W.current ss : W.visible ss
        sids = map W.screen screens
    in length sids >= 2 ==>
        forAll (elements sids) $ \sid ->
            forAll (elements (map W.tag (W.hidden ss) ++ map (W.tag . W.workspace) screens)) $ \tag ->
                invariant (viewOnScreen sid tag ss)

prop_viewOnScreen_places_workspace :: TestStackSet -> Property
prop_viewOnScreen_places_workspace ss =
    let screens = W.current ss : W.visible ss
        sids = map W.screen screens
        hiddenTags = map W.tag (W.hidden ss)
    in (length sids >= 2 && not (null hiddenTags)) ==>
        forAll (elements sids) $ \sid ->
            forAll (elements hiddenTags) $ \tag ->
                let ss' = viewOnScreen sid tag ss
                in W.currentTag ss' == tag

-- === FOCUS RESOLUTION (resolveFocusedWindow / resolveFrontApp) ===
--
-- These properties guard the multi-window-per-app focus fix. The historic
-- bug was that on every FrontAppChanged event, focus would jump to
-- @find ((== pid) . wrPid) (W.allWindows ws)@ — i.e. the first window
-- with that PID — which made multi-window apps (browsers, etc.)
-- indistinguishable when the user clicked any of their windows.

-- | A StackSet containing two distinct windows that share a PID, with a
-- handle to both. Used to demonstrate the bug and verify the fix.
data SharedPidWindows = SharedPidWindows
    { spsStackSet :: TestStackSet
    , spsW1       :: WindowRef
    , spsW2       :: WindowRef
    }
    deriving Show

instance Arbitrary SharedPidWindows where
    arbitrary = do
        baseSS <- arbitrary
        let usedWids = map wrWindowId (W.allWindows baseSS)
        pid <- choose (1, 1000)
        -- Use a wid range disjoint from baseSS's generator to avoid the
        -- "insertUp of a duplicate is a no-op" trap in W.StackSet.
        wid1 <- choose (20001, 30000) `suchThat` (`notElem` usedWids)
        wid2 <- choose (20001, 30000) `suchThat`
                  (\w -> w /= wid1 && w `notElem` usedWids)
        let w1 = WindowRef wid1 pid
            w2 = WindowRef wid2 pid
            tag = W.currentTag baseSS
            withW1 = W.insertUp w1 (W.view tag baseSS)
            withBoth = W.insertUp w2 withW1
        return (SharedPidWindows withBoth w1 w2)

-- | The historic (broken) PID-only focus logic. Kept here only so the
-- bug-reproduction property has something to test against.
brokenPidOnlyFocus :: Int32 -> TestStackSet -> Maybe TestStackSet
brokenPidOnlyFocus pid ws =
    case L.find ((== pid) . wrPid) (W.allWindows ws) of
        Just wr | W.peek ws /= Just wr -> Just (W.focusWindow wr ws)
        _                              -> Nothing

-- | Windows on the CURRENT workspace — the only set
-- 'resolveFocusedWindow' / 'resolveFrontApp' are allowed to act on.
-- Mirror of 'MCMonad.Core.currentWorkspaceWindows' kept here so the
-- tests don't depend on it being exported.
currentWorkspaceWindowsForTest :: TestStackSet -> [WindowRef]
currentWorkspaceWindowsForTest ss =
    W.integrate' (W.stack (W.workspace (W.current ss)))

-- Mirror of 'MCMonad.Core.visibleScreenWindows': everything displayed on
-- some monitor. This is the reach of the focus resolvers.
visibleScreenWindowsForTest :: TestStackSet -> [WindowRef]
visibleScreenWindowsForTest ss =
    concatMap (W.integrate' . W.stack . W.workspace)
              (W.current ss : W.visible ss)

-- Windows parked on a hidden workspace. Permanently out of reach: no
-- macOS focus signal may change *what is displayed*.
hiddenWindowsForTest :: TestStackSet -> [WindowRef]
hiddenWindowsForTest ss =
    concatMap (W.integrate' . W.stack) (W.hidden ss)

-- For any window on the *current* workspace, asking resolveFocusedWindow
-- for it results in that exact window being focused — regardless of
-- whether other windows share its PID. This is the within-workspace
-- multi-window-per-app precision the AX path exists for.
prop_focusedWindow_picks_exact :: TestStackSet -> Property
prop_focusedWindow_picks_exact ss = case currentWorkspaceWindowsForTest ss of
    [] -> property True
    wins -> forAll (elements wins) $ \wr ->
        let r = resolveFocusedWindow (wrWindowId wr) (wrPid wr) ss
            focused = maybe (W.peek ss) W.peek r
        in focused === Just wr

-- A focused-window event targeting a window outside the current
-- workspace must be a no-op. This is the property that prevents
-- macOS-originated focus signals — Chrome rendering a hidden tab,
-- the AX side-effect cascade from mcmonad's own 'FocusWindow'
-- commands, an app activating on the other monitor — from dragging
-- the current screen anywhere the user didn't ask.
prop_focusedWindow_off_workspace_is_no_op :: TestStackSet -> Property
prop_focusedWindow_off_workspace_is_no_op ss =
    case hiddenWindowsForTest ss of
        [] -> property True
        wins -> forAll (elements wins) $ \wr ->
            property $ isNothing
                     $ resolveFocusedWindow (wrWindowId wr) (wrPid wr) ss

-- resolveFocusedWindow never *displays* a workspace that wasn't already
-- displayed. It may move the current screen to a secondary monitor
-- (that's "active workspace follows focus"), so the current tag can
-- change — but only to a tag that was already on a monitor, and the set
-- of displayed tags is untouched.
prop_focusedWindow_never_changes_displayed_set :: TestStackSet -> Property
prop_focusedWindow_never_changes_displayed_set ss = case W.allWindows ss of
    [] -> property True
    wins -> forAll (elements wins) $ \wr ->
        case resolveFocusedWindow (wrWindowId wr) (wrPid wr) ss of
            Nothing  -> property True
            Just ss' -> displayedTags ss' === displayedTags ss
  where
    displayedTags s =
        L.sort (map (W.tag . W.workspace) (W.current s : W.visible s))

-- The point of the widening: a window on a secondary monitor can be
-- focused, and doing so makes that monitor current. Clicking a window
-- on the other screen moves mcmonad's notion of "here".
prop_focusedWindow_follows_to_other_screen :: TestStackSet -> Property
prop_focusedWindow_follows_to_other_screen ss =
    let secondary = concatMap (W.integrate' . W.stack . W.workspace)
                              (W.visible ss)
    in case secondary of
        [] -> property True
        wins -> forAll (elements wins) $ \wr ->
            case resolveFocusedWindow (wrWindowId wr) (wrPid wr) ss of
                Nothing  -> property False  -- displayed window must resolve
                Just ss' -> conjoin
                    [ W.peek ss' === Just wr
                    , W.findTag wr ss' === Just (W.currentTag ss')
                    ]

-- resolveFocusedWindow preserves the no-duplicates invariant.
prop_focusedWindow_invariant :: TestStackSet -> Property
prop_focusedWindow_invariant ss = case currentWorkspaceWindowsForTest ss of
    [] -> property True
    wins -> forAll (elements wins) $ \wr ->
        property $ maybe True invariant
                 $ resolveFocusedWindow (wrWindowId wr) (wrPid wr) ss

-- An unknown (wid, pid) is a no-op. Wid is outside both the base
-- generator range (1..10000) and the SharedPidWindows range (20001..30000).
prop_focusedWindow_unknown_noop :: TestStackSet -> Bool
prop_focusedWindow_unknown_noop ss =
    isNothing (resolveFocusedWindow 4294967290 (-12345) ss)

-- THE BUG REPRO. With two windows sharing a PID, resolveFocusedWindow
-- distinguishes between them: asking for w1 focuses w1, asking for w2
-- focuses w2.
prop_focusedWindow_distinguishes_shared_pid :: SharedPidWindows -> Property
prop_focusedWindow_distinguishes_shared_pid (SharedPidWindows ss w1 w2) =
    let r1 = resolveFocusedWindow (wrWindowId w1) (wrPid w1) ss
        r2 = resolveFocusedWindow (wrWindowId w2) (wrPid w2) ss
        focused1 = maybe (W.peek ss) W.peek r1
        focused2 = maybe (W.peek ss) W.peek r2
    in (focused1 === Just w1) .&&. (focused2 === Just w2)

-- The companion "broken logic is broken" property: with two windows
-- sharing a PID, the historic PID-only lookup is INDISTINGUISHABLE
-- between them — it always lands on the same window regardless of
-- which the caller meant. This is the failure mode the fix removes.
prop_brokenPidOnly_indistinguishable :: SharedPidWindows -> Property
prop_brokenPidOnly_indistinguishable (SharedPidWindows ss w1 w2) =
    let r1 = brokenPidOnlyFocus (wrPid w1) ss
        r2 = brokenPidOnlyFocus (wrPid w2) ss
        focused1 = maybe (W.peek ss) W.peek r1
        focused2 = maybe (W.peek ss) W.peek r2
    in focused1 === focused2

-- resolveFrontApp is a no-op when focus is already in that PID — the
-- precise AX-driven focus inside the app must survive.
prop_frontApp_noop_within :: TestStackSet -> Property
prop_frontApp_noop_within ss = case W.peek ss of
    Nothing -> property True
    Just wr -> property $ isNothing (resolveFrontApp (wrPid wr) ss)

-- resolveFrontApp switches focus when the user crossed app boundaries
-- *within the current workspace*. PID-only events for apps whose
-- windows are all on other workspaces (hidden or visible-secondary)
-- must NOT switch workspaces — that's the new-window-lands-on-the-
-- wrong-screen and Mod-j-leaks-to-the-other-monitor regression
-- sentinel.
prop_frontApp_switches_within_workspace :: TestStackSet -> Property
prop_frontApp_switches_within_workspace ss = case W.peek ss of
    Nothing -> property True
    Just wr ->
        let curPids = L.nub
                    $ filter (/= wrPid wr)
                    $ map wrPid (currentWorkspaceWindowsForTest ss)
        in case curPids of
            [] -> property True
            (p:_) -> case resolveFrontApp p ss of
                Just ss' -> property (fmap wrPid (W.peek ss') === Just p)
                Nothing  -> property False  -- a current-workspace window of pid p exists; must switch

-- resolveFrontApp never displays a workspace that wasn't displayed. As
-- with the AX path it may move the current screen, but only among
-- monitors that are already showing those workspaces.
prop_frontApp_never_changes_displayed_set :: TestStackSet -> Property
prop_frontApp_never_changes_displayed_set ss =
    let pids = L.nub $ map wrPid (W.allWindows ss)
    in case pids of
        [] -> property True
        _  -> forAll (elements pids) $ \p ->
            case resolveFrontApp p ss of
                Nothing  -> property True
                Just ss' -> displayedTags ss' === displayedTags ss
  where
    displayedTags s =
        L.sort (map (W.tag . W.workspace) (W.current s : W.visible s))

-- An app whose windows are ALL on hidden workspaces is never followed:
-- activating it must not haul a hidden workspace onto a monitor.
prop_frontApp_ignores_hidden_only_app :: TestStackSet -> Property
prop_frontApp_ignores_hidden_only_app ss =
    let visiblePids = map wrPid (visibleScreenWindowsForTest ss)
        hiddenOnly  = L.nub [ wrPid w | w <- hiddenWindowsForTest ss
                            , wrPid w `notElem` visiblePids ]
    in case hiddenOnly of
        [] -> property True
        ps -> forAll (elements ps) $ \p ->
            property $ isNothing (resolveFrontApp p ss)

-- A PID says nothing about *which* window was activated, so an app with
-- a window on the current screen resolves to that one — activating
-- LibreWolf must not fling the current screen to whichever monitor
-- happens to hold LibreWolf's first window in stack order.
prop_frontApp_prefers_current_screen :: TestStackSet -> Property
prop_frontApp_prefers_current_screen ss =
    let here = currentWorkspaceWindowsForTest ss
        candidates = L.nub [ wrPid w | w <- here
                           , Just (wrPid w) /= fmap wrPid (W.peek ss) ]
    in case candidates of
        [] -> property True
        ps -> forAll (elements ps) $ \p ->
            case resolveFrontApp p ss of
                Nothing  -> property False  -- an app window is right here
                Just ss' -> W.currentTag ss' === W.currentTag ss

-- ...but when the app has no window on this screen at all, focus does
-- follow it to the monitor that has one.
prop_frontApp_follows_to_other_screen :: TestStackSet -> Property
prop_frontApp_follows_to_other_screen ss =
    let herePids = map wrPid (currentWorkspaceWindowsForTest ss)
        elsewhere = L.nub
            [ wrPid w
            | scr <- W.visible ss
            , w <- W.integrate' (W.stack (W.workspace scr))
            , wrPid w `notElem` herePids
            ]
    in case elsewhere of
        [] -> property True
        ps -> forAll (elements ps) $ \p ->
            case resolveFrontApp p ss of
                Nothing  -> property False  -- displayed app must resolve
                Just ss' -> property (fmap wrPid (W.peek ss') === Just p)

-- === FOCUS AUTHORITY (FocusIntent / armingIntent / isFocusIntentTarget) ===
--
-- 'MCMonad.Operations.windows' arms a 'FocusIntent' on every focus
-- change. The event-handler path in 'MCMonad.Main' classifies arriving
-- AX/NSWorkspace events against the intent into three buckets:
--
--   * exact target match — AX confirmation, no-op.
--   * same app, different window — intra-app focus change (typically a
--     user clicking another window in the same app); accept and clear.
--   * any other divergence — bounce or spurious AX echo; re-issue
--     'FocusWindow' and decrement the budget until it exhausts.
--
-- These properties cover the pure helpers that drive the dispatch.

-- | A pair of distinct WindowRefs that live in *different* apps.
data CrossAppPair = CrossAppPair WindowRef WindowRef deriving Show

instance Arbitrary CrossAppPair where
    arbitrary = do
        wid1 <- choose (1, 10000)
        wid2 <- choose (1, 10000) `suchThat` (/= wid1)
        pid1 <- choose (1, 1000)
        pid2 <- choose (1, 1000) `suchThat` (/= pid1)
        return (CrossAppPair (WindowRef wid1 pid1) (WindowRef wid2 pid2))

-- | A pair of distinct WindowRefs that live in the *same* app.
data SameAppPair = SameAppPair WindowRef WindowRef deriving Show

instance Arbitrary SameAppPair where
    arbitrary = do
        wid1 <- choose (1, 10000)
        wid2 <- choose (1, 10000) `suchThat` (/= wid1)
        pid  <- choose (1, 1000)
        return (SameAppPair (WindowRef wid1 pid) (WindowRef wid2 pid))

-- armingIntent arms whenever there is a target focus to record. This
-- happens after every focus-bearing 'windows' transition, not just
-- cross-app changes: intra-app bounces are possible too.
prop_armingIntent_arms_when_target :: WindowRef -> Bool
prop_armingIntent_arms_when_target w =
    case armingIntent originBase Set.empty (Just w) of
        Just i  -> fiTarget i == w
        Nothing -> False

-- armingIntent does not arm when the focus is cleared (empty workspace).
prop_armingIntent_nothing_clears :: Bool
prop_armingIntent_nothing_clears = armingIntent originBase Set.empty Nothing == Nothing

-- isFocusIntentTarget identifies the exact (wid, pid) of the intent's
-- target — the AX confirmation signal — and only that pair.
prop_isFocusIntentTarget_recognises_target :: WindowRef -> Bool
prop_isFocusIntentTarget_recognises_target w =
    case armingIntent originBase Set.empty (Just w) of
        Nothing -> False
        Just i  -> isFocusIntentTarget (wrWindowId w) (wrPid w) i

-- A different window (anywhere — different wid, different pid, or both)
-- is NOT the target.
prop_isFocusIntentTarget_distinguishes :: WindowRef -> WindowRef -> Property
prop_isFocusIntentTarget_distinguishes w1 w2 =
    (wrWindowId w1, wrPid w1) /= (wrWindowId w2, wrPid w2)
    ==> case armingIntent originBase Set.empty (Just w1) of
            Nothing -> property False
            Just i  -> property $ not (isFocusIntentTarget (wrWindowId w2) (wrPid w2) i)

-- isIntentTargetPid is the looser predicate the handlers use for both
-- (a) NSWorkspace confirmation echoes — same-pid means the right app is
-- front — and (b) intra-app AX divergence — same-pid different-wid
-- means a different window of the target's app gained focus.
prop_isIntentTargetPid_matches_same_pid :: SameAppPair -> Bool
prop_isIntentTargetPid_matches_same_pid (SameAppPair from to) =
    case armingIntent originBase Set.empty (Just to) of
        Nothing -> False
        Just i  -> isIntentTargetPid (wrPid from) i
                   && isIntentTargetPid (wrPid to) i

-- And it does NOT match a different pid (cross-app divergence).
prop_isIntentTargetPid_distinguishes_other_pid :: CrossAppPair -> Bool
prop_isIntentTargetPid_distinguishes_other_pid (CrossAppPair from to) =
    case armingIntent originBase Set.empty (Just to) of
        Nothing -> False
        Just i  -> isIntentTargetPid (wrPid to) i
                   && not (isIntentTargetPid (wrPid from) i)

-- consumeIntent is monotonic: each call decrements 'fiReissuesRemaining'
-- and returns 'Nothing' exactly when the budget runs out, so a
-- pathological multi-bounce sequence is bounded and user-initiated
-- divergence eventually wins.
prop_consumeIntent_drains_exactly_the_budget :: WindowRef -> Bool
prop_consumeIntent_drains_exactly_the_budget w =
    case armingIntent originBase Set.empty (Just w) of
        Nothing -> False
        Just i0 ->
            let budget = fromIntegral (fiReissuesRemaining i0) :: Int
                steps  = take (budget + 1)
                              (iterate (>>= consumeIntent) (Just i0))
            in last steps == Nothing
               && length (filter (/= Nothing) steps) == budget

-- === SETTLING-ECHO SUPPRESSION (fiSettling) ===
--
-- 'MCMonad.Operations.windows' writes frames to every window on every
-- screen, then arms the intent with that whole set as 'fiSettling'. The
-- AX/NSWorkspace echoes those writes provoke — especially for windows on
-- the *other* monitor — must be recognised as our own settling, not as
-- the user looking elsewhere. Getting this wrong is the "Opt-h/l/j makes
-- focus jump to the wrong screen" bug: the echoes drain the budget and
-- then flip the current screen.

-- A window that was part of the just-laid-out set is a settling echo,
-- whatever its pid — so the handler no-ops it instead of pushing back.
prop_isSettlingEcho_recognises_laid_out :: WindowRef -> [WindowRef] -> Property
prop_isSettlingEcho_recognises_laid_out w rest =
    case armingIntent originBase (Set.fromList (w : rest)) (Just w) of
        Nothing -> property False
        Just i  -> property $ isSettlingEcho (wrWindowId w) (wrPid w) i

-- Any member of the settling set is recognised, not only the focus
-- target — this is the whole point (secondary-monitor windows we moved
-- but did not focus).
prop_isSettlingEcho_covers_whole_set :: WindowRef -> WindowRef -> Property
prop_isSettlingEcho_covers_whole_set target other =
    (wrWindowId target, wrPid target) /= (wrWindowId other, wrPid other)
    ==> case armingIntent originBase (Set.fromList [target, other]) (Just target) of
            Nothing -> property False
            Just i  -> property $ isSettlingEcho (wrWindowId other) (wrPid other) i

-- A window we did NOT lay out is not a settling echo — otherwise a real
-- focus change would be swallowed forever.
prop_isSettlingEcho_rejects_outsider :: WindowRef -> WindowRef -> Property
prop_isSettlingEcho_rejects_outsider target outsider =
    outsider `notElem` [target]
    && (wrWindowId target, wrPid target) /= (wrWindowId outsider, wrPid outsider)
    ==> case armingIntent originBase (Set.singleton target) (Just target) of
            Nothing -> property False
            Just i  -> property $
                not (isSettlingEcho (wrWindowId outsider) (wrPid outsider) i)

-- The PID-only front-app variant matches when any settling window shares
-- the pid, and rejects a pid absent from the set.
prop_isSettlingPidEcho_matches_and_rejects :: WindowRef -> Int32 -> Property
prop_isSettlingPidEcho_matches_and_rejects w otherPid =
    otherPid /= wrPid w
    ==> case armingIntent originBase (Set.singleton w) (Just w) of
            Nothing -> property False
            Just i  -> property $
                isSettlingPidEcho (wrPid w) i
                && not (isSettlingPidEcho otherPid i)

-- The settle window is what makes echo-suppression safe: a set member is
-- suppressible at arming time, but NOT once the grace has elapsed — past
-- the deadline the same window's event is a genuine later user switch and
-- must be free to move the current screen. (settleGrace is 1s.)
prop_settle_window_bounds_suppression :: WindowRef -> Property
prop_settle_window_bounds_suppression w =
    case armingIntent originBase (Set.singleton w) (Just w) of
        Nothing -> property False
        Just i  -> property $
            withinSettleWindow originBase i
            && not (withinSettleWindow (addUTCTime 2 originBase) i)


-- === PERSISTENCE ROUND-TRIP (MCMonad.Persistence) ===
--
-- Identity is exact 'WindowRef' equality. The properties below
-- exercise the three classes of behaviour at restore time:
--
--   1. Saved windows that are in the live list stay where they
--      were (round-trip).
--   2. Saved windows NOT in the live list are dropped (stale).
--   3. Live windows NOT in the saved set are returned to the
--      caller for the manage hook (new).
--
-- The matcher / tier / fingerprint machinery that used to live in
-- this module is gone — see commit `<TBD>` for the rationale. The
-- properties below replace seven previous ones with three because
-- there's nothing else worth asserting.

-- | A tiny WindowInfo with bland defaults — only wid and pid matter
-- to the persistence layer.
mkWindowInfo :: Word32 -> Int32 -> WindowInfo
mkWindowInfo wid pid = WindowInfo
    { wiWindowId            = wid
    , wiPid                 = pid
    , wiTitle               = Nothing
    , wiAppName             = Nothing
    , wiBundleId            = Nothing
    , wiSubrole             = Nothing
    , wiIsDialog            = False
    , wiIsFixedSize         = False
    , wiHasCloseButton      = True
    , wiHasFullscreenButton = True
    , wiFrame               = Rectangle 0 0 100 100
    }

-- | A two-workspace, two-screen SerialState carrying explicit
-- WindowRefs, plus a live list of WindowInfos. Used for the three
-- persistence properties below.
--
-- Saved layout:
--   workspace "L" on screen 0, focus = wrL1, down = [wrL2]
--   workspace "R" on screen 1, focus = wrR1
--
-- Live windows are a (possibly partial, possibly extended) subset:
--   * 'kept'      — saved refs the user has had since save.
--   * 'newRefs'   — fresh refs that should fall through to manage hook.
genPersistCase :: Gen ([WindowRef], [WindowRef], [WindowRef])
genPersistCase = do
    let mkRef n = WindowRef n 100
    -- Three saved refs (wrL1 + wrL2 on "L", wrR1 on "R").
    let savedRefs = [mkRef 1, mkRef 2, mkRef 3]
    -- Decide which subset of saved survives ("still live").
    keep <- sublistOf savedRefs
    -- Extra live refs that aren't saved.
    extras <- listOf (do
        n <- choose (100 :: Word32, 200)
        return (WindowRef n 200))
    return (savedRefs, keep, extras)

buildSavedState :: [WindowRef] -> SerialState WindowRef
buildSavedState [wrL1, wrL2, wrR1] = SerialState
    { ssVersion    = persistenceVersion
    , ssStacks     = [ ("L", Just (SerStack wrL1 [] [wrL2]))
                     , ("R", Just (SerStack wrR1 [] []))
                     ]
    , ssCurrentTag = "L"
    , ssFloating   = []
    , ssAffinity   = [("L", 0), ("R", 1)]
    , ssTimers     = []
    , ssNextTimerId = 1
    }
buildSavedState _ = error "buildSavedState: expected 3 saved refs"

twoScreens :: [(ScreenId, ScreenDetail)]
twoScreens =
    [ (S 0, SD (Rectangle 0 0 1000 1000))
    , (S 1, SD (Rectangle 1000 0 1000 1000))
    ]

twoTags :: [String]
twoTags = ["L", "R"]

-- After restore, the WindowSet contains exactly the saved refs that
-- are still live. Refs in 'kept' must be present; saved refs NOT in
-- 'kept' (i.e. stale) must be absent.
prop_persistence_round_trip :: Property
prop_persistence_round_trip = forAll genPersistCase $ \(savedRefs, kept, extras) ->
    let saved = buildSavedState savedRefs
        lives = [ mkWindowInfo (wrWindowId r) (wrPid r) | r <- kept ++ extras ]
        ws0 :: W.StackSet String Int WindowRef ScreenId ScreenDetail
        ws0 = serialToWindowSet (0 :: Int) twoTags twoScreens saved
        liveSet = Set.fromList [WindowRef (wiWindowId wi) (wiPid wi) | wi <- lives]
        stale = filter (`Set.notMember` liveSet) (W.allWindows ws0)
        ws = foldr W.delete ws0 stale
        present = W.allWindows ws
        staleRefs = filter (`notElem` kept) savedRefs
    in counterexample ("kept=" ++ show kept ++ " stale=" ++ show staleRefs
                        ++ " present=" ++ show present) $
       all (`elem` present)    kept
       .&&. all (`notElem` present) staleRefs

-- The unmatched list is exactly the live refs that don't appear in
-- the (reconciled) WindowSet — i.e. windows not covered by saved
-- state. These are the ones that go through the manage hook.
prop_persistence_unmatched_are_new :: Property
prop_persistence_unmatched_are_new = forAll genPersistCase $ \(savedRefs, kept, extras) ->
    let saved = buildSavedState savedRefs
        lives = [ mkWindowInfo (wrWindowId r) (wrPid r) | r <- kept ++ extras ]
        ws0 :: W.StackSet String Int WindowRef ScreenId ScreenDetail
        ws0 = serialToWindowSet (0 :: Int) twoTags twoScreens saved
        liveSet = Set.fromList [WindowRef (wiWindowId wi) (wiPid wi) | wi <- lives]
        stale = filter (`Set.notMember` liveSet) (W.allWindows ws0)
        ws = foldr W.delete ws0 stale
        inWs wi = let wr = WindowRef (wiWindowId wi) (wiPid wi) in W.member wr ws
        unmatched = filter (not . inWs) lives
        expectedNew = [ WindowRef (wiWindowId wi) (wiPid wi) | wi <- unmatched ]
    in counterexample ("extras=" ++ show extras ++ " unmatched=" ++ show expectedNew) $
       map (\wr -> (wrWindowId wr, wrPid wr)) expectedNew
       === map (\wr -> (wrWindowId wr, wrPid wr)) extras

-- Round-trip preservation: saved windows that survive land on the
-- workspace they were saved to (not somewhere else).
prop_persistence_workspace_preserved :: Property
prop_persistence_workspace_preserved = forAll genPersistCase $ \(savedRefs, kept, _extras) ->
    let saved = buildSavedState savedRefs
        ws0 :: W.StackSet String Int WindowRef ScreenId ScreenDetail
        ws0 = serialToWindowSet (0 :: Int) twoTags twoScreens saved
        liveSet = Set.fromList kept
        stale = filter (`Set.notMember` liveSet) (W.allWindows ws0)
        ws = foldr W.delete ws0 stale
        -- Expected: "L" holds wrL1 and/or wrL2; "R" holds wrR1.
        [wrL1, wrL2, wrR1] = savedRefs
        windowsOn tag = case lookup tag [(W.tag w, W.integrate' (W.stack w))
                                          | w <- W.workspaces ws] of
            Just xs -> xs
            Nothing -> []
        lWins = windowsOn "L"
        rWins = windowsOn "R"
    in conjoin
        [ counterexample ("wrL1 on L? kept=" ++ show kept)
            ((wrL1 `elem` kept) === (wrL1 `elem` lWins))
        , counterexample ("wrL2 on L? kept=" ++ show kept)
            ((wrL2 `elem` kept) === (wrL2 `elem` lWins))
        , counterexample ("wrR1 on R? kept=" ++ show kept)
            ((wrR1 `elem` kept) === (wrR1 `elem` rWins))
        ]

-- === FLOATING-MAP HYGIENE (the mcmonad.state leak) ===
--
-- 'W.float' inserts into the floating map unconditionally and
-- 'W.delete'' deliberately skips it (xmonad keeps the entry for
-- temporary removals), so float-only entries for dead windows used to
-- accumulate in mcmonad.state forever (~480 observed on 2026-07-17).
-- Three guards now enforce the invariant floating ⊆ allWindows:
-- restore prunes, save filters, and the unmanage / stale-window paths
-- use the full 'W.delete'.

-- Restoring a snapshot whose ssFloating carries entries for windows
-- absent from every stack drops exactly those entries.
prop_floating_pruned_on_restore :: Property
prop_floating_pruned_on_restore = forAll genPersistCase $ \(savedRefs, _, _) ->
    let wrL1 = head savedRefs
        garbage = WindowRef 9999 9999
        saved = (buildSavedState savedRefs)
            { ssFloating = [ (wrL1,    (0.1, 0.1, 0.5, 0.5))
                           , (garbage, (0.2, 0.2, 0.5, 0.5))
                           ]
            }
        ws :: W.StackSet String Int WindowRef ScreenId ScreenDetail
        ws = serialToWindowSet (0 :: Int) twoTags twoScreens saved
    in counterexample ("floating=" ++ show (Map.keys (W.floating ws))) $
       Map.member wrL1 (W.floating ws)
       .&&. not (Map.member garbage (W.floating ws))

-- Saving keeps floating entries for members and never emits one for a
-- float-only (leaked) window.
prop_floating_pruned_on_save :: Property
prop_floating_pruned_on_save = forAll genPersistCase $ \(savedRefs, _, _) ->
    let wrL1 = head savedRefs
        garbage = WindowRef 9999 9999
        ws0 :: W.StackSet String Int WindowRef ScreenId ScreenDetail
        ws0 = serialToWindowSet (0 :: Int) twoTags twoScreens
                                (buildSavedState savedRefs)
        ws  = ws0 { W.floating = Map.fromList
                        [ (wrL1,    W.RationalRect 0.1 0.1 0.5 0.5)
                        , (garbage, W.RationalRect 0.2 0.2 0.5 0.5)
                        ]
                  }
        ser = windowSetToSerial ws Map.empty [] 1
        savedFloats = map fst (ssFloating ser)
    in counterexample ("ssFloating=" ++ show savedFloats) $
       (wrL1 `elem` savedFloats) .&&. (garbage `notElem` savedFloats)

-- The stale-window reconciliation at restore uses the full 'W.delete':
-- a floated stale window loses its floating entry along with its stack
-- slot.
prop_stale_delete_clears_floating :: Property
prop_stale_delete_clears_floating = forAll genPersistCase $ \(savedRefs, _, _) ->
    let wrL1 = head savedRefs
        saved = (buildSavedState savedRefs)
            { ssFloating = [ (wrL1, (0.1, 0.1, 0.5, 0.5)) ] }
        ws0 :: W.StackSet String Int WindowRef ScreenId ScreenDetail
        ws0 = serialToWindowSet (0 :: Int) twoTags twoScreens saved
        -- wrL1 died while mcmonad was down: reconcile exactly as
        -- 'restoreSnapshot' does.
        ws = foldr W.delete ws0 [wrL1]
    in counterexample ("floating=" ++ show (Map.keys (W.floating ws))) $
       not (W.member wrL1 ws)
       .&&. not (Map.member wrL1 (W.floating ws))

-- === serialToWindowSet RESPECTS ssAffinity ===
--
-- The regression sentinel for the Mod-w/Mod-e wrong-screen bug. The
-- pre-fix rebuilder put 'ssCurrentTag' on screen 0 and the remaining
-- workspaces on screens 1+ in config order, ignoring 'ssAffinity'.
-- On a two-monitor setup this swapped which workspace each monitor
-- held whenever 'ssCurrentTag' had been on screen 1 at save time.

-- Two screens, two workspaces with explicit affinity to opposite
-- screens — the rebuilder must place each on its saved screen,
-- regardless of which one is the saved current.
prop_serialToWindowSet_respects_affinity_two_screens :: Bool -> Property
prop_serialToWindowSet_respects_affinity_two_screens currentIsLeft =
    let tagL = "L"
        tagR = "R"
        allTags = [tagL, tagR]
        screens = [ (S 0, SD (Rectangle 0 0 1000 1000))
                  , (S 1, SD (Rectangle 1000 0 1000 1000))
                  ]
        saved = SerialState
            { ssVersion    = persistenceVersion
            , ssStacks     = [(tagL, Nothing), (tagR, Nothing)]
            , ssCurrentTag = if currentIsLeft then tagL else tagR
            , ssFloating   = []
            , ssAffinity   = [(tagL, 0), (tagR, 1)]
            , ssTimers     = []
            , ssNextTimerId = 1
            }
        ws :: W.StackSet String Int WindowRef ScreenId ScreenDetail
        ws = serialToWindowSet (0 :: Int) allTags screens saved
        tagOn n = listToMaybe
                $ [ W.tag (W.workspace s)
                  | s <- W.current ws : W.visible ws
                  , W.screen s == S n
                  ]
    in counterexample (show ws) $
       (tagOn 0 === Just tagL) .&&. (tagOn 1 === Just tagR)
  where
    listToMaybe [] = Nothing
    listToMaybe (x:_) = Just x

-- Whichever workspace was saved as current must be the current one
-- after restore (the screen it lands on is whichever one its
-- ssAffinity says).
prop_serialToWindowSet_preserves_current_tag :: Bool -> Property
prop_serialToWindowSet_preserves_current_tag currentIsLeft =
    let tagL = "L"
        tagR = "R"
        allTags = [tagL, tagR]
        screens = [ (S 0, SD (Rectangle 0 0 1000 1000))
                  , (S 1, SD (Rectangle 1000 0 1000 1000))
                  ]
        cur = if currentIsLeft then tagL else tagR
        saved = SerialState
            { ssVersion    = persistenceVersion
            , ssStacks     = [(tagL, Nothing), (tagR, Nothing)]
            , ssCurrentTag = cur
            , ssFloating   = []
            , ssAffinity   = [(tagL, 0), (tagR, 1)]
            , ssTimers     = []
            , ssNextTimerId = 1
            }
        ws :: W.StackSet String Int WindowRef ScreenId ScreenDetail
        ws = serialToWindowSet (0 :: Int) allTags screens saved
    in W.currentTag ws === cur

-- When 'ssAffinity' is empty (e.g. a save from an older format or a
-- single-screen session), the rebuilder must still produce something
-- sensible: the saved current tag goes on the first screen, the rest
-- in config order.
prop_serialToWindowSet_no_affinity_falls_back :: Property
prop_serialToWindowSet_no_affinity_falls_back =
    let allTags = ["a", "b", "c"]
        screens = [(S 0, SD (Rectangle 0 0 1000 1000))]
        saved = SerialState
            { ssVersion    = persistenceVersion
            , ssStacks     = []
            , ssCurrentTag = "b"
            , ssFloating   = []
            , ssAffinity   = []        -- no affinity hints
            , ssTimers     = []
            , ssNextTimerId = 1
            }
        ws :: W.StackSet String Int WindowRef ScreenId ScreenDetail
        ws = serialToWindowSet (0 :: Int) allTags screens saved
    in W.currentTag ws === "b"

-- === PARK-CORNER DETECTION (multi-monitor) ===
--
-- 'frameAtParkCorner' answers "is this should-be-hidden window still
-- parked, or has it drifted back on-screen?" A false "yes" means the
-- window never gets re-parked and stays visible.
--
-- The regression these pin: the test used to be "x is at or past SOME
-- screen's right edge", which on a side-by-side layout is satisfied by
-- every ordinary window on the right-hand display — its left edge IS the
-- left display's right edge. Windows tiled on the second monitor were
-- therefore reported as parked and never hidden on a workspace switch.

-- The real septnesis layout: 3440-wide ultrawide at the origin, laptop
-- display butted against its right edge.
twoScreenSet :: TestStackSet
twoScreenSet = W.StackSet
    { W.current = W.Screen (wsp "a") (S 0) (SD (Rectangle 0 30 3440 1410))
    , W.visible = [W.Screen (wsp "b") (S 1) (SD (Rectangle 3440 147 1728 1085))]
    , W.hidden  = [wsp "c"]
    , W.floating = Map.empty
    }
  where wsp t = W.Workspace t (0 :: TestLayout) Nothing

-- A window filling the second monitor is NOT parked, even though its
-- origin sits exactly on the first monitor's right edge.
prop_parkCorner_tiled_on_second_screen :: Property
prop_parkCorner_tiled_on_second_screen =
    frameAtParkCorner (Rectangle 3440 147 1728 1085) twoScreenSet === False

-- Neither is a half-width tile on the second monitor.
prop_parkCorner_half_tile_on_second_screen :: Property
prop_parkCorner_half_tile_on_second_screen =
    frameAtParkCorner (Rectangle 4304 147 864 1085) twoScreenSet === False

-- A window parked in the first screen's corner IS parked: only a 1px
-- column overlaps, and the frame hangs below the second display.
prop_parkCorner_parked_on_first_screen :: Property
prop_parkCorner_parked_on_first_screen =
    frameAtParkCorner (Rectangle 3439 1439 3440 1410) twoScreenSet === True

-- So is one parked in the second screen's corner.
prop_parkCorner_parked_on_second_screen :: Property
prop_parkCorner_parked_on_second_screen =
    frameAtParkCorner (Rectangle 5167 1231 1728 1085) twoScreenSet === True

-- The fullscreen-transition sweep re-fits a window flush against a
-- screen's right edge (x = screenRight - width). That is drift, not a
-- park, and must trigger a re-assert.
prop_parkCorner_rejects_unpark_sweep :: Property
prop_parkCorner_rejects_unpark_sweep =
    frameAtParkCorner (Rectangle 0 33 3440 1410) twoScreenSet === False

-- === RESCREEN (display reconfiguration) ===
--
-- 'reassignScreens' runs on every macOS
-- @didChangeScreenParametersNotification@ — which fires for resolution
-- changes, display sleep and menu-bar geometry, not just plug/unplug.
-- It therefore has to be a no-op when the screen set is unchanged. The
-- regression these pin: the old implementation rebuilt the assignment
-- from @current : visible ++ hidden@ and gave the head to screen 0, so
-- with focus on the secondary monitor every notification swapped the
-- two displays' workspaces, and windows ping-ponged between monitors.

detailsOf :: TestStackSet -> [(ScreenId, ScreenDetail)]
detailsOf ss = [ (W.screen s, W.screenDetail s) | s <- W.current ss : W.visible ss ]

-- Re-running with the screen set unchanged changes nothing at all.
prop_reassignScreens_unchanged_is_identity :: TestStackSet -> Property
prop_reassignScreens_unchanged_is_identity ss =
    let details = L.sortOn fst (detailsOf ss)
    in case reassignScreens details ss of
        Nothing  -> property False
        Just ss' -> conjoin
            [ W.currentTag ss' === W.currentTag ss
            , W.screen (W.current ss') === W.screen (W.current ss)
            , screenAssignment ss' === screenAssignment ss
            ]

-- Every surviving screen id keeps the workspace it was displaying —
-- the property the ping-pong bug violated.
prop_reassignScreens_preserves_assignment :: TestStackSet -> Property
prop_reassignScreens_preserves_assignment ss =
    let details = L.sortOn fst (detailsOf ss)
    in case reassignScreens details ss of
        Nothing  -> property False
        Just ss' -> screenAssignment ss' === screenAssignment ss

-- No window is lost or duplicated across a reconfiguration.
prop_reassignScreens_invariant :: TestStackSet -> Property
prop_reassignScreens_invariant ss =
    let details = L.sortOn fst (detailsOf ss)
    in case reassignScreens details ss of
        Nothing  -> property False
        Just ss' -> conjoin
            [ property (invariant ss')
            , L.sort (W.allWindows ss') === L.sort (W.allWindows ss)
            ]

-- Unplugging the focused monitor must still leave exactly one current
-- screen, drawn from the survivors, with nothing lost.
prop_reassignScreens_drop_focused_screen :: TestStackSet -> Property
prop_reassignScreens_drop_focused_screen ss =
    let details = L.sortOn fst (detailsOf ss)
        survivors = filter ((/= W.screen (W.current ss)) . fst) details
    in not (null survivors) ==>
        case reassignScreens survivors ss of
            Nothing  -> property False
            Just ss' -> conjoin
                [ property (invariant ss')
                , L.sort (W.allWindows ss') === L.sort (W.allWindows ss)
                , property (W.screen (W.current ss') `elem` map fst survivors)
                , L.sort (map W.screen (W.current ss' : W.visible ss'))
                    === L.sort (map fst survivors)
                ]

-- (screenId, workspace tag) for every displayed screen.
screenAssignment :: TestStackSet -> [(ScreenId, String)]
screenAssignment ss = L.sort
    [ (W.screen s, W.tag (W.workspace s)) | s <- W.current ss : W.visible ss ]

-- | The historic (broken) rescreen assignment, kept so the
-- bug-reproduction property below has something to fail against.
-- Rebuilds from @current : visible ++ hidden@ and hands the head to the
-- first screen — position-based, so the focused workspace is dragged to
-- screen 0 no matter which monitor it was on.
reassignScreensBroken
    :: [(ScreenId, ScreenDetail)] -> TestStackSet -> Maybe TestStackSet
reassignScreensBroken newDetails ss =
    case (screenWsps, newDetails) of
        (w:restWsps, (sid, sd):restDetails) -> Just ss
            { W.current = W.Screen w sid sd
            , W.visible = zipWith (\wsp (s, d) -> W.Screen wsp s d)
                                  restWsps restDetails
            , W.hidden  = newHidden
            }
        _ -> Nothing
  where
    allWsps = W.workspace (W.current ss)
            : map W.workspace (W.visible ss)
           ++ W.hidden ss
    (screenWsps, newHidden) = splitAt (length newDetails) allWsps

-- THE BUG REPRO. With focus on a monitor other than the first, the old
-- assignment moves the focused workspace to screen 0 — i.e. a bare
-- "screen parameters changed" notification teleports windows between
-- displays. The fixed 'reassignScreens' leaves the assignment alone.
prop_reassignScreens_fixes_the_swap :: TestStackSet -> Property
prop_reassignScreens_fixes_the_swap ss =
    let details = L.sortOn fst (detailsOf ss)
        focusedElsewhere = W.screen (W.current ss) /= fst (head details)
    in not (null details) && focusedElsewhere ==> conjoin
        [ counterexample "old code should have swapped the assignment"
            $ fmap screenAssignment (reassignScreensBroken details ss)
                =/= Just (screenAssignment ss)
        , counterexample "new code must preserve the assignment"
            $ fmap screenAssignment (reassignScreens details ss)
                === Just (screenAssignment ss)
        ]

-- ---------------------------------------------------------------------------
-- Re-manage routing: reclaimOrigin / unmanagedOrigin
--
-- mcmonad-core's reconcile sweep re-offers any live, manageable window
-- the brain isn't holding, so 'manage' now runs for windows that were
-- never really gone. 'chooseOriginTag' decides where such a window
-- lands. Getting it wrong is user-visible in both directions: too eager
-- and an unrelated window teleports onto a stale tag, too lax and every
-- reclaimed window piles onto whatever workspace is current.

originBase :: UTCTime
originBase = posixSecondsToUTCTime 1700000000

-- | An entry that is @age@ seconds old relative to 'originBase'.
aged :: String -> Int -> (String, UTCTime)
aged tag age = (tag, addUTCTime (negate (fromIntegral age)) originBase)

liveTags :: [String]
liveTags = ["1", "2", "3", "web", "chat"]

-- An exact-window reclaim beats the pid heuristic: the same CGWindowID
-- coming back is proof the window never died, whereas the pid entry is
-- only ever an inference about a *replacement* window.
prop_chooseOrigin_reclaim_beats_pid :: WindowRef -> Property
prop_chooseOrigin_reclaim_beats_pid wr =
    chooseOriginTag originBase liveTags wr (wrPid wr)
        (Map.singleton wr (aged "web" 1))
        (Map.singleton (wrPid wr) (aged "chat" 1))
        === Just "web"

-- With no reclaim entry the pid heuristic still applies — this is the
-- Gecko destroy/recreate path, which must keep working.
prop_chooseOrigin_pid_when_no_reclaim :: WindowRef -> Property
prop_chooseOrigin_pid_when_no_reclaim wr =
    chooseOriginTag originBase liveTags wr (wrPid wr)
        Map.empty
        (Map.singleton (wrPid wr) (aged "chat" 1))
        === Just "chat"

-- A reclaim older than its TTL is not merely deprioritised, it is gone:
-- fall through to the pid entry rather than honouring a stale tag.
prop_chooseOrigin_expired_reclaim_falls_through :: WindowRef -> Property
prop_chooseOrigin_expired_reclaim_falls_through wr =
    chooseOriginTag originBase liveTags wr (wrPid wr)
        (Map.singleton wr (aged "web" (round reclaimOriginTTL + 1)))
        (Map.singleton (wrPid wr) (aged "chat" 1))
        === Just "chat"

-- A tag the config no longer has must never be resurrected.
prop_chooseOrigin_rejects_dead_tag :: WindowRef -> Property
prop_chooseOrigin_rejects_dead_tag wr =
    chooseOriginTag originBase liveTags wr (wrPid wr)
        (Map.singleton wr (aged "renamed-away" 1))
        Map.empty
        === Nothing

-- No opinion for a genuinely new window.
prop_chooseOrigin_empty_is_nothing :: WindowRef -> Property
prop_chooseOrigin_empty_is_nothing wr =
    chooseOriginTag originBase liveTags wr (wrPid wr) Map.empty Map.empty
        === Nothing

mkReclaims :: [(WindowRef, Int)] -> Map.Map WindowRef (String, UTCTime)
mkReclaims entries =
    Map.fromList [ (w, aged "1" (abs age)) | (w, age) <- entries ]

-- 'reclaimOrigin' is fed by *every* unmanage, so pruning must actually
-- bound it — a fullscreen Space transition can churn the whole desktop.
prop_pruneReclaims_respects_cap :: [(WindowRef, Int)] -> Property
prop_pruneReclaims_respects_cap entries =
    property $
        Map.size (pruneReclaims originBase (mkReclaims entries))
            <= reclaimOriginCap

prop_pruneReclaims_drops_expired :: [(WindowRef, Int)] -> Property
prop_pruneReclaims_drops_expired entries =
    property $ all withinTTL
        (Map.elems (pruneReclaims originBase (mkReclaims entries)))
  where
    withinTTL (_, at) = diffUTCTime originBase at <= reclaimOriginTTL

-- Pruning is not allowed to lose a fresh entry that fits under the cap;
-- a dropped reclaim silently degrades to "lands on the current
-- workspace", which is the bug this map exists to prevent.
prop_pruneReclaims_keeps_fresh :: [WindowRef] -> Property
prop_pruneReclaims_keeps_fresh ws =
    length ws <= reclaimOriginCap ==>
        pruneReclaims originBase m === m
  where
    m = mkReclaims [ (w, 0) | w <- ws ]

-- Collect all properties
allProperties :: [(String, Property)]
allProperties =
    [ ("invariant",               property prop_invariant)
    , ("focusUp/focusDown",       property prop_focusUp_focusDown)
    , ("focusDown/focusUp",       property prop_focusDown_focusUp)
    , ("focusMaster idem",        property prop_focusMaster_idem)
    , ("focusUp invariant",       property prop_focusUp_invariant)
    , ("focusDown invariant",     property prop_focusDown_invariant)
    , ("focusMaster invariant",   property prop_focusMaster_invariant)
    , ("focusUp local",           property prop_focusUp_local)
    , ("focusDown local",         property prop_focusDown_local)
    , ("focus all left",          property prop_focus_all_l)
    , ("focus all right",         property prop_focus_all_r)
    , ("focusWindow works",       property prop_focusWindow_works)
    , ("focusWindow invariant",   property prop_focusWindow_invariant)
    , ("view current",            property prop_view_current)
    , ("view idem",               property prop_view_idem)
    , ("view reversible",         property prop_view_reversible)
    , ("view invariant",          property prop_view_invariant)
    , ("greedyView current",      property prop_greedyView_current)
    , ("greedyView invariant",    property prop_greedyView_invariant)
    , ("insertUp invariant",      property prop_insertUp_invariant)
    , ("insert/delete",           property prop_insert_delete)
    , ("delete invariant",        property prop_delete_invariant)
    , ("delete member",           property prop_delete_member)
    , ("insert member",           property prop_insert_member)
    , ("size insert",             property prop_size_insert)
    , ("insert local",            property prop_insert_local)
    , ("swapMaster invariant",    property prop_swapMaster_invariant)
    , ("swapUp invariant",        property prop_swapUp_invariant)
    , ("swapDown invariant",      property prop_swapDown_invariant)
    , ("swapMaster focus",        property prop_swapMaster_focus)
    , ("swapUp focus",            property prop_swapUp_focus)
    , ("swapDown focus",          property prop_swapDown_focus)
    , ("swapMaster idem",         property prop_swapMaster_idem)
    , ("swapMaster local",        property prop_swapMaster_local)
    , ("shift invariant",         property prop_shift_invariant)
    , ("shift reversible",        property prop_shift_reversible)
    , ("float invariant",         property prop_float_invariant)
    , ("float/sink",              property prop_float_sink)
    , ("member/peek",             property prop_member_peek)
    , ("allWindows member",       property prop_allWindows_member)
    , ("currentTag",              property prop_currentTag)
    , ("screens current",         property prop_screens_current)
    , ("mapLayout id",            property prop_mapLayout_id)
    -- Affinity
    , ("updateAffinities records visible", property prop_updateAffinities_records_visible)
    , ("updateAffinities preserves hidden", property prop_updateAffinities_preserves_hidden)
    , ("viewOnScreen invariant",  property prop_viewOnScreen_invariant)
    , ("viewOnScreen places workspace", property prop_viewOnScreen_places_workspace)
    -- Focus resolution (multi-window-per-app focus fix)
    , ("focusedWindow picks exact",                  property prop_focusedWindow_picks_exact)
    , ("focusedWindow hidden is no-op",              property prop_focusedWindow_off_workspace_is_no_op)
    , ("focusedWindow keeps displayed set",          property prop_focusedWindow_never_changes_displayed_set)
    , ("focusedWindow follows to other screen",      property prop_focusedWindow_follows_to_other_screen)
    , ("focusedWindow invariant",                    property prop_focusedWindow_invariant)
    , ("focusedWindow unknown is no-op",             property prop_focusedWindow_unknown_noop)
    , ("focusedWindow distinguishes shared-PID",     property prop_focusedWindow_distinguishes_shared_pid)
    , ("broken PID-only is indistinguishable",       property prop_brokenPidOnly_indistinguishable)
    , ("frontApp no-op within app",                  property prop_frontApp_noop_within)
    , ("frontApp switches within workspace",         property prop_frontApp_switches_within_workspace)
    , ("frontApp keeps displayed set",               property prop_frontApp_never_changes_displayed_set)
    , ("frontApp ignores hidden-only app",           property prop_frontApp_ignores_hidden_only_app)
    , ("frontApp prefers current screen",            property prop_frontApp_prefers_current_screen)
    , ("frontApp follows to other screen",           property prop_frontApp_follows_to_other_screen)

    , ("armingIntent arms with target",                property prop_armingIntent_arms_when_target)
    , ("armingIntent Nothing clears",                  property prop_armingIntent_nothing_clears)
    , ("isFocusIntentTarget recognises target",        property prop_isFocusIntentTarget_recognises_target)
    , ("isFocusIntentTarget distinguishes others",     property prop_isFocusIntentTarget_distinguishes)
    , ("isIntentTargetPid matches same pid",           property prop_isIntentTargetPid_matches_same_pid)
    , ("isIntentTargetPid distinguishes cross-app",    property prop_isIntentTargetPid_distinguishes_other_pid)
    , ("consumeIntent drains exactly the budget",      property prop_consumeIntent_drains_exactly_the_budget)
    , ("settling echo recognises laid-out window",     property prop_isSettlingEcho_recognises_laid_out)
    , ("settling echo covers whole set, not just target", property prop_isSettlingEcho_covers_whole_set)
    , ("settling echo rejects an outsider window",     property prop_isSettlingEcho_rejects_outsider)
    , ("settling pid-echo matches and rejects",        property prop_isSettlingPidEcho_matches_and_rejects)
    , ("settle window bounds echo suppression",        property prop_settle_window_bounds_suppression)
    -- Cross-restart identity matcher
    -- Persistence round-trip (WindowRef identity)
    , ("persistence: kept saved survives, stale dropped", property prop_persistence_round_trip)
    , ("persistence: live-not-saved becomes 'new'",       property prop_persistence_unmatched_are_new)
    , ("persistence: surviving windows stay on workspace",property prop_persistence_workspace_preserved)
    -- Floating-map hygiene (the mcmonad.state leak)
    , ("floating: restore prunes float-only entries",  property prop_floating_pruned_on_restore)
    , ("floating: save filters float-only entries",    property prop_floating_pruned_on_save)
    , ("floating: stale delete clears floating",       property prop_stale_delete_clears_floating)
    -- serialToWindowSet restoring per-screen workspace assignment
    , ("serialToWindowSet respects ssAffinity",       property prop_serialToWindowSet_respects_affinity_two_screens)
    , ("serialToWindowSet preserves current tag",     property prop_serialToWindowSet_preserves_current_tag)
    , ("serialToWindowSet no affinity falls back",    property prop_serialToWindowSet_no_affinity_falls_back)
    -- Park-corner detection on side-by-side displays
    , ("park: second-screen tile is not parked",      property prop_parkCorner_tiled_on_second_screen)
    , ("park: second-screen half tile is not parked", property prop_parkCorner_half_tile_on_second_screen)
    , ("park: first-screen corner is parked",         property prop_parkCorner_parked_on_first_screen)
    , ("park: second-screen corner is parked",        property prop_parkCorner_parked_on_second_screen)
    , ("park: un-park sweep is drift",                property prop_parkCorner_rejects_unpark_sweep)
    -- Display reconfiguration
    , ("rescreen: unchanged is identity",             property prop_reassignScreens_unchanged_is_identity)
    , ("rescreen: preserves screen assignment",       property prop_reassignScreens_preserves_assignment)
    , ("rescreen: invariant + no window lost",        property prop_reassignScreens_invariant)
    , ("rescreen: focused monitor unplugged",         property prop_reassignScreens_drop_focused_screen)
    , ("rescreen: broken version swapped displays",   property prop_reassignScreens_fixes_the_swap)
    -- Re-manage routing after a reconcile-sweep reclaim
    , ("origin: exact reclaim beats pid guess",       property prop_chooseOrigin_reclaim_beats_pid)
    , ("origin: pid guess when no reclaim",           property prop_chooseOrigin_pid_when_no_reclaim)
    , ("origin: expired reclaim falls through",       property prop_chooseOrigin_expired_reclaim_falls_through)
    , ("origin: dead tag is not resurrected",         property prop_chooseOrigin_rejects_dead_tag)
    , ("origin: nothing known means no opinion",      property prop_chooseOrigin_empty_is_nothing)
    , ("reclaim: prune respects cap",                 property prop_pruneReclaims_respects_cap)
    , ("reclaim: prune drops expired",                property prop_pruneReclaims_drops_expired)
    , ("reclaim: prune keeps fresh entries",          property prop_pruneReclaims_keeps_fresh)
    ]
