#!/usr/bin/env bash
# VPN tool installer — called by the root meta-installer
# Can also be run standalone: bash vpn/install.sh
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFTBAR_PLUGINS="$HOME/Library/Application Support/SwiftBar/Plugins"

# Ensure gum is available (standalone mode)
if ! command -v gum &>/dev/null; then
    echo "gum is required. Install: brew install gum"
    exit 1
fi

# ── Permissions & runtime dir ────────────────────────────
chmod +x "$TOOL_DIR/vpn" "$TOOL_DIR/aws-connect.sh" "$TOOL_DIR/lib.sh"
chmod +x "$TOOL_DIR/vpn.30s.sh"
mkdir -p "$TOOL_DIR/run"

gum log --level info --prefix "✓" "VPN toolkit ready at $TOOL_DIR"

# ── Add vpn to PATH ─────────────────────────────────────
SHELL_RC=""
if [ -f "$HOME/.zshrc" ]; then
    SHELL_RC="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
    SHELL_RC="$HOME/.bashrc"
fi

PATH_LINE="export PATH=\"\$HOME/.config/ofsz-tooling/vpn:\$PATH\""
if [ -n "$SHELL_RC" ]; then
    if ! grep -qF '.config/ofsz-tooling/vpn' "$SHELL_RC" 2>/dev/null; then
        {
            echo ""
            echo "# OFSZ VPN toolkit"
            echo "$PATH_LINE"
        } >> "$SHELL_RC"
        gum log --level info --prefix "✓" "Added vpn to PATH in $SHELL_RC"
    else
        gum log --level info --prefix "✓" "PATH already configured"
    fi
else
    gum log --level warn "Could not detect shell rc — add manually: $PATH_LINE"
fi

# ── SwiftBar plugin ─────────────────────────────────────
if [ -d "$SWIFTBAR_PLUGINS" ]; then
    SWIFTBAR_SRC="$TOOL_DIR/vpn.30s.sh"
    SWIFTBAR_DEST="$SWIFTBAR_PLUGINS/vpn.30s.sh"
    if [ -f "$SWIFTBAR_SRC" ]; then
        ln -sf "$SWIFTBAR_SRC" "$SWIFTBAR_DEST"
        gum log --level info --prefix "✓" "SwiftBar plugin symlinked"
    fi
else
    gum log --level info "SwiftBar not found — install: brew install --cask swiftbar"
fi

# ── Prerequisites check ─────────────────────────────────
echo ""
gum style --bold --foreground 212 "Prerequisites"
failed=0

check() {
    local name="$1" ok_msg="$2" fail_msg="$3"
    shift 3
    if "$@" &>/dev/null; then
        gum log --level info --prefix "✓" "$name: $ok_msg"
    else
        gum log --level warn "$name: $fail_msg"
        failed=1
    fi
}

# Tailscale
check "Tailscale" "installed" "not installed → https://tailscale.com/download/mac" \
    test -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

# AWS VPN Client
OVPN_BIN="/Applications/AWS VPN Client/AWS VPN Client.app/Contents/Resources/openvpn/acvc-openvpn"
check "AWS VPN Client" "installed" "not installed → https://aws.amazon.com/vpn/client-vpn-download/" \
    test -x "$OVPN_BIN"

if [ -x "$OVPN_BIN" ]; then
    if sudo -n "$OVPN_BIN" --version &>/dev/null; then
        gum log --level info --prefix "✓" "AWS VPN sudoers: configured"
    else
        gum log --level warn "AWS VPN sudoers: not configured → run: vpn setup"
    fi
fi

# AWS VPN profile
check "AWS VPN profile" "found" "not configured → connect once via AWS VPN Client GUI" \
    test -f "$HOME/.config/AWSVPNClient/ConnectionProfiles"

# WatchGuard
if pgrep -qf "WatchGuard Mobile VPN" 2>/dev/null; then
    gum log --level info --prefix "✓" "WatchGuard: running"
else
    gum log --level warn "WatchGuard: not running (may not be installed)"
fi

# WatchGuard password
if security find-generic-password -s "vpn-watchguard" -w &>/dev/null; then
    gum log --level info --prefix "✓" "WatchGuard password: in keychain"
else
    gum log --level warn "WatchGuard password: not stored → run: vpn wg-set-password"
fi

# Python 3
check "Python 3" "$(python3 --version 2>&1)" "not found → xcode-select --install" \
    command -v python3

echo ""
return "$failed" 2>/dev/null || exit "$failed"
