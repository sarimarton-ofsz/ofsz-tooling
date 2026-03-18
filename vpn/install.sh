#!/usr/bin/env bash
# VPN tool installer — called by the root meta-installer
# Can also be run standalone: bash vpn/install.sh
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$HOME/.config/ofsz-tooling/vpn"
SWIFTBAR_PLUGINS="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || echo "$HOME/Library/Application Support/SwiftBar/Plugins")"
OVPN_BIN="/Applications/AWS VPN Client/AWS VPN Client.app/Contents/Resources/openvpn/acvc-openvpn"

# Ensure gum is available (standalone mode)
if ! command -v gum &>/dev/null; then
    echo "gum is required. Install: brew install gum"
    exit 1
fi

# Dependency tracker (shared with root uninstall.sh)
DEPS_FILE="$HOME/.config/ofsz-tooling/.installed-deps"
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
mkdir -p "$DATA_DIR/run"

gum log --level info --prefix "✓" "VPN scripts at $TOOL_DIR"
gum log --level info --prefix "✓" "VPN data at $DATA_DIR"

# ── 2. Add vpn to PATH ──────────────────────────────────
SHELL_RC=""
if [ -f "$HOME/.zshrc" ]; then
    SHELL_RC="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
    SHELL_RC="$HOME/.bashrc"
fi

PATH_LINE="export PATH=\"$TOOL_DIR:\$PATH\""
if [ -n "$SHELL_RC" ]; then
    if ! grep -qF '# OFSZ VPN toolkit' "$SHELL_RC" 2>/dev/null; then
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

# ── 3. Microsoft (céges) credentials ─────────────────────
# Used for both WatchGuard and AWS SAML auth. Asked once, stored in keychain.
HAVE_EMAIL=$(security find-generic-password -s "vpn-entra" -a "email" -w 2>/dev/null) || true
HAVE_PW=$(security find-generic-password -s "vpn-watchguard" -w 2>/dev/null) || true

if [ -n "$HAVE_EMAIL" ] && [ -n "$HAVE_PW" ]; then
    gum log --level info --prefix "✓" "Microsoft credentials: in keychain"
else
    echo ""
    gum style --bold --foreground 212 "Microsoft (céges) bejelentkezés"
    echo ""
    email=$(gum input --placeholder "nev@ceg.hu" --header "Céges email cím:")
    pw=$(gum input --password --placeholder "jelszó" --header "Céges jelszó:")
    if [ -n "$email" ] && [ -n "$pw" ]; then
        security delete-generic-password -s "vpn-entra" 2>/dev/null || true
        security add-generic-password -s "vpn-entra" -a "email" -w "$email" -T ""
        security delete-generic-password -s "vpn-watchguard" 2>/dev/null || true
        security add-generic-password -s "vpn-watchguard" -a "watchguard" -w "$pw" -T ""
        gum log --level info --prefix "✓" "Credentials stored in keychain"
    else
        warn_prereq "Credentials: not stored (empty input)"
    fi
fi

# ── 4. WatchGuard (skippable) ────────────────────────────
# Asked early so the config file exists before SwiftBar starts polling.
SKIP_WG=false
if ! gum confirm "WatchGuard VPN beállítása?" --default=yes; then
    SKIP_WG=true
    gum log --level info --prefix "–" "WatchGuard: skipped"
fi

echo "WG_ENABLED=$( $SKIP_WG && echo false || echo true )" > "$DATA_DIR/config"

if ! $SKIP_WG; then
    if pgrep -qf "WatchGuard Mobile VPN" 2>/dev/null; then
        gum log --level info --prefix "✓" "WatchGuard: running"
    else
        warn_prereq "WatchGuard: not running → contact IT for installation"
    fi
fi

# ── Prerequisite notice ──────────────────────────────────
echo ""
gum style --bold --foreground 212 "Előfeltételek"
echo ""
gum style --faint "A telepítő feltételezi, hogy minden VPN már be van állítva és működik:" \
    "" \
    "  • Tailscale — telepítve és bejelentkezve" \
    "  • AWS VPN Client — telepítve, profil konfigurálva (legalább 1 GUI-s csatlakozás volt)" \
    "$( [ "$SKIP_WG" = "false" ] && echo '  • WatchGuard — futó kliens a céges jelszóval' || true )"
echo ""
if ! gum confirm "Megerősítem, ezek működnek" --default=yes --affirmative "Megerősítem" --negative "Mégsem"; then
    gum log --level warn "Telepítés megszakítva — állítsd be a VPN-eket és futtasd újra"
    return 1 2>/dev/null || exit 1
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

# ── 7. Playwright (headless Chromium for SAML auth) ──────
if ! command -v node &>/dev/null; then
    gum log --level info "Node.js not found — installing..."
    brew install node
    _mark_dep node
fi
if [ ! -d "$TOOL_DIR/node_modules/playwright" ]; then
    gum log --level info "Playwright: installing..."
    (cd "$TOOL_DIR" && npm install --save playwright 2>&1 | tail -1)
fi
if ! ls -d "$DATA_DIR/run/browsers/chromium-"* &>/dev/null; then
    gum log --level info "Chromium: downloading..."
    (cd "$TOOL_DIR" && PLAYWRIGHT_BROWSERS_PATH="$DATA_DIR/run/browsers" npx playwright install chromium 2>&1 | tail -1)
fi
gum log --level info --prefix "✓" "Playwright + Chromium: ready"

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
    sudoers_file="/etc/sudoers.d/vpn-aws"
    if [ -f "$sudoers_file" ]; then
        gum log --level info --prefix "✓" "AWS VPN sudoers: configured"
    else
        ovpn_bin_escaped="${OVPN_BIN// /\\ }"
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

    # AWS VPN — connect via CLI; Playwright handles Entra SAML auth.
    # First connect saves session state for future headless auto-reconnects.
    echo ""
    gum style --bold --foreground 212 "AWS VPN — Entra ID bejelentkezés"
    echo ""
    if gum confirm "Indítás? (Eltarthat néhány másodpercig)" --default=yes --affirmative "Mehet" --negative "Mégse"; then
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

    # ── Verification: wait for all VPNs to be connected ──
    echo ""
    gum style --bold --foreground 212 "Ellenőrzés"
    max_wait=90; waited=0
    while [ $waited -lt $max_wait ]; do
        ts_ok=""; aws_ok=""; wg_ok=true
        ts_ok=$(ts_status)
        aws_ok=$(aws_vpn_status)
        $SKIP_WG || wg_ok=$(wg_status)

        if [ "$ts_ok" = "connected" ] && [ "$aws_ok" = "connected" ] && { $SKIP_WG || [ "$wg_ok" = "connected" ]; }; then
            gum log --level info --prefix "✓" "Tailscale: connected"
            gum log --level info --prefix "✓" "AWS VPN: connected"
            $SKIP_WG || gum log --level info --prefix "✓" "WatchGuard: connected"
            break
        fi

        if [ $waited -eq 0 ]; then
            gum log --level info "Várakozás az összes VPN csatlakozására..."
        fi
        sleep 5
        waited=$((waited + 5))
    done

    if [ $waited -ge $max_wait ]; then
        gum log --level warn "Timeout — nem sikerült minden VPN-t csatlakoztatni"
        gum log --level info "  Tailscale: $(ts_status)"
        gum log --level info "  AWS VPN: $(aws_vpn_status)"
        $SKIP_WG || gum log --level info "  WatchGuard: $(wg_status)"
        failed=1
    fi
fi

echo ""
# shellcheck disable=SC2317
return "$failed" 2>/dev/null || exit "$failed"
