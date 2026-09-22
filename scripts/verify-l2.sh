#!/usr/bin/env bash
# L2 component probes (TESTING_VERIFICATION_STRATEGY §2.3).
# Exit non-zero on any regression. Run: make l2  (or bash scripts/verify-l2.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

TARGETS_DIR="$ROOT/shikumi-campaign/targets"
CAMPAIGN_BIN="${CAMPAIGN_BIN:-$(cabal list-bin campaign-demo 2>/dev/null || true)}"
RECEIPT_BIN="${RECEIPT_BIN:-$(cabal list-bin repair-receipt 2>/dev/null || true)}"

if [[ -z "$CAMPAIGN_BIN" || ! -x "$CAMPAIGN_BIN" ]]; then
  echo "building campaign-demo…" >&2
  cabal build campaign-demo -v0
  CAMPAIGN_BIN="$(cabal list-bin campaign-demo)"
fi
if [[ -z "$RECEIPT_BIN" || ! -x "$RECEIPT_BIN" ]]; then
  echo "building repair-receipt…" >&2
  cabal build repair-receipt -v0
  RECEIPT_BIN="$(cabal list-bin repair-receipt)"
fi

# ---------------------------------------------------------------------------
# 1. Manifest discovery flip: count with vs without targets/, and both
#    manifest cells present when the directory is visible.
# ---------------------------------------------------------------------------
count_with() {
  CAMPAIGN_TARGETS_DIR="$TARGETS_DIR" DISCOVER=json "$CAMPAIGN_BIN" 2>/dev/null \
    | python3 -c 'import json,sys
raw=sys.stdin.read(); i=raw.find("[")
print(len(json.loads(raw[i:])))'
}
count_without() {
  CAMPAIGN_TARGETS_DIR=/nonexistent DISCOVER=json "$CAMPAIGN_BIN" 2>/dev/null \
    | python3 -c 'import json,sys
raw=sys.stdin.read(); i=raw.find("[")
print(len(json.loads(raw[i:])))'
}

n_with=$(count_with)
n_without=$(count_without)
[[ "$n_with" -gt "$n_without" ]] || fail "discovery flip: with=$n_with without=$n_without (expected with > without)"
delta=$((n_with - n_without))
# mowgli-film-fixture replaces a built-in (same key → count unchanged);
# tessera-cbmc-sanity is a new key → +1. Strategy §2.3 records 99 ↔ 100.
[[ "$delta" -ge 1 ]] || fail "discovery flip: expected >=1 new manifest unit, got $delta"

keys=$(CAMPAIGN_TARGETS_DIR="$TARGETS_DIR" DISCOVER=json "$CAMPAIGN_BIN" 2>/dev/null \
  | python3 -c 'import json,sys
raw=sys.stdin.read(); i=raw.find("[")
for u in json.loads(raw[i:]):
    print("%s/%s@%s" % (u["ruProject"], u["ruArch"], u["ruConfig"]))')
echo "$keys" | grep -qx 'mowgli/host@film-fixture' || fail "missing manifest cell mowgli/host@film-fixture"
echo "$keys" | grep -qx 'tessera/host@cbmc-sanity' || fail "missing manifest cell tessera/host@cbmc-sanity"
ok "discovery flip ($n_without → $n_with, delta=$delta, both manifest cells present)"

# ---------------------------------------------------------------------------
# 2. Waiver gate / CLASSIFY triple on a synthetic log that mirrors the
#    archived m68k_6 shape (69 passed, 2 failed; FAIL LIST fork04 mincore04).
#    m68k has an empty built-in baseline, so the same three controls the
#    WORKQUEUE Milestone 2 run recorded hold without needing the archive.
# ---------------------------------------------------------------------------
CLASSIFY_LOG="$(mktemp /tmp/verify-l2-classify-XXXXXX.log)"
trap 'rm -f "$CLASSIFY_LOG"' EXIT
cat >"$CLASSIFY_LOG" <<'EOF'
=== matrix cell: ARCH=m68k CONFIG=6 ===
  LTP subtotals: 69 passed, 2 failed, 30 skipped
  LTP FAIL LIST: fork04 mincore04
EOF

classify() {
  CLASSIFY="$1" "$CAMPAIGN_BIN" 2>/dev/null | sed -n 's/.*-> //p' | head -1
}

v1=$(classify "m68k:$CLASSIFY_LOG")
[[ "$v1" == "failed" ]] || fail "CLASSIFY bare: expected failed, got '$v1'"

v2=$(classify "m68k@fork04;mincore04:$CLASSIFY_LOG")
[[ "$v2" == "passed-waived" ]] || fail "CLASSIFY exact baseline: expected passed-waived, got '$v2'"

v3=$(classify "m68k@fork04;wrongname:$CLASSIFY_LOG")
[[ "$v3" == "failed" ]] || fail "CLASSIFY wrong-name negative control: expected failed, got '$v3'"
ok "CLASSIFY triple (failed → passed-waived → failed)"

# ---------------------------------------------------------------------------
# 3. Repair receipt validator: ADMISSIBLE + built-in tamper negative control
#    (the exe always runs its own negative control and fails if it holds wrong).
# ---------------------------------------------------------------------------
receipt_out=$("$RECEIPT_BIN" "$ROOT/shikumi-campaign/repairs")
echo "$receipt_out" | grep -q 'ADMISSIBLE' || fail "repair-receipt: no ADMISSIBLE line\n$receipt_out"
echo "$receipt_out" | grep -q 'negative control held' || fail "repair-receipt: tamper control did not hold\n$receipt_out"
ok "repair-receipt (ADMISSIBLE + tamper refused)"

# ---------------------------------------------------------------------------
# 4. Attestation + oracle + receipt unit suites (L1) — hash recompute and
#    pure-oracle negative controls live there; running them here keeps the
#    component gate honest without a second attestation CLI.
# ---------------------------------------------------------------------------
echo "running L1 suites (oracle/receipt/attestation/codegraph/interpreters)…"
cabal test all --test-show-details=direct
ok "L1 suites green"

echo
echo "verify-l2: all probes passed"
