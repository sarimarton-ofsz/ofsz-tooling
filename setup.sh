#!/usr/bin/env bash
# OFSZ Tooling — meta-installer
# Usage:
#   Local repo:  ./setup.sh
#   Remote:      curl -fsSL https://raw.githubusercontent.com/sarimarton-ofsz/ofsz-tooling/<hash>/setup.sh | bash
#
# The { ... } block ensures bash reads the entire script before executing,
# preventing brew/curl output from interleaving with the script when piped.
{
set -euo pipefail

REPO_URL="https://github.com/sarimarton-ofsz/ofsz-tooling.git"
DATA_DIR="$HOME/.config/ofsz-tooling"
OLD_INSTALL_DIR="$HOME/.config/vpn"

# Detect if running from a local repo checkout
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || true
if [ -n "$_script_dir" ] && [ -f "$_script_dir/vpn/vpn" ]; then
    INSTALL_DIR="$_script_dir"
    _local_repo=true
else
    INSTALL_DIR="$HOME/.local/share/ofsz-tooling"
    _local_repo=false
fi

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
_we_installed_gum=false
if ! command -v gum &>/dev/null; then
    echo "Installing gum via Homebrew..."
    brew install gum
    _we_installed_gum=true
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
    if [ -d "$DATA_DIR/vpn/config" ] || [ -d "$DATA_DIR/vpn/run" ]; then
        gum log --level warn "Old installation at $OLD_INSTALL_DIR still exists — skipping migration (data already present)"
        return
    fi

    header "Migrating old installation"
    gum log --level info "Extracting data from $OLD_INSTALL_DIR → $DATA_DIR"

    mkdir -p "$DATA_DIR/vpn/run"
    [ -f "$OLD_INSTALL_DIR/vpn/config" ] && cp "$OLD_INSTALL_DIR/vpn/config" "$DATA_DIR/vpn/config"
    [ -d "$OLD_INSTALL_DIR/vpn/run" ] && cp -a "$OLD_INSTALL_DIR/vpn/run/." "$DATA_DIR/vpn/run/"
    [ -f "$OLD_INSTALL_DIR/.installed-deps" ] && cp "$OLD_INSTALL_DIR/.installed-deps" "$DATA_DIR/"

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

    rm -rf "$OLD_INSTALL_DIR"
    gum log --level info --prefix "✓" "Migration complete"
}

# ── Migration from old git-repo-in-config layout ─────────
migrate_config_repo() {
    if [ ! -d "$DATA_DIR/.git" ]; then
        return
    fi

    header "Migrating config repo to data-only layout"

    # Preserve data in a temp location, then clean the git repo out
    local tmp
    tmp="$(mktemp -d)"
    [ -f "$DATA_DIR/.installed-deps" ] && cp "$DATA_DIR/.installed-deps" "$tmp/"
    if [ -d "$DATA_DIR/vpn" ]; then
        mkdir -p "$tmp/vpn"
        [ -f "$DATA_DIR/vpn/config" ] && cp "$DATA_DIR/vpn/config" "$tmp/vpn/"
        [ -d "$DATA_DIR/vpn/run" ] && cp -a "$DATA_DIR/vpn/run" "$tmp/vpn/"
    fi

    rm -rf "$DATA_DIR"
    mkdir -p "$DATA_DIR/vpn"
    [ -f "$tmp/.installed-deps" ] && mv "$tmp/.installed-deps" "$DATA_DIR/"
    [ -f "$tmp/vpn/config" ] && mv "$tmp/vpn/config" "$DATA_DIR/vpn/"
    [ -d "$tmp/vpn/run" ] && mv "$tmp/vpn/run" "$DATA_DIR/vpn/"
    rm -rf "$tmp"

    # Remove old PATH entry that pointed into .config
    local rc
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
        if [ -f "$rc" ] && grep -qF '.config/ofsz-tooling/vpn' "$rc" 2>/dev/null; then
            gum log --level info "Removing old PATH entry from $rc"
            sed -i '' '/# OFSZ VPN toolkit/d' "$rc"
            sed -i '' '/\.config\/ofsz-tooling\/vpn/d' "$rc"
        fi
    done

    # Remove old SwiftBar symlink (will be recreated by vpn/install.sh)
    local old_link="$HOME/Library/Application Support/SwiftBar/Plugins/vpn.30s.sh"
    if [ -L "$old_link" ]; then
        rm "$old_link"
    fi

    gum log --level info --prefix "✓" "Config repo migrated to data-only layout"
}

# ── Step 1: Migrate if needed ────────────────────────────
migrate_old_install
migrate_config_repo

# ── Step 2: Clone or update repo ─────────────────────────
header "OFSZ Tooling Installer"

mkdir -p "$DATA_DIR"

if $_local_repo; then
    gum log --level info --prefix "✓" "Using local repo: $INSTALL_DIR"
else
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
        mkdir -p "$(dirname "$INSTALL_DIR")"
        gum spin --spinner dot --title "Cloning repository..." -- \
            git clone "$REPO_URL" "$INSTALL_DIR"
        gum log --level info --prefix "✓" "Repository cloned to $INSTALL_DIR"
    fi
fi

# Record dependencies we installed (for clean uninstall)
DEPS_FILE="$DATA_DIR/.installed-deps"
[ -f "$DEPS_FILE" ] || touch "$DEPS_FILE"
if $_we_installed_gum && ! grep -qx 'gum' "$DEPS_FILE" 2>/dev/null; then
    echo "gum" >> "$DEPS_FILE"
fi

# ── Step 3: Status ───────────────────────────────────────
echo ""
gum style --bold "Állapot"
gum log --level info --prefix "✓" "Homebrew: $(brew --version 2>&1 | head -1)"
gum log --level info --prefix "✓" "gum: v$(gum --version 2>&1)"
gum log --level info --prefix "✓" "Scripts: $INSTALL_DIR"
gum log --level info --prefix "✓" "Data: $DATA_DIR"

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
            if grep -qF '# OFSZ VPN toolkit' "${HOME}/.zshrc" 2>/dev/null || \
               grep -qF '# OFSZ VPN toolkit' "${HOME}/.bashrc" 2>/dev/null; then
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
