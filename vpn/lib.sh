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

# ── Tailscale exit node ────────────────────────────────────────────
TS_EXIT_NODE_DEFAULT="${TS_EXIT_NODE_DEFAULT:-neobank-ci}"

ts_exit_node_current() {
    # Prints the hostname of the currently active exit node, empty if none.
    "$TS_CLI" status --json 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
en = d.get("ExitNodeStatus") or {}
eid = en.get("ID", "")
if not eid: sys.exit(0)
for p in (d.get("Peer") or {}).values():
    if p.get("ID") == eid:
        print(p.get("HostName") or (p.get("DNSName") or "").split(".")[0])
        break
' 2>/dev/null
}

ts_exit_on() {
    local node="${1:-$TS_EXIT_NODE_DEFAULT}"
    log "Tailscale: exit node → $node (LAN access allowed)"
    if ! "$TS_CLI" set --exit-node="$node" --exit-node-allow-lan-access=true 2>&1; then
        err "Failed to set exit node to '$node'. Is it advertising and approved in the admin console?"
        return 1
    fi
    ok "Exit node: $node"
}

ts_exit_off() {
    log "Tailscale: disabling exit node..."
    if ! "$TS_CLI" set --exit-node= 2>&1; then
        err "Failed to clear exit node"
        return 1
    fi
    ok "Exit node: off"
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
        rm -f "$DATA_DIR/run/reconnect-aws-failures"
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
        rm -f "$DATA_DIR/run/reconnect-aws-failures"
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
GP_DNS_SERVERS=("10.10.122.6" "10.10.122.7")
GP_DNS_DOMAINS=("ofsz.local" "ofsz.hu")
GP_PID_FILE="$DATA_DIR/run/globalprotect.pid"
GP_LOG_FILE="$DATA_DIR/run/globalprotect.log"
GP_RECONNECT_FLAG="$DATA_DIR/run/gp-auto-reconnect"
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

gp_cleanup_stale() {
    # Clean up leftover state from a crashed openconnect session.
    # Called when GP is detected as disconnected but resolver/hosts entries remain.
    local cleaned=false
    for domain in "${GP_DNS_DOMAINS[@]}"; do
        if [ -f "/etc/resolver/$domain" ]; then
            sudo rm -f "/etc/resolver/$domain" 2>/dev/null || true
            cleaned=true
        fi
    done
    if grep -q "$GP_PORTAL" /etc/hosts 2>/dev/null; then
        sudo sed -i '' "/$GP_PORTAL/d" /etc/hosts 2>/dev/null || true
        cleaned=true
    fi
    $cleaned && log "GlobalProtect: cleaned up stale DNS/hosts from crashed session"
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

    # Clean up stale resolver files from a previous session that may have
    # crashed without running gp_down. These files route *.ofsz.hu queries
    # to corporate DNS (10.10.122.x) which is unreachable when GP is down,
    # preventing us from resolving the portal hostname.
    for domain in "${GP_DNS_DOMAINS[@]}"; do
        sudo rm -f "/etc/resolver/$domain" 2>/dev/null || true
    done

    # Resolve portal IP ourselves — sudo openconnect's getaddrinfo can fail
    # after Tailscale cycling even though user-level DNS works fine.
    # When AWS VPN is up, the default resolver may point to corporate DNS
    # which can't resolve the public GP portal — fall back to public DNS.
    local portal_ip
    portal_ip=$(dig +short "$GP_PORTAL" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
    if [ -z "$portal_ip" ]; then
        # Retry with DNS flush
        sudo dscacheutil -flushcache 2>/dev/null || true
        sudo killall -HUP mDNSResponder 2>/dev/null || true
        local d=0
        while [ $d -lt 5 ]; do
            portal_ip=$(dig +short "$GP_PORTAL" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
            [ -n "$portal_ip" ] && break
            sleep 1
            d=$((d + 1))
        done
    fi
    if [ -z "$portal_ip" ]; then
        # Default resolver failed — try public DNS directly
        for dns in 1.1.1.1 8.8.8.8; do
            portal_ip=$(dig +short "$GP_PORTAL" "@$dns" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
            [ -n "$portal_ip" ] && { log "Resolved $GP_PORTAL via $dns"; break; }
        done
    fi
    if [ -z "$portal_ip" ]; then
        err "GlobalProtect: DNS cannot resolve $GP_PORTAL"
        return 1
    fi

    # Ensure /etc/hosts has the portal entry so sudo openconnect can resolve it
    if ! grep -q "$GP_PORTAL" /etc/hosts 2>/dev/null; then
        echo "$portal_ip $GP_PORTAL" | sudo tee -a /etc/hosts > /dev/null 2>&1 \
            || warn "Could not add $GP_PORTAL to /etc/hosts (no sudo?)"
    fi

    # Set up /etc/resolver/ files for split-DNS (macOS native per-domain DNS).
    # The vpnc-script wrapper strips DNS vars so openconnect won't override
    # system DNS; these files route only corporate domains to corporate DNS.
    # Non-fatal: split-DNS is important but should not block the connection.
    if sudo mkdir -p /etc/resolver 2>/dev/null; then
        for domain in "${GP_DNS_DOMAINS[@]}"; do
            printf 'nameserver %s\n' "${GP_DNS_SERVERS[@]}" | sudo tee "/etc/resolver/$domain" > /dev/null 2>&1 \
                || warn "Could not write /etc/resolver/$domain"
        done
    else
        warn "Could not create /etc/resolver/ (no sudo?) — split-DNS won't work"
    fi

    # Pipe password + gateway selection (openconnect reads both from stdin)
    if ! printf '%s\n%s\n' "$password" "$GP_GATEWAY" | sudo "$OPENCONNECT_BIN" \
        --protocol=gp \
        --user="$user" \
        --passwd-on-stdin \
        --script="$SCRIPT_DIR/gp-vpnc-script.sh" \
        --background \
        --pid-file="$GP_PID_FILE" \
        --reconnect-timeout=0 \
        "$GP_PORTAL" \
        >> "$GP_LOG_FILE" 2>&1; then
        err "GlobalProtect: openconnect failed (see $GP_LOG_FILE)"
        return 1
    fi

    # Wait for tunnel to come up
    local i=0
    while [ $i -lt 10 ]; do
        if [ "$(gp_status)" = "connected" ]; then
            touch "$GP_RECONNECT_FLAG"
            ok "GlobalProtect: connected"
            return 0
        fi
        sleep 2
        i=$((i + 1))
    done
    err "GlobalProtect: timeout after 20s"
    return 1
}

gp_down() {
    rm -f "$GP_RECONNECT_FLAG"
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

    # Clean up split-DNS resolver files
    for domain in "${GP_DNS_DOMAINS[@]}"; do
        sudo rm -f "/etc/resolver/$domain" 2>/dev/null || true
    done

    # Remove /etc/hosts entry added by gp_up
    if grep -q "$GP_PORTAL" /etc/hosts 2>/dev/null; then
        sudo sed -i '' "/$GP_PORTAL/d" /etc/hosts 2>/dev/null || true
    fi

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
GP_HEALTH_URL="https://jc360.ofsz.hu/Login/"
AWS_HEALTH_URL="https://jenkins.devops.local.ofsz.cloud/job/ofsz-neobank-web-build/"

net_check() {
    log "Network diagnostics:"
    echo "  Default gateway:  $(netstat -rn -f inet 2>/dev/null | awk '/^default/{print $2; exit}')"
    echo "  Tailscale:        $(ts_status)"
    echo "  AWS VPN:          $(aws_vpn_status)"
    [[ "$GP_ENABLED" == "true" ]] && echo "  GlobalProtect:    $(gp_status)"
    echo "  Internet (1.1.1.1): $(ping -c1 -W2 1.1.1.1 &>/dev/null && echo "ok" || echo "FAIL")"
    echo "  DNS (google.com):   $(ping -c1 -W2 google.com &>/dev/null && echo "ok" || echo "FAIL")"
    # VPN health checks — verify actual connectivity through tunnels
    [[ "$GP_ENABLED" == "true" ]] && [[ "$(gp_status)" == "connected" ]] && \
        echo "  GP health:         $(curl -so /dev/null -w '%{http_code}' --max-time 5 "$GP_HEALTH_URL" 2>/dev/null | grep -q '^[23]' && echo "ok" || echo "FAIL ($GP_HEALTH_URL)")"
    [[ "$(aws_vpn_status)" == "connected" ]] && \
        echo "  AWS health:        $(curl -so /dev/null -w '%{http_code}' --max-time 5 "$AWS_HEALTH_URL" 2>/dev/null | grep -q '^[23]' && echo "ok" || echo "FAIL ($AWS_HEALTH_URL)")"
}

route_snapshot() {
    log "Route table snapshot:"
    netstat -rn -f inet 2>/dev/null | grep -E "^(default|10\.|100\.|172\.)" | head -20
}
