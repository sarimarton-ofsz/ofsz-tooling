#!/usr/bin/env bash
# Tests for vpn.30s.sh fast status logic — the "connecting" flag-file handling.
# Run: bash vpn/tests/test-plugin-status.sh
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$TESTS_DIR/../vpn.30s.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/run"

# Point the plugin at the fixture dir and source only its functions
export VPN_DIR="$TMP"
VPN_30S_TEST=1 source "$PLUGIN"

# Shadow process checks so the host machine's live VPN state can't leak in
ps()    { return 1; }
pgrep() { return 1; }

fail=0
assert_eq() {
    local got="$1" want="$2" msg="$3"
    if [[ "$got" == "$want" ]]; then
        echo "ok   — $msg"
    else
        echo "FAIL — $msg: expected '$want', got '$got'"
        fail=1
    fi
}

# ── AWS ─────────────────────────────────────────────────────
assert_eq "$(fast_aws_status)" "disconnected" "aws: no flag, no process → disconnected"

echo "Entra login — 2FA…" > "$TMP/run/aws-connecting"
assert_eq "$(fast_aws_status)" "connecting" "aws: fresh connecting flag → connecting"

touch -t 202601010000 "$TMP/run/aws-connecting"
assert_eq "$(fast_aws_status)" "disconnected" "aws: stale connecting flag (crashed connect) → disconnected"

echo "x" > "$TMP/run/aws-connecting"
echo "12345" > "$TMP/run/openvpn.pid"
ps() { return 0; }  # pid alive
assert_eq "$(fast_aws_status)" "connected" "aws: live pid wins over connecting flag"
ps() { return 1; }
rm -f "$TMP/run/aws-connecting" "$TMP/run/openvpn.pid"

# ── GlobalProtect ───────────────────────────────────────────
assert_eq "$(fast_gp_status)" "disconnected" "gp: no flag, no process → disconnected"

echo "kapcsolódás…" > "$TMP/run/gp-connecting"
assert_eq "$(fast_gp_status)" "connecting" "gp: fresh connecting flag → connecting"

touch -t 202601010000 "$TMP/run/gp-connecting"
assert_eq "$(fast_gp_status)" "disconnected" "gp: stale connecting flag → disconnected"

echo
if [[ $fail -eq 0 ]]; then
    echo "ALL PASS"
else
    echo "FAILURES"
fi
exit $fail
