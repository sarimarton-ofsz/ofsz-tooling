#!/usr/bin/env bash
# aws-connect.sh — CLI-based AWS Client VPN with SAML/Entra ID auth
# Replaces the AWS VPN Client GUI entirely.
#
# Usage: ~/.config/ofsz-tooling/vpn/aws-connect.sh [up|down|status]
#
# Runs as YOUR user. Only the final openvpn call uses sudo (for tun device).
# Run `vpn setup-sudoers` once to allow passwordless sudo for the openvpn binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0")")" && pwd)"

# ── Lock (prevent double-run from shell init) ───────────────────────
LOCK_FILE="/tmp/.aws-vpn-lock"
if [ -f "$LOCK_FILE" ] && kill -0 "$(cat "$LOCK_FILE" 2>/dev/null)" 2>/dev/null; then
    exit 0  # silently skip if already running
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# ── Paths ───────────────────────────────────────────────────────────
OVPN_BIN="/Applications/AWS VPN Client/AWS VPN Client.app/Contents/Resources/openvpn/acvc-openvpn"
AWS_CONFIG_DIR="$HOME/.config/AWSVPNClient"
PROFILES_FILE="$AWS_CONFIG_DIR/ConnectionProfiles"
DATA_DIR="$HOME/.config/ofsz-tooling/vpn"
RUNTIME_DIR="$DATA_DIR/run"
mkdir -p "$RUNTIME_DIR"
export PLAYWRIGHT_BROWSERS_PATH="$RUNTIME_DIR/browsers"
SAML_RESPONSE_FILE="$RUNTIME_DIR/saml-response"
OVPN_LOG="$RUNTIME_DIR/openvpn.log"
OVPN_PID_FILE="$RUNTIME_DIR/openvpn.pid"

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; BLUE="\033[0;34m"; NC="\033[0m"
log()  { echo -e "${BLUE}[aws-vpn]${NC} $*" >&2; }
ok()   { echo -e "${GREEN}[aws-vpn ✓]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[aws-vpn !]${NC} $*" >&2; }
err()  { echo -e "${RED}[aws-vpn ✗]${NC} $*" >&2; }


# ── Preflight checks ─────────────────────────────────────────────
# Validates all prerequisites before attempting connection.
# Returns 0 if ready, 1 if something is missing (with actionable message).
preflight_check() {
    local failed=0

    # 1. AWS VPN Client app installed?
    if [ ! -x "$OVPN_BIN" ]; then
        err "AWS VPN Client not installed"
        err "  Install from: https://self-service.clientvpn.amazonaws.com/endpoints/cvpn-endpoint-022755a701a9c6b8c"
        err "  Required: the bundled acvc-openvpn binary"
        failed=1
    fi

    # 2. Connection profile exists? (GUI was configured at least once)
    if [ ! -f "$PROFILES_FILE" ]; then
        err "No AWS VPN connection profile found"
        err "  Open AWS VPN Client GUI → File → Manage Profiles → Add Profile"
        err "  Connect at least once via the GUI, then you can use CLI instead"
        failed=1
    fi

    # 3. OpenVPN config file exists?
    if [ $failed -eq 0 ]; then
        local config_path
        config_path=$(get_ovpn_config 2>/dev/null) || {
            err "OpenVPN config file missing or profile corrupt"
            err "  Re-add the profile in AWS VPN Client GUI"
            failed=1
        }
    fi

    # 4. Node.js + Playwright
    if ! command -v node &>/dev/null; then
        err "Node.js hiányzik — telepítsd újra a toolkitet"
        failed=1
    elif [ ! -d "$SCRIPT_DIR/node_modules/playwright" ]; then
        err "Playwright hiányzik — telepítsd újra a toolkitet"
        failed=1
    fi

    # 5. Sudoers configured? (passwordless openvpn for tun device)
    if ! [ -f /etc/sudoers.d/vpn-aws ]; then
        log "Passwordless sudo not configured — setting up now..."
        local ovpn_bin_escaped="${OVPN_BIN// /\\ }"
        local sudoers_file="/etc/sudoers.d/vpn-aws"
        printf '%s ALL=(ALL) NOPASSWD: %s *\n%s ALL=(ALL) NOPASSWD: /bin/kill *\n' \
            "$USER" "$ovpn_bin_escaped" "$USER" | sudo tee "$sudoers_file" > /dev/null \
            && sudo chmod 440 "$sudoers_file" \
            && sudo visudo -cf "$sudoers_file" &>/dev/null \
            && ok "Sudoers configured" \
            || { err "Sudoers setup failed"; sudo rm -f "$sudoers_file" 2>/dev/null; failed=1; }
    fi

    return $failed
}

# ── Auto-discover profile ──────────────────────────────────────────
get_ovpn_config() {
    local config_path
    config_path=$(python3 -c "
import json, sys
with open('$PROFILES_FILE') as f:
    data = json.load(f)
profiles = data.get('ConnectionProfiles', [])
if not profiles:
    sys.exit(1)
print(profiles[0]['OvpnConfigFilePath'])
" 2>/dev/null) || { err "Failed to parse connection profiles"; return 1; }

    if [ ! -f "$config_path" ]; then
        err "OpenVPN config not found: $config_path"
        return 1
    fi

    echo "$config_path"
}

# ── Phase 1: get SAML URL + SID + server IP (no sudo needed) ────────
# Outputs three lines: SID, server IP, SAML URL
get_saml_info() {
    local ovpn_config="$1"

    log "Csatlakozás az AWS szerverhez..."

    # openvpn connects, gets AUTH_FAILED with CRV1 response — no tun device needed
    # Response format: AUTH_FAILED,CRV1:R:<SID>:<extra>:<SAML_URL>
    local output
    output=$("$OVPN_BIN" \
        --config "$ovpn_config" \
        --verb 3 \
        --auth-retry none \
        --connect-timeout 10 \
        --auth-user-pass <(printf "N/A\nACS::35001\n") \
        2>&1 || true)

    local crv1_line
    crv1_line=$(echo "$output" | grep -o 'CRV1:R:[^ ]*' | head -1)

    if [ -z "$crv1_line" ]; then
        err "Failed to extract CRV1 response"
        echo "$output" | tail -10 >&2
        return 1
    fi

    # Parse CRV1:R:SID:extra:URL — SID is field 3 (colon-delimited)
    local sid
    sid=$(echo "$crv1_line" | cut -d: -f3)

    local saml_url
    saml_url=$(echo "$crv1_line" | grep -oE 'https://[^ ]+')

    # Extract the server IP that Phase 1 connected to (for Phase 2 pinning)
    # remote-random-hostname causes different DNS results each time;
    # we must pin Phase 2 to the same server where the SID was created
    local server_ip
    server_ip=$(echo "$output" | grep -oE 'Peer Connection Initiated with \[AF_INET\][0-9.]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    if [ -z "$sid" ] || [ -z "$saml_url" ]; then
        err "Failed to parse CRV1 response: $crv1_line"
        return 1
    fi

    echo "$sid"
    echo "${server_ip:-}"
    echo "$saml_url"
}

# ── SAML capture + VPN connect ─────────────────────────────────────
do_connect() {
    local ovpn_config="$1"
    local sid="$2"
    local server_ip="$3"
    local saml_url="$4"

    rm -f "$SAML_RESPONSE_FILE"

    local pw_state="$RUNTIME_DIR/pw-state.json"
    local saml_response

    # Try headless first if we have a saved session
    if [ -f "$pw_state" ]; then
        log "Headless SAML (mentett session)..."
        if saml_response=$(node "$SCRIPT_DIR/pw-saml.mjs" saml "$saml_url" "$pw_state" 2>/dev/null); then
            ok "SAML response captured (headless)!"
            echo "$saml_response" > "$SAML_RESPONSE_FILE"
        else
            warn "Headless SAML sikertelen — interaktív login szükséges"
        fi
    fi

    # Fallback: automated login with keychain credentials, or interactive
    if [ ! -s "$SAML_RESPONSE_FILE" ]; then
        local email password
        email=$(security find-generic-password -s "vpn-entra" -a "email" -w 2>/dev/null) || true
        password=$(security find-generic-password -s "vpn-gp" -w 2>/dev/null || security find-generic-password -s "vpn-watchguard" -w 2>/dev/null) || true

        if [ -n "$email" ] && [ -n "$password" ]; then
            log "Automatikus Entra login..."
            if saml_response=$(node "$SCRIPT_DIR/pw-saml.mjs" login "$saml_url" "$pw_state" "$email" "$password" 2>/dev/null); then
                ok "SAML response captured!"
                echo "$saml_response" > "$SAML_RESPONSE_FILE"
            else
                warn "Automatikus login sikertelen — interaktív fallback"
            fi
        fi

        if [ ! -s "$SAML_RESPONSE_FILE" ]; then
            log "Interaktív Entra login..."
            if saml_response=$(node "$SCRIPT_DIR/pw-saml.mjs" login "$saml_url" "$pw_state"); then
                ok "SAML response captured!"
                echo "$saml_response" > "$SAML_RESPONSE_FILE"
            fi
        fi
    fi

    if [ ! -s "$SAML_RESPONSE_FILE" ]; then
        err "SAML auth sikertelen"
        return 1
    fi

    saml_response=$(cat "$SAML_RESPONSE_FILE")

    # Phase 2: VPN connection (sudo needed for tun device)
    log "VPN tunnel felépítése..."
    # Pre-create log+pid as user (writable by root via 666) so we can read them later
    rm -f "$OVPN_PID_FILE" 2>/dev/null || true
    touch "$OVPN_LOG" "$OVPN_PID_FILE"
    chmod 666 "$OVPN_LOG" "$OVPN_PID_FILE"

    # sudo can't access <() process substitution fds — use a temp file
    local auth_file="/tmp/.aws-vpn-auth"
    printf "N/A\nCRV1::%s::%s\n" "$sid" "$saml_response" > "$auth_file"
    chmod 600 "$auth_file"

    # Create modified config pinned to the Phase 1 server IP
    # (remote-random-hostname causes different DNS results per connection;
    #  SID is server-specific so Phase 2 MUST hit the same backend)
    local pinned_config="$RUNTIME_DIR/pinned.ovpn"
    if [ -n "$server_ip" ]; then
        log "Pinning to Phase 1 server: $server_ip"
        sed -e "s/^remote .*/remote $server_ip 443/" \
            -e '/^remote-random-hostname/d' \
            "$ovpn_config" > "$pinned_config"
    else
        cp "$ovpn_config" "$pinned_config"
    fi

    # Skip --up/--down scripts (they need TUNNELBLICK_CONFIG_FOLDER from AWS GUI)
    # Routes are added by openvpn itself via server-pushed directives
    sudo "$OVPN_BIN" \
        --config "$pinned_config" \
        --verb 3 \
        --auth-retry none \
        --auth-user-pass "$auth_file" \
        --script-security 1 \
        --daemon aws-vpn-cli \
        --log-append "$OVPN_LOG" \
        --writepid "$OVPN_PID_FILE"

    # Clean up auth file immediately (openvpn already read it)
    rm -f "$auth_file"

    # Wait for connection
    local j=0
    while [ $j -lt 15 ]; do
        if grep -q "Initialization Sequence Completed" "$OVPN_LOG" 2>/dev/null; then
            ok "VPN connected!"
            rm -f "$SAML_RESPONSE_FILE"
            return 0
        fi
        if grep -q "AUTH_FAILED" "$OVPN_LOG" 2>/dev/null; then
            err "Auth failed — SAML token may have expired"
            tail -5 "$OVPN_LOG" >&2
            return 1
        fi
        sleep 1
        j=$((j + 1))
    done

    err "VPN connection timeout"
    tail -10 "$OVPN_LOG" >&2
    return 1
}

# ── Commands ───────────────────────────────────────────────────────
cmd_up() {
    preflight_check || return 1

    # Kill the GUI client (it fights over tun)
    if pgrep -f "AWS VPN Client.app/Contents/MacOS" >/dev/null 2>&1; then
        warn "Killing AWS VPN Client GUI..."
        osascript -e 'tell application "AWS VPN Client" to quit' 2>/dev/null || true
        pkill -f "AWS VPN Client.app/Contents/MacOS/AWS VPN Client" 2>/dev/null || true
        sudo pkill -f "acvc-openvpn.*--management" 2>/dev/null || true
        sleep 2
    fi

    # Kill any existing CLI VPN
    cmd_down 2>/dev/null || true

    local ovpn_config
    ovpn_config=$(get_ovpn_config) || return 1

    local saml_info sid server_ip saml_url
    saml_info=$(get_saml_info "$ovpn_config") || return 1
    sid=$(echo "$saml_info" | sed -n '1p')
    server_ip=$(echo "$saml_info" | sed -n '2p')
    saml_url=$(echo "$saml_info" | sed -n '3p')
    log "SID: $sid"
    log "Server IP: ${server_ip:-unknown}"
    log "SAML URL: ${saml_url:0:80}..."

    do_connect "$ovpn_config" "$sid" "$server_ip" "$saml_url"
}

cmd_down() {
    # Find the process: PID file first, then pgrep fallback
    local pid
    pid=$(cat "$OVPN_PID_FILE" 2>/dev/null) || true
    if [ -z "$pid" ] || ! ps -p "$pid" &>/dev/null; then
        pid=$(pgrep -f "acvc-openvpn.*aws-vpn-cli" 2>/dev/null | head -1) || true
    fi

    if [ -n "$pid" ] && ps -p "$pid" &>/dev/null; then
        log "Stopping VPN (pid $pid)..."
        sudo kill "$pid" 2>/dev/null
        local i=0
        while [ $i -lt 3 ] && ps -p "$pid" &>/dev/null; do
            sleep 1
            i=$((i + 1))
        done
        if ps -p "$pid" &>/dev/null; then
            sudo kill -9 "$pid" 2>/dev/null || true
        fi
        ok "VPN stopped"
    fi
    rm -f "$OVPN_PID_FILE" "$SAML_RESPONSE_FILE" 2>/dev/null || true
}

cmd_status() {
    # Check PID file first, then fallback to pgrep
    local pid
    pid=$(cat "$OVPN_PID_FILE" 2>/dev/null) || true
    if [ -z "$pid" ] || ! ps -p "$pid" &>/dev/null; then
        # PID file missing or stale — check for orphaned daemon
        pid=$(pgrep -f "acvc-openvpn.*aws-vpn-cli" 2>/dev/null | head -1) || true
    fi
    if [ -n "$pid" ] && ps -p "$pid" &>/dev/null; then
        ok "VPN: connected (pid $pid)"
        grep -o "ifconfig utun[0-9]* [0-9.]*" "$OVPN_LOG" 2>/dev/null | tail -1 || true
        return 0
    else
        echo "VPN: disconnected"
        return 1
    fi
}

case "${1:-up}" in
    up)     cmd_up ;;
    down)   cmd_down ;;
    status) cmd_status ;;
    *)      echo "Usage: $0 [up|down|status]"; exit 1 ;;
esac
