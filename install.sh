#!/usr/bin/env bash
# OFSZ Tooling installer
# Usage: curl -fsSL https://raw.githubusercontent.com/sarimarton-ofsz/ofsz-tooling/main/install.sh | bash
set -euo pipefail

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[1;33m"; BLUE="\033[0;34m"; NC="\033[0m"
log()  { echo -e "${BLUE}[ofsz]${NC} $*"; }
ok()   { echo -e "${GREEN}[ofsz ✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[ofsz !]${NC} $*"; }
err()  { echo -e "${RED}[ofsz ✗]${NC} $*" >&2; }

REPO_URL="https://github.com/sarimarton-ofsz/ofsz-tooling.git"
INSTALL_DIR="$HOME/.config/vpn"
SWIFTBAR_PLUGINS="$HOME/Library/Application Support/SwiftBar/Plugins"

# ── Step 1: Clone or update repo ─────────────────────────
log "Installing OFSZ VPN toolkit..."

if [ -d "$INSTALL_DIR/.git" ]; then
    log "Updating existing installation..."
    git -C "$INSTALL_DIR" pull --ff-only
else
    if [ -d "$INSTALL_DIR" ]; then
        # Existing non-git vpn dir — back it up
        warn "Backing up existing $INSTALL_DIR → ${INSTALL_DIR}.bak"
        mv "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%s)"
    fi
    log "Cloning repo..."
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

# The repo has vpn/ and swiftbar/ subdirs — we need vpn files at the top level
# Restructure: move vpn/* to install dir root if cloned as full repo
if [ -d "$INSTALL_DIR/vpn" ] && [ ! -f "$INSTALL_DIR/lib.sh" ]; then
    log "Restructuring: moving vpn/ contents to $INSTALL_DIR root..."
    # Keep swiftbar dir for symlinking
    cp -a "$INSTALL_DIR/vpn/"* "$INSTALL_DIR/"
fi

chmod +x "$INSTALL_DIR/vpn" "$INSTALL_DIR/aws-connect.sh" "$INSTALL_DIR/lib.sh"
mkdir -p "$INSTALL_DIR/run"

ok "VPN toolkit installed at $INSTALL_DIR"

# ── Step 2: Add vpn to PATH ──────────────────────────────
log "Setting up PATH..."

SHELL_RC=""
if [ -f "$HOME/.zshrc" ]; then
    SHELL_RC="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
    SHELL_RC="$HOME/.bashrc"
fi

PATH_LINE='export PATH="$HOME/.config/vpn:$PATH"'
if [ -n "$SHELL_RC" ]; then
    if ! grep -qF '.config/vpn' "$SHELL_RC" 2>/dev/null; then
        echo "" >> "$SHELL_RC"
        echo "# OFSZ VPN toolkit" >> "$SHELL_RC"
        echo "$PATH_LINE" >> "$SHELL_RC"
        ok "Added vpn to PATH in $SHELL_RC"
    else
        ok "PATH already configured in $SHELL_RC"
    fi
else
    warn "Could not detect shell rc file — add manually:"
    echo "  $PATH_LINE"
fi

# ── Step 3: SwiftBar plugin ──────────────────────────────
if [ -d "$SWIFTBAR_PLUGINS" ]; then
    log "SwiftBar detected — installing VPN menu plugin..."
    SWIFTBAR_SRC="$INSTALL_DIR/swiftbar/vpn.30s.sh"
    SWIFTBAR_DEST="$SWIFTBAR_PLUGINS/vpn.30s.sh"
    if [ -f "$SWIFTBAR_SRC" ]; then
        ln -sf "$SWIFTBAR_SRC" "$SWIFTBAR_DEST"
        chmod +x "$SWIFTBAR_SRC"
        ok "SwiftBar plugin symlinked: $SWIFTBAR_DEST → $SWIFTBAR_SRC"
    fi
else
    log "SwiftBar not found — skipping menu bar plugin"
    log "  Install SwiftBar: brew install --cask swiftbar"
    log "  Then re-run this installer"
fi

# ── Step 4: Prerequisites check ──────────────────────────
echo ""
log "Checking prerequisites..."
failed=0

# Tailscale
if [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    ok "Tailscale: installed"
else
    warn "Tailscale: not installed"
    echo "    Install: https://tailscale.com/download/mac"
    failed=1
fi

# AWS VPN Client
OVPN_BIN="/Applications/AWS VPN Client/AWS VPN Client.app/Contents/Resources/openvpn/acvc-openvpn"
if [ -x "$OVPN_BIN" ]; then
    ok "AWS VPN Client: installed"
    # Check sudoers
    if sudo -n "$OVPN_BIN" --version &>/dev/null; then
        ok "AWS VPN sudoers: configured"
    else
        warn "AWS VPN sudoers: not configured"
        echo "    Run: vpn setup"
    fi
else
    warn "AWS VPN Client: not installed"
    echo "    Install: https://aws.amazon.com/vpn/client-vpn-download/"
    failed=1
fi

# AWS VPN profile
AWS_PROFILES="$HOME/.config/AWSVPNClient/ConnectionProfiles"
if [ -f "$AWS_PROFILES" ]; then
    ok "AWS VPN profile: found"
else
    warn "AWS VPN profile: not configured"
    echo "    Open AWS VPN Client → File → Manage Profiles → Add Profile"
    echo "    Connect once via GUI, then CLI will work"
fi

# WatchGuard
if pgrep -qf "WatchGuard Mobile VPN" 2>/dev/null; then
    ok "WatchGuard: running"
else
    warn "WatchGuard: not running (may not be installed)"
    echo "    Install WatchGuard Mobile VPN with SSL if needed"
fi

# WatchGuard password
if security find-generic-password -s "vpn-watchguard" -w &>/dev/null; then
    ok "WatchGuard password: stored in keychain"
else
    warn "WatchGuard password: not stored"
    echo "    Run: vpn wg-set-password"
fi

# Python 3
if command -v python3 &>/dev/null; then
    ok "Python 3: $(python3 --version 2>&1)"
else
    warn "Python 3: not found (needed for AWS SAML auth)"
    echo "    Install: xcode-select --install"
    failed=1
fi

# ── Done ──────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────────"
if [ $failed -eq 0 ]; then
    ok "Installation complete! Open a new terminal and run: vpn status"
else
    ok "Installation complete (with warnings above)"
    echo "    Fix the warnings, then run: vpn status"
fi
echo ""
echo "  Commands:    vpn help"
echo "  Presets:     vpn preset all    (AWS + WatchGuard + Tailscale)"
echo "               vpn preset aws-ts (AWS + Tailscale)"
echo "  SwiftBar:    menu bar VPN icon with status + controls"
echo "─────────────────────────────────────────────"
