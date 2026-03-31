#!/usr/bin/env bash
# VPN tool uninstaller — called by the root uninstall.sh
# Can also be run standalone: bash vpn/uninstall.sh
set -euo pipefail

DATA_DIR="$HOME/.config/ofsz-tooling/vpn"
SWIFTBAR_LINK="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || echo "$HOME/Library/Application Support/SwiftBar/Plugins")/vpn.30s.sh"
SUDOERS_FILE="/etc/sudoers.d/vpn"
SUDOERS_FILE_OLD="/etc/sudoers.d/vpn-aws"

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
# GlobalProtect (openconnect) daemon
gp_pid=$(cat "$DATA_DIR/run/globalprotect.pid" 2>/dev/null) || true
if [ -n "$gp_pid" ] && ps -p "$gp_pid" &>/dev/null; then
    sudo kill "$gp_pid" 2>/dev/null || true
    gum log --level info --prefix "✓" "GlobalProtect stopped"
fi
sudo pkill -f "openconnect.*--protocol=gp" 2>/dev/null || true
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
    if [ -f "$rc" ] && grep -qF '# OFSZ VPN toolkit' "$rc" 2>/dev/null; then
        sed -i '' '/# OFSZ VPN toolkit/d' "$rc"
        sed -i '' '/ofsz-tooling\/vpn/d' "$rc"
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
for sf in "$SUDOERS_FILE" "$SUDOERS_FILE_OLD"; do
    if [ -f "$sf" ]; then
        sudo rm -f "$sf"
        gum log --level info --prefix "✓" "Sudoers config removed ($sf)"
    fi
done

# ── 4. Remove credentials from keychain ──────────────────
for entry in "vpn-gp:GlobalProtect password" "vpn-gp-user:GlobalProtect username" "vpn-entra:Entra email" "vpn-watchguard:WatchGuard password (legacy)"; do
    svc="${entry%%:*}"
    label="${entry#*:}"
    if security find-generic-password -s "$svc" -w &>/dev/null; then
        security delete-generic-password -s "$svc" &>/dev/null
        gum log --level info --prefix "✓" "$label removed from keychain"
    fi
done

# ── 5. Remove runtime data ───────────────────────────
if [ -d "$DATA_DIR/run" ]; then
    rm -rf "$DATA_DIR/run"
    gum log --level info --prefix "✓" "Runtime dir removed"
fi

# ── 6. Remove config ────────────────────────────────
if [ -f "$DATA_DIR/config" ]; then
    rm -f "$DATA_DIR/config"
    gum log --level info --prefix "✓" "Config removed"
fi
