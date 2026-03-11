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

# ── 5. Remove Chrome OFSZ-VPN profile ─────────────────
CHROME_PROFILE="$HOME/Library/Application Support/Google/Chrome/OFSZ-VPN"
if [ -d "$CHROME_PROFILE" ]; then
    rm -rf "$CHROME_PROFILE"
    gum log --level info --prefix "✓" "Chrome OFSZ-VPN profile removed"
else
    gum log --level info --prefix "·" "Chrome OFSZ-VPN profile: already removed"
fi

# ── 6. Remove runtime dir ───────────────────────────────
if [ -d "$TOOL_DIR/run" ]; then
    rm -rf "$TOOL_DIR/run"
    gum log --level info --prefix "✓" "Runtime dir removed"
fi
