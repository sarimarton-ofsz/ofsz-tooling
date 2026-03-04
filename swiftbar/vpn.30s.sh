#!/usr/bin/env bash

# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>false</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

VPN_DIR="$HOME/.config/vpn"
VPN="$VPN_DIR/vpn"
TS_CLI="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

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
wg=$(fast_wg_status)

status_color() {
    case "$1" in
        connected)            echo "#33CC33" ;;
        disconnected|stopped) echo "#FF3B30" ;;
        connecting)           echo "#E6B310" ;;
        *)                    echo "#888888" ;;
    esac
}

icon() {
    case "$1" in
        connected)            echo "🟢" ;;
        disconnected|stopped) echo "🔴" ;;
        connecting)           echo "🟡" ;;
        *)                    echo "⚪" ;;
    esac
}

n=0
[[ "$ts"  == "connected" ]] && ((n++)) || true
[[ "$aws" == "connected" ]] && ((n++)) || true
[[ "$wg"  == "connected" ]] && ((n++)) || true

# ── Menu bar ───────────────────────────────────────────────

if (( n > 0 )); then
    echo "$n | sfimage=lock.shield.fill sfcolor=#34C759 sfsize=14"
else
    echo "| sfimage=lock.shield sfcolor=#8E8E93 sfsize=14"
fi

echo "---"

# ── Status (with tooltips, badges, checked) ──────────────

ts_iface=$(netstat -rn -f inet 2>/dev/null | awk '/100\.64\/10.*utun/{print $NF}')
aws_iface=$(grep -o 'utun[0-9]*' "$VPN_DIR/run/openvpn.log" 2>/dev/null | tail -1)

ts_tt=$(ts_detail)
aws_tt=$(aws_detail)

ts_extra=""
[[ "$ts" == "connected" ]]  && ts_extra=" checked=true badge=$ts_iface"
[[ -n "$ts_tt" ]]           && ts_extra="$ts_extra tooltip=$ts_tt"

aws_extra=""
[[ "$aws" == "connected" ]] && aws_extra=" checked=true badge=$aws_iface"
[[ -n "$aws_tt" ]]          && aws_extra="$aws_extra tooltip=$aws_tt"

wg_extra=""
[[ "$wg" == "connected" ]]  && wg_extra=" checked=true"

echo "$(icon "$ts")  Tailscale — $ts | size=13 color=$(status_color "$ts")${ts_extra}"
echo "$(icon "$aws")  AWS VPN — $aws | size=13 color=$(status_color "$aws")${aws_extra}"
echo "$(icon "$wg")  WatchGuard — $wg | size=13 color=$(status_color "$wg")${wg_extra}"

echo "---"

# ── Presets (with shortcuts) ─────────────────────────────

echo "Presets | sfimage=square.stack.3d.up size=13"
echo "-- All Three | bash=$VPN param1=preset param2=all terminal=true refresh=true shortcut=CMD+OPT+1"
echo "-- AWS + Tailscale | bash=$VPN param1=preset param2=aws-ts terminal=true refresh=true shortcut=CMD+OPT+2"

echo "---"

# ── Individual controls (with alternate for verbose mode) ─

if [[ "$ts" == "connected" ]]; then
    echo "Disconnect Tailscale | bash=$VPN param1=ts-down terminal=false refresh=true sfimage=arrow.down.circle color=#E65A26"
    echo "Disconnect Tailscale (verbose) | bash=$VPN param1=ts-down terminal=true refresh=true sfimage=arrow.down.circle color=#E65A26 alternate=true"
else
    echo "Connect Tailscale | bash=$VPN param1=ts-up terminal=false refresh=true sfimage=arrow.up.circle color=#33CC33"
    echo "Connect Tailscale (verbose) | bash=$VPN param1=ts-up terminal=true refresh=true sfimage=arrow.up.circle color=#33CC33 alternate=true"
fi

if [[ "$aws" == "connected" ]]; then
    echo "Disconnect AWS VPN | bash=$VPN param1=aws-down terminal=false refresh=true sfimage=arrow.down.circle color=#E65A26"
    echo "Disconnect AWS VPN (verbose) | bash=$VPN param1=aws-down terminal=true refresh=true sfimage=arrow.down.circle color=#E65A26 alternate=true"
else
    echo "Connect AWS VPN | bash=$VPN param1=aws-up terminal=true refresh=true sfimage=arrow.up.circle color=#33CC33"
fi

if [[ "$wg" == "connected" ]]; then
    echo "Disconnect WatchGuard | bash=$VPN param1=wg-down terminal=false refresh=true sfimage=arrow.down.circle color=#E65A26"
    echo "Disconnect WatchGuard (verbose) | bash=$VPN param1=wg-down terminal=true refresh=true sfimage=arrow.down.circle color=#E65A26 alternate=true"
else
    echo "Connect WatchGuard | bash=$VPN param1=wg-up terminal=true refresh=true sfimage=arrow.up.circle color=#33CC33"
fi

echo "---"

# ── Utilities ────────────────────────────────────────────

echo "Kill All | bash=$VPN param1=kill-all terminal=true refresh=true sfimage=xmark.shield color=#FF3B30"
echo "Diagnostics | bash=$VPN param1=check terminal=true sfimage=stethoscope color=#888888"
echo "---"
echo "Refresh | refresh=true sfimage=arrow.clockwise"
