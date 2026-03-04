#!/usr/bin/env bash
# OFSZ Tooling — meta-installer
# Usage: curl -fsSL https://raw.githubusercontent.com/sarimarton-ofsz/ofsz-tooling/main/install.sh | bash
set -euo pipefail

REPO_URL="https://github.com/sarimarton-ofsz/ofsz-tooling.git"
INSTALL_DIR="$HOME/.config/ofsz-tooling"
OLD_INSTALL_DIR="$HOME/.config/vpn"

# ── Ensure Homebrew is available ──────────────────────────
if ! command -v brew &>/dev/null; then
    echo "Homebrew not found — installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add brew to PATH for the rest of this session
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

# ── Ensure gum is available ──────────────────────────────
if ! command -v gum &>/dev/null; then
    echo "Installing gum via Homebrew..."
    brew install gum
fi

header() {
    echo ""
    gum style --border rounded --border-foreground 212 --padding "0 2" --bold "$1"
}

# ── Migration from old ~/.config/vpn layout ──────────────
migrate_old_install() {
    if [ ! -d "$OLD_INSTALL_DIR/.git" ]; then
        return
    fi
    if [ -d "$INSTALL_DIR/.git" ]; then
        gum log --level warn "Old installation at $OLD_INSTALL_DIR still exists — skipping migration"
        return
    fi

    header "Migrating old installation"
    gum log --level info "Moving $OLD_INSTALL_DIR → $INSTALL_DIR"

    mkdir -p "$(dirname "$INSTALL_DIR")"
    mv "$OLD_INSTALL_DIR" "$INSTALL_DIR"

    # Clean up old PATH from shell rc
    local rc
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
        if [ -f "$rc" ] && grep -qF '.config/vpn' "$rc" 2>/dev/null; then
            gum log --level info "Removing old PATH entry from $rc"
            sed -i '' '/# OFSZ VPN toolkit/d' "$rc"
            sed -i '' '/\.config\/vpn/d' "$rc"
        fi
    done

    # Remove old SwiftBar symlink (will be recreated by vpn/install.sh)
    local old_link="$HOME/Library/Application Support/SwiftBar/Plugins/vpn.30s.sh"
    if [ -L "$old_link" ]; then
        rm "$old_link"
        gum log --level info "Removed old SwiftBar symlink"
    fi

    gum log --level info --prefix "✓" "Migration complete"
}

# ── Step 1: Migrate if needed ────────────────────────────
migrate_old_install

# ── Step 2: Clone or update repo ─────────────────────────
header "OFSZ Tooling Installer"

if [ -d "$INSTALL_DIR/.git" ]; then
    gum spin --spinner dot --title "Updating repository..." -- \
        git -C "$INSTALL_DIR" pull --ff-only
    gum log --level info --prefix "✓" "Repository updated"
else
    if [ -d "$INSTALL_DIR" ]; then
        gum log --level warn "Backing up existing $INSTALL_DIR"
        mv "$INSTALL_DIR" "${INSTALL_DIR}.bak.$(date +%s)"
    fi
    gum spin --spinner dot --title "Cloning repository..." -- \
        git clone "$REPO_URL" "$INSTALL_DIR"
    gum log --level info --prefix "✓" "Repository cloned to $INSTALL_DIR"
fi

# ── Step 3: Run tool-specific installers ─────────────────
failed=0

for installer in "$INSTALL_DIR"/*/install.sh; do
    [ -f "$installer" ] || continue
    tool_name="$(basename "$(dirname "$installer")")"
    header "Installing: $tool_name"
    bash "$installer" || failed=1
done

# ── Done ─────────────────────────────────────────────────
echo ""
if [ $failed -eq 0 ]; then
    gum style --border double --border-foreground 76 --padding "0 2" --bold \
        "✓ All tools installed!" \
        "" \
        "Open a new terminal, then run: vpn help"
else
    gum style --border double --border-foreground 214 --padding "0 2" --bold \
        "! Installation complete with warnings" \
        "" \
        "Fix warnings above, then run: vpn help"
fi
echo ""
