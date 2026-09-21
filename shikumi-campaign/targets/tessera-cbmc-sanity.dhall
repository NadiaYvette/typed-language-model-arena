-- tessera CBMC sanity-suite target — NEW unit, absent from the built-in
-- discovery. Its very presence in the cell list proves runtime manifest
-- discovery: authoring it was a filesystem write, not an orchestrator
-- rebuild. The command mirrors the operator path (run.sh <T> <OUTLOG>);
-- the success marker is the suite's own complete-run line.
{ project = "tessera"
, kind = "host-verify"
, arch = "host"
, config = "cbmc-sanity"
, workDir = "/home/nyc/src/tessera"
, command = "bash /home/nyc/src/tessera/property2/cbmc/run.sh /home/nyc/src/tessera /home/nyc/src/tessera/property2/cbmc/cbmc-sanity.log"
, successMarkers = [ "SUITE OK" ]
, waiveBaseline = [] : List Text
, logSchema = None Text
, proofHygiene = None Text
, exitMustSucceed = True
, timeoutSeconds = 1800
}
