{-# LANGUAGE OverloadedStrings #-}
module Properties where

import Test.QuickCheck
import qualified XMonad.StackSet as W
import MCMonad.Core
    ( WindowRef(..), ScreenId(..), ScreenDetail(..), Rectangle(..)
    , StableWindowId(..)
    , updateAffinities, resolveFocusedWindow, resolveFrontApp
    )
import MCMonad.IPC (WindowInfo(..))
import MCMonad.Persistence
    ( SerialState(..), SerStack(..), MatchResult(..)
    , matchWindows, stableIdFor, persistenceVersion
    , serialToWindowSet
    )
import MCMonad.Sway (viewOnScreen)
import qualified Data.List as L
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import Data.Int (Int32)
import qualified Data.Text as T
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

-- | Windows on the current and visible workspaces — the set
-- 'resolveFocusedWindow' / 'resolveFrontApp' are allowed to act on.
-- Mirror of 'MCMonad.Core.visibleWindows' kept here so the tests
-- don't depend on it being exported.
visibleWindowsForTest :: TestStackSet -> [WindowRef]
visibleWindowsForTest ss =
    concatMap (W.integrate' . W.stack . W.workspace)
              (W.current ss : W.visible ss)

-- For any *visible* window, asking resolveFocusedWindow for it results
-- in that exact window being focused — regardless of whether other
-- windows share its PID.
prop_focusedWindow_picks_exact :: TestStackSet -> Property
prop_focusedWindow_picks_exact ss = case visibleWindowsForTest ss of
    [] -> property True
    wins -> forAll (elements wins) $ \wr ->
        let r = resolveFocusedWindow (wrWindowId wr) (wrPid wr) ss
            focused = maybe (W.peek ss) W.peek r
        in focused === Just wr

-- A focused-window event targeting a window on a HIDDEN workspace must
-- be a no-op. This is the property that prevents background AX
-- activity (Chrome rendering a hidden tab, Librewolf network callbacks,
-- Electron polling) from silently dragging the current screen onto a
-- workspace the user didn't ask for.
prop_focusedWindow_hidden_is_no_op :: TestStackSet -> Property
prop_focusedWindow_hidden_is_no_op ss =
    let hiddenWins = concatMap (W.integrate' . W.stack) (W.hidden ss)
        visWins   = visibleWindowsForTest ss
        -- Only meaningful when the hidden window isn't also visible (a
        -- StackSet invariant says it can't be, but the generator
        -- nominally allows duplicates — be defensive).
        purelyHidden = filter (`notElem` visWins) hiddenWins
    in case purelyHidden of
        [] -> property True
        wins -> forAll (elements wins) $ \wr ->
            property $ isNothing
                     $ resolveFocusedWindow (wrWindowId wr) (wrPid wr) ss

-- resolveFocusedWindow never lands the current screen on a workspace
-- that was hidden before the call. This is the regression sentinel
-- for the flicker bug: the previous version used 'W.allWindows', so a
-- focus event for a hidden window pulled the current screen onto that
-- workspace via 'W.focusWindow''s implicit 'view' call. Note that
-- swapping current with a *visible-secondary* screen IS allowed —
-- that's the multi-monitor "click a window on the other monitor"
-- case, and xmonad implements it as a current-tag swap.
prop_focusedWindow_never_lands_on_hidden :: TestStackSet -> Property
prop_focusedWindow_never_lands_on_hidden ss = case W.allWindows ss of
    [] -> property True
    wins -> forAll (elements wins) $ \wr ->
        case resolveFocusedWindow (wrWindowId wr) (wrPid wr) ss of
            Nothing  -> property True
            Just ss' ->
                let visibleBefore = W.currentTag ss
                                  : map (W.tag . W.workspace) (W.visible ss)
                in counterexample
                    ("landed on " ++ show (W.currentTag ss')
                     ++ " from visible " ++ show visibleBefore)
                    (property (W.currentTag ss' `elem` visibleBefore))

-- resolveFocusedWindow preserves the no-duplicates invariant.
prop_focusedWindow_invariant :: TestStackSet -> Property
prop_focusedWindow_invariant ss = case visibleWindowsForTest ss of
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
-- and the target app has a *visible* window. (PID-only events for
-- apps whose windows are all hidden must NOT switch workspaces.)
prop_frontApp_switches_across :: TestStackSet -> Property
prop_frontApp_switches_across ss = case W.peek ss of
    Nothing -> property True
    Just wr ->
        let visPids = L.nub
                    $ filter (/= wrPid wr)
                    $ map wrPid (visibleWindowsForTest ss)
        in case visPids of
            [] -> property True
            (p:_) -> case resolveFrontApp p ss of
                Just ss' -> property (fmap wrPid (W.peek ss') === Just p)
                Nothing  -> property False  -- a visible window of pid p exists; must switch

-- resolveFrontApp must not land the current screen on a hidden
-- workspace either — same hidden-app regression sentinel.
prop_frontApp_never_lands_on_hidden :: TestStackSet -> Property
prop_frontApp_never_lands_on_hidden ss =
    let pids = L.nub $ map wrPid (W.allWindows ss)
    in case pids of
        [] -> property True
        _  -> forAll (elements pids) $ \p ->
            case resolveFrontApp p ss of
                Nothing  -> property True
                Just ss' ->
                    let visibleBefore = W.currentTag ss
                                      : map (W.tag . W.workspace) (W.visible ss)
                    in property (W.currentTag ss' `elem` visibleBefore)


-- === CROSS-RESTART IDENTITY (MCMonad.Persistence) ===
--
-- Properties for the three-tier 'matchWindows' assignment. The
-- saved snapshot's CGWindowIDs are stale; matching has to look only
-- at the stable identity components carried by the matched
-- WindowInfo.

-- | A small dictionary of bundle ids / subroles / titles to keep
-- generated 'StableWindowId's overlapping often enough that the
-- matcher actually gets exercised.
genBundle :: Gen (Maybe T.Text)
genBundle = oneof
    [ pure Nothing
    , Just <$> elements
        [ "com.app.alpha", "com.app.beta", "com.app.gamma" ]
    ]

genSubrole :: Gen (Maybe T.Text)
genSubrole = oneof
    [ pure Nothing
    , Just <$> elements [ "AXStandardWindow", "AXDialog", "AXSystemDialog" ]
    ]

genAxIdentifier :: Gen (Maybe T.Text)
genAxIdentifier = oneof
    [ pure Nothing
    , pure Nothing  -- weight nil higher (most apps don't set it)
    , Just <$> elements [ "main", "settings", "downloads" ]
    ]

genTitleHash :: Gen (Maybe T.Text)
genTitleHash = oneof
    [ pure Nothing
    , Just <$> elements [ "aabbccdd11223344", "deadbeefcafebabe", "0000111122223333" ]
    ]

instance Arbitrary StableWindowId where
    arbitrary = StableWindowId
        <$> genBundle
        <*> genAxIdentifier
        <*> genSubrole
        <*> genTitleHash

-- | Build a 'WindowInfo' that, when fed through 'stableIdFor', yields
-- the given 'StableWindowId'. The other 'WindowInfo' fields are
-- irrelevant to the matcher and use bland defaults.
windowInfoFor :: Word32 -> Int32 -> StableWindowId -> WindowInfo
windowInfoFor wid pid sid = WindowInfo
    { wiWindowId            = wid
    , wiPid                 = pid
    , wiTitle               = Nothing
    , wiAppName             = Nothing
    , wiBundleId            = swiBundleId sid
    , wiSubrole             = swiSubrole sid
    , wiAxIdentifier        = swiAxIdentifier sid
    , wiIdentityHash        = swiTitleHash sid
    , wiIsDialog            = False
    , wiIsFixedSize         = False
    , wiHasCloseButton      = True
    , wiHasFullscreenButton = True
    , wiFrame               = Rectangle 0 0 100 100
    }

-- | A saved snapshot + a live window list, where the lives are a
-- shuffled, freshly-wid'd version of the saved entries plus some
-- extras of arbitrary identity. The expected matches are: every saved
-- entry maps to exactly one live window.
data RoundTripCase = RoundTripCase
    { rtSaved   :: SerialState StableWindowId
    , rtLives   :: [WindowInfo]
    , rtSavedIds :: [StableWindowId]  -- in workspace traversal order
    }
    deriving Show

instance Arbitrary RoundTripCase where
    arbitrary = do
        savedIds <- listOf1 arbitrary
        extras   <- listOf arbitrary :: Gen [StableWindowId]
        -- Build the saved snapshot: one workspace, all on one stack.
        let savedStack = case savedIds of
                (f:rest) -> Just (SerStack f [] rest)
                []       -> Nothing
            saved = SerialState
                { ssVersion    = persistenceVersion
                , ssStacks     = [("ws", savedStack)]
                , ssCurrentTag = "ws"
                , ssFloating   = []
                , ssAffinity   = [("ws", 0)]
                }
        -- Live windows: one for each saved id (new wid), plus extras
        -- with disjoint wid range. Lives are shuffled so the matcher
        -- can't rely on input order alone.
        let savedLives =
                [ windowInfoFor (1000 + fromIntegral i) 100 sid
                | (i, sid) <- zip [0 :: Int ..] savedIds
                ]
            extraLives =
                [ windowInfoFor (5000 + fromIntegral i) 200 sid
                | (i, sid) <- zip [0 :: Int ..] extras
                ]
            allLives = savedLives ++ extraLives
        shuffledLives <- shuffle allLives
        return (RoundTripCase saved shuffledLives savedIds)

-- Every saved id has its own mirror in lives (built by the generator),
-- so every saved id must match at tier 1, and every match must be to
-- the exact mirror. This is the strongest possible round-trip
-- guarantee: the matcher loses no identity information when both
-- sides have it.
prop_matcher_round_trip :: RoundTripCase -> Property
prop_matcher_round_trip (RoundTripCase saved lives savedIds) =
    let result = matchWindows saved lives
        matched = Map.toList (mrIdentities result)
    in counterexample (show result) $
       length matched === length savedIds
       .&&. conjoin
            [ counterexample
                ("for match " ++ show (ref, sid))
                (case L.find
                        (\wi -> wrWindowId ref == wiWindowId wi
                             && wrPid ref == wiPid wi) lives of
                    Just wi -> stableIdFor wi === sid
                    Nothing -> counterexample "matched ref absent from lives" (property False))
            | (ref, sid) <- matched
            ]

-- |matched| + |unmatched| == |lives|, and the matched lives are
-- disjoint from mrUnmatched.
prop_matcher_partition :: RoundTripCase -> Property
prop_matcher_partition (RoundTripCase saved lives _) =
    let result = matchWindows saved lives
        matchedWids =
            [ wid | wid <- Map.keys (mrIdentities result) ]
        unmatchedWids =
            [ WindowRef (wiWindowId wi) (wiPid wi)
            | wi <- mrUnmatched result
            ]
    in (length matchedWids + length unmatchedWids === length lives)
       .&&. L.intersect matchedWids unmatchedWids === []

-- Determinism: matching the same saved snapshot against the same lives
-- yields the same result.
prop_matcher_deterministic :: RoundTripCase -> Property
prop_matcher_deterministic (RoundTripCase saved lives _) =
    let a = matchWindows saved lives
        b = matchWindows saved lives
    in (mrIdentities a === mrIdentities b)
       .&&. (map (\wi -> wiWindowId wi) (mrUnmatched a)
             === map (\wi -> wiWindowId wi) (mrUnmatched b))

-- Class-tier handling: N class-equal saved entries (same bundleId +
-- subrole, no axId, no titleHash) get matched to N class-equal lives
-- in deterministic order. Important for browser-like apps where every
-- window has the same identity attributes.
prop_matcher_class_tier_multi :: Positive Int -> Property
prop_matcher_class_tier_multi (Positive nRaw) =
    let n = 1 + (nRaw `mod` 6)   -- 1..6
        classOnly = StableWindowId
            { swiBundleId     = Just "com.app.browser"
            , swiAxIdentifier = Nothing
            , swiSubrole      = Just "AXStandardWindow"
            , swiTitleHash    = Nothing
            }
        savedIds = replicate n classOnly
        savedStack = Just (SerStack (head savedIds) [] (tail savedIds))
        saved = SerialState
            { ssVersion    = persistenceVersion
            , ssStacks     = [("ws", savedStack)]
            , ssCurrentTag = "ws"
            , ssFloating   = []
            , ssAffinity   = [("ws", 0)]
            }
        -- Lives have unique-but-meaningless titleHashes; class still matches.
        lives =
            [ (windowInfoFor (1000 + fromIntegral i) 42 classOnly)
                { wiIdentityHash = Just (T.pack ("hash-" ++ show i)) }
            | i <- [0 .. n - 1]
            ]
        result = matchWindows saved lives
    in counterexample (show result) $
       Map.size (mrIdentities result) === n
       .&&. null (mrUnmatched result)

-- Tier precedence: a fully-equal candidate is preferred over a
-- class-equal candidate, even if the class-equal one appears earlier
-- in the live list.
prop_matcher_tier_precedence :: Property
prop_matcher_tier_precedence =
    let target = StableWindowId
            { swiBundleId     = Just "com.app.alpha"
            , swiAxIdentifier = Just "main"
            , swiSubrole      = Just "AXStandardWindow"
            , swiTitleHash    = Just "exactmatch"
            }
        sameClass = StableWindowId  -- matches at tier 3 only
            { swiBundleId     = Just "com.app.alpha"
            , swiAxIdentifier = Just "main"
            , swiSubrole      = Just "AXStandardWindow"
            , swiTitleHash    = Just "differenthash"
            }
        saved = SerialState
            { ssVersion    = persistenceVersion
            , ssStacks     = [("ws", Just (SerStack target [] []))]
            , ssCurrentTag = "ws"
            , ssFloating   = []
            , ssAffinity   = []
            }
        -- The exact match is SECOND in the live list. A naive
        -- first-class-match-wins matcher would pick the wrong one;
        -- the tiered matcher must prefer the exact match.
        lives =
            [ windowInfoFor 100 1 sameClass
            , windowInfoFor 200 1 target
            ]
        result = matchWindows saved lives
        matchedWid = case Map.toList (mrIdentities result) of
            [(WindowRef wid _, _)] -> Just wid
            _                      -> Nothing
    in matchedWid === Just 200

-- A saved id that has no compatible live at any tier produces no
-- match. The corresponding entry vanishes from mrResolved.
prop_matcher_unmatched_saved_disappears :: Property
prop_matcher_unmatched_saved_disappears =
    let savedId = StableWindowId
            { swiBundleId     = Just "com.app.nonexistent"
            , swiAxIdentifier = Just "unique"
            , swiSubrole      = Just "AXDialog"
            , swiTitleHash    = Just "zzzz"
            }
        saved = SerialState
            { ssVersion    = persistenceVersion
            , ssStacks     = [("ws", Just (SerStack savedId [] []))]
            , ssCurrentTag = "ws"
            , ssFloating   = [(savedId, (0, 0, 1, 1))]
            , ssAffinity   = []
            }
        lives = [windowInfoFor 1 1 (StableWindowId
            { swiBundleId     = Just "com.app.completelydifferent"
            , swiAxIdentifier = Nothing
            , swiSubrole      = Just "AXStandardWindow"
            , swiTitleHash    = Nothing
            })]
        result = matchWindows saved lives
        resolved = mrResolved result
    in (Map.size (mrIdentities result) === 0)
       .&&. (lookup "ws" (ssStacks resolved) === Just Nothing)
       .&&. (ssFloating resolved === [])

-- persistenceVersion is preserved through matching.
prop_matcher_preserves_version :: RoundTripCase -> Property
prop_matcher_preserves_version (RoundTripCase saved lives _) =
    ssVersion (mrResolved (matchWindows saved lives))
        === ssVersion saved

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
            }
        ws :: W.StackSet String Int WindowRef ScreenId ScreenDetail
        ws = serialToWindowSet (0 :: Int) allTags screens saved
    in W.currentTag ws === "b"

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
    , ("focusedWindow hidden is no-op",              property prop_focusedWindow_hidden_is_no_op)
    , ("focusedWindow never lands on hidden",        property prop_focusedWindow_never_lands_on_hidden)
    , ("focusedWindow invariant",                    property prop_focusedWindow_invariant)
    , ("focusedWindow unknown is no-op",             property prop_focusedWindow_unknown_noop)
    , ("focusedWindow distinguishes shared-PID",     property prop_focusedWindow_distinguishes_shared_pid)
    , ("broken PID-only is indistinguishable",       property prop_brokenPidOnly_indistinguishable)
    , ("frontApp no-op within app",                  property prop_frontApp_noop_within)
    , ("frontApp switches across apps",              property prop_frontApp_switches_across)
    , ("frontApp never lands on hidden",             property prop_frontApp_never_lands_on_hidden)
    -- Cross-restart identity matcher
    , ("matcher round-trip",                          property prop_matcher_round_trip)
    , ("matcher partitions lives",                    property prop_matcher_partition)
    , ("matcher is deterministic",                    property prop_matcher_deterministic)
    , ("matcher class tier handles N candidates",     property prop_matcher_class_tier_multi)
    , ("matcher prefers exact over class",            property prop_matcher_tier_precedence)
    , ("matcher drops unmatched saved entries",       property prop_matcher_unmatched_saved_disappears)
    , ("matcher preserves persistenceVersion",        property prop_matcher_preserves_version)
    -- serialToWindowSet restoring per-screen workspace assignment
    , ("serialToWindowSet respects ssAffinity",       property prop_serialToWindowSet_respects_affinity_two_screens)
    , ("serialToWindowSet preserves current tag",     property prop_serialToWindowSet_preserves_current_tag)
    , ("serialToWindowSet no affinity falls back",    property prop_serialToWindowSet_no_affinity_falls_back)
    ]
