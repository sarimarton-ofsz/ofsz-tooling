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

# Dependency tracker (shared with root uninstall.sh)
DEPS_FILE="$(dirname "$TOOL_DIR")/.installed-deps"
[ -f "$DEPS_FILE" ] || touch "$DEPS_FILE"
_mark_dep() { grep -qx "$1" "$DEPS_FILE" 2>/dev/null || echo "$1" >> "$DEPS_FILE"; }

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

# ── 3. WatchGuard (skippable) ────────────────────────────
# Asked early so the config file exists before SwiftBar starts polling.
SKIP_WG=false
if ! gum confirm "WatchGuard VPN beállítása?" --default=yes; then
    SKIP_WG=true
    gum log --level info --prefix "–" "WatchGuard: skipped"
fi

echo "WG_ENABLED=$( $SKIP_WG && echo false || echo true )" > "$TOOL_DIR/config"

if ! $SKIP_WG; then
    if pgrep -qf "WatchGuard Mobile VPN" 2>/dev/null; then
        gum log --level info --prefix "✓" "WatchGuard: running"
    else
        warn_prereq "WatchGuard: not running → contact IT for installation"
    fi

    # WatchGuard password: prompt if missing
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
fi

# ── 4. SwiftBar: auto-install + symlink ──────────────────
# Placed after config write so SwiftBar reads WG_ENABLED correctly on first poll.
SWIFTBAR_SRC="$TOOL_DIR/vpn.30s.sh"
SWIFTBAR_DEST="$SWIFTBAR_PLUGINS/vpn.30s.sh"

if [ ! -d "/Applications/SwiftBar.app" ]; then
    gum log --level info "SwiftBar not found — installing..."
    brew install --cask swiftbar
    _mark_dep swiftbar
    mkdir -p "$SWIFTBAR_PLUGINS"
    # Set plugin directory before first launch to skip the directory picker dialog
    defaults write com.ameba.SwiftBar PluginDirectory -string "$SWIFTBAR_PLUGINS"
    open -a SwiftBar
    gum log --level info "  → Ha macOS engedélyt kér a SwiftBar futtatásához, engedélyezd"
    gum confirm "SwiftBar elindult?" --default=yes --affirmative "Igen, mehet tovább" --negative "Nem indult el"
elif [ ! -d "$SWIFTBAR_PLUGINS" ]; then
    mkdir -p "$SWIFTBAR_PLUGINS"
fi

if [ -d "$SWIFTBAR_PLUGINS" ] && [ -f "$SWIFTBAR_SRC" ]; then
    rm -rf "$SWIFTBAR_DEST"
    ln -sf "$SWIFTBAR_SRC" "$SWIFTBAR_DEST"
    # Restart SwiftBar to pick up new/changed symlinks reliably
    # (swiftbar:// URL scheme doesn't always detect newly added plugins)
    killall SwiftBar 2>/dev/null || true
    sleep 1
    open -a SwiftBar
    sleep 2
    gum log --level info --prefix "✓" "SwiftBar plugin symlinked + restarted"
fi

# ── Prerequisites ────────────────────────────────────────
echo ""
gum style --bold --foreground 212 "Prerequisites"

# ── 5. Python 3 ──────────────────────────────────────────
if command -v python3 &>/dev/null; then
    gum log --level info --prefix "✓" "Python 3: $(python3 --version 2>&1)"
else
    warn_prereq "Python 3: not found → run: xcode-select --install"
fi

# ── 6. Tailscale ─────────────────────────────────────────
if [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    gum log --level info --prefix "✓" "Tailscale: installed"
else
    warn_prereq "Tailscale: not installed → https://tailscale.com/download/mac"
fi

# ── 7. Google Chrome ─────────────────────────────────────
if [ -d "/Applications/Google Chrome.app" ]; then
    gum log --level info --prefix "✓" "Google Chrome: installed"
else
    gum log --level info "Google Chrome not found — installing..."
    brew install --cask google-chrome
    _mark_dep google-chrome
    gum log --level info --prefix "✓" "Google Chrome: installed"
fi

# ── 8. AWS VPN Client ────────────────────────────────────
if [ -x "$OVPN_BIN" ]; then
    gum log --level info --prefix "✓" "AWS VPN Client: installed"
    # Quit GUI — CLI manages the connection; GUI fights over tun device
    if pgrep -qf "AWS VPN Client.app/Contents/MacOS" 2>/dev/null; then
        osascript -e 'tell application "AWS VPN Client" to quit' 2>/dev/null || true
        gum log --level info --prefix "✓" "AWS VPN Client GUI: quit (CLI takes over)"
    fi
else
    warn_prereq "AWS VPN Client: not installed → https://self-service.clientvpn.amazonaws.com/endpoints/cvpn-endpoint-022755a701a9c6b8c"
fi

# ── 9. Sudoers: auto-setup if AWS VPN Client present ────
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

# ── 10. AWS VPN profile ──────────────────────────────────
if [ -f "$HOME/.config/AWSVPNClient/ConnectionProfiles" ]; then
    gum log --level info --prefix "✓" "AWS VPN profile: found"
else
    warn_prereq "AWS VPN profile: not configured → connect once via AWS VPN Client GUI"
fi

# ── 11. VPN connect ──────────────────────────────────────
if [ $failed -eq 0 ]; then
    echo ""
    gum style --bold --foreground 212 "VPN Connect"

    # Source lib.sh for vpn functions
    export SCRIPT_DIR="$TOOL_DIR"
    source "$TOOL_DIR/lib.sh"

    # Tailscale
    if [ "$(ts_status)" = "connected" ]; then
        gum log --level info --prefix "✓" "Tailscale: already connected"
    else
        gum log --level info "Tailscale: connecting..."
        ts_up || { gum log --level warn "Tailscale: failed"; failed=1; }
    fi

    # AWS VPN — always (re)connect via CLI with dedicated Chrome profile
    # This ensures the Entra SSO cookie is stored in our OFSZ-VPN profile
    # for future auto-reconnects. Even if already connected (e.g. via GUI),
    # we reconnect to seed the cookie in the right profile.
    echo ""
    gum style --bold --foreground 212 "AWS VPN — Entra ID bejelentkezés"
    CHROME_VPN_DATA="$TOOL_DIR/run/chrome-data"
    if [ ! -d "$CHROME_VPN_DATA" ]; then
        gum log --level info "Chrome megnyilik egy izolalt VPN profillal (nem a szemelyes profil)."
        gum log --level info "  Az elso inditasnal Chrome EU-s keresovalasztot mutathat - ez normalis"
    fi
    echo ""
    gum log --level info "A folyamat kb. 1-2 percig tart:"
    gum log --level info "  1. AWS szerver kapcsolat + SAML token kinyerese (~10 mp)"
    gum log --level info "  2. Chrome megnyilik → jelentkezz be ceges Microsoft fiokkal"
    gum log --level info "  3. Bejelentkezes utan Chrome automatikusan bezarul"
    gum log --level info "  4. VPN tunnel felepitese (~5 mp)"
    echo ""
    if gum confirm "Inditas?" --default=yes --affirmative "Mehet" --negative "Megse"; then
        aws_vpn_down 2>/dev/null || true
        aws_vpn_up || { gum log --level warn "AWS VPN: failed"; failed=1; }
    else
        gum log --level warn "AWS VPN: skipped"
        failed=1
    fi

    # WatchGuard
    if ! $SKIP_WG; then
        if [ "$(wg_status)" = "connected" ]; then
            gum log --level info --prefix "✓" "WatchGuard: already connected"
        else
            gum log --level info "WatchGuard: connecting..."
            wg_up || { gum log --level warn "WatchGuard: failed"; failed=1; }
        fi
    fi
fi

echo ""
# shellcheck disable=SC2317
return "$failed" 2>/dev/null || exit "$failed"
