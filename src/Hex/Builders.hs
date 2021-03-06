{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

-- | Printers of server messages.

module Hex.Builders where

import           Data.Bits
import           Data.ByteString (ByteString)
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Lazy.Builder as L
import           Data.Coerce
import           Data.Int
import           Data.Monoid
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Word
import           Hex.Types

streamBuilderToByteString :: StreamSettings -> StreamBuilder -> ByteString
streamBuilderToByteString settings builder =
  L.toStrict (L.toLazyByteString (runStreamBuilder builder settings))

buildServerMessage :: ServerMessage -> StreamBuilder
buildServerMessage =
  \case
    CreateNotify sn nw ->
      mconcat
        [ buildWord8 16
        , buildUnused 1
        , buildWord16 (coerce sn)
        , buildWord32 (coerce (newWindowParent nw))
        , buildWord32 (coerce (newWindowID nw))
        , buildInt16 (coerce (newWindowX nw))
        , buildInt16 (coerce (newWindowY nw))
        , buildWord16 (coerce (newWindowWidth nw))
        , buildWord16 (coerce (newWindowHeight nw))
        , buildWord16 (coerce (newWindowBorderWidth nw))
        , buildEnum8 True
        , buildUnused 9
        ]
    ConnectionAccepted info -> mconcat [buildEnum8 Success, buildInfo info]
    UnsupportedExtension sid ->
      mconcat
        [ buildWord8 1
        , buildUnused 1
        , buildWord16 (coerce sid)
        , buildWord32 0
        , buildEnum8 False
        , buildUnused 3
        , buildUnused 20
        ]
    GrabPointerStatus sid ->
      mconcat
        [ buildWord8 1
        , buildWord8 0
        , buildWord16 (coerce sid)
        , buildWord32 0
        , buildUnused 24
        ]
    SelectionOwner sid ->
      mconcat
        [ buildWord8 1
        , buildUnused 1
        , buildWord16 (coerce sid)
        , buildWord32 0
        , buildWord32 0
        , buildUnused 20
        ]
    SupportedExtension sid majorOpcode ->
      mconcat
        [ buildWord8 1
        , buildUnused 1
        , buildWord16 (coerce sid)
        , buildWord32 0
        , buildEnum8 True
        , buildWord8 (coerce (majorOpcode))
        , buildUnused 2
        , buildUnused 20
        ]
    PropertyValue sid ->
      mconcat
        [ buildWord8 1
        , buildUnused 1
        , buildWord16 (coerce sid)
        , buildWord32 0 -- len
        , buildWord32 0 -- None
        , buildWord32 0 -- bytes-after
        , buildWord32 0 -- value length
        , buildUnused 12
        ]
    XIDRange sid ->
      mconcat
        [ buildWord8 1
        , buildUnused 1
        , buildWord16 (coerce sid)
        , buildWord32 0
        , buildWord32 startId
        , buildWord32 maxBound
        , buildUnused 16
        ]
      where startId = 1 -- (Must be >0, Xlib expects this.)
    AtomInterned sid aid ->
      mconcat
        [ buildWord8 1
        , buildUnused 1
        , buildWord16 (coerce sid)
        , buildUnused 4
        , buildWord32 (coerce aid)
        , buildUnused 20
        ]
    WindowAttributes sid ->
      mconcat
        [ buildWord8 1
        , buildUnused 1 -- Backing store.
        , buildWord16 (coerce sid)
        , buildWord32 3 -- len
        , buildWord32 0 -- visual
        , buildWord16 2
        , buildWord8 0
        , buildWord8 0
        , buildWord32 0
        , buildWord32 0
        , buildEnum8 False
        , buildEnum8 True
        , buildWord8 2 -- viewable
        , buildEnum8 True
        , buildWord32 0
        , buildEventSet mempty
        , buildEventSet mempty
        , buildDeviceEventSet mempty
        , buildUnused 2
        ]
    GeometryGot sid ->
      mconcat
        [ buildWord8 1
        , buildUnused 1 --depth
        , buildWord16 (coerce sid)
        , buildWord32 0 -- len
        , buildWord32 0 --root
        , buildWord16 0 --x
        , buildWord16 0 --y
        , buildWord16 1024 --w
        , buildWord16 768 --h
        , buildWord16 0
        , buildUnused 10
        ]
    ColorsQueried sid pixels ->
      mconcat
        [ buildWord8 1
        , buildWord8 0
        , buildWord16 (coerce sid)
        , buildWord32 (2 * fromIntegral n)
        , buildWord16 (fromIntegral n)
        , buildUnused 22
        , mconcat (map (const buildRGB) pixels)
        ]
      where n = length pixels
            buildRGB =
              mconcat
                [buildWord16 0, buildWord16 0, buildWord16 0, buildUnused 2]
    PointerQueried sid ->
      mconcat
        [ buildWord8 1
        , buildEnum8 True
        , buildWord16 (coerce sid)
        , buildWord32 0
        , buildWord32 0
        , buildWord32 0
        , buildWord16 0 -- x
        , buildWord16 0 -- y
        , buildWord16 0 -- wx
        , buildWord16 0 -- wy
        , buildUnused 2
        , buildUnused 6
        ]
    InputFocus sid ->
      mconcat
        [ buildWord8 1
        , buildWord8 0
        , buildWord16 (coerce sid)
        , buildWord32 0
        , buildWord32 1
        , buildUnused 20
        ]
    ColorAllocated sid ->
      mconcat
        [ buildWord8 1
        , buildWord8 0
        , buildWord16 (coerce sid)
        , buildWord32 0
        , buildWord16 0 -- r
        , buildWord16 0 -- g
        , buildWord16 0 -- b
        , buildUnused 2
        , buildWord32 0 -- pixel
        , buildUnused 12
        ]
    PointerMapping sid ->
      mconcat
        [ buildWord8 1
        , buildWord8 1
        , buildWord16 (coerce sid)
        , buildWord32 1
        , buildUnused 24
        , buildWord8 0
        , buildUnused 3
        ]

buildInfo :: Info -> StreamBuilder
buildInfo info =
  StreamBuilder
    (\settings ->
       let body = makeBody settings
       in runStreamBuilder (header body) settings <> L.byteString body)
  where
    header body =
      mconcat
        [ buildUnused 1
        , buildVersion (infoVersion info)
        , buildWord16 (fromIntegral (div (S.length body) 4))
        ]
    makeBody settings =
      streamBuilderToByteString
        settings
        (mconcat
           [ buildWord32 (infoRelease info)
           , buildWord32 (infoResourceIdBase info)
           , buildWord32 (infoResourceIdMask info)
           , buildWord32 (infoMotionBufferSize info)
           , buildWord16 (fromIntegral (S.length (infoVendor info)))
           , buildWord16 (infoMaximumRequestLength info)
           , buildWord8 (fromIntegral (length (infoScreens info)))
           , buildWord8 (fromIntegral (length (infoPixmapFormats info)))
           , buildEnum8 (infoImageByteOrder info)
           , buildEnum8 (infoImageBitOrder info)
           , buildWord8 (infoBitmapFormatScanlineUnit info)
           , buildWord8 (infoBitmapFormatScanlinePad info)
           , buildWord8 (infoMinKeycode info)
           , buildWord8 (infoMaxKeycode info)
           , buildUnused 4
           , buildByteStringPadded (infoVendor info)
           , mconcat (map buildPixmapFormat (infoPixmapFormats info))
           , mconcat (map buildScreen (infoScreens info))
           ])

buildPixmapFormat :: Format -> StreamBuilder
buildPixmapFormat fmt =
  mconcat
    [ buildWord8 (formatDepth fmt)
    , buildWord8 (formatBitsperpixel fmt)
    , buildWord8 (formatScanlinepad fmt)
    , buildUnused 5
    ]

buildScreen :: Screen -> StreamBuilder
buildScreen scr =
  mconcat
    [ {-0-} buildWord32 (coerce (screenRoot scr))
    , {-4-} buildWord32 (coerce (screenDefaultColormap scr))
    , {-8-} buildWord32 (screenWhitePixel scr)
    , {-12-} buildWord32 (screenBlackPixel scr)
    , {-16-} buildEventSet (screenCurrentInputMasks scr)
    , {-20-} buildWord16 (screenWidthInPixels scr)
    , {-22-} buildWord16 (screenHeightInPixels scr)
    , {-24-} buildWord16 (screenWidthInMillimeters scr)
    , {-26-} buildWord16 (screenHeightInMillimeters scr)
    , {-28-} buildWord16 (screenMinInstalledMaps scr)
    , {-30-} buildWord16 (screenMaxInstalledMaps scr)
    , {-32-} buildWord32 (coerce (screenRootVisual scr))
    , {-36-} buildEnum8 (screenBackingStores scr)
    , {-37-} buildEnum8 (screenSaveUnders scr)
    , {-38-} buildWord8 (screenRootDepth scr)
    , {-39-} buildWord8 (fromIntegral (length (screenAllowedDepths scr)))
    , mconcat (map buildDepth (screenAllowedDepths scr))
    ]

buildDepth :: Depth -> StreamBuilder
buildDepth depth =
  mconcat
    [ buildWord8 (depthDepth depth)
    , buildUnused 1
    , buildWord16 (fromIntegral (length (depthVisuals depth)))
    , buildUnused 4
    , mconcat (map buildVisual (depthVisuals depth))
    ]

buildVisual :: Visual -> StreamBuilder
buildVisual v =
  mconcat
    [ buildWord32 (coerce (visualId v))
    , buildEnum8 (visualClass v)
    , buildWord8 (visualBitsPerRgbValue v)
    , buildWord16 (visualColormapEntries v)
    , buildWord32 (visualRedMask v)
    , buildWord32 (visualGreenMask v)
    , buildWord32 (visualBlueMask v)
    , buildUnused 4
    ]

buildDeviceEventSet :: Set Event -> StreamBuilder
buildDeviceEventSet = buildWord16 . const 0

buildEventSet :: Set Event -> StreamBuilder
buildEventSet = buildWord32 . foldl (.|.) 0 . map encode . Set.toList
  where
    encode :: Event -> Word32
    encode =
      \case
        KeyPressEvent -> 0x00000001
        KeyReleaseEvent -> 0x00000002
        ButtonPressEvent -> 0x00000004
        ButtonReleaseEvent -> 0x00000008
        EnterWindowEvent -> 0x00000010
        LeaveWindowEvent -> 0x00000020
        PointerMotionEvent -> 0x00000040
        PointerMotionHintEvent -> 0x00000080
        Button1MotionEvent -> 0x00000100
        Button2MotionEvent -> 0x00000200
        Button3MotionEvent -> 0x00000400
        Button4MotionEvent -> 0x00000800
        Button5MotionEvent -> 0x00001000
        ButtonMotionEvent -> 0x00002000
        KeymapStateEvent -> 0x00004000
        ExposureEvent -> 0x00008000
        VisibilityChangeEvent -> 0x00010000
        StructureNotifyEvent -> 0x00020000
        ResizeRedirectEvent -> 0x00040000
        SubstructureNotifyEvent -> 0x00080000
        SubstructureRedirectEvent -> 0x00100000
        FocusChangeEvent -> 0x00200000
        PropertyChangeEvent -> 0x00400000
        ColormapChangeEvent -> 0x00800000
        OwnerGrabButtonEvent -> 0x01000000

buildVersion :: Version -> StreamBuilder
buildVersion (Version major minor) =
  mconcat [buildWord16 major, buildWord16 minor]

buildUnused :: Int -> StreamBuilder
buildUnused n = StreamBuilder (const (L.byteString (S.replicate n 0)))

buildEnum8 :: Enum a => a -> StreamBuilder
buildEnum8 = buildWord8 . fromIntegral . fromEnum

buildByteStringPadded :: ByteString -> StreamBuilder
buildByteStringPadded = StreamBuilder . const . L.byteString . padded
  where
    padded s =
      S.take
        (fromIntegral (pad (fromIntegral (S.length s))))
        (s <> S.replicate 4 (0 :: Word8))

buildByteString :: ByteString -> StreamBuilder
buildByteString = StreamBuilder . const . L.byteString

buildLazyByteString :: L.ByteString -> StreamBuilder
buildLazyByteString = StreamBuilder . const . L.lazyByteString

buildWord8 :: Word8 -> StreamBuilder
buildWord8 = StreamBuilder . const . L.word8

buildInt16 :: Int16 -> StreamBuilder
buildInt16 = buildWord16 . fromIntegral

buildWord16 :: Word16 -> StreamBuilder
buildWord16 w =
  StreamBuilder
    (\s ->
       case streamSettingsEndianness s of
         MostSignificantFirst -> L.word16BE w
         LeastSignificantFirst -> L.word16LE w)

buildWord32 :: Word32 -> StreamBuilder
buildWord32 w =
  StreamBuilder
    (\s ->
       case streamSettingsEndianness s of
         MostSignificantFirst -> L.word32BE w
         LeastSignificantFirst -> L.word32LE w)

--------------------------------------------------------------------------------
-- X11 Helpers

-- | If the number of unused bytes is variable, the encode-form
-- typically is:
--
-- p unused, p=pad(E)
--
-- where E is some expression, and pad(E) is the number of bytes
-- needed to round E up to a multiple of four.
--
-- pad(E) = (4 - (E mod 4)) mod 4
pad :: Word16 -> Word16
pad e =
  case mod e 4 of
    0 -> e
    remainder -> e + 4 - remainder
