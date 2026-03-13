#!/usr/bin/env bash
# VPN tool uninstaller — called by the root uninstall.sh
# Can also be run standalone: bash vpn/uninstall.sh
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFTBAR_LINK="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || echo "$HOME/Library/Application Support/SwiftBar/Plugins")/vpn.30s.sh"
SUDOERS_FILE="/etc/sudoers.d/vpn-aws"

# Ensure gum is available
if ! command -v gum &>/dev/null; then
    echo "gum is required. Install: brew install gum"
    exit 1
fi

# ── 0. Stop VPN processes directly (no lib.sh — avoids sudo prompts)
# AWS VPN daemon
aws_pid=$(pgrep -f "acvc-openvpn.*aws-vpn-cli" 2>/dev/null | head -1) || true
if [ -n "$aws_pid" ]; then
    sudo kill "$aws_pid" 2>/dev/null || kill "$aws_pid" 2>/dev/null || true
    gum log --level info --prefix "✓" "AWS VPN stopped"
fi
# SwiftBar (only stop if no other plugins remain after removing ours)
SWIFTBAR_DIR="$(dirname "$SWIFTBAR_LINK")"
other_plugins=$(find "$SWIFTBAR_DIR" -maxdepth 1 -name '*.sh' ! -name 'vpn.30s.sh' 2>/dev/null | head -1)
if [ -z "$other_plugins" ]; then
    killall SwiftBar 2>/dev/null && gum log --level info --prefix "✓" "SwiftBar stopped (no other plugins)" || true
else
    gum log --level info --prefix "·" "SwiftBar: kept running (other plugins present)"
fi

# ── 1. Remove PATH from shell rc ────────────────────────
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    if [ -f "$rc" ] && grep -qF '.config/ofsz-tooling/vpn' "$rc" 2>/dev/null; then
        sed -i '' '/# OFSZ VPN toolkit/d' "$rc"
        sed -i '' '/\.config\/ofsz-tooling\/vpn/d' "$rc"
        gum log --level info --prefix "✓" "PATH removed from $rc"
    fi
done

# ── 2. Remove SwiftBar symlink ───────────────────────────
if [ -L "$SWIFTBAR_LINK" ]; then
    rm "$SWIFTBAR_LINK"
    gum log --level info --prefix "✓" "SwiftBar symlink removed"
else
    gum log --level info --prefix "·" "SwiftBar symlink: already removed"
fi

# ── 3. Remove sudoers config ────────────────────────────
if [ -f "$SUDOERS_FILE" ]; then
    sudo rm -f "$SUDOERS_FILE"
    gum log --level info --prefix "✓" "Sudoers config removed"
else
    gum log --level info --prefix "·" "Sudoers config: already removed"
fi

# ── 4. Remove WatchGuard password from keychain ─────────
if security find-generic-password -s "vpn-watchguard" -w &>/dev/null; then
    security delete-generic-password -s "vpn-watchguard" &>/dev/null
    gum log --level info --prefix "✓" "WatchGuard password removed from keychain"
else
    gum log --level info --prefix "·" "WatchGuard password: already removed"
fi

# ── 5. Kill isolated VPN Chrome ──────────────────────
pkill -f "user-data-dir=$TOOL_DIR/run/chrome-data" 2>/dev/null || true

# ── 6. Remove runtime dir (preserve chrome-data for SSO cookie) ──
if [ -d "$TOOL_DIR/run" ]; then
    find "$TOOL_DIR/run" -maxdepth 1 ! -name run ! -name chrome-data -exec rm -rf {} + 2>/dev/null
    gum log --level info --prefix "✓" "Runtime dir cleaned (SSO cookie preserved)"
fi
