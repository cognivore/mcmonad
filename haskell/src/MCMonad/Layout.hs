{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module MCMonad.Layout
    ( -- * Standard layouts
      Tall(..)
    , Full(..)
    , Mirror(..)
    , Choose(..), CL(..)
      -- * Layout combinators
    , (|||)
      -- * Tiling geometry
    , tile
    , splitVertically
    , splitHorizontally
    , splitHorizontallyBy
    , splitVerticallyBy
      -- * Geometry helpers
    , mirrorRect
    ) where

import qualified XMonad.StackSet as W

import MCMonad.Core

-- ---------------------------------------------------------------------------
-- Tall layout

-- | Master/stack layout: one master pane on the left, remaining windows
-- stacked vertically on the right.
--
-- Parameters: number of master windows, resize increment, master-to-total
-- width ratio.
data Tall a = Tall
    { tallNMaster :: !Int       -- ^ Number of windows in the master pane
    , tallDelta   :: !Double    -- ^ Fraction to increment/decrement on resize
    , tallFrac    :: !Double    -- ^ Width fraction allocated to master pane
    } deriving (Show, Read)

instance LayoutClass Tall WindowRef where
    pureLayout (Tall nmaster _ frac) rect stack =
        zip ws rs
      where
        ws = W.integrate stack
        rs = tile frac rect nmaster (length ws)

    pureMessage (Tall nm delta frac) msg =
        case fromMessage msg of
            Just Shrink         -> Just $ Tall nm delta (max 0.0 (frac - delta))
            Just Expand         -> Just $ Tall nm delta (min 1.0 (frac + delta))
            Just (IncMasterN d) -> Just $ Tall (max 0 (nm + d)) delta frac
            _                   -> Nothing

    description _ = "Tall"

-- ---------------------------------------------------------------------------
-- The tile function -- matches xmonad's tile exactly

-- | Divide a screen rectangle into @n@ tiles, with @nmaster@ windows in
-- the master column (left) and the rest in the slave column (right).
-- The master column gets fraction @frac@ of the total width.
tile :: Double          -- ^ Master width fraction
     -> Rectangle       -- ^ Screen rectangle
     -> Int             -- ^ Number of master windows
     -> Int             -- ^ Total number of windows
     -> [Rectangle]
tile frac rect nmaster n
    | n <= nmaster || nmaster == 0
        = splitVertically n rect
    | otherwise
        = splitVertically nmaster r1 ++ splitVertically (n - nmaster) r2
  where
    (r1, r2) = splitHorizontallyBy frac rect

-- ---------------------------------------------------------------------------
-- Rectangle splitting functions

-- | Split a rectangle into @n@ equal vertical slices (stacked top to bottom).
-- Matches xmonad's splitVertically: each slice gets 1/n of the height.
splitVertically :: Int -> Rectangle -> [Rectangle]
splitVertically n (Rectangle x y w h)
    | n < 1     = []
    | otherwise =
        [ Rectangle x (y + fromIntegral i * sliceH) w sliceH
        | i <- [0 .. n - 1]
        ]
  where
    sliceH = h / fromIntegral n

-- | Split a rectangle into @n@ equal horizontal slices (side by side, left
-- to right). Each slice gets 1/n of the width.
splitHorizontally :: Int -> Rectangle -> [Rectangle]
splitHorizontally n (Rectangle x y w h)
    | n < 1     = []
    | otherwise =
        [ Rectangle (x + fromIntegral i * sliceW) y sliceW h
        | i <- [0 .. n - 1]
        ]
  where
    sliceW = w / fromIntegral n

-- | Split a rectangle vertically at a given fraction, returning the top
-- and bottom sub-rectangles.
splitVerticallyBy :: Double -> Rectangle -> (Rectangle, Rectangle)
splitVerticallyBy frac (Rectangle x y w h) =
    ( Rectangle x y w topH
    , Rectangle x (y + topH) w (h - topH)
    )
  where
    topH = h * frac

-- | Split a rectangle horizontally at a given fraction, returning left and
-- right sub-rectangles.
splitHorizontallyBy :: Double -> Rectangle -> (Rectangle, Rectangle)
splitHorizontallyBy frac (Rectangle x y w h) =
    ( Rectangle x y leftW h
    , Rectangle (x + leftW) y (w - leftW) h
    )
  where
    leftW = w * frac

-- ---------------------------------------------------------------------------
-- Full layout

-- | Every window gets the full screen rectangle. Only the focused window
-- is laid out.
data Full a = Full
    deriving (Show, Read)

instance LayoutClass Full WindowRef where
    pureLayout Full rect stack = [(W.focus stack, rect)]
    description _ = "Full"

-- ---------------------------------------------------------------------------
-- Mirror layout

-- | Reflect a layout: swap width/height, x/y. Turns a horizontal Tall into
-- a vertical one.
data Mirror l a = Mirror (l a)
    deriving (Show, Read)

instance LayoutClass l WindowRef => LayoutClass (Mirror l) WindowRef where
    runLayout (W.Workspace tag (Mirror l) s) rect = do
        (arranged, ml') <- runLayout (W.Workspace tag l s) (mirrorRect rect)
        return (map (\(w, r) -> (w, mirrorRect r)) arranged, Mirror <$> ml')

    handleMessage (Mirror l) msg = fmap (fmap Mirror) (handleMessage l msg)

    description (Mirror l) = "Mirror " ++ description l

-- | Mirror a rectangle: swap x\/y and width\/height.
mirrorRect :: Rectangle -> Rectangle
mirrorRect (Rectangle x y w h) = Rectangle y x h w

-- ---------------------------------------------------------------------------
-- Choose layout

-- | Which side of a 'Choose' is currently active.
data CL = CL | CR
    deriving (Show, Read, Eq)

-- | Switch between two layouts. This is the implementation behind '(|||)'.
data Choose l r a = Choose CL (l a) (r a)
    deriving (Show, Read)

instance (LayoutClass l WindowRef, LayoutClass r WindowRef)
    => LayoutClass (Choose l r) WindowRef where

    runLayout (W.Workspace tag (Choose side l r) s) rect =
        case side of
            CL -> do
                (arranged, ml') <- runLayout (W.Workspace tag l s) rect
                return (arranged, (\l' -> Choose CL l' r) <$> ml')
            CR -> do
                (arranged, mr') <- runLayout (W.Workspace tag r s) rect
                return (arranged, (\r' -> Choose CR l r') <$> mr')

    handleMessage (Choose side l r) msg =
        case fromMessage msg of
            Just NextLayout ->
                case side of
                    CL -> return $ Just $ Choose CR l r
                    CR -> return $ Just $ Choose CL l r
            Just (SetLayout d) ->
                if d == description l
                    then return $ Just $ Choose CL l r
                    else if d == description r
                        then return $ Just $ Choose CR l r
                        else return Nothing
            _ ->
                case side of
                    CL -> fmap (fmap (\l' -> Choose CL l' r)) (handleMessage l msg)
                    CR -> fmap (fmap (\r' -> Choose CR l r')) (handleMessage r msg)

    description (Choose CL l _) = description l
    description (Choose CR _ r) = description r

-- | Combine two layouts with a toggle. Use 'NextLayout' message to switch.
infixr 5 |||
(|||) :: (LayoutClass l WindowRef, Read (l WindowRef),
          LayoutClass r WindowRef, Read (r WindowRef))
      => l WindowRef -> r WindowRef -> Choose l r WindowRef
l ||| r = Choose CL l r
