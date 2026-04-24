{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | i3/Sway-style binary tree layout.
--
-- This is a native mcmonad 'LayoutClass' that implements i3/Sway's container
-- tree model directly. Each container can be split horizontally, vertically,
-- or tabbed. The tree is reconciled against the incoming 'Stack' on each
-- layout pass, so it stays in sync with xmonad's window tracking.
module MCMonad.Layout.I3Tree
    ( -- * Layout
      I3Layout(..)
      -- * Tree
    , ITree(..)
    , SplitDir(..)
    , ContainerMode(..)
      -- * Messages
    , I3Msg(..)
    ) where

import Data.List (findIndex)
import Data.Typeable (Typeable)
import qualified Data.Set as Set
import qualified XMonad.Core as XCore (Message)
import qualified XMonad.Layout as XLayout (Resize(..))
import qualified XMonad.StackSet as W

import MCMonad.Core

-- ---------------------------------------------------------------------------
-- Data types

-- | Split direction for a container.
data SplitDir = SplitH | SplitV
    deriving (Eq, Show, Read)

-- | Container layout mode.
data ContainerMode = Split SplitDir | Tabbed
    deriving (Eq, Show, Read)

-- | The tree. Each node is either a leaf (holding a window) or a container
-- with a layout mode, proportional weights, and children.
--
-- Invariant: a 'Container' always has >= 2 children. Single-child containers
-- are collapsed during 'removeWindow'.
data ITree a
    = Leaf a
    | Container ContainerMode [Double] [ITree a]
    deriving (Eq, Show, Read)

-- | Messages that 'I3Layout' responds to.
data I3Msg
    = SetSplitH            -- ^ Set next split direction to horizontal
    | SetSplitV            -- ^ Set next split direction to vertical
    | ToggleTabbed         -- ^ Toggle current container between tabbed and split
    | FocusParent          -- ^ Move structural focus up the tree
    | FocusChild           -- ^ Move structural focus down the tree
    | ResizeDir SplitDir Double
      -- ^ Directional resize: walk up from focused window to find the
      -- nearest ancestor with matching split direction, adjust weight.
      -- E.g. @ResizeDir SplitH (-0.05)@ shrinks width,
      -- @ResizeDir SplitV 0.05@ grows height.
    deriving (Show, Typeable)

instance XCore.Message I3Msg

-- | The layout state. Persists across layout passes via the
-- @Maybe (layout a)@ return from 'doLayout' and 'handleMessage'.
data I3Layout a = I3Layout
    { tree        :: !(Maybe (ITree a))
    -- ^ The container tree. 'Nothing' when workspace is empty.
    , nextSplit   :: !SplitDir
    -- ^ Direction for the next window insertion (set by 'SetSplitH'/'SetSplitV').
    -- Sway behaviour: persists until explicitly changed.
    , parentDepth :: !Int
    -- ^ How many levels above the focused window's leaf the structural focus
    -- sits. 0 = leaf's direct parent. Incremented by 'FocusParent'.
    , tabbedBarH  :: !Double
    -- ^ Height in pixels reserved for each non-focused window's titlebar
    -- in tabbed containers. macOS windows have native titlebars, so this
    -- creates a stacked-titlebar effect. Default: 28.0.
    } deriving (Show, Read)

-- ---------------------------------------------------------------------------
-- LayoutClass instance

instance LayoutClass I3Layout WindowRef where

    doLayout layout rect stack = do
        let (reconciledTree, _) = reconcile (tree layout) (nextSplit layout) stack
            focused = W.focus stack
            barH = tabbedBarH layout
            rects = renderTree focused barH reconciledTree rect
            layout' = layout { tree = Just reconciledTree }
        return (rects, Just layout')

    emptyLayout layout _ =
        return ([], if tree layout /= Nothing
                    then Just layout { tree = Nothing }
                    else Nothing)

    handleMessage layout msg
        -- Split direction
        | Just SetSplitH <- fromMessage msg =
            return $ Just layout { nextSplit = SplitH }
        | Just SetSplitV <- fromMessage msg =
            return $ Just layout { nextSplit = SplitV }
        -- Tabbed toggle: operates on the container at parentDepth
        | Just ToggleTabbed <- fromMessage msg = do
            ws <- gets windowset
            return $ case (W.peek ws, tree layout) of
                (Just focused, Just t) ->
                    case pathToWindow focused t of
                        Nothing -> Nothing
                        Just path ->
                            let depth = parentDepth layout
                                -- Path to the target container (leaf's parent,
                                -- then up 'depth' more levels)
                                targetLen = max 0 (length path - 1 - depth)
                                targetPath = take targetLen path
                                t' = modifyAtPath targetPath
                                         (toggleMode (nextSplit layout)) t
                            in Just layout { tree = Just t'
                                           , parentDepth = 0 }
                _ -> Nothing
        -- Structural focus navigation
        | Just FocusParent <- fromMessage msg =
            return $ Just layout { parentDepth = parentDepth layout + 1 }
        | Just FocusChild <- fromMessage msg =
            return $ Just layout { parentDepth = max 0 (parentDepth layout - 1) }
        -- Directional resize: find nearest ancestor with matching split direction
        | Just (ResizeDir dir delta) <- fromMessage msg = do
            ws <- gets windowset
            return $ case (W.peek ws, tree layout) of
                (Just focused, Just t) ->
                    Just layout { tree = Just (resizeDirAt focused dir delta t) }
                _ -> Nothing
        -- Resize: adjust weight of the focused child in its parent container
        | Just XLayout.Shrink <- fromMessage msg = do
            ws <- gets windowset
            return $ case (W.peek ws, tree layout) of
                (Just focused, Just t) ->
                    Just layout { tree = Just (resizeAt focused (-0.05) t) }
                _ -> Nothing
        | Just XLayout.Expand <- fromMessage msg = do
            ws <- gets windowset
            return $ case (W.peek ws, tree layout) of
                (Just focused, Just t) ->
                    Just layout { tree = Just (resizeAt focused 0.05 t) }
                _ -> Nothing
        | otherwise = return Nothing

    description _ = "I3Tree"

-- ---------------------------------------------------------------------------
-- Tree queries

-- | Collect all windows (leaves) in the tree.
treeWindows :: ITree a -> [a]
treeWindows (Leaf w) = [w]
treeWindows (Container _ _ children) = concatMap treeWindows children

-- | Check whether a window exists anywhere in the tree.
containsWindow :: Eq a => a -> ITree a -> Bool
containsWindow w (Leaf x) = w == x
containsWindow w (Container _ _ cs) = any (containsWindow w) cs

-- | Path from root to a window's leaf. Each 'Int' is a child index.
-- Returns 'Nothing' if the window is not in the tree.
pathToWindow :: Eq a => a -> ITree a -> Maybe [Int]
pathToWindow w (Leaf x)
    | w == x    = Just []
    | otherwise = Nothing
pathToWindow w (Container _ _ children) = go 0 children
  where
    go _ [] = Nothing
    go i (c:cs) = case pathToWindow w c of
        Just path -> Just (i : path)
        Nothing   -> go (i + 1) cs

-- ---------------------------------------------------------------------------
-- Tree modifications

-- | Remove a window from the tree. Returns 'Nothing' if the tree becomes
-- empty. Collapses single-child containers.
removeWindow :: Eq a => a -> ITree a -> Maybe (ITree a)
removeWindow w (Leaf x)
    | w == x    = Nothing
    | otherwise = Just (Leaf x)
removeWindow w (Container mode weights children) =
    let pairs = zip weights (map (removeWindow w) children)
        kept = [(wt, c') | (wt, mc) <- pairs, Just c' <- [mc]]
    in case kept of
        []       -> Nothing
        [(_, c)] -> Just c   -- collapse single-child container
        _        -> let (ws', cs') = unzip kept
                    in Just (Container mode ws' cs')

-- | Insert window @new@ next to @target@ using @dir@ as split direction.
-- The target leaf is replaced with a container holding both windows.
insertAt :: Eq a => a -> a -> SplitDir -> ITree a -> ITree a
insertAt new target dir (Leaf x)
    | x == target = Container (Split dir) [1.0, 1.0] [Leaf x, Leaf new]
    | otherwise   = Leaf x
insertAt new target dir (Container mode weights children) =
    Container mode weights (map (insertAt new target dir) children)

-- | Modify the tree node at a given path.
modifyAtPath :: [Int] -> (ITree a -> ITree a) -> ITree a -> ITree a
modifyAtPath [] f t = f t
modifyAtPath (i:is) f (Container mode weights children)
    | i >= 0, i < length children =
        let c' = modifyAtPath is f (children !! i)
            children' = take i children ++ [c'] ++ drop (i + 1) children
        in Container mode weights children'
    | otherwise = Container mode weights children
modifyAtPath _ _ t = t

-- | Toggle a container between tabbed and split mode.
toggleMode :: SplitDir -> ITree a -> ITree a
toggleMode _   (Container (Split _) ws cs) = Container Tabbed ws cs
toggleMode dir (Container Tabbed ws cs)    = Container (Split dir) ws cs
toggleMode _   t                           = t

-- ---------------------------------------------------------------------------
-- Tree queries (continued)

-- | Get the tree node at a given path. Returns 'Nothing' if the path
-- is invalid.
nodeAtPath :: [Int] -> ITree a -> Maybe (ITree a)
nodeAtPath [] t = Just t
nodeAtPath (i:is) (Container _ _ children)
    | i >= 0, i < length children = nodeAtPath is (children !! i)
    | otherwise = Nothing
nodeAtPath _ _ = Nothing

-- ---------------------------------------------------------------------------
-- Resize

-- | Directional resize: walk up from the focused window to find the nearest
-- ancestor container with the given split direction, then adjust the focused
-- subtree's weight in that container.
resizeDirAt :: Eq a => a -> SplitDir -> Double -> ITree a -> ITree a
resizeDirAt focused dir delta t = case pathToWindow focused t of
    Nothing   -> t
    Just path -> findAndResize (length path - 1) path
  where
    findAndResize depth _
        | depth < 0 = t  -- no matching container found, no change
    findAndResize depth path' =
        let containerPath = take depth path'
            childIdx      = path' !! depth
        in case nodeAtPath containerPath t of
            Just (Container (Split d) _ _) | d == dir ->
                modifyAtPath containerPath (adjustWeight childIdx delta) t
            _ -> findAndResize (depth - 1) path'

-- | Adjust the weight of the focused window's slot in its parent container.
resizeAt :: Eq a => a -> Double -> ITree a -> ITree a
resizeAt focused delta t = case pathToWindow focused t of
    Nothing   -> t
    Just []   -> t    -- focused is root leaf, nothing to resize
    Just path ->
        let parentPath = init path
            childIdx   = last path
        in modifyAtPath parentPath (adjustWeight childIdx delta) t

-- | Adjust the weight at a given child index within a container.
adjustWeight :: Int -> Double -> ITree a -> ITree a
adjustWeight idx delta (Container mode weights children)
    | idx >= 0, idx < length weights =
        let w = weights !! idx
            w' = max 0.1 (w + delta)
            weights' = take idx weights ++ [w'] ++ drop (idx + 1) weights
        in Container mode weights' children
    | otherwise = Container mode weights children
adjustWeight _ _ t = t

-- ---------------------------------------------------------------------------
-- Reconciliation

-- | Reconcile the stored tree with the current 'Stack'. Removes windows
-- that no longer exist, inserts new windows at the focused position.
-- Returns the reconciled tree and whether it changed.
reconcile :: Ord a => Maybe (ITree a) -> SplitDir -> W.Stack a -> (ITree a, Bool)
reconcile Nothing splitDir stack =
    -- No tree yet: create a flat container from the stack
    let ws = W.integrate stack
    in case ws of
        [w]  -> (Leaf w, True)
        ws'  -> ( Container (Split splitDir)
                            (replicate (length ws') 1.0)
                            (map Leaf ws')
                , True )
reconcile (Just t) splitDir stack =
    let stackWins = W.integrate stack
        stackSet  = Set.fromList stackWins
        treeWins  = treeWindows t
        treeSet   = Set.fromList treeWins
        dead      = filter (`Set.notMember` stackSet) treeWins
        new       = filter (`Set.notMember` treeSet) stackWins
        -- Remove dead windows
        mt1 = foldl (\mt w -> mt >>= removeWindow w) (Just t) dead
    in case mt1 of
        Nothing ->
            -- Tree fully collapsed: rebuild from stack
            reconcile Nothing splitDir stack
        Just t1
            | null new  -> (t1, not (null dead))
            | otherwise ->
                -- Find a window in the tree to use as insertion target.
                -- W.insertUp makes the NEW window the focus, so W.focus stack
                -- is the new window (not in the tree). The PREVIOUSLY focused
                -- window (where the user was when they spawned) is the first
                -- element of W.down, or failing that, W.up.
                let focused = W.focus stack
                    oldFocus = case W.down stack of
                        (w:_) -> w
                        []    -> case W.up stack of
                            (w:_) -> w
                            []    -> focused
                    target
                        | containsWindow focused t1  = focused
                        | containsWindow oldFocus t1 = oldFocus
                        | otherwise = case treeWindows t1 of
                            (tw:_) -> tw
                            []     -> focused
                    t2 = foldl (\tr w -> insertAt w target splitDir tr) t1 new
                in (t2, True)

-- ---------------------------------------------------------------------------
-- Rendering

-- | Render the tree into (window, rectangle) pairs.
--
-- For tabbed containers, non-focused children show only their titlebar
-- (a strip of @barH@ pixels). The focused child fills the remaining space.
-- This creates a stacked-titlebar effect using macOS native titlebars.
renderTree :: Eq a => a -> Double -> ITree a -> Rectangle -> [(a, Rectangle)]
renderTree _ _ (Leaf w) rect = [(w, rect)]
renderTree focused barH (Container (Split dir) weights children) rect =
    let rects = splitProportionally dir weights rect
    in concat [renderTree focused barH child r | (child, r) <- zip children rects]
renderTree focused barH (Container Tabbed _weights children) rect
    | barH <= 0 =
        -- No titlebar offset: just stack all, focused on top (fallback)
        let outputs = map (\child -> renderTree focused barH child rect) children
            focusIdx = case findIndex (containsWindow focused) children of
                Just i  -> i
                Nothing -> 0
            n = length outputs
            reordered = [outputs !! i | i <- [0..n-1], i /= focusIdx]
                        ++ [outputs !! focusIdx]
        in concat reordered
    | otherwise =
        -- Titlebar stacking: non-focused children show barH-height strips
        -- at the top, focused child fills the remaining space below.
        let focusIdx = case findIndex (containsWindow focused) children of
                Just i  -> i
                Nothing -> 0
            nonFocused = [(i, c) | (i, c) <- zip [0..] children, i /= focusIdx]
            nBar = length nonFocused
            headerH = barH * fromIntegral nBar
            -- Non-focused: all windows in subtree get the titlebar strip
            -- (they overlap, but only one titlebar is visible per strip)
            barResults =
                [ (w, rect { rect_y = rect_y rect + barH * fromIntegral j
                           , rect_h = barH })
                | (j, (_, c)) <- zip [0..] nonFocused
                , w <- treeWindows c
                ]
            -- Focused child fills the rest
            focusRect = rect { rect_y = rect_y rect + headerH
                             , rect_h = max barH (rect_h rect - headerH) }
            focusResults = renderTree focused barH (children !! focusIdx) focusRect
        in barResults ++ focusResults

-- | Divide a rectangle proportionally among children.
splitProportionally :: SplitDir -> [Double] -> Rectangle -> [Rectangle]
splitProportionally SplitH weights (Rectangle x y w h) =
    let total   = sum weights
        sizes   = map (\wt -> w * wt / total) weights
        offsets = scanl (+) 0 sizes
    in [ Rectangle (x + off) y sz h | (off, sz) <- zip offsets sizes ]
splitProportionally SplitV weights (Rectangle x y w h) =
    let total   = sum weights
        sizes   = map (\wt -> h * wt / total) weights
        offsets = scanl (+) 0 sizes
    in [ Rectangle x (y + off) w sz | (off, sz) <- zip offsets sizes ]
