#!/usr/bin/env bash

# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>false</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# SCRIPT_DIR: where scripts live (resolved via symlink from SwiftBar)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || readlink "$0" 2>/dev/null || echo "$0")")" && pwd)"
# VPN_DIR: where runtime data lives
VPN_DIR="$HOME/.config/ofsz-tooling/vpn"
VPN="$SCRIPT_DIR/vpn"
TS_CLI="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

# ── Config ──────────────────────────────────────────────────
GP_ENABLED=true
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

fast_gp_status() {
    local pid
    pid=$(cat "$VPN_DIR/run/globalprotect.pid" 2>/dev/null) || true
    if [[ -n "$pid" ]] && ps -p "$pid" &>/dev/null; then
        echo "connected"; return
    fi
    if pgrep -qf "openconnect.*--protocol=gp" 2>/dev/null; then
        echo "connected"; return
    fi
    echo "disconnected"
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
if [[ "$GP_ENABLED" == "true" ]]; then
    gp=$(fast_gp_status)
else
    gp="disabled"
fi

# ── Auto-reconnect helper ─────────────────────────────────
# Usage: auto_reconnect <vpn-name> <flag-file> <lock-file> <fail-file> <up-command>
# Sets the status variable (by name) to "reconnecting" / "no-sudo" as needed.
auto_reconnect() {
    local name="$1" flag="$2" lock="$3" fail_file="$4" up_cmd="$5"
    local max_retries=3 cooldown=300  # 5 min between retries

    if ! [ -f /etc/sudoers.d/vpn ] && ! [ -f /etc/sudoers.d/vpn-aws ]; then
        echo "no-sudo"; return
    fi

    local failures
    failures=$(cat "$fail_file" 2>/dev/null || echo 0)
    if (( failures >= max_retries )); then
        rm -f "$flag" "$fail_file"
        echo "gave-up"; return
    fi
    if [[ -f "$fail_file" ]] && \
       (( $(date +%s) - $(stat -f %m "$fail_file") < cooldown )); then
        echo "cooldown"; return
    fi

    local reconnect_pid
    reconnect_pid=$(cat "$lock" 2>/dev/null) || true
    if [[ -n "$reconnect_pid" ]] && kill -0 "$reconnect_pid" 2>/dev/null; then
        echo "reconnecting"; return
    fi

    nohup bash -c '
        echo $$ > "$3"
        if "$1" "$5" &>"$2"; then
            rm -f "$4"
        else
            prev=$(cat "$4" 2>/dev/null || echo 0)
            echo $((prev + 1)) > "$4"
        fi
        rm -f "$3"
    ' _ "$VPN" "$VPN_DIR/run/reconnect-${name}.log" "$lock" "$fail_file" "$up_cmd" </dev/null &
    echo "reconnecting"
}

# ── AWS auto-reconnect (if dropped unexpectedly) ─────────
AWS_RECONNECT_FLAG="$VPN_DIR/run/aws-auto-reconnect"
AWS_RECONNECT_LOCK="$VPN_DIR/run/reconnect-aws.lock"
AWS_RECONNECT_FAIL="$VPN_DIR/run/reconnect-aws-failures"
if [[ "$aws" == "disconnected" ]] && [[ -f "$AWS_RECONNECT_FLAG" ]]; then
    aws=$(auto_reconnect "aws" "$AWS_RECONNECT_FLAG" "$AWS_RECONNECT_LOCK" "$AWS_RECONNECT_FAIL" "aws-up")
fi

# ── GP auto-reconnect (if crashed, e.g. network change) ──
GP_RECONNECT_FLAG="$VPN_DIR/run/gp-auto-reconnect"
GP_RECONNECT_LOCK="$VPN_DIR/run/reconnect-gp.lock"
GP_RECONNECT_FAIL="$VPN_DIR/run/reconnect-gp-failures"
if [[ "$GP_ENABLED" == "true" ]] && [[ "$gp" == "disconnected" ]] && [[ -f "$GP_RECONNECT_FLAG" ]]; then
    # Clean up stale resolver/hosts from crashed openconnect
    for domain in ofsz.local ofsz.hu; do
        [ -f "/etc/resolver/$domain" ] && sudo rm -f "/etc/resolver/$domain" 2>/dev/null || true
    done
    sudo sed -i '' '/vpn\.ofsz\.hu/d' /etc/hosts 2>/dev/null || true

    gp=$(auto_reconnect "gp" "$GP_RECONNECT_FLAG" "$GP_RECONNECT_LOCK" "$GP_RECONNECT_FAIL" "gp-up")
fi

status_color() {
    case "$1" in
        connected)              echo "#33CC33" ;;
        disconnected|stopped|gave-up|cooldown) echo "#FF3B30" ;;
        connecting|reconnecting) echo "#E6B310" ;;
        no-sudo)                 echo "#FF6B00" ;;
        not-running)             echo "#888888" ;;
        *)                       echo "#888888" ;;
    esac
}

n=0
expected=0
[[ "$ts"  == "connected" ]] && ((n++)) || true
[[ "$aws" == "connected" ]] && ((n++)) || true
[[ "$GP_ENABLED" == "true" ]] && [[ "$gp" == "connected" ]] && ((n++)) || true
# Count how many VPNs are configured (expected to be connected)
((expected++)) || true  # Tailscale always expected
((expected++)) || true  # AWS always expected
[[ "$GP_ENABLED" == "true" ]] && ((expected++)) || true

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
    echo "AWS | size=13 color=$(status_color "$aws") checked=true badge=$aws_iface bash=$VPN param1=aws-down terminal=false refresh=true${aws_extra}"
    echo "AWS (verbose) | size=13 color=$(status_color "$aws") checked=true bash=$VPN param1=aws-down terminal=true refresh=true alternate=true"
elif [[ "$aws" == "no-sudo" ]]; then
    echo "AWS ⚠ sudo | size=13 color=$(status_color "$aws") bash=$VPN param1=aws-up terminal=true refresh=true"
else
    echo "AWS | size=13 color=$(status_color "$aws") bash=$VPN param1=aws-up terminal=false refresh=true"
    echo "AWS (verbose) | size=13 color=$(status_color "$aws") bash=$VPN param1=aws-up terminal=true refresh=true alternate=true"
fi

# GlobalProtect
if [[ "$GP_ENABLED" == "true" ]]; then
    if [[ "$gp" == "connected" ]]; then
        echo "GlobalProtect | size=13 color=$(status_color "$gp") checked=true bash=$VPN param1=gp-down terminal=false refresh=true"
        echo "GlobalProtect (verbose) | size=13 color=$(status_color "$gp") checked=true bash=$VPN param1=gp-down terminal=true refresh=true alternate=true"
    else
        echo "GlobalProtect | size=13 color=$(status_color "$gp") bash=$VPN param1=gp-up terminal=false refresh=true"
        echo "GlobalProtect (verbose) | size=13 color=$(status_color "$gp") bash=$VPN param1=gp-up terminal=true refresh=true alternate=true"
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
