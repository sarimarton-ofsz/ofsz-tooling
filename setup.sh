#!/usr/bin/env bash
# OFSZ Tooling — meta-installer
# Usage: curl -fsSL https://raw.githubusercontent.com/sarimarton-ofsz/ofsz-tooling/main/setup.sh | bash
#
# The { ... } block ensures bash reads the entire script before executing,
# preventing brew/curl output from interleaving with the script when piped.
{
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
    pull_output=$(git -C "$INSTALL_DIR" pull --ff-only 2>&1) || {
        gum log --level warn "git pull failed — resetting to remote"
        git -C "$INSTALL_DIR" stash --quiet 2>/dev/null || true
        git -C "$INSTALL_DIR" pull --ff-only --quiet
    }
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

# ── Step 3: Status ───────────────────────────────────────
echo ""
gum style --bold "Állapot"
gum log --level info --prefix "✓" "Homebrew: $(brew --version 2>&1 | head -1)"
gum log --level info --prefix "✓" "gum: v$(gum --version 2>&1)"
gum log --level info --prefix "✓" "Repo: $INSTALL_DIR"

# Discover available modules
mod_dirs=()
mod_names=()
mod_descs=()

for installer in "$INSTALL_DIR"/*/install.sh; do
    [ -f "$installer" ] || continue
    mod="$(basename "$(dirname "$installer")")"
    mod_dirs+=("$mod")
    desc_file="$INSTALL_DIR/$mod/.description"
    if [ -f "$desc_file" ]; then
        mod_names+=("$(sed -n '1p' "$desc_file")")
        mod_descs+=("$(sed -n '2p' "$desc_file")")
    else
        mod_names+=("$mod")
        mod_descs+=("")
    fi
done

if [ ${#mod_dirs[@]} -eq 0 ]; then
    gum log --level warn "No installable modules found"
    exit 0
fi

# Show module status
echo ""
gum style --bold "Modulok"
for i in "${!mod_dirs[@]}"; do
    mod="${mod_dirs[$i]}"
    label="${mod_names[$i]}"
    [ -n "${mod_descs[$i]}" ] && label="${mod_names[$i]} — ${mod_descs[$i]}"

    installed=false
    case "$mod" in
        vpn)
            if grep -qF '.config/ofsz-tooling/vpn' "${HOME}/.zshrc" 2>/dev/null || \
               grep -qF '.config/ofsz-tooling/vpn' "${HOME}/.bashrc" 2>/dev/null; then
                installed=true
            fi ;;
    esac

    if $installed; then
        gum log --level info --prefix "✓" "$label"
    else
        gum log --level info --prefix "○" "$label"
    fi
done

# ── Step 4: Select modules ──────────────────────────────
choices=()
for i in "${!mod_dirs[@]}"; do
    label="${mod_names[$i]}"
    [ -n "${mod_descs[$i]}" ] && label="${mod_names[$i]} — ${mod_descs[$i]}"
    choices+=("$label")
done

echo ""
selected=$(printf '%s\n' "${choices[@]}" | gum choose --no-limit --header "Telepíthető modulok:")

if [ -z "$selected" ]; then
    echo ""
    gum log --level info "Nincs kiválasztott modul"
    exit 0
fi

# ── Step 5: Install selected modules ────────────────────
failed=0

while IFS= read -r sel; do
    [ -n "$sel" ] || continue
    for i in "${!choices[@]}"; do
        if [ "${choices[$i]}" = "$sel" ]; then
            header "Installing: ${mod_names[$i]}"
            bash "$INSTALL_DIR/${mod_dirs[$i]}/install.sh" || failed=1
            break
        fi
    done
done <<< "$selected"

# ── Done ─────────────────────────────────────────────────
echo ""
if [ $failed -eq 0 ]; then
    gum style --border double --border-foreground 76 --padding "0 2" --bold \
        "✓ All done!" \
        "" \
        "Open a new terminal for PATH changes to take effect."
else
    gum style --border double --border-foreground 214 --padding "0 2" --bold \
        "! Installation complete with warnings" \
        "" \
        "Fix warnings above, then re-run the installer."
fi
echo ""
}
