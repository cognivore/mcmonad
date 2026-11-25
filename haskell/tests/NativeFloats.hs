{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A native float keeps the frame its application chose. This replays the
-- ways a window stops being one, and checks that the daemon is then told
-- one frame for it: the one its layout gives it.
module Main where

import Control.Monad (unless, when)
import Data.Aeson
import Data.Aeson.Types (Parser, parseMaybe)
import Data.List (nub)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)

import Replay

main :: IO ()
main = replayMain "native float" replay

type Frame = (Int, Int, Int, Int)

data Effect = SetFrames [(Int, Frame)] | Cmd Text deriving (Show, Eq)

instance FromJSON Effect where
    parseJSON = withObject "command" $ \o -> o .: "cmd" >>= \case
        "set-frames" -> SetFrames <$> (o .: "frames" >>= mapM assignment)
        cmd -> pure (Cmd cmd)
      where
        assignment = withObject "assignment" $ \a ->
            (,) <$> a .: "windowId" <*> (a .: "frame" >>= rectangle)

rectangle :: Object -> Parser Frame
rectangle f = (,,,) <$> int "x" <*> int "y" <*> int "w" <*> int "h"
  where int key = round <$> (f .: key :: Parser Double)

-- | The hotkey id the brain registered for Option+T, sink.
sinkHotkey :: [Object] -> Maybe Int
sinkHotkey commands = listToMaybe
    [ i | specs <- mapMaybe (parseMaybe (.: "hotkeys")) commands, (i, code, mods) <- mapMaybe (parseMaybe spec) specs
        , code == tKey, mods == optionKey ]
  where
    spec s = (,,) <$> s .: "id" <*> s .: "keyCode" <*> s .: "modifiers"
    tKey = 0x11 :: Int
    optionKey = 0x0800 :: Int

replay :: Brain -> IO ()
replay brain = do
    started <- startEmpty brain
    sink <- maybe (fail "The brain registered no hotkey for Option+T.") pure (sinkHotkey started)
    let frameOf (x, y, w, h) = object ["x" .= x, "y" .= y, "w" .= w, "h" .= h]
        create :: Int -> Int -> Frame -> Bool -> IO ()
        create w p f canFullscreen = event brain "window-created"
            [ "windowId" .= w, "pid" .= p, "frame" .= frameOf f
            , "hasFullscreenButton" .= canFullscreen ]
        -- Every frame sent up to the end of the next layout pass.
        pass :: String -> IO [(Int, Frame)]
        pass what = do
            sent <- concat . mapMaybe (\case SetFrames fs -> Just fs; _ -> Nothing)
                        <$> through brain (== Cmd "set-overlay-state")
            let ids = map fst sent
            when (nub ids /= ids) $
                fail (what ++ ": a window was sent two frames in one pass: " ++ show sent)
            pure sent
        expect what wanted = do
            sent <- pass what
            unless (sent == wanted) $
                fail (what ++ ": expected " ++ show wanted ++ ", the daemon was sent " ++ show sent)
        view tag = event brain "menu-view-workspace" ["tag" .= (tag :: Text)]
        whole = (0, 0, 1200, 800)

    -- A popup is placed where its application put it, and comes back there.
    let popup = (300, 200, 400, 300)
    create 21 201 popup False
    expect "Opening a popup" [(21, popup)]
    view "r1" >> expect "Leaving a popup" []
    view "1" >> expect "Returning to a popup" [(21, popup)]

    -- Sunk, it is a tile like any other.
    event brain "hotkey-pressed" ["hotkeyId" .= sink]
    expect "Sinking a popup" [(21, whole)]
    view "r1" >> expect "Leaving a sunk popup" []
    view "1" >> expect "Returning to a sunk popup" [(21, whole)]
    putStrLn "Native float replay passed: kept frame, sunk popup."
