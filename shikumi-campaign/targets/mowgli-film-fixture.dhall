-- mowgli film-fixture target — REPLACEMENT manifest for the built-in unit
-- mowgli/host@film-fixture. Same identity, same command, same oracle as the
-- Haskell built-in it replaces (the built-in's "all checks passed" marker).
-- A manifest on an existing key is authoritative: this file's command and
-- markers govern execution.
{ project = "mowgli"
, kind = "host-verify"
, arch = "host"
, config = "film-fixture"
, workDir = "/home/nyc/src/mowgli"
, command = "make -C /home/nyc/src/mowgli film_episode_test film_annotation_fixture_test && /home/nyc/src/mowgli/src/logic/film_episode_test && /home/nyc/src/mowgli/src/logic/film_annotation_fixture_test"
, successMarkers = [ "all checks passed" ]
, waiveBaseline = [] : List Text
, exitMustSucceed = True
, timeoutSeconds = 600
}
