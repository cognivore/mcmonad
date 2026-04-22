module Main where

import MCMonad
import MCMonad.Compat.XMonadContrib (XMonadWrapper(..))
import qualified XMonad.Layout.ThreeColumns as XMonad

main :: IO ()
main = mcmonad defaultConfig
    { layoutHook = Layout (XW (XMonad.ThreeColMid 1 0.03 (1/3))
                       ||| Tall 1 0.03 0.5
                       ||| Full)
    }
