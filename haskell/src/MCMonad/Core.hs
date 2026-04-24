{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

module MCMonad.Core
    ( -- * The M monad
      M(..), MState(..), MConf(..)
    , runM, catchM, userCode, userCodeDef
    , io, withConnection, withWindowSet
      -- * Re-exports for convenience
    , gets, modify, asks, MonadIO(..)
      -- * Window and screen types
    , WindowRef(..), ScreenId(..), ScreenDetail(..)
    , WindowSet, WindowSpace
      -- * Layout system
    , Layout(..)
    , LayoutClass(..)
    , SomeMessage, Message, fromMessage, someMessage
      -- * Layout messages (re-exported from xmonad)
    , Resize(..), IncMasterN(..)
    , ChangeLayout(..)
      -- * Geometry
    , Rectangle(..)
      -- * IPC connection (opaque)
    , Connection(..)
      -- * Affinity
    , updateAffinities
    ) where

import Control.Concurrent.MVar
import Control.Exception (SomeException, catch)
import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.Aeson (FromJSON(..), ToJSON(..), (.=), (.:))
import qualified Data.Aeson as Aeson
import Data.Int (Int32)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import Data.Typeable (Typeable, cast)
import Data.Word (Word32)
import GHC.Generics (Generic)
import System.IO (Handle)
import qualified XMonad.Core as XMonad
import qualified XMonad.Layout as XMonad (Resize(..), IncMasterN(..), ChangeLayout(..))
import qualified XMonad.StackSet as W

-- ---------------------------------------------------------------------------
-- Window identifier for macOS

-- | A reference to a macOS window, identified by its CGWindowID and owning PID.
data WindowRef = WindowRef
    { wrWindowId :: !Word32
    , wrPid      :: !Int32
    } deriving (Eq, Ord, Show, Read, Generic)

instance FromJSON WindowRef where
    parseJSON = Aeson.withObject "WindowRef" $ \v ->
        WindowRef <$> v .: "windowId" <*> v .: "pid"

instance ToJSON WindowRef where
    toJSON (WindowRef wid pid) =
        Aeson.object ["windowId" .= wid, "pid" .= pid]

-- Hashable-like hashing for use as Map keys. WindowRef already derives Ord,
-- which is sufficient for Map/Set usage.

-- ---------------------------------------------------------------------------
-- Screen types

-- | Screen identifier.
newtype ScreenId = S Int
    deriving (Eq, Ord, Show, Read, Enum, Num, Integral, Real)

-- | Physical screen geometry.
data ScreenDetail = SD { screenRect :: !Rectangle }
    deriving (Eq, Show, Read)

-- ---------------------------------------------------------------------------
-- Geometry

-- | A rectangle in macOS screen coordinates (origin top-left, doubles).
data Rectangle = Rectangle
    { rect_x :: !Double
    , rect_y :: !Double
    , rect_w :: !Double
    , rect_h :: !Double
    } deriving (Eq, Show, Read, Generic)

instance FromJSON Rectangle where
    parseJSON = Aeson.withObject "Rectangle" $ \v ->
        Rectangle <$> v .: "x" <*> v .: "y" <*> v .: "w" <*> v .: "h"

instance ToJSON Rectangle where
    toJSON (Rectangle x y w h) =
        Aeson.object ["x" .= x, "y" .= y, "w" .= w, "h" .= h]

-- ---------------------------------------------------------------------------
-- Message system

-- | Message system: reuse xmonad's directly so xmonad-contrib layouts work.
type Message = XMonad.Message
type SomeMessage = XMonad.SomeMessage
type Resize = XMonad.Resize
type IncMasterN = XMonad.IncMasterN
type ChangeLayout = XMonad.ChangeLayout

fromMessage :: XMonad.Message a => SomeMessage -> Maybe a
fromMessage = XMonad.fromMessage

someMessage :: XMonad.Message a => a -> SomeMessage
someMessage = XMonad.SomeMessage

-- ---------------------------------------------------------------------------
-- Layout system

-- | The layout typeclass. Mirrors xmonad's LayoutClass but uses 'M' instead of 'X'.
class (Show (layout a), Typeable layout) => LayoutClass layout a where

    -- | Run the layout on a workspace. Default delegates to 'doLayout' or
    -- 'emptyLayout' depending on whether the stack is empty.
    runLayout :: W.Workspace String (layout a) a -> Rectangle
              -> M ([(a, Rectangle)], Maybe (layout a))
    runLayout (W.Workspace _ l s) r = maybe (emptyLayout l r) (doLayout l r) s

    -- | Lay out windows given a stack. Default wraps 'pureLayout'.
    doLayout :: layout a -> Rectangle -> W.Stack a
             -> M ([(a, Rectangle)], Maybe (layout a))
    doLayout l r s = return (pureLayout l r s, Nothing)

    -- | Pure version of layout. Default gives every window the full rectangle.
    pureLayout :: layout a -> Rectangle -> W.Stack a -> [(a, Rectangle)]
    pureLayout _ r s = [(W.focus s, r)]

    -- | Handle the case when the workspace is empty. Default returns no windows.
    emptyLayout :: layout a -> Rectangle
                -> M ([(a, Rectangle)], Maybe (layout a))
    emptyLayout _ _ = return ([], Nothing)

    -- | Handle a message. Default wraps 'pureMessage'.
    handleMessage :: layout a -> SomeMessage -> M (Maybe (layout a))
    handleMessage l m = return (pureMessage l m)

    -- | Pure version of message handling. Default ignores all messages.
    pureMessage :: layout a -> SomeMessage -> Maybe (layout a)
    pureMessage _ _ = Nothing

    -- | Human-readable description of the layout.
    description :: layout a -> String
    description = show

-- | Existential wrapper for layouts, allowing different layout types to be
-- stored in the same StackSet.
data Layout a = forall l. (LayoutClass l a, Read (l a)) => Layout (l a)

instance Show (Layout a) where
    show (Layout l) = show l

instance LayoutClass Layout WindowRef where
    runLayout (W.Workspace tag (Layout l) s) r =
        fmap (fmap (fmap Layout)) $ runLayout (W.Workspace tag l s) r
    doLayout (Layout l) r s = fmap (fmap (fmap Layout)) $ doLayout l r s
    pureLayout (Layout l) = pureLayout l
    emptyLayout (Layout l) r = fmap (fmap (fmap Layout)) $ emptyLayout l r
    handleMessage (Layout l) m = fmap (fmap Layout) $ handleMessage l m
    pureMessage (Layout l) m = Layout <$> pureMessage l m
    description (Layout l) = description l

-- We need a Read instance for Layout to satisfy StackSet constraints.
-- In practice it is never used (state is not serialized via Read/Show).
instance Read (Layout a) where
    readsPrec _ _ = []

-- ---------------------------------------------------------------------------
-- The WindowSet — xmonad's StackSet instantiated with our types

-- | The complete window manager state: all workspaces, screens, and windows.
type WindowSet = W.StackSet String (Layout WindowRef) WindowRef ScreenId ScreenDetail

-- | A single workspace.
type WindowSpace = W.Workspace String (Layout WindowRef) WindowRef

-- ---------------------------------------------------------------------------
-- IPC connection

-- | A connection to the mcmonad-core Swift daemon over a Unix socket.
data Connection = Connection
    { connHandle :: !Handle
    , connLock   :: !(MVar ())
    }

-- ---------------------------------------------------------------------------
-- The M monad

-- | Mutable window manager state.
data MState = MState
    { windowset         :: !WindowSet
    , mapped            :: !(Set WindowRef)
    , affinity          :: !(Map.Map String ScreenId)
    , inputMode         :: !String
      -- ^ Current input mode (\"default\", \"resize\", etc.).
    , sticky            :: !(Set WindowRef)
      -- ^ Windows that follow focus across workspace switches.
    , scratchpads       :: !(Map.Map String WindowRef)
      -- ^ Named scratchpad windows (name -> window ref).
    , pendingScratchpad :: !(Maybe String)
      -- ^ When set, the next window created is registered as this scratchpad.
    , windowRects      :: !(Map.Map WindowRef Rectangle)
      -- ^ Last known positions of all visible windows (from the most recent
      -- layout pass). Used for directional focus navigation.
    }

-- | Read-only environment for the M monad. Parameterised over the config's
-- layout type, but the connection and resolved config are always present.
data MConf = MConf
    { connection :: !Connection
    }

-- | The M monad: ReaderT for config/connection, StateT for window manager state,
-- IO at the bottom. This mirrors xmonad's X monad but communicates with a
-- Swift daemon instead of X11.
newtype M a = M (ReaderT MConf (StateT MState IO) a)
    deriving (Functor, Applicative, Monad, MonadIO,
              MonadState MState, MonadReader MConf)

-- | Run an M action with the given config and initial state.
runM :: MConf -> MState -> M a -> IO (a, MState)
runM conf st (M m) = runStateT (runReaderT m conf) st

-- | Exception isolation: try the first action, fall back to the second.
-- Same pattern as xmonad's catchX.
catchM :: M a -> M a -> M a
catchM (M primary) (M fallback) = M $ ReaderT $ \conf -> StateT $ \st -> do
    runStateT (runReaderT primary conf) st
        `catch` \(_ :: SomeException) ->
            runStateT (runReaderT fallback conf) st

-- | Run user code, catching any exceptions. Returns Nothing on failure.
userCode :: M a -> M (Maybe a)
userCode act = catchM (Just <$> act) (return Nothing)

-- | Run user code with a default value on failure.
userCodeDef :: a -> M a -> M a
userCodeDef defVal act = catchM act (return defVal)

-- | Convenient alias for 'liftIO'.
io :: MonadIO m => IO a -> m a
io = liftIO

-- | Access the IPC connection.
withConnection :: (Connection -> M a) -> M a
withConnection f = asks connection >>= f

-- | Access the current window set.
withWindowSet :: (WindowSet -> M a) -> M a
withWindowSet f = gets windowset >>= f

-- ---------------------------------------------------------------------------
-- Affinity tracking

-- | Record current workspace-to-screen associations. Visible workspaces
-- get their screen recorded; hidden workspaces retain their previous affinity.
updateAffinities :: Ord i => W.StackSet i l a sid sd -> Map.Map i sid -> Map.Map i sid
updateAffinities ws existing =
    Map.union current existing
  where
    current = Map.fromList
        [ (W.tag (W.workspace scr), W.screen scr)
        | scr <- W.current ws : W.visible ws
        ]
