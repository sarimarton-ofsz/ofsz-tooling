#!/usr/bin/env bash
# VPN control library — shared functions for all VPN scripts
# Source this file, do not execute directly.

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────
DATA_DIR="$HOME/.config/ofsz-tooling/vpn"

# ── Config ──────────────────────────────────────────────────────────
GP_ENABLED=true
CONFIG_FILE="$DATA_DIR/config"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# ── Colors ──────────────────────────────────────────────────────────
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; BLUE="\033[0;34m"; NC="\033[0m"

log()  { echo -e "${BLUE}[vpn]${NC} $*"; }
ok()   { echo -e "${GREEN}[vpn ✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[vpn !]${NC} $*"; }
err()  { echo -e "${RED}[vpn ✗]${NC} $*" >&2; }

# ── Tailscale ───────────────────────────────────────────────────────
TS_CLI="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

ts_status() {
    # Returns: connected | stopped | unknown
    local raw
    raw=$("$TS_CLI" status 2>&1) && echo "connected" && return
    if echo "$raw" | grep -q "stopped"; then
        echo "stopped"
    else
        echo "unknown"
    fi
}

ts_up() {
    log "Tailscale: connecting..."
    "$TS_CLI" up 2>&1
    local i=0
    while [ $i -lt 15 ]; do
        if [ "$(ts_status)" = "connected" ]; then
            ok "Tailscale: connected"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    err "Tailscale: timeout after 15s"
    return 1
}

ts_down() {
    log "Tailscale: disconnecting..."
    "$TS_CLI" down 2>&1
    local i=0
    while [ $i -lt 10 ]; do
        if [ "$(ts_status)" = "stopped" ]; then
            ok "Tailscale: disconnected"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    err "Tailscale: disconnect timeout"
    return 1
}

# ── Tailscale safety watchdog ──────────────────────────────────────
# Background process that restores Tailscale after 3 minutes if it's still down.
# Protects against AWS Entra SAML flow hanging and leaving Tailscale disconnected.
TS_WATCHDOG_PID=""
TS_WATCHDOG_TIMEOUT=180  # 3 minutes

ts_watchdog_start() {
    (
        sleep $TS_WATCHDOG_TIMEOUT
        if [ "$(ts_status)" != "connected" ]; then
            warn "Tailscale watchdog: ${TS_WATCHDOG_TIMEOUT}s timeout — forcing restore"
            ts_up || true
        fi
    ) &
    TS_WATCHDOG_PID=$!
    log "Tailscale safety watchdog started (${TS_WATCHDOG_TIMEOUT}s timeout, pid $TS_WATCHDOG_PID)"
}

ts_watchdog_stop() {
    if [ -n "$TS_WATCHDOG_PID" ]; then
        kill "$TS_WATCHDOG_PID" 2>/dev/null || true
        wait "$TS_WATCHDOG_PID" 2>/dev/null || true
        TS_WATCHDOG_PID=""
    fi
}

# ── AWS VPN Client ──────────────────────────────────────────────────
# Uses aws-connect.sh (CLI openvpn + SAML capture) instead of the GUI app.
AWS_VPN_PID_FILE="$DATA_DIR/run/openvpn.pid"
AWS_VPN_RECONNECT_FLAG="$DATA_DIR/run/aws-auto-reconnect"

aws_vpn_status() {
    # Check CLI-based VPN (process runs as root — use ps, not kill -0)
    local pid; pid=$(cat "$AWS_VPN_PID_FILE" 2>/dev/null) || true
    if [ -n "$pid" ] && ps -p "$pid" &>/dev/null; then
        echo "connected"
        return
    fi
    # Fallback: PID file may be missing but daemon still running
    if pgrep -f "acvc-openvpn.*aws-vpn-cli" &>/dev/null; then
        echo "connected"
        return
    fi
    # Check if the GUI client is connected (fallback)
    local statusbar
    statusbar=$(osascript -e '
tell application "System Events"
    tell process "AWS VPN Client"
        return name of menu item 1 of menu 1 of menu bar item 1 of menu bar 2
    end tell
end tell' 2>/dev/null) || { echo "disconnected"; return; }
    case "$statusbar" in
        *"Disconnect from:"*) echo "connected" ;;
        *)                    echo "disconnected" ;;
    esac
}

aws_vpn_up() {
    if [ "$(aws_vpn_status)" = "connected" ]; then
        ok "AWS VPN: already connected"
        touch "$AWS_VPN_RECONNECT_FLAG"
        rm -f "$DATA_DIR/run/reconnect-failures"
        return 0
    fi

    # If Tailscale is up, disconnect it first — AWS VPN sets aggressive routes
    # that conflict. Tailscale is restored after successful connect.
    # Safety: a watchdog timer ensures Tailscale is restored within 3 minutes
    # even if the AWS Entra SAML flow hangs or crashes.
    local ts_was_up=false
    if [ "$(ts_status)" = "connected" ]; then
        ts_was_up=true
        log "Tailscale is up — disconnecting before AWS connect..."
        ts_down || true
        ts_watchdog_start
    fi

    log "AWS VPN: connecting via CLI (SAML)..."
    if "$SCRIPT_DIR/aws-connect.sh" up; then
        touch "$AWS_VPN_RECONNECT_FLAG"
        rm -f "$DATA_DIR/run/reconnect-failures"
        if $ts_was_up; then
            ts_watchdog_stop
            log "Restoring Tailscale..."
            ts_up || err "Tailscale restore failed after AWS connect"
        fi
        return 0
    fi

    # AWS failed — restore Tailscale anyway
    if $ts_was_up; then
        ts_watchdog_stop
        log "AWS failed — restoring Tailscale..."
        ts_up || true
    fi
    return 1
}

aws_vpn_down() {
    rm -f "$AWS_VPN_RECONNECT_FLAG"
    if [ "$(aws_vpn_status)" = "disconnected" ]; then
        ok "AWS VPN: already disconnected"
        return 0
    fi
    log "AWS VPN: disconnecting..."
    "$SCRIPT_DIR/aws-connect.sh" down
    # Also kill the GUI if running
    osascript -e 'tell application "AWS VPN Client" to quit' 2>/dev/null || true
    pkill -f "AWS VPN Client.app/Contents/MacOS/AWS VPN Client" 2>/dev/null || true
    ok "AWS VPN: disconnected"
}

# ── GlobalProtect (via openconnect) ───────────────────────────────────
GP_PORTAL="vpn.ofsz.hu"
GP_GATEWAY="OFSZ_GW"
GP_PID_FILE="$DATA_DIR/run/globalprotect.pid"
GP_LOG_FILE="$DATA_DIR/run/globalprotect.log"
GP_KEYCHAIN_PASSWORD="vpn-gp"
GP_KEYCHAIN_USER="vpn-gp-user"
OPENCONNECT_BIN="$(command -v openconnect 2>/dev/null || echo /opt/homebrew/bin/openconnect)"

gp_get_password() {
    local pw
    pw=$(security find-generic-password -s "$GP_KEYCHAIN_PASSWORD" -w 2>/dev/null) && { echo "$pw"; return 0; }
    return 1
}

gp_get_user() {
    local user
    user=$(security find-generic-password -s "$GP_KEYCHAIN_USER" -w 2>/dev/null) && { echo "$user"; return 0; }
    return 1
}

gp_store_credentials() {
    local user="$1" pw="$2"
    security delete-generic-password -s "$GP_KEYCHAIN_USER" 2>/dev/null || true
    security add-generic-password -s "$GP_KEYCHAIN_USER" -a "globalprotect" -w "$user" -T /usr/bin/security 2>/dev/null
    security delete-generic-password -s "$GP_KEYCHAIN_PASSWORD" 2>/dev/null || true
    security add-generic-password -s "$GP_KEYCHAIN_PASSWORD" -a "globalprotect" -w "$pw" -T /usr/bin/security 2>/dev/null
    ok "GlobalProtect: credentials stored in keychain"
}

gp_status() {
    # Returns: connected | disconnected
    local pid; pid=$(cat "$GP_PID_FILE" 2>/dev/null) || true
    if [ -n "$pid" ] && ps -p "$pid" &>/dev/null; then
        echo "connected"
        return
    fi
    if pgrep -qf "openconnect.*--protocol=gp" 2>/dev/null; then
        echo "connected"
        return
    fi
    echo "disconnected"
}

gp_up() {
    if [ "$(gp_status)" = "connected" ]; then
        ok "GlobalProtect: already connected"
        return 0
    fi

    local user password
    if ! user=$(gp_get_user); then
        err "GlobalProtect: no username in keychain"
        err "Run: vpn gp-set-credentials"
        return 1
    fi
    if ! password=$(gp_get_password); then
        err "GlobalProtect: no password in keychain"
        err "Run: vpn gp-set-credentials"
        return 1
    fi

    log "GlobalProtect: connecting to $GP_PORTAL..."

    # Pipe password + gateway selection (openconnect reads both from stdin)
    printf '%s\n%s\n' "$password" "$GP_GATEWAY" | sudo "$OPENCONNECT_BIN" \
        --protocol=gp \
        --user="$user" \
        --passwd-on-stdin \
        --background \
        --pid-file="$GP_PID_FILE" \
        "$GP_PORTAL" \
        >> "$GP_LOG_FILE" 2>&1

    # Wait for tunnel to come up
    local i=0
    while [ $i -lt 15 ]; do
        if [ "$(gp_status)" = "connected" ]; then
            ok "GlobalProtect: connected"
            return 0
        fi
        sleep 2
        i=$((i + 1))
    done
    err "GlobalProtect: timeout after 30s"
    return 1
}

gp_down() {
    if [ "$(gp_status)" = "disconnected" ]; then
        ok "GlobalProtect: already disconnected"
        return 0
    fi

    log "GlobalProtect: disconnecting..."
    local pid; pid=$(cat "$GP_PID_FILE" 2>/dev/null) || true
    if [ -n "$pid" ]; then
        sudo kill "$pid" 2>/dev/null || true
    fi
    # Fallback: kill by pattern
    sudo pkill -f "openconnect.*--protocol=gp" 2>/dev/null || true
    rm -f "$GP_PID_FILE"

    local i=0
    while [ $i -lt 10 ]; do
        if [ "$(gp_status)" = "disconnected" ]; then
            ok "GlobalProtect: disconnected"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    err "GlobalProtect: disconnect timeout"
    return 1
}

# ── Network diagnostics ────────────────────────────────────────────
net_check() {
    log "Network diagnostics:"
    echo "  Default gateway:  $(netstat -rn -f inet 2>/dev/null | awk '/^default/{print $2; exit}')"
    echo "  Tailscale:        $(ts_status)"
    echo "  AWS VPN:          $(aws_vpn_status)"
    [[ "$GP_ENABLED" == "true" ]] && echo "  GlobalProtect:    $(gp_status)"
    echo "  Internet (1.1.1.1): $(ping -c1 -W2 1.1.1.1 &>/dev/null && echo "ok" || echo "FAIL")"
    echo "  DNS (google.com):   $(ping -c1 -W2 google.com &>/dev/null && echo "ok" || echo "FAIL")"
}

route_snapshot() {
    log "Route table snapshot:"
    netstat -rn -f inet 2>/dev/null | grep -E "^(default|10\.|100\.|172\.)" | head -20
}
