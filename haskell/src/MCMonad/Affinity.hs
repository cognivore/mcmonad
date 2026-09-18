-- | Workspace → screen affinity: the pure half.
--
-- Screens have /roles/ — 'Primary', 'Secondary', 'Tertiary' and three
-- auxiliary ones — assigned by mcmonad-core from how the displays are
-- attached (main display, right of it, left of it, …) or by the user in
-- the launcher. Nothing here knows left from right: a rule names a role.
--
-- A workspace /belongs/ to a role. Viewing it shows it on that role's
-- screen and moves focus there (Sway, not xmonad: the workspace is never
-- pulled to the screen the user happens to be on). When the role's screen
-- is not attached the workspace lives on 'Primary' until it is. Workspaces
-- no rule names belong to 'Primary'. 'MCMonad.Config.xmonadClassic' keeps
-- xmonad's greedy behaviour instead.
--
-- The types live in "MCMonad.Core" (the state carries them); the actions
-- ('MCMonad.Operations.viewWorkspace') in "MCMonad.Operations". Everything
-- here is pure, so QuickCheck drives it.
module MCMonad.Affinity
    ( -- * Roles and rules (re-exported from "MCMonad.Core")
      ScreenRole(..)
    , roleName, parseRole
    , AffinityRule(..)
    , ViewMode(..)
      -- * Resolution
    , resolveAffinity
    , splitChunks
    , screenForRole
      -- * StackSet operations
    , viewOn
    , placeForRoles
    ) where

import Data.List (findIndex)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe, maybeToList)
import qualified Data.Set as Set
import qualified XMonad.StackSet as W

import MCMonad.Core

-- ---------------------------------------------------------------------------
-- Resolution

-- | The role a workspace belongs to right now, given which roles are
-- attached. The first rule naming the workspace decides; none means
-- 'Primary'.
--
-- 'Pin': the role while attached, 'Primary' otherwise. 'SplitAcross': the
-- workspaces are cut into as many contiguous chunks as there are roles
-- and dealt out in order; with only some roles attached the /last/ chunks
-- take the attached roles (in order) and the earlier chunks return to
-- 'Primary'. So @SplitAcross [Tertiary, Secondary] ["7","8","9","0"]@ sends 7 8
-- to Tertiary and 9 0 to Secondary with both attached, 9 0 to whichever
-- one is attached and 7 8 to Primary with one, everything to Primary
-- with none.
resolveAffinity :: [AffinityRule] -> Set.Set ScreenRole -> String -> ScreenRole
resolveAffinity rules present tag =
    fromMaybe Primary (listToMaybe (mapMaybe match rules))
  where
    match (Pin role tags)
        | tag `elem` tags = Just (if role `Set.member` present then role else Primary)
    match (SplitAcross roles tags)
        | tag `elem` tags =
            let chunks   = splitChunks (length roles) tags
                attached = filter (`Set.member` present) roles
                targets  = replicate (length chunks - length attached) Primary ++ attached
            in (targets !!) <$> findIndex (tag `elem`) chunks
    match _ = Nothing

-- | Cut a list into @n@ contiguous chunks, as even as possible, the
-- earlier chunks taking any remainder. @n <= 1@ is one chunk.
splitChunks :: Int -> [a] -> [[a]]
splitChunks n xs
    | n <= 1    = [xs]
    | otherwise = go n xs
  where
    go k ys
        | k <= 1    = [ys]
        | otherwise =
            let size = (length ys + k - 1) `div` k
                (chunk, rest) = splitAt size ys
            in chunk : go (k - 1) rest

-- | The screen currently carrying a role, if any.
screenForRole :: Map.Map ScreenId ScreenRole -> ScreenRole -> Maybe ScreenId
screenForRole roles role =
    listToMaybe [ sid | (sid, r) <- Map.toList roles, r == role ]

-- ---------------------------------------------------------------------------
-- StackSet operations

-- | Show @tag@ on screen @sid@ and focus that screen, the Sway way. A
-- hidden workspace replaces whatever the screen showed (that becomes
-- hidden); a workspace already on the screen is just focused; one visible
-- on another screen is moved here, the displaced workspace taking the
-- screen it left. A screen that does not exist means a plain 'W.view'.
viewOn :: (Eq i, Eq sid) => sid -> i -> W.StackSet i l a sid sd -> W.StackSet i l a sid sd
viewOn sid tag ws = case W.lookupWorkspace sid ws of
    Nothing -> W.view tag ws
    Just there
        | there == tag -> W.view tag ws
        | otherwise    -> W.greedyView tag (W.view there ws)

-- | Give every non-'Primary' screen a workspace that belongs to its role,
-- unless it already shows one: the workspace last shown on that role if
-- it is hidden, else the first hidden workspace (in @order@) the rules
-- send there. The screen the user is on is never touched, and focus stays
-- where it was. Run after screens come or go, and at startup.
placeForRoles
    :: [AffinityRule]
    -> Map.Map ScreenId ScreenRole      -- ^ role of every attached screen
    -> Map.Map ScreenRole String        -- ^ workspace last shown per role
    -> [String]                         -- ^ workspace tags in config order
    -> W.StackSet String l a ScreenId sd
    -> W.StackSet String l a ScreenId sd
placeForRoles rules roles lastOn order ws0 =
    W.view currentTag (foldl' place ws0 targets)
  where
    present    = Set.fromList (Map.elems roles)
    resolved   = resolveAffinity rules present
    currentSid = W.screen (W.current ws0)
    currentTag = W.tag (W.workspace (W.current ws0))
    targets    = [ (sid, role) | (sid, role) <- Map.toList roles
                 , role /= Primary, sid /= currentSid ]

    place ws (sid, role) = case W.lookupWorkspace sid ws of
        Nothing -> ws
        Just showing
            | resolved showing == role -> ws
            | otherwise -> maybe ws (\tag -> viewOn sid tag ws) (candidate ws role)

    candidate ws role =
        let hiddenTags = map W.tag (W.hidden ws)
        in listToMaybe [ t | t <- maybeToList (Map.lookup role lastOn) ++ order
                           , t `elem` hiddenTags, resolved t == role ]
