{-# LANGUAGE OverloadedStrings #-}

-- Temporary: probe OpenSSH ed25519 key parse + crypton sign/verify.
module Main where

import Data.ByteString qualified as B
import Data.ByteString.Base64 qualified as B64
import Data.Char (ord)
import Data.Word (Word32)
import Numeric (showHex)

home :: FilePath
home = "/home/nyc"

be32 :: B.ByteString -> Word32
be32 bs = foldl' (\acc b -> acc * 256 + fromIntegral b) 0 (B.unpack bs)

rdString :: B.ByteString -> (B.ByteString, B.ByteString)
rdString bs =
  let len = fromIntegral (be32 (B.take 4 bs))
   in (B.take len (B.drop 4 bs), B.drop (4 + len) bs)

main :: IO ()
main = do
  raw <- readFile (home <> "/.radicle/keys/radicle")
  let content = B.pack $ map (fromIntegral . ord) $ concat $ filter (not . isDashLine) (lines raw)
  let payload = B64.decodeBase64Lenient content

  -- Get the public key blob from the payload
  let (_magic, r1) = B.splitAt 15 payload
  let (_cipher, r2) = rdString r1
  let (_kdf, r3) = rdString r2
  let (_kdf_opts, r4) = rdString r3
  let (_count_bs, r5) = B.splitAt 4 r4
  let (pub_blob, _) = rdString r5

  -- Extract the actual 32-byte public key from the blob
  let (kty_len_bs, rest1) = B.splitAt 4 pub_blob
  let kty_len = fromIntegral (be32 kty_len_bs)
  let (kty, rest2) = B.splitAt kty_len rest1
  let (pk_len_bs, rest3) = B.splitAt 4 rest2
  let pk_len = fromIntegral (be32 pk_len_bs)
  let (pub_key, _) = B.splitAt pk_len rest3

  print ("pub key len" :: String, B.length pub_key)
  print ("pub key hex" :: String, concatMap (`showHex` "") (B.unpack pub_key))

  -- Use the public key as-is for verification (it's the raw 32-byte key)
  -- We'll need to convert it to PublicKey type

  -- For now, just show we can read the file
  putStrLn "Successfully parsed SSH private key file"
  putStrLn ("Key type (should be ssh-ed25519): " ++ show kty)

isDashLine :: String -> Bool
isDashLine = elem '-'
