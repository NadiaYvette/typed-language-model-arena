{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Campaign.SshAgent
  ( signWithAgent
  , SshAgentError (..)
  , getSshAgentKey
  , pubKeyBlobForEd25519
  ) where

import Control.Exception (Exception, IOException, try, throwIO)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Base64 as B64
import Data.Binary.Put (runPut, putWord32be, putByteString, putWord8)
import Data.Binary.Get (runGet, getWord32be, getWord8)
import Network.Socket
  ( Socket, socket, connect, close, Family (AF_UNIX), SocketType (Stream), defaultProtocol, SockAddr (SockAddrUnix)
  )
import Network.Socket.ByteString (sendAll, recv)
import System.Environment (lookupEnv)
import Data.Bits (shiftR)
import System.Process.Typed (proc, readProcess_)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

data SshAgentError
  = SshAgentNotRunning !String
  | SshAgentConnectionError !String
  | SshAgentProtocolError !String
  | SshAgentSignError !String
  deriving (Show)

instance Exception SshAgentError

-- | Build an SSH wire-format public key blob for an ed25519 key.
pubKeyBlobForEd25519 :: B.ByteString -> B.ByteString
pubKeyBlobForEd25519 raw32 =
  let kty = encodeSshString "ssh-ed25519"
      pk  = encodeSshString raw32
   in kty `B.append` pk

-- | Encode a byte string as SSH string (4-byte big-endian length + data).
encodeSshString :: B.ByteString -> B.ByteString
encodeSshString bs =
  B.concat [lenBs, bs]
  where
    l = B.length bs
    lenBs = B.pack
      [ fromIntegral (l `shiftR` 24)
      , fromIntegral (l `shiftR` 16)
      , fromIntegral (l `shiftR` 8)
      , fromIntegral l
      ]

-- | Sign arbitrary data using the SSH agent.
signWithAgent :: B.ByteString -> B.ByteString -> IO B.ByteString
signWithAgent pubKeyBlob dataToSign = do
  sockPath <- lookupEnv "SSH_AUTH_SOCK"
  case sockPath of
    Nothing -> throwIO (SshAgentNotRunning "SSH_AUTH_SOCK not set")
    Just path -> do
      sock <- socket AF_UNIX Stream defaultProtocol
      connect sock (SockAddrUnix path)
      result <- try $ do
        -- SSH_AGENTC_SIGN_REQUEST = 13
        let payload = runPut $ do
                                      putByteString (encodeSshString pubKeyBlob)
                                      putByteString (encodeSshString dataToSign)
                                      putWord32be 0 -- flags
            req = runPut $ do
                      putWord32be (fromIntegral (B.length (BL.toStrict payload)))
                      putWord8 13
                      putByteString (BL.toStrict payload)
        sendAll sock (BL.toStrict req)
        resp <- recv sock 4096
        case parseSignResponse resp of
          Left err -> throwIO (SshAgentProtocolError err)
          Right sig -> pure sig
      close sock
      case result of
        Left (e :: SshAgentError) -> throwIO e
        -- Left (e :: IOException) -> throwIO (SshAgentConnectionError (show e))
        Right sig -> pure sig

-- | Parse the sign response
-- SSH_AGENT_SIGN_RESPONSE = 14
parseSignResponse :: B.ByteString -> Either String B.ByteString
parseSignResponse bs =
  let (lenBs, rest) = B.splitAt 4 bs
      len = runGet getWord32be (BL.fromStrict lenBs)
      (typeBs, rest') = B.splitAt 1 rest
      type_ = runGet getWord8 (BL.fromStrict typeBs)
  in if type_ /= 14
     then Left ("Expected SSH_AGENT_SIGN_RESPONSE (14), got " ++ show type_)
     else Right (snd (decodeSshString rest'))

decodeSshString :: B.ByteString -> (B.ByteString, B.ByteString)
decodeSshString bs =
  let len = fromIntegral (runGet getWord32be (BL.fromStrict (B.take 4 bs)))
  in (B.take len (B.drop 4 bs), B.drop (4 + len) bs)

-- | Get the first Ed25519 key from ssh-add -L
getSshAgentKey :: IO B.ByteString
getSshAgentKey = do
  (out, _) <- readProcess_ (proc "ssh-add" ["-L"])
  let keyLine = head (lines (T.unpack (T.decodeUtf8 (BL.toStrict out))))
  let base64Part = T.encodeUtf8 (T.pack (words keyLine !! 1))
  pure (either (const B.empty) id (B64.decodeBase64Untyped base64Part))
