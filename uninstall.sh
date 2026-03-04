#!/usr/bin/env bash
# OFSZ Tooling — uninstaller
# Usage: bash ~/.config/ofsz-tooling/uninstall.sh
set -euo pipefail

INSTALL_DIR="$HOME/.config/ofsz-tooling"

# ── Ensure gum is available ──────────────────────────────
if ! command -v gum &>/dev/null; then
    echo "gum is required. Install: brew install gum"
    exit 1
fi

header() {
    echo ""
    gum style --border rounded --border-foreground 196 --padding "0 2" --bold "$1"
}

header "OFSZ Tooling Uninstaller"

# ── Discover installed modules ───────────────────────────
mod_dirs=()
mod_names=()
mod_descs=()

for uninstaller in "$INSTALL_DIR"/*/uninstall.sh; do
    [ -f "$uninstaller" ] || continue
    mod="$(basename "$(dirname "$uninstaller")")"
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
    # Nothing installed — just clean up the repo and exit
    gum log --level info "Nincs telepített modul"
    rm -rf "$INSTALL_DIR"
    gum log --level info --prefix "✓" "Repository removed"
    echo ""
    gum style --border double --border-foreground 76 --padding "0 2" --bold \
        "✓ Uninstall complete"
    echo ""
    exit 0
fi

# Show modules
echo ""
gum style --bold "Telepített modulok"
for i in "${!mod_dirs[@]}"; do
    label="${mod_names[$i]}"
    [ -n "${mod_descs[$i]}" ] && label="${mod_names[$i]} — ${mod_descs[$i]}"
    gum log --level info --prefix "✓" "$label"
done

# Select modules to uninstall
choices=()
for i in "${!mod_dirs[@]}"; do
    label="${mod_names[$i]}"
    [ -n "${mod_descs[$i]}" ] && label="${mod_names[$i]} — ${mod_descs[$i]}"
    choices+=("$label")
done

echo ""
selected=$(printf '%s\n' "${choices[@]}" | gum choose --no-limit --header "Eltávolítandó modulok:")

if [ -n "$selected" ]; then
    while IFS= read -r sel; do
        [ -n "$sel" ] || continue
        for i in "${!choices[@]}"; do
            if [ "${choices[$i]}" = "$sel" ]; then
                header "Uninstalling: ${mod_names[$i]}"
                bash "$INSTALL_DIR/${mod_dirs[$i]}/uninstall.sh"
                break
            fi
        done
    done <<< "$selected"
fi

# ── Offer to remove the repo ────────────────────────────
echo ""
if gum confirm "Repo törlése ($INSTALL_DIR)?"; then
    rm -rf "$INSTALL_DIR"
    gum log --level info --prefix "✓" "Repository removed"
    echo ""
    gum style --border double --border-foreground 76 --padding "0 2" --bold \
        "✓ Uninstall complete"
else
    echo ""
    gum style --border double --border-foreground 76 --padding "0 2" --bold \
        "✓ Modules removed — repo kept at $INSTALL_DIR"
fi
echo ""
