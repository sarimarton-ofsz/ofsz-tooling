#!/usr/bin/env bash
# VPN tool installer — called by the root meta-installer
# Can also be run standalone: bash vpn/install.sh
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFTBAR_PLUGINS="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || echo "$HOME/Library/Application Support/SwiftBar/Plugins")"
OVPN_BIN="/Applications/AWS VPN Client/AWS VPN Client.app/Contents/Resources/openvpn/acvc-openvpn"

# Ensure gum is available (standalone mode)
if ! command -v gum &>/dev/null; then
    echo "gum is required. Install: brew install gum"
    exit 1
fi

failed=0
warn_prereq() {
    gum log --level warn "$@"
    failed=1
}

# ── 1. Permissions & runtime dir ─────────────────────────
chmod +x "$TOOL_DIR/vpn" "$TOOL_DIR/aws-connect.sh" "$TOOL_DIR/lib.sh"
chmod +x "$TOOL_DIR/vpn.30s.sh"
mkdir -p "$TOOL_DIR/run"

gum log --level info --prefix "✓" "VPN toolkit ready at $TOOL_DIR"

# ── 2. Add vpn to PATH ──────────────────────────────────
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

# ── 3. SwiftBar: auto-install + symlink ──────────────────
SWIFTBAR_SRC="$TOOL_DIR/vpn.30s.sh"
SWIFTBAR_DEST="$SWIFTBAR_PLUGINS/vpn.30s.sh"

if [ ! -d "$SWIFTBAR_PLUGINS" ]; then
    gum log --level info "SwiftBar not found — installing..."
    brew install --cask swiftbar
    mkdir -p "$SWIFTBAR_PLUGINS"
fi

if [ -d "$SWIFTBAR_PLUGINS" ] && [ -f "$SWIFTBAR_SRC" ]; then
    # Remove stale target first — ln -sf into an existing directory
    # creates the link *inside* it instead of replacing it
    rm -rf "$SWIFTBAR_DEST"
    ln -sf "$SWIFTBAR_SRC" "$SWIFTBAR_DEST"
    gum log --level info --prefix "✓" "SwiftBar plugin symlinked"
fi

# ── Prerequisites ────────────────────────────────────────
echo ""
gum style --bold --foreground 212 "Prerequisites"

# ── 4. Python 3 ──────────────────────────────────────────
if command -v python3 &>/dev/null; then
    gum log --level info --prefix "✓" "Python 3: $(python3 --version 2>&1)"
else
    warn_prereq "Python 3: not found → run: xcode-select --install"
fi

# ── 5. Tailscale ─────────────────────────────────────────
if [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    gum log --level info --prefix "✓" "Tailscale: installed"
else
    warn_prereq "Tailscale: not installed → https://tailscale.com/download/mac"
fi

# ── 6. AWS VPN Client ────────────────────────────────────
if [ -x "$OVPN_BIN" ]; then
    gum log --level info --prefix "✓" "AWS VPN Client: installed"
else
    warn_prereq "AWS VPN Client: not installed → https://aws.amazon.com/vpn/client-vpn-download/"
fi

# ── 7. Sudoers: auto-setup if AWS VPN Client present ────
if [ -x "$OVPN_BIN" ]; then
    if sudo -n "$OVPN_BIN" --version &>/dev/null; then
        gum log --level info --prefix "✓" "AWS VPN sudoers: configured"
    else
        ovpn_bin_escaped="${OVPN_BIN// /\\ }"
        sudoers_file="/etc/sudoers.d/vpn-aws"
        gum log --level info "Configuring passwordless sudo for AWS VPN..."
        printf '%s ALL=(ALL) NOPASSWD: %s *\n%s ALL=(ALL) NOPASSWD: /bin/kill *\n' \
            "$USER" "$ovpn_bin_escaped" "$USER" | sudo tee "$sudoers_file" > /dev/null
        sudo chmod 440 "$sudoers_file"
        if sudo visudo -cf "$sudoers_file"; then
            gum log --level info --prefix "✓" "AWS VPN sudoers: configured"
        else
            gum log --level error "Sudoers syntax error — removing broken file"
            sudo rm -f "$sudoers_file"
            failed=1
        fi
    fi
fi

# ── 8. AWS VPN profile ──────────────────────────────────
if [ -f "$HOME/.config/AWSVPNClient/ConnectionProfiles" ]; then
    gum log --level info --prefix "✓" "AWS VPN profile: found"
else
    warn_prereq "AWS VPN profile: not configured → connect once via AWS VPN Client GUI"
fi

# ── 9. WatchGuard app ───────────────────────────────────
if pgrep -qf "WatchGuard Mobile VPN" 2>/dev/null; then
    gum log --level info --prefix "✓" "WatchGuard: running"
else
    warn_prereq "WatchGuard: not running → contact IT for installation"
fi

# ── 10. WatchGuard password: prompt if missing ───────────
if security find-generic-password -s "vpn-watchguard" -w &>/dev/null; then
    gum log --level info --prefix "✓" "WatchGuard password: in keychain"
else
    pw=$(gum input --password --placeholder "WatchGuard jelszó" --header "Enter your WatchGuard VPN password:")
    if [ -n "$pw" ]; then
        security delete-generic-password -s "vpn-watchguard" 2>/dev/null || true
        security add-generic-password -s "vpn-watchguard" -a "watchguard" -w "$pw" -T ""
        gum log --level info --prefix "✓" "WatchGuard password: stored in keychain"
    else
        warn_prereq "WatchGuard password: not stored (empty input)"
    fi
fi

echo ""
# shellcheck disable=SC2317
return "$failed" 2>/dev/null || exit "$failed"
