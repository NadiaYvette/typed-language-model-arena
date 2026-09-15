{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The campaign boots its own store.
--
-- The stack under the campaign is three schema layers deep — kiroku (the
-- event store), keiro (the durable workflow runtime), kioku (memory) — and
-- each layer ships numbered, idempotent SQL migrations. Until now bringing a
-- fresh database up meant a hand-run psql loop over three checkouts. This
-- module replaces that recipe:
--
--   * 'bootstrapStore' applies all three migration sets in-process, ordered
--     by layer then number, each file as one @Session.script@ transaction.
--     The files are @IF NOT EXISTS@-shaped (their own guarantee), so
--     re-running is a no-op.
--   * 'bootstrapCampaignStore' is the main-store boot: create the database
--     if the server lacks it, migrate if the schema is absent, report what
--     was done. The driver calls it once at startup, so a @dropdb@ followed
--     by the demo Just Works.
--   * 'storeWorkflowCount' reads keiro's @keiro_workflow_instances@ —
--     freshness is /data/, not schema: @Nothing@ means unmigrated, @Just 0@
--     means migrated and fresh (no journal-collision guards will fire).
--
-- Migration directories default to @~/src/<stack>/...@ and are overridable
-- per layer via @CAMPAIGN_MIGRATIONS_DIR_KIROKU@, @_KEIRO@, @_KIOKU@. Every
-- session runs through a short-lived hasql-pool — the sanctioned runner in
-- this stack (kiroku runs everything through 'P.use').
module Campaign.Bootstrap
  ( -- * Connections
    CampaignConn (..),
    parseCampaignConn,
    renderCampaignConn,
    defaultCampaignConn,
    campaignConnString,
    scratchConnFor,
    -- * Boot
    bootstrapCampaignStore,
    bootstrapStore,
    createDatabaseIfAbsent,
    storeWorkflowCount,
    dropDatabase,
    -- * Plumbing (for the driver's act 14)
    withPool,
    sentinelRelation,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (forM, forM_)
import Data.Char qualified as Char
import Data.List (sort)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Hasql.Connection qualified as Conn
import Hasql.Connection.Settings qualified as ConnSettings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as P
import Hasql.Pool.Config qualified as PC
import Hasql.Session qualified as Session
import Hasql.Statement (unpreparable)
import System.Directory (doesDirectoryExist, listDirectory)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath (takeExtension, (</>))
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

-- ---------------------------------------------------------------------------
-- Connection parsing: the campaign speaks libpq key=value strings, so the
-- bootstrap needs just enough parsing to derive a scratch database on the
-- same server (act 14) and to create a missing database.
-- ---------------------------------------------------------------------------

data CampaignConn = CampaignConn
  { ccHost :: Maybe T.Text
  , ccPort :: Maybe Int
  , ccUser :: Maybe T.Text
  , ccPassword :: Maybe T.Text
  , ccDbname :: T.Text
  }
  deriving stock (Eq, Show)

-- | Parse the subset of libpq @key=value@ syntax the campaign uses. An
-- unparseable string falls back to the historical default
-- (@host=/tmp dbname=campaign@) so behavior never silently changes shape.
parseCampaignConn :: T.Text -> CampaignConn
parseCampaignConn raw
  | T.null (T.strip raw) = CampaignConn Nothing Nothing Nothing Nothing "campaign"
  | otherwise =
      CampaignConn
        { ccHost = val "host"
        , ccPort = val "port" >>= (readMaybe . T.unpack)
        , ccUser = val "user"
        , ccPassword = val "password"
        , ccDbname = fromMaybe "campaign" (val "dbname")
        }
  where
    pairs =
      [ (k, T.strip v)
      | kv <- T.words (T.strip raw)
      , let (k, rest) = T.break (== '=') kv
      , not (T.null rest)
      , let v = T.drop 1 rest
      ]
    val k = lookup k pairs

renderCampaignConn :: CampaignConn -> T.Text
renderCampaignConn c =
  T.unwords $
    concat
      [ maybe [] (\h -> ["host=" <> h]) c.ccHost
      , maybe [] (\p -> ["port=" <> T.pack (show p)]) c.ccPort
      , maybe [] (\u -> ["user=" <> u]) c.ccUser
      , maybe [] (\p -> ["password=" <> p]) c.ccPassword
      , ["dbname=" <> c.ccDbname]
      ]

-- | The campaign's own connection: @$PG_CONNECTION_STRING@ when set, the
-- historical default otherwise.
defaultCampaignConn :: IO CampaignConn
defaultCampaignConn =
  parseCampaignConn . T.pack . fromMaybe "host=/tmp dbname=campaign"
    <$> lookupEnv "PG_CONNECTION_STRING"

-- | The connection string the store layers consume (same resolution as
-- 'defaultCampaignConn').
campaignConnString :: IO T.Text
campaignConnString = renderCampaignConn <$> defaultCampaignConn

-- | Derive a scratch connection on the /same server/: same host, port, and
-- credentials, a different database. This is act 14's raw material.
scratchConnFor :: CampaignConn -> T.Text -> CampaignConn
scratchConnFor main dbname = main {ccDbname = dbname}

-- ---------------------------------------------------------------------------
-- Migration roots
-- ---------------------------------------------------------------------------

data Layer = Kiroku | Keiro | Kioku
  deriving stock (Bounded, Enum, Eq, Ord, Show)

layerDir :: Layer -> FilePath
layerDir Kiroku = "kiroku/kiroku-store-migrations/migrations"
layerDir Keiro = "keiro/keiro-migrations/migrations"
layerDir Kioku = "kioku/kioku-migrations/migrations"

layerEnvVar :: Layer -> String
layerEnvVar l = "CAMPAIGN_MIGRATIONS_DIR_" <> map Char.toUpper (show l)

-- | @layer -> migrations directory@, defaults under @~/src@ (the arena's
-- convention for its sibling stack checkouts), overridable per layer.
migrationRoots :: IO [(Layer, FilePath)]
migrationRoots = do
  home <- lookupEnv "HOME"
  let base = maybe "/home/nyc/src" (</> "src") home
  forM [minBound .. maxBound] $ \layer -> do
    override <- lookupEnv (layerEnvVar layer)
    pure (layer, fromMaybe (base </> layerDir layer) override)

-- ---------------------------------------------------------------------------
-- SQL plumbing
-- ---------------------------------------------------------------------------

-- | A short-lived pool: the sanctioned way to run sessions in this stack
-- (kiroku runs everything through 'P.use').
withPool :: CampaignConn -> (P.Pool -> IO a) -> IO a
withPool conn =
  bracket
    ( P.acquire
        ( PC.settings
            [ PC.staticConnectionSettings
                (ConnSettings.connectionString (renderCampaignConn conn))
            , PC.size 2
            ]
        )
    )
    P.release

-- | Run one session through a pool; any failure aborts with the hasql error.
usePool :: P.Pool -> Session.Session a -> IO a
usePool pool sess =
  either (fail . ("bootstrap: " <>) . show) pure =<< P.use pool sess

-- | Database-create/drop and probe sessions run on the /server/ connection
-- (database @postgres@), because @CREATE DATABASE@ cannot run on the target
-- database itself. These statements cannot be @PREPARE@d, so they use
-- 'unpreparable' — the same pattern kiroku uses for its @SET@ statements.
withServerPool :: CampaignConn -> (P.Pool -> IO a) -> IO a
withServerPool conn = withPool conn {ccDbname = "postgres"}

-- | Double-quote a SQL identifier (embedded quotes doubled).
quoteIdent :: T.Text -> T.Text
quoteIdent t = "\"" <> T.replace "\"" "\"\"" t <> "\""

-- | Create the database on its server if absent. Returns whether the
-- database was created. Exported for act 14, which sequences drop → create
-- → bootstrap by hand on its scratch database.
createDatabaseIfAbsent :: CampaignConn -> IO Bool
createDatabaseIfAbsent conn = withServerPool conn $ \pool -> do
  exists <-
    usePool pool
      ( Session.statement
          conn.ccDbname
          ( unpreparable
              "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)"
              (E.param (E.nonNullable E.text))
              (D.singleRow (D.column (D.nonNullable D.bool)))
          )
      )
  if exists
    then pure False
    else do
      usePool pool
        ( Session.statement
            ()
            ( unpreparable
                ("CREATE DATABASE " <> quoteIdent conn.ccDbname)
                E.noParams
                D.noResult
            )
        )
      -- A fresh database is briefly unavailable (57P03) while the creating
      -- backend finishes; poll until it accepts a trivial session.
      retryConnect 10
      pure True
  where
    retryConnect n
      | n <= (0 :: Int) = fail "bootstrap: created database never became connectable"
      | otherwise = do
          probe <- try (withPool conn (\p -> usePool p (Session.script "SELECT 1")))
          case probe of
            Right () -> pure ()
            Left (_ :: SomeException) -> threadDelay 500000 >> retryConnect (n - 1)

-- | Drop the database (act 14's teardown). @WITH (FORCE)@ clears lingering
-- backends so a re-run of the act always starts clean.
dropDatabase :: CampaignConn -> IO ()
dropDatabase conn = withServerPool conn $ \pool ->
  usePool pool
    ( Session.statement
        ()
        ( unpreparable
            ("DROP DATABASE IF EXISTS " <> quoteIdent conn.ccDbname <> " WITH (FORCE)")
            E.noParams
            D.noResult
        )
    )

-- ---------------------------------------------------------------------------
-- Sentinel: freshness is data, not schema
-- ---------------------------------------------------------------------------

-- | keiro's workflow-instances table: created by keiro's own migrations, so
-- its existence certifies the schema, and its row count certifies freshness.
sentinelRelation :: T.Text
sentinelRelation = "keiro.keiro_workflows"

-- | @Just n@ = migrated, n workflows journaled. @Nothing@ = unmigrated.
storeWorkflowCount :: CampaignConn -> IO (Maybe Int)
storeWorkflowCount conn = withPool conn $ \pool -> do
  schemaOk <-
    usePool pool
      ( Session.statement
          ()
          ( unpreparable
              ("SELECT to_regclass('" <> sentinelRelation <> "') IS NOT NULL")
              E.noParams
              (D.singleRow (D.column (D.nonNullable D.bool)))
          )
      )
  if not schemaOk
    then pure Nothing
    else do
      n <-
        usePool pool
          ( Session.statement
              ()
              ( unpreparable
                  ("SELECT count(*) FROM " <> sentinelRelation)
                  E.noParams
                  (D.singleRow (D.column (D.nonNullable D.int8)))
              )
          )
      pure (Just (fromIntegral n))

-- ---------------------------------------------------------------------------
-- Migration application
-- ---------------------------------------------------------------------------

-- | Apply every layer's migrations, ordered by layer then migration number.
-- Idempotent: the SQL files are @IF NOT EXISTS@-shaped, so a second run is a
-- no-op. Returns the number of migration files applied (the full set every
-- time — the count certifies discovery, not delta).
bootstrapStore :: CampaignConn -> IO Int
bootstrapStore conn = do
  roots <- migrationRoots
  files <- fmap concat $ forM roots $ \(layer, dir) -> do
    ok <- doesDirectoryExist dir
    if not ok
      then fail ("bootstrap: migration directory missing for " <> show layer <> ": " <> dir <> " (set " <> layerEnvVar layer <> ")")
      else do
        entries <- listDirectory dir
        let sqls =
              sort
                [ dir </> e
                | e <- entries
                , takeExtension e == ".sql"
                ]
        pure [(layer, f) | f <- sqls]
  withPool conn $ \pool ->
    forM_ files $ \(layer, f) -> do
      contents <- readFile f
      applied <-
        P.use pool (Session.script (T.pack contents))
      case applied of
        Right () -> pure ()
        Left err -> do
          hPutStrLn stderr ("bootstrap: migration failed: layer " <> show layer <> ", file " <> f)
          hPutStrLn stderr (show err)
          exitFailure
  pure (length files)

-- | The main-store boot the driver runs once at startup: create the
-- database if absent, migrate if the schema is absent. Returns how many
-- migration files were applied (0 when the schema was already current).
bootstrapCampaignStore :: CampaignConn -> IO Int
bootstrapCampaignStore conn = do
  _created <- createDatabaseIfAbsent conn
  count <- storeWorkflowCount conn
  case count of
    Just _ -> pure 0
    Nothing -> bootstrapStore conn
