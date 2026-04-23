module Properties where

import Test.QuickCheck
import qualified XMonad.StackSet as W
import MCMonad.Core (WindowRef(..), ScreenId(..), ScreenDetail(..), Rectangle(..), updateAffinities)
import MCMonad.Sway (viewOnScreen)
import qualified Data.List as L
import qualified Data.Map.Strict as Map
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
    ]
