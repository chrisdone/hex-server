{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Server-side X11 protocol implementation.

module Hex
  ( runServer
  ) where

import           BinaryView
import           Control.Applicative
import           Control.Concurrent.MVar
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.IO.Unlift (MonadUnliftIO)
import           Control.Monad.Logger.CallStack (logError, logDebug, logInfo, MonadLogger)
import           Control.Monad.Trans.Reader
import qualified Data.Attoparsec.ByteString as Atto
import           Data.ByteString (ByteString)
import           Data.Coerce
import           Data.Conduit
import           Data.Conduit (runConduit, (.|))
import qualified Data.Conduit.Attoparsec as CA
import qualified Data.Conduit.List as CL
import qualified Data.Conduit.Network as Network
import qualified Data.HashMap.Strict as HM
import           Data.List
import           Data.Monoid
import qualified Data.Text as T
import           Data.Word
import           Hex.Builders
import           Hex.Constants
import           Hex.Parsers
import           Hex.Types

--------------------------------------------------------------------------------
-- Exposed functions

-- | Runs a server in the current thread.
runServer :: (MonadLogger m, MonadUnliftIO m, MonadMask m,MonadCatch m) => m ()
runServer = do
  mutex <- liftIO (newMVar ())
  Network.runGeneralTCPServer
    (Network.serverSettings (fst x11PortRange) "*")
    (\app -> do
       -- () <- liftIO (takeMVar mutex)
       logInfo ("New client: " <> T.pack (show (Network.appSockAddr app)))
       finally (catch
                  (runConduit
                     (Network.appSource app .| -- logBytes "<=" .|
                      clientConduit .|
                      -- logBytes "=>" .|
                      Network.appSink app))
                  (\(e :: ClientException) -> logError (T.pack (displayException e))))
               (liftIO (putMVar mutex ()))
       logInfo ("Client closed: " <> T.pack (show (Network.appSockAddr app))))

-- | Log raw bytes for debugging purposes.
logBytes :: (MonadLogger m) => String -> ConduitT ByteString ByteString m ()
logBytes prefix =
  CL.mapM
    (\bytes ->
       let debug =
             if False
               then "\n" ++ show bytes
               else ""
           lhs = intercalate "\n" . map ((prefix ++ " ") ++) . lines
       in bytes <$
          logDebug (T.pack ("\n" ++ lhs (binaryView 12 bytes) ++ "\n" ++ debug)))

--------------------------------------------------------------------------------
-- Complete protocol conduit

-- | Complete client-handling conduit.
clientConduit ::
     (MonadLogger m, MonadThrow m) => ConduitT ByteString ByteString m ()
clientConduit = do
  streamSettings <- handshakeSink
  yieldBuiltMessage streamSettings (ConnectionAccepted defaultInfo)
  requestReplyLoop streamSettings

-- | Initial handshake with client.
handshakeSink ::
     (MonadLogger m, MonadThrow m) => ConduitT ByteString void m StreamSettings
handshakeSink = do
  endiannessResult <- CA.sinkParserEither endiannessParser
  case endiannessResult of
    Left e -> throwM (InvalidEndianness e)
    Right endianness -> do
      logDebug ("Received endianness: " <> T.pack (show endianness))
      let streamSettings =
            StreamSettings {streamSettingsEndianness = endianness}
      initResult <-
        CA.sinkParserEither
          (runReaderT (runStreamParser initiationParser) streamSettings)
      case initResult of
        Left e -> throwM (InvalidInitiationMessage e)
        Right version -> do
          logDebug
            ("Received initiation message. Protocol version: " <>
             T.pack (show version))
          pure streamSettings

-- | The request/reply loop.
requestReplyLoop ::
     (MonadLogger m, MonadThrow m)
  => StreamSettings
  -> ConduitT ByteString ByteString m ()
requestReplyLoop streamSettings = do
  logDebug "Starting request/reply loop."
  let loop clientState = do
        requestResult <-
          CA.sinkParserEither
            (fmap
               Just
               (runReaderT (runStreamParser requestParser) streamSettings) <|>
             (Nothing <$ Atto.endOfInput))
        case requestResult of
          Left e -> throwM (InvalidRequest e)
          Right parsed -> do
            case parsed of
              Nothing -> logDebug "End of input stream."
              Just request -> do
                result <- dispatchRequest streamSettings clientState request
                case result of
                  Nothing -> logDebug "Closing client connection."
                  Just clientState' -> loop clientState'
  loop
    (ClientState
     { clientStateSequenceNumber = initialSequenceNumber
     , clientStateAtoms = predefinedAtoms
     })

-- | Dispatch on the client request.
dispatchRequest ::
     (MonadLogger m, MonadThrow m)
  => StreamSettings
  -> ClientState
  -> ClientMessage
  -> ConduitT i ByteString m (Maybe ClientState)
dispatchRequest streamSettings clientState =
  \case
    QueryExtension extensionName -> do
      case extensionName of
        "XC-MISC" -> do
          logDebug
            ("Client queried supported extension: " <>
             T.pack (show extensionName))
          reply (SupportedExtension sn xcMiscOpcode)
        _ -> do
          logInfo
            ("Client queried unsupported extension: " <>
             T.pack (show extensionName))
          reply (UnsupportedExtension sn)
      pure continue
    CreateGC -> do
      logDebug "Client asked to create a graphics context. Ignoring."
      pure continue
    FreeGC -> do
      logDebug "Client asked to free a graphics context. Ignoring."
      pure continue
    ChangeGC -> do
      logDebug "Client asked to change a graphics context. Ignoring."
      pure continue
    GetProperty -> do
      logDebug "Client asked for a property. Returning None."
      reply (PropertyValue sn)
      pure continue
    CreateWindow newWindow -> do
      logInfo "Client asked to create a window. Sending CreateNotify event."
      reply (CreateNotify sn newWindow)
      pure continue
    CreatePixmap -> do
      logInfo "Client asked to create a pixmap. Doing nothing."
      pure continue
    AllocColor -> do
      logInfo "Client asked to alloc a color."
      reply (ColorAllocated sn)
      pure continue
    GetPointerMapping -> do
      logInfo "Client asked for pointer mapping."
      reply (PointerMapping sn)
      pure continue
    FreePixmap -> do
      logInfo "Client asked to free a pixmap. Doing nothing."
      pure continue
    MapWindow -> do
      logInfo "Client asked to map a window. Doing nothing."
      pure continue
    XCMiscGetXIDRange -> do
      logDebug "Client asked for the ID range."
      reply (XIDRange sn)
      pure continue
    InternAtom name _onlyIfExists -> do
      logDebug ("Request to intern atom: " <> T.pack (show name))
      let atomId =
            coerce
              (fromIntegral (HM.size (clientStateAtoms clientState) + 1) :: Word32)
          atoms = HM.insert atomId name (clientStateAtoms clientState)
      logDebug ("Interned to: " <> T.pack (show atomId))
      reply (AtomInterned sn atomId)
      pure (fmap (\s -> s {clientStateAtoms = atoms}) continue)
    ChangeProperty -> do
      logDebug "Client requested to change property. Doing nothing."
      pure continue
    ChangeWindowAttributes -> do
      logDebug "Client requested to change window attributes. Ignoring"
      pure continue
    QueryColors cmi pixels -> do
      logDebug
        ("Client queried colors: " <> T.pack (show cmi) <> " " <>
         T.pack (show pixels) <>
         ", length=" <>
         T.pack (show (length pixels)))
      reply (ColorsQueried sn pixels)
      pure continue
    QueryPointer -> do
      logDebug "Client queried pointer. Sending back pointer."
      reply (PointerQueried sn)
      pure continue
    GetWindowAttributes -> do
      logDebug "Client requested window attributes."
      reply (WindowAttributes sn)
      pure continue
    GetInputFocus -> do
      logDebug "Client requested input focus."
      reply (InputFocus sn)
      pure continue
    GetGeometry -> do
      logDebug "Geometry requested."
      reply (GeometryGot sn)
      pure continue
    GrabServer -> do
      logDebug "Client grabbed server."
      pure continue
    UngrabServer -> do
      logDebug "Client ungrabbed server."
      pure continue
    GetSelectionOwner -> do
      logDebug "Client requested selection owner."
      reply (SelectionOwner sn)
      pure continue
    SetClipRectangles -> do
      logDebug "Client set clip rectangles."
      pure continue
    PolyFillRectangle -> do
      logDebug "Client poly-filled a rectangle."
      pure continue
    DeleteProperty -> do
      logDebug "Client deleted a property."
      pure continue
    GrabPointer -> do
      logDebug "Grab the pointer."
      reply (GrabPointerStatus sn)
      pure continue
    Ignored -> logDebug "Ignored message." *> pure continue
  where
    sn = clientStateSequenceNumber clientState
    reply = yieldBuiltMessage streamSettings
    continue =
      Just
        (clientState
         {clientStateSequenceNumber = clientStateSequenceNumber clientState + 1})

--------------------------------------------------------------------------------
-- Communication facilities

-- | Yield a single built message downstream.
yieldBuiltMessage ::
     Monad m => StreamSettings -> ServerMessage -> ConduitM void ByteString m ()
yieldBuiltMessage streamSettings msg =
  yield msg .| buildMessagesConduit streamSettings

-- | A conduit that builds messages into bytes.
buildMessagesConduit ::
     Monad m => StreamSettings -> ConduitT ServerMessage ByteString m ()
buildMessagesConduit streamSettings =
  CL.map (streamBuilderToByteString streamSettings . buildServerMessage)

--------------------------------------------------------------------------------
-- Initial server info

defaultInfo :: Info
defaultInfo =
  Info
  { infoRelease = 0 -- TODO: ?
  , infoResourceIdBase = 0 -- TODO: ?
  , infoResourceIdMask = 1 -- TODO: ?
  , infoMotionBufferSize = 0
  , infoVendor = "ABCD"
  , infoMaximumRequestLength = maxBound :: Word16
  , infoImageByteOrder = MostSignificantFirst -- TODO: ?
  , infoImageBitOrder = MostSignificantFirst -- TODO: ?
  , infoBitmapFormatScanlineUnit = 32
  , infoBitmapFormatScanlinePad = 32
  , infoMinKeycode = 8
  , infoMaxKeycode = 8
  , infoPixmapFormats =
      [ Format
        {formatDepth = 32, formatBitsperpixel = 32, formatScanlinepad = 32}
      ]
  , infoScreens =
      [ Screen
        { screenRoot = WindowID (ResourceID 0)
        , screenDefaultColormap = ColorMapID (ResourceID 0)
        , screenWhitePixel = 0x00ffffff
        , screenBlackPixel = 0x00000000
        , screenCurrentInputMasks = mempty
        , screenWidthInPixels = 1024
        , screenHeightInPixels = 768
        , screenWidthInMillimeters = 1024
        , screenHeightInMillimeters = 768
        , screenMinInstalledMaps = 1
        , screenMaxInstalledMaps = 1
        , screenRootVisual = visual
        , screenBackingStores = Never
        , screenSaveUnders = False
        , screenRootDepth = 32
        , screenAllowedDepths =
            [ Depth
                32
                [ Visual
                  { visualId = visual
                  , visualClass = TrueColor
                  , visualBitsPerRgbValue = 8
                  , visualColormapEntries = 256
                  , visualRedMask = 0x00ff0000
                  , visualGreenMask = 0x0000ff00
                  , visualBlueMask = 0x000000ff
                  }
                ]
            ]
        }
      ]
  , infoVersion = Version {versionMajor = 11, versionMinor = 0}
  }
  where visual = VisualID (ResourceID 0)
