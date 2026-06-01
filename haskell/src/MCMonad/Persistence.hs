{-# LANGUAGE DeriveFunctor      #-}
{-# LANGUAGE DeriveFoldable     #-}
{-# LANGUAGE DeriveTraversable  #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE OverloadedStrings  #-}

-- |
-- = Cross-restart window identity for mcmonad
--
-- macOS CGWindowIDs are issued by the WindowServer at window creation
-- and are *session-local*: quitting and reopening an app — and even
-- restarting the Swift mcmonad-core daemon — gives every window a
-- fresh id. PIDs change every app launch. Persisting workspace
-- assignments by @(wid, pid)@, as the original 'MCMonad.Operations.RestartState'
-- did, therefore only worked within a single Mod-q recompile (where
-- mcmonad-core stays alive); any reboot, daemon crash, or app
-- relaunch reduced the persistence file to a list of integers that
-- match nothing, and 'MCMonad.Main.reconcileState' would treat every
-- live window as new and clump them onto the default workspace.
--
-- This module replaces that with a stable identity:
--
-- @
-- StableWindowId =
--   ( bundleId        -- "io.gitlab.librewolf-community"
--   , axIdentifier    -- kAXIdentifierAttribute, when an app sets one
--   , subrole         -- "AXStandardWindow", "AXDialog", ...
--   , titleHash       -- salted SHA-256 of title, persistent salt
--   )
-- @
--
-- == Three-tier matcher
--
-- 'matchWindows' assigns saved 'StableWindowId's to live 'WindowInfo's
-- in three passes of decreasing precision:
--
-- 1. **Full identity** — every field matches. The strongest signal.
--    Catches "I closed and reopened Library X.app and it landed on
--    workspace 4 again".
-- 2. **Identity minus title** — same bundleId / axIdentifier /
--    subrole, but the title changed since we saved. Catches the
--    common case of a browser window whose page title is now
--    different but is otherwise "the same window".
-- 3. **Class with positional fallback** — same bundleId and subrole;
--    among multiple candidates, assign in deterministic document
--    order. This is the only thing we can do for genuinely
--    interchangeable windows (e.g. two unnamed Librewolf windows).
--    The assignment is stable across restarts of the same set of
--    windows.
--
-- Each tier consumes the previous tier's leftovers. Live windows
-- that never match are returned to the caller for normal manage-hook
-- placement.
--
-- == Privacy
--
-- Window titles often carry sensitive content (URLs, document
-- names, chat partners, customer identifiers). The persistence file
-- never contains the raw title — only @titleHash@, a salted SHA-256
-- computed Swift-side using a 32-byte salt stored at
-- @~\/.config\/mcmonad\/.identity-salt@ (mode 0600). The salt never
-- leaves the disk, never enters logs, and never crosses the IPC
-- boundary; mcmonad-core just sends the resulting hex hash in
-- 'WindowInfo'. See @core\/Sources\/MCMonadCore\/IdentityHash.swift@.
--
-- Other fields (bundleId, subrole, axIdentifier) are not hashed —
-- they are app-author-controlled opaque strings with low individual
-- entropy and high cross-user overlap, so hashing them adds no
-- meaningful privacy. They are also exactly what an app rule in
-- @mcmonad.hs@ would already match on, so the persistence file
-- contains nothing the user's config doesn't already commit to disk
-- in cleartext.
module MCMonad.Persistence
    ( -- * Stable window identity (re-exported from "MCMonad.Core")
      StableWindowId(..)
    , stableIdFor
    , identitySpecificity
      -- * Persistence format
    , SerialState(..)
    , SerStack(..)
    , persistenceVersion
    , windowSetToSerial
    , serialToWindowSet
      -- * Matching saved state to live windows
    , MatchResult(..)
    , matchWindows
    ) where

import Data.List (foldl')
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified XMonad.StackSet as W

import MCMonad.Core
    ( WindowRef(..), ScreenId(..), ScreenDetail(..), WindowSet
    , StableWindowId(..)
    )
import MCMonad.IPC (WindowInfo(..))

-- ---------------------------------------------------------------------------
-- StableWindowId derivation
--
-- The 'StableWindowId' type itself lives in "MCMonad.Core" so that
-- 'MCMonad.Core.MState' can carry a @Map WindowRef StableWindowId@
-- without a cyclic import on this module.

-- | Derive a 'StableWindowId' from the 'WindowInfo' Swift just sent.
stableIdFor :: WindowInfo -> StableWindowId
stableIdFor wi = StableWindowId
    { swiBundleId     = wiBundleId wi
    , swiAxIdentifier = wiAxIdentifier wi
    , swiSubrole      = wiSubrole wi
    , swiTitleHash    = wiIdentityHash wi
    }

-- | Rough "how distinctive is this identity" score (0–4) used only for
-- diagnostics. Each populated field contributes one point.
identitySpecificity :: StableWindowId -> Int
identitySpecificity (StableWindowId b a s t) =
    length [() | Just _ <- [b], _ <- [()]]
  + length [() | Just _ <- [a], _ <- [()]]
  + length [() | Just _ <- [s], _ <- [()]]
  + length [() | Just _ <- [t], _ <- [()]]

-- ---------------------------------------------------------------------------
-- Persistence format
--
-- The on-disk shape is the same StackSet structure mcmonad already
-- has, but parameterised over the window type. Going to disk it
-- carries 'StableWindowId's; after matching it carries 'WindowRef's
-- and 'serialToWindowSet' turns it into the real 'WindowSet'.

-- | Persistence format version. Bumped whenever the on-disk schema
-- changes in any way that older parsers can't tolerate. mcmonad reads
-- the @ssVersion@ field on load; any mismatch (or a parse failure)
-- causes a clean fresh start, with the stale file removed so the next
-- save isn't shadowed.
persistenceVersion :: Int
persistenceVersion = 1

-- | A workspace stack zipper, generalised over the window type.
-- 'ssUp' is reverse-ordered relative to display order, matching
-- @XMonad.StackSet.Stack@'s convention so the zero-cost focus
-- operations carry over.
data SerStack a = SerStack
    { ssFocus :: !a
    , ssUp    :: ![a]
    , ssDown  :: ![a]
    } deriving (Eq, Show, Read, Functor, Foldable, Traversable)

-- | A serialisable snapshot of the WindowSet, parameterised over the
-- window type. The on-disk file is @SerialState StableWindowId@; the
-- in-memory form during 'matchWindows' is @SerialState WindowRef@.
data SerialState a = SerialState
    { ssVersion    :: !Int
      -- ^ 'persistenceVersion' at the time this snapshot was written.
    , ssStacks     :: ![(String, Maybe (SerStack a))]
      -- ^ Per-workspace zipper, keyed by workspace tag.
    , ssCurrentTag :: !String
      -- ^ Tag of the workspace that held focus.
    , ssFloating   :: ![(a, (Rational, Rational, Rational, Rational))]
      -- ^ Floating window positions as (x, y, w, h) rationals.
    , ssAffinity   :: ![(String, Int)]
      -- ^ Serialised workspace -> screen-id affinity map.
    } deriving (Eq, Show, Read)
-- Functor/Foldable/Traversable instances are deliberately omitted:
-- stock deriving would fail because `a` appears in the first slot of
-- the @ssFloating@ tuple, which 'Functor' on tuples doesn't cover.
-- The single point of substitution lives in 'resolveSerial', so we
-- don't need a generic 'fmap'.

-- | Build a 'SerialState' parameterised over 'StableWindowId' from the
-- live 'WindowSet' plus a map of currently-known stable identities.
--
-- Windows that have no entry in @idMap@ (which should never happen if
-- the bookkeeping in 'MCMonad.Operations.manage' is correct) are
-- silently dropped from the snapshot rather than written with a
-- placeholder — better to lose them across the restart than to
-- corrupt the file with sentinel values.
windowSetToSerial
    :: WindowSet
    -> Map.Map String ScreenId
    -> Map.Map WindowRef StableWindowId
    -> SerialState StableWindowId
windowSetToSerial ws aff idMap = SerialState
    { ssVersion    = persistenceVersion
    , ssStacks     = map serWsp allWsps
    , ssCurrentTag = W.tag (W.workspace (W.current ws))
    , ssFloating   =
        [ (sid, (rx, ry, rw, rh))
        | (w, W.RationalRect rx ry rw rh) <- Map.toList (W.floating ws)
        , Just sid <- [Map.lookup w idMap]
        ]
    , ssAffinity   = [(tag, n) | (tag, S n) <- Map.toList aff]
    }
  where
    allWsps = map W.workspace (W.current ws : W.visible ws) ++ W.hidden ws
    serWsp wsp = (W.tag wsp, fmap serStack (W.stack wsp))
    serStack (W.Stack f u d) =
        let resolve = mapMaybe (`Map.lookup` idMap)
        in SerStack
            { ssFocus = case Map.lookup f idMap of
                Just sid -> sid
                -- Focus has no identity. Pick one we can resolve; if
                -- nothing in the stack has an identity (impossible in
                -- practice), the caller will drop this workspace.
                Nothing -> case resolve (u ++ d) of
                    (sid:_) -> sid
                    []      -> StableWindowId Nothing Nothing Nothing Nothing
            , ssUp   = resolve u
            , ssDown = resolve d
            }

-- | Inverse of 'windowSetToSerial': rebuild a 'WindowSet' from a
-- 'SerialState' that has already been resolved to live 'WindowRef's,
-- the current screen configuration, and the config's layout.
serialToWindowSet
    :: l                                   -- ^ from @config.layoutHook@ — opaque to the rebuilder
    -> [String]                            -- ^ all workspace tags from config
    -> [(ScreenId, ScreenDetail)]          -- ^ live screen geometry
    -> SerialState WindowRef
    -> W.StackSet String l WindowRef ScreenId ScreenDetail
serialToWindowSet layout allTags screens saved =
    W.StackSet
        { W.current  = currentSc
        , W.visible  = visibleScs
        , W.hidden   = hiddenWSs
        , W.floating = Map.fromList
            [ (w, W.RationalRect rx ry rw rh)
            | (w, (rx, ry, rw, rh)) <- ssFloating saved
            ]
        }
  where
    savedMap = Map.fromList (ssStacks saved)
    mkWorkspace tag = W.Workspace tag layout $ case Map.lookup tag savedMap of
        Just (Just s) -> Just (W.Stack (ssFocus s) (ssUp s) (ssDown s))
        _             -> Nothing

    -- Pre-built affinity lookup: ScreenId index → tag at save time.
    -- Drop entries whose tag is no longer in the config (renamed,
    -- removed) so we don't try to assign a tag that 'mkWorkspace'
    -- couldn't sensibly produce.
    affByScreen :: Map.Map Int String
    affByScreen = Map.fromList
        [ (sid, tag)
        | (tag, sid) <- ssAffinity saved
        , tag `elem` allTags
        ]
    affTags = Map.elems affByScreen

    -- Tags that affinity didn't claim, with 'ssCurrentTag' moved to the
    -- front when it's still unclaimed. The reorder preserves the
    -- pre-fix behaviour for files with empty affinity (older format,
    -- fresh restore) — 'ssCurrentTag' lands on the first unassigned
    -- screen — while still respecting affinity when it's there.
    poolInit =
        let unused = filter (`notElem` affTags) allTags
            cur    = ssCurrentTag saved
        in if cur `elem` unused
            then cur : filter (/= cur) unused
            else unused

    -- For each present screen, in ScreenId order, pick the tag that
    -- had affinity for that index at save time. Fall back to the next
    -- tag from 'poolInit' if no affinity entry exists (e.g. screen
    -- added since save, or the saved file pre-dates the affinity
    -- field).
    --
    -- Without this, the previous version unconditionally put
    -- 'ssCurrentTag' on screen 0 and remaining workspaces on
    -- screens 1+ in config order. On a two-monitor setup that
    -- swapped which workspace each monitor held whenever
    -- 'ssCurrentTag' had been on screen 1 at save time, and
    -- Mod-w/Mod-e (focus screen 0 / 1) landed on the wrong workspace.
    (assignments, leftover) = foldl' assignOne ([], poolInit) screens
      where
        assignOne (acc, pool) (sid@(S i), sd) =
            case Map.lookup i affByScreen of
                Just tag -> (acc ++ [(sid, sd, tag)], pool)
                Nothing  -> case pool of
                    (t:rest') -> (acc ++ [(sid, sd, t)], rest')
                    []        -> error
                        "MCMonad.Persistence.serialToWindowSet: \
                        \fewer config workspaces than screens"

    -- The current screen is the one whose chosen tag matches the
    -- saved 'ssCurrentTag'. If 'ssCurrentTag' doesn't appear in any
    -- assignment (renamed-away workspace, or screen count decreased),
    -- fall back to the first assignment.
    mkScreen (sid, sd, tag) = W.Screen (mkWorkspace tag) sid sd
    (currentSc, visibleScs) =
        case break (\(_, _, t) -> t == ssCurrentTag saved) assignments of
            (before, curr:after) ->
                (mkScreen curr, map mkScreen (before ++ after))
            (_, []) -> case assignments of
                (a:rest') -> (mkScreen a, map mkScreen rest')
                []        -> error
                    "MCMonad.Persistence.serialToWindowSet: no screens"

    hiddenWSs = map mkWorkspace leftover

-- ---------------------------------------------------------------------------
-- Matcher

-- | Result of matching a saved snapshot against the live window list.
data MatchResult = MatchResult
    { mrResolved :: !(SerialState WindowRef)
      -- ^ The saved state with every resolved 'StableWindowId'
      -- replaced by the matching live 'WindowRef'. Unresolved entries
      -- are dropped from stacks and floating positions.
    , mrIdentities :: !(Map.Map WindowRef StableWindowId)
      -- ^ The identity each matched live window was matched against.
      -- The caller stores this in 'MState.windowIdentities' so the
      -- next 'windowSetToSerial' write is round-trippable.
    , mrUnmatched :: ![WindowInfo]
      -- ^ Live windows not matched to any saved entry. These should
      -- be processed via the normal manage hook.
    } deriving (Show)

-- | Match a saved 'SerialState' against the live windows the Swift
-- core just enumerated.
--
-- Three-tier greedy bipartite matching:
--
-- (1) Full identity, (2) identity ignoring titleHash, (3) class
-- equality (bundleId + subrole), with axIdentifier required to match
-- iff *both* sides have it. Each tier consumes a copy of the
-- still-unmatched lives; we iterate the saved ids in document order
-- (current workspace's stack, then visible screens, then hidden
-- workspaces — same as 'W.allWindows').
matchWindows :: SerialState StableWindowId -> [WindowInfo] -> MatchResult
matchWindows saved liveAll =
    let savedIds = collectSavedIds saved
        (assigns, unmatchedLives) = greedyAssign savedIds liveAll
        idMap = Map.fromList
            [ (WindowRef (wiWindowId wi) (wiPid wi), sid)
            | (sid, wi) <- assigns
            ]
        -- Map StableWindowId -> WindowRef, only for matched entries.
        toRef = Map.fromList
            [ (sid, WindowRef (wiWindowId wi) (wiPid wi))
            | (sid, wi) <- assigns
            ]
        resolved = resolveSerial toRef saved
    in MatchResult
        { mrResolved   = resolved
        , mrIdentities = idMap
        , mrUnmatched  = unmatchedLives
        }

-- | Flatten a saved 'SerialState' into the ordered list of stable ids
-- it contains. Order is current workspace -> visible -> hidden, with
-- each workspace contributing @up ++ [focus] ++ down@.
collectSavedIds :: SerialState StableWindowId -> [StableWindowId]
collectSavedIds st = concatMap stackIds (ssStacks st)
  where
    stackIds (_, Nothing) = []
    stackIds (_, Just s)  = reverse (ssUp s) ++ [ssFocus s] ++ ssDown s

-- | Greedy three-tier assignment of saved ids to live windows.
--
-- The matcher runs three passes in order of decreasing specificity:
-- first across all saved ids it tries to find a tier-1 match (full
-- equality); then across the remaining unmatched saved ids a tier-2
-- match (identity minus title); then a tier-3 class-only match. Each
-- pass consumes the lives it claims.
--
-- This ordering matters. A *per-id* fallback (try tier 1 then tier 2
-- then tier 3 for saved id A, then for saved id B, ...) would let an
-- earlier saved id's tier-3 match steal a live that a later saved id
-- could have matched at tier 1. The per-tier ordering guarantees that
-- the strongest available match always wins.
greedyAssign
    :: [StableWindowId]
    -> [WindowInfo]
    -> ([(StableWindowId, WindowInfo)], [WindowInfo])
greedyAssign savedIds0 lives0 =
    let (m1, savedLeft1, livesLeft1) = passTier tierFull         savedIds0   lives0
        (m2, savedLeft2, livesLeft2) = passTier tierWithoutTitle savedLeft1  livesLeft1
        (m3, _,           livesLeft3) = passTier tierClass        savedLeft2  livesLeft2
    in (m1 ++ m2 ++ m3, livesLeft3)
  where
    -- One pass of tier @t@: walk the saved ids in order, taking the
    -- first @t@-matching live for each. Returns (matched pairs in
    -- saved-id order, still-unmatched saved ids in original order,
    -- still-unmatched lives in original order).
    passTier
        :: (StableWindowId -> StableWindowId -> Bool)
        -> [StableWindowId]
        -> [WindowInfo]
        -> ([(StableWindowId, WindowInfo)], [StableWindowId], [WindowInfo])
    passTier _    []         remaining = ([], [], remaining)
    passTier tier (sid:rest) remaining =
        case takeFirst (\wi -> tier sid (stableIdFor wi)) remaining of
            Just (wi, remaining') ->
                let (ms, leftSaved, finalRem) = passTier tier rest remaining'
                in ((sid, wi) : ms, leftSaved, finalRem)
            Nothing ->
                let (ms, leftSaved, finalRem) = passTier tier rest remaining
                in (ms, sid : leftSaved, finalRem)

-- | Tier 1 — every populated field must match. nil/nil counts as a
-- match.
tierFull :: StableWindowId -> StableWindowId -> Bool
tierFull a b = a == b

-- | Tier 2 — identity equality ignoring 'swiTitleHash'.
tierWithoutTitle :: StableWindowId -> StableWindowId -> Bool
tierWithoutTitle a b =
       swiBundleId a == swiBundleId b
    && swiAxIdentifier a == swiAxIdentifier b
    && swiSubrole a == swiSubrole b

-- | Tier 3 — class equality (bundleId and subrole). axIdentifier must
-- agree when both sides have one; if only one side has an axIdentifier
-- they are NOT considered class-equal, because the side with the
-- identifier is meaningfully more specific.
tierClass :: StableWindowId -> StableWindowId -> Bool
tierClass a b =
       swiBundleId a == swiBundleId b
    && swiSubrole a == swiSubrole b
    && case (swiAxIdentifier a, swiAxIdentifier b) of
         (Nothing, Nothing) -> True
         (Just x,  Just y ) -> x == y
         _                  -> False

-- | Remove the first element of a list that satisfies the predicate,
-- returning it and the rest of the list. @Nothing@ if no element
-- matches.
takeFirst :: (a -> Bool) -> [a] -> Maybe (a, [a])
takeFirst p = go []
  where
    go _   []     = Nothing
    go acc (x:xs)
        | p x       = Just (x, reverse acc ++ xs)
        | otherwise = go (x : acc) xs

-- | Apply a (StableWindowId -> WindowRef) lookup to every entry in a
-- 'SerialState'. Entries with no live counterpart are dropped from
-- stacks and floating positions. A workspace whose 'ssFocus' has no
-- counterpart is rebuilt by promoting the first resolvable up or down
-- entry; a workspace with no resolvable entries at all becomes
-- @Nothing@.
resolveSerial
    :: Map.Map StableWindowId WindowRef
    -> SerialState StableWindowId
    -> SerialState WindowRef
resolveSerial toRef saved = saved
    { ssVersion = ssVersion saved   -- preserved verbatim
    , ssStacks  = map resolveStack (ssStacks saved)
    , ssFloating =
        [ (ref, rect)
        | (sid, rect) <- ssFloating saved
        , Just ref <- [Map.lookup sid toRef]
        ]
    }
  where
    resolveStack (tag, Nothing) = (tag, Nothing)
    resolveStack (tag, Just s)  =
        let mFocus = Map.lookup (ssFocus s) toRef
            up'   = mapMaybe (`Map.lookup` toRef) (ssUp s)
            down' = mapMaybe (`Map.lookup` toRef) (ssDown s)
        in case mFocus of
            Just f  -> (tag, Just (SerStack f up' down'))
            Nothing -> case down' of
                (f:rest) -> (tag, Just (SerStack f up' rest))
                []       -> case up' of
                    (f:rest) -> (tag, Just (SerStack f rest []))
                    []       -> (tag, Nothing)
