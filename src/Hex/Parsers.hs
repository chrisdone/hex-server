-- | Parsers of client messages.

module Hex.Parsers where

import           Control.Monad.Trans
import           Control.Monad.Trans.Reader
import qualified Data.Attoparsec.Binary as Atto
import qualified Data.Attoparsec.ByteString as Atto
import           Data.Attoparsec.ByteString.Char8 (Parser)
import qualified Data.Attoparsec.ByteString.Char8 as Atto8
import           Data.ByteString (ByteString)
import qualified Data.ByteString as S
import           Data.Functor
import           Data.Word
import           Hex.Types

--------------------------------------------------------------------------------
-- Endianness parser
--
-- The client must send an initial byte of data to identify the byte
-- order to be employed. The value of the byte must be octal 102 or
-- 154. The value 102 (ASCII uppercase B) means values are transmitted
-- most significant byte first, and value 154 (ASCII lowercase l)
-- means values are transmitted least significant byte first. Except
-- where explicitly noted in the protocol, all 16-bit and 32-bit
-- quantities sent by the client must be transmitted with this byte
-- order, and all 16-bit and 32-bit quantities returned by the server
-- will be transmitted with this byte order.

-- | Parse the endianness.
endiannessParser :: Parser Endianness
endiannessParser = Atto.choice [most, least] <* unused
  where
    least = LeastSignificantFirst <$ Atto8.char 'l'
    most = MostSignificantFirst <$ Atto8.char 'B'
    unused = void Atto.anyWord8

--------------------------------------------------------------------------------
-- Parsers for X11-protocol-specific types

-- | An unused number of bytes.
unusedParser :: Int -> StreamParser ()
unusedParser n = StreamParser (lift (void (Atto.take n)))

-- | Parse minor/major versions.
protocolVersionParser :: StreamParser Version
protocolVersionParser = do
  major <- card16Parser
  minor <- card16Parser
  pure (Version {versionMajor = major, versionMinor = minor})

-- | Connection initiation. The data is ignored, we just walk past it.
initiationParser :: StreamParser Version
initiationParser = do
  version <- protocolVersionParser
  authNameLen <- stringLengthParser
  authDataLen <- stringLengthParser
  unusedParser 2
  _authName <- stringParser authNameLen
  _authData <- stringParser authDataLen
  pure version

-- | Parse a length of a string.
stringLengthParser :: StreamParser Word16
stringLengthParser = card16Parser

-- | Parse a string, including padding.
stringParser :: Word16 -> StreamParser ByteString
stringParser len =
  StreamParser (lift (fmap (S.take (fromIntegral len)) (Atto.take (pad len))))

-- | Parse a 16-bit word with the right endianness.
card16Parser :: StreamParser Word16
card16Parser =
  StreamParser
    (do endianness <- asks streamSettingsEndianness
        lift
          (case endianness of
             MostSignificantFirst -> Atto.anyWord16be
             LeastSignificantFirst -> Atto.anyWord16le))

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
pad :: Word16 -> Int
pad e =
  fromIntegral
    (case mod e 4 of
       0 -> e
       remainder -> e + 4 - remainder)