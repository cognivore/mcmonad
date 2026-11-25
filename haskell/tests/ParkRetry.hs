{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A hidden window that cannot be parked reports its frame every time it
-- is asked to be, as a window in native fullscreen does. This replays the
-- reports and checks that asking stops, and that the window is parked
-- again once there is a reason to.
module Main where

import Control.Monad (replicateM_, unless, void)
import Data.Aeson
import Data.Text (Text)

import MCMonad.Operations (maxParkRetries)
import Replay

main :: IO ()
main = replayMain "park retry" replay

data Effect = Hide [Int] | Cmd Text deriving (Show, Eq)

instance FromJSON Effect where
    parseJSON = withObject "command" $ \o -> o .: "cmd" >>= \case
        "hide-windows" -> Hide <$> o .: "windowIds"
        cmd -> pure (Cmd cmd)

replay :: Brain -> IO ()
replay brain = do
    void $ startEmpty brain
    let pass = void (through brain (== Cmd "set-overlay-state"))
        -- The windows parked so far, as soon as the brain has read every
        -- event sent before this.
        parked = do
            event brain "menu-toggle-debug" []
            effects <- through brain (== Cmd "set-debug-overlays")
            pure [ ids | Hide ids <- effects ]
        reportOnScreen = event brain "window-frame-changed" ["windowId" .= (41 :: Int), "frame" .= screenFrame]
        expect what wanted = do
            hides <- parked
            unless (hides == wanted) $
                fail (what ++ ": expected " ++ show wanted ++ ", the daemon was asked to hide " ++ show hides)
        create :: Int -> Int -> IO ()
        create w p = event brain "window-created" ["windowId" .= w, "pid" .= p, "frame" .= screenFrame] >> pass
        view tag = event brain "menu-view-workspace" ["tag" .= (tag :: Text)] >> pass
    create 41 401
    view "r1"
    create 42 402
    replicateM_ 100 reportOnScreen
    expect "A hidden window reporting itself on screen" (replicate maxParkRetries [41])
    event brain "menu-view-workspace" ["tag" .= ("2" :: Text)]
    hides <- parked
    unless (any (41 `elem`) hides) $
        fail ("Switching workspace should park it again. The daemon was asked to hide " ++ show hides)
    -- The same screens reported again is what an active Space change is.
    event brain "screens-changed" ["screens" .= [screenInfo]]
    again <- parked
    unless (any (\ids -> all (`elem` ids) [41, 42]) again) $
        fail ("A screens report should park every hidden window. The daemon was asked to hide " ++ show again)
    putStrLn "Park retry replay passed: a window that will not park is left until something changes."
