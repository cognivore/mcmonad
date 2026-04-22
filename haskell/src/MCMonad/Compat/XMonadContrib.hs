{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | Compatibility bridge for xmonad-contrib layouts.
--
-- Most xmonad-contrib layouts only implement 'pureLayout' and 'pureMessage',
-- which are pure functions. This module wraps them for use with mcmonad by
-- converting between xmonad's X11 'Rectangle' (integral) and mcmonad's
-- 'Rectangle' (Double).
--
-- Usage:
--
-- > import qualified XMonad.Layout.ThreeColumns as XMonad
-- > import MCMonad.Compat.XMonadContrib (fromXMonad)
-- >
-- > main = mcmonad defaultConfig
-- >     { layoutHook = fromXMonad (XMonad.ThreeColMid 1 0.03 0.5)
-- >                ||| Layout Full
-- >     }
module MCMonad.Compat.XMonadContrib
    ( fromXMonad
    , XMonadWrapper(..)
    ) where

import Data.Typeable (Typeable)
import qualified Graphics.X11.Xlib as X11
import qualified XMonad.Core as XMonad
import qualified XMonad.StackSet as W

import MCMonad.Core
    ( LayoutClass(..), Layout(..)
    , Rectangle(..)
    )

-- | Wrap an xmonad-contrib layout for use in mcmonad.
fromXMonad :: (XMonad.LayoutClass l a, Read (l a), Show (l a), Typeable l, Typeable a)
           => l a -> Layout a
fromXMonad = Layout . XW

-- | Newtype wrapper that adapts an xmonad layout to mcmonad's LayoutClass.
newtype XMonadWrapper l a = XW (l a)
    deriving (Show, Read)

instance (XMonad.LayoutClass l a, Typeable l, Read (l a)) => LayoutClass (XMonadWrapper l) a where
    pureLayout (XW l) rect s =
        map (\(w, r) -> (w, fromX11Rect r)) $ XMonad.pureLayout l (toX11Rect rect) s

    pureMessage (XW l) msg =
        XW <$> XMonad.pureMessage l msg
        -- Works directly because mcmonad's SomeMessage IS xmonad's SomeMessage

    description (XW l) = XMonad.description l

-- | Convert mcmonad Rectangle (Double) to X11 Rectangle (Int/Word).
toX11Rect :: Rectangle -> X11.Rectangle
toX11Rect (Rectangle x y w h) = X11.Rectangle
    (round x) (round y) (round w) (round h)

-- | Convert X11 Rectangle to mcmonad Rectangle (Double).
fromX11Rect :: X11.Rectangle -> Rectangle
fromX11Rect (X11.Rectangle x y w h) = Rectangle
    (fromIntegral x) (fromIntegral y) (fromIntegral w) (fromIntegral h)
