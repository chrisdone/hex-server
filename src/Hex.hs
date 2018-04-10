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
import           Control.Monad.Catch
import           Control.Monad.IO.Unlift (MonadUnliftIO)
import           Control.Monad.Logger.CallStack (logError, logDebug, logInfo, MonadLogger)
import           Control.Monad.Trans.Reader
import qualified Data.Attoparsec.ByteString as Atto
import           Data.ByteString (ByteString)
import           Data.Conduit
import           Data.Conduit (runConduit, (.|))
import qualified Data.Conduit.Attoparsec as CA
import qualified Data.Conduit.List as CL
import qualified Data.Conduit.Network as Network
import           Data.List
import           Data.Monoid
import qualified Data.Text as T
import           Data.Word
import           Hex.Builders
import           Hex.Parsers
import           Hex.Types

--------------------------------------------------------------------------------
-- Exposed functions

-- | Runs a server in the current thread.
runServer :: (MonadLogger m, MonadUnliftIO m, MonadCatch m) => m ()
runServer =
  Network.runGeneralTCPServer
    (Network.serverSettings (fst x11PortRange) "127.0.0.1")
    (\app -> do
       logInfo ("New client: " <> T.pack (show (Network.appSockAddr app)))
       catch
         (runConduit
            (Network.appSource app .| logBytes "<=" .| clientConduit .|
             logBytes "=>" .|
             Network.appSink app))
         (\(e :: ClientException) -> logError (T.pack (displayException e)))
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

-- | Result of a request dispatch.
data DispatchResult = Continue | Done

-- | The request/reply loop.
requestReplyLoop ::
     (MonadLogger m, MonadThrow m)
  => StreamSettings
  -> ConduitT ByteString ByteString m ()
requestReplyLoop streamSettings = do
  logDebug "Starting request/reply loop."
  let loop sn = do
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
                result <- dispatchRequest streamSettings sn request
                case result of
                  Done -> logDebug "Closing client connection."
                  Continue -> loop (sn + 1)
  loop 1

-- | Dispatch on the client request.
dispatchRequest ::
     (MonadLogger m, MonadThrow m)
  => StreamSettings
  -> SequenceNumber
  -> ClientMessage
  -> ConduitT i ByteString m DispatchResult
dispatchRequest streamSettings sn =
  \case
    QueryExtension extensionName -> do
      logInfo ("Client queried extension: " <> T.pack (show extensionName))
      yieldBuiltMessage streamSettings (UnsupportedExtension sn)
      pure Continue
    CreateGC -> do
      logInfo "Client asked to create a graphics context. Ignoring."
      pure Continue
    GetProperty -> do
      logInfo "Client asked for a property. Returning None."
      yieldBuiltMessage streamSettings (PropertyValue sn)
      pure Continue
    CreateWindow -> do
      logInfo "Client asked to create a window. Doing nothing."
      pure Continue

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
        , screenRootVisual = VisualID (ResourceID 0)
        , screenBackingStores = Never
        , screenSaveUnders = False
        , screenRootDepth = 32
        , screenAllowedDepths = [Depth 32 []]
        }
      ]
  , infoVersion = Version {versionMajor = 11, versionMinor = 0}
  }

--------------------------------------------------------------------------------
-- Constants

-- | The X11 range of ports. From <https://wiki.wireshark.org/X11>
--
-- > TCP: X11 uses TCP as its transport protocol. The well known TCP
-- > ports for X11 are 6000-6063: typically the port number used is 6000
-- > plus the server/display number.
--
x11PortRange :: (Int, Int)
x11PortRange = (6000, 6063)
