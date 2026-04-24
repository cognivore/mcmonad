-- | cognivore's mcmonad configuration.
--
-- xmonad-style with ThreeColMid as the primary layout.
-- 19 workspaces: 1-9, 0, and 10 letter-named workspaces.

import MCMonad
import MCMonad.Config.Keys
import MCMonad.Compat.XMonadContrib (XMonadWrapper(..))
import qualified XMonad.Layout.ThreeColumns as XMonad
import qualified Data.Map.Strict as Map
import Data.Bits ((.|.))

main :: IO ()
main = mcmonad defaultConfig
    { layoutHook = Layout (XW (XMonad.ThreeColMid 1 0.03 (1/3))
                       ||| Tall 1 0.03 0.5
                       ||| Full)
    , mcWorkspaces = numWs ++ extraWs
    , mcKeys = myKeys
    }

-- Workspaces: 1-9, 0, then letter workspaces
numWs :: [String]
numWs = map show [1 :: Int .. 9] ++ ["0"]

extraWs :: [String]
extraWs = ["a", "z", "x", "c", "y", "u", "i", "o", "n", "m"]

-- Extra workspace -> keycode pairs
extraWsKeys :: [(String, KeyCode)]
extraWsKeys =
    [ ("a", kA)   -- secondary project
    , ("z", kZ)   -- tertiary project
    , ("x", kX)   -- social chats
    , ("c", kC)   -- persistent shells
    , ("y", kY)   -- backup
    , ("u", kU)   -- backup
    , ("i", kI)   -- backup
    , ("o", kO)   -- logseq / notetaking
    , ("n", kN)   -- MarginNote mind map
    , ("m", kM)   -- music & media
    ]

myKeys :: MConfig Layout -> Map.Map (Modifiers, KeyCode) (M ())
myKeys conf = defaultKeys conf `Map.union` Map.fromList
    (
    -- Option+<letter> -> view workspace
    [ ((m, key), windows (greedyView ws))
    | (ws, key) <- extraWsKeys
    ]
    ++
    -- Option+Shift+<letter> -> shift window to workspace
    -- EXCEPT "c": Option+Shift+C is kill (close window)
    [ ((m .|. shiftMask, key), windows (shift ws))
    | (ws, key) <- extraWsKeys
    , ws /= "c"
    ]
    ++
    -- Option+0 -> workspace "0" (boring stuff)
    [ ((m, k0),                    windows (greedyView "0"))
    , ((m .|. shiftMask, k0),      windows (shift "0"))
    ]
    )
  where
    m = modMask conf
