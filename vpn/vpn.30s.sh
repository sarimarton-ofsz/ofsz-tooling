#!/usr/bin/env bash

# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>false</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

VPN_DIR="$HOME/.config/ofsz-tooling/vpn"
VPN="$VPN_DIR/vpn"
TS_CLI="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

# ── Config ──────────────────────────────────────────────────
WG_ENABLED=true
[ -f "$VPN_DIR/config" ] && source "$VPN_DIR/config"

# ── Fast status checks (no AppleScript — pure process/route detection) ──

fast_ts_status() {
    local raw
    raw=$("$TS_CLI" status 2>&1) && { echo "connected"; return; }
    if echo "$raw" | grep -q "stopped"; then echo "stopped"; else echo "unknown"; fi
}

fast_aws_status() {
    local pid
    pid=$(cat "$VPN_DIR/run/openvpn.pid" 2>/dev/null) || true
    if [[ -n "$pid" ]] && ps -p "$pid" &>/dev/null; then
        echo "connected"; return
    fi
    if pgrep -qf "acvc-openvpn" 2>/dev/null; then
        echo "connected"; return
    fi
    echo "disconnected"
}

fast_wg_status() {
    local ts_iface aws_iface exclude
    ts_iface=$(netstat -rn -f inet 2>/dev/null | awk '/100\.64\/10.*utun/{print $NF}')
    aws_iface=$(grep -o 'utun[0-9]*' "$VPN_DIR/run/openvpn.log" 2>/dev/null | tail -1)
    exclude="${ts_iface:-__ts__}|${aws_iface:-__aws__}"

    if netstat -rn -f inet 2>/dev/null | grep utun | grep -vE "$exclude" \
         | grep -qE "^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)"; then
        echo "connected"
    elif pgrep -qf "WatchGuard Mobile VPN" 2>/dev/null; then
        echo "disconnected"
    else
        echo "unknown"
    fi
}

# ── Network detail helpers (for tooltips) ────────────────

ts_detail() {
    if [[ "$ts" != "connected" ]]; then return; fi
    local ip iface
    iface=$(netstat -rn -f inet 2>/dev/null | awk '/100\.64\/10.*utun/{print $NF}')
    ip=$("$TS_CLI" ip -4 2>/dev/null | head -1)
    echo "IP: ${ip:-?}\\nInterface: ${iface:-?}"
}

aws_detail() {
    if [[ "$aws" != "connected" ]]; then return; fi
    local iface ip gw
    iface=$(grep -o 'utun[0-9]*' "$VPN_DIR/run/openvpn.log" 2>/dev/null | tail -1)
    ip=$(grep -o 'ifconfig [^ ]* [0-9.]*' "$VPN_DIR/run/openvpn.log" 2>/dev/null | tail -1 | awk '{print $3}')
    gw=$(netstat -rn -f inet 2>/dev/null | awk "/${iface:-__none__}/"'{if($1 ~ /^10\.254/){print $2; exit}}')
    echo "IP: ${ip:-?}\\nInterface: ${iface:-?}\\nGateway: ${gw:-?}"
}

# ── Gather status ──────────────────────────────────────────

ts=$(fast_ts_status)
aws=$(fast_aws_status)
if [[ "$WG_ENABLED" == "true" ]]; then
    wg=$(fast_wg_status)
else
    wg="disabled"
fi

# ── AWS auto-reconnect (if dropped unexpectedly) ─────────
RECONNECT_FLAG="$VPN_DIR/run/aws-auto-reconnect"
RECONNECT_LOCK="$VPN_DIR/run/reconnect.lock"
OVPN_BIN="/Applications/AWS VPN Client/AWS VPN Client.app/Contents/Resources/openvpn/acvc-openvpn"
if [[ "$aws" == "disconnected" ]] && [[ -f "$RECONNECT_FLAG" ]]; then
    if ! [ -f /etc/sudoers.d/vpn-aws ]; then
        # Passwordless sudo not configured — can't reconnect without terminal
        aws="no-sudo"
    else
        reconnect_pid=$(cat "$RECONNECT_LOCK" 2>/dev/null) || true
        if [[ -n "$reconnect_pid" ]] && kill -0 "$reconnect_pid" 2>/dev/null; then
            aws="reconnecting"
        else
            nohup bash -c 'echo $$ > "$3" && "$1" aws-up &>"$2"; rm -f "$3"' \
                _ "$VPN" "$VPN_DIR/run/reconnect.log" "$RECONNECT_LOCK" </dev/null &
            aws="reconnecting"
        fi
    fi
fi

status_color() {
    case "$1" in
        connected)              echo "#33CC33" ;;
        disconnected|stopped)   echo "#FF3B30" ;;
        connecting|reconnecting) echo "#E6B310" ;;
        no-sudo)                echo "#FF6B00" ;;
        *)                      echo "#888888" ;;
    esac
}

n=0
expected=0
[[ "$ts"  == "connected" ]] && ((n++)) || true
[[ "$aws" == "connected" ]] && ((n++)) || true
[[ "$WG_ENABLED" == "true" ]] && [[ "$wg" == "connected" ]] && ((n++)) || true
# Count how many VPNs are configured (expected to be connected)
((expected++)) || true  # Tailscale always expected
((expected++)) || true  # AWS always expected
[[ "$WG_ENABLED" == "true" ]] && ((expected++)) || true

# ── Menu bar (ANSI 16-color for text, sfcolor for icon) ───
A_RST=$'\033[0m'
A_GREEN=$'\033[32m'
A_YELLOW=$'\033[33m'
A_DIM=$'\033[38;5;243m'

if (( n == expected )); then
    echo "${A_GREEN}✓${A_RST} | ansi=true sfimage=lock.shield.fill sfcolor=#34C759 sfsize=14"
elif (( n > 0 )); then
    echo "${A_YELLOW}$n/$expected${A_RST} | ansi=true sfimage=lock.shield.fill sfcolor=#E6B310 sfsize=14"
else
    echo "${A_DIM}—${A_RST} | ansi=true sfimage=lock.shield sfcolor=#8E8E93 sfsize=14"
fi

echo "---"

# ── VPN toggles (click to connect/disconnect) ─────────────

ts_iface=$(netstat -rn -f inet 2>/dev/null | awk '/100\.64\/10.*utun/{print $NF}')
aws_iface=$(grep -o 'utun[0-9]*' "$VPN_DIR/run/openvpn.log" 2>/dev/null | tail -1)

ts_tt=$(ts_detail)
aws_tt=$(aws_detail)

# AWS VPN
aws_extra=""
[[ -n "$aws_tt" ]] && aws_extra=" tooltip=$aws_tt"
if [[ "$aws" == "connected" ]]; then
    echo "AWS VPN | size=13 color=$(status_color "$aws") checked=true badge=$aws_iface bash=$VPN param1=aws-down terminal=false refresh=true${aws_extra}"
    echo "AWS VPN (verbose) | size=13 color=$(status_color "$aws") checked=true bash=$VPN param1=aws-down terminal=true refresh=true alternate=true"
elif [[ "$aws" == "no-sudo" ]]; then
    echo "AWS VPN ⚠ sudo | size=13 color=$(status_color "$aws") bash=$VPN param1=aws-up terminal=true refresh=true"
else
    echo "AWS VPN | size=13 color=$(status_color "$aws") bash=$VPN param1=aws-up terminal=false refresh=true"
    echo "AWS VPN (verbose) | size=13 color=$(status_color "$aws") bash=$VPN param1=aws-up terminal=true refresh=true alternate=true"
fi

# WatchGuard
if [[ "$WG_ENABLED" == "true" ]]; then
    if [[ "$wg" == "connected" ]]; then
        echo "WatchGuard | size=13 color=$(status_color "$wg") checked=true bash=$VPN param1=wg-down terminal=false refresh=true"
        echo "WatchGuard (verbose) | size=13 color=$(status_color "$wg") checked=true bash=$VPN param1=wg-down terminal=true refresh=true alternate=true"
    else
        echo "WatchGuard | size=13 color=$(status_color "$wg") bash=$VPN param1=wg-up terminal=true refresh=true"
    fi
fi

# Tailscale
ts_extra=""
[[ -n "$ts_tt" ]] && ts_extra=" tooltip=$ts_tt"
if [[ "$ts" == "connected" ]]; then
    echo "Tailscale | size=13 color=$(status_color "$ts") checked=true badge=$ts_iface bash=$VPN param1=ts-down terminal=false refresh=true${ts_extra}"
    echo "Tailscale (verbose) | size=13 color=$(status_color "$ts") checked=true bash=$VPN param1=ts-down terminal=true refresh=true alternate=true"
else
    echo "Tailscale | size=13 color=$(status_color "$ts") bash=$VPN param1=ts-up terminal=false refresh=true"
    echo "Tailscale (verbose) | size=13 color=$(status_color "$ts") bash=$VPN param1=ts-up terminal=true refresh=true alternate=true"
fi

echo "---"

echo "Reconnect All | bash=$VPN param1=preset param2=all terminal=true refresh=true"
echo "Kill All | bash=$VPN param1=kill-all terminal=true refresh=true color=#FF3B30"
echo "---"
echo "Diagnostics | bash=$VPN param1=check terminal=true color=#888888"
