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
    = SetSplitH       -- ^ Set next split direction to horizontal
    | SetSplitV       -- ^ Set next split direction to vertical
    | ToggleTabbed    -- ^ Toggle current container between tabbed and split
    | FocusParent     -- ^ Move structural focus up the tree
    | FocusChild      -- ^ Move structural focus down the tree
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
    } deriving (Show, Read)

-- ---------------------------------------------------------------------------
-- LayoutClass instance

instance LayoutClass I3Layout WindowRef where

    doLayout layout rect stack = do
        let (reconciledTree, _) = reconcile (tree layout) (nextSplit layout) stack
            focused = W.focus stack
            rects = renderTree focused reconciledTree rect
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
-- Resize

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
                -- Find a window in the tree to use as insertion target
                let focused = W.focus stack
                    target = if containsWindow focused t1
                             then focused
                             else case treeWindows t1 of
                                     (tw:_) -> tw
                                     []     -> focused  -- shouldn't happen
                    t2 = foldl (\tr w -> insertAt w target splitDir tr) t1 new
                in (t2, True)

-- ---------------------------------------------------------------------------
-- Rendering

-- | Render the tree into (window, rectangle) pairs. For tabbed containers,
-- the child containing the focused window is emitted last (drawn on top).
renderTree :: Eq a => a -> ITree a -> Rectangle -> [(a, Rectangle)]
renderTree _ (Leaf w) rect = [(w, rect)]
renderTree focused (Container (Split dir) weights children) rect =
    let rects = splitProportionally dir weights rect
    in concat [renderTree focused child r | (child, r) <- zip children rects]
renderTree focused (Container Tabbed _weights children) rect =
    -- All children get the full rect; focused child comes last (on top)
    let outputs = map (\child -> renderTree focused child rect) children
        focusIdx = case findIndex (containsWindow focused) children of
            Just i  -> i
            Nothing -> 0
        n = length outputs
        reordered = [outputs !! i | i <- [0..n-1], i /= focusIdx]
                    ++ [outputs !! focusIdx]
    in concat reordered

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
