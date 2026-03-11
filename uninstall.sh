#!/usr/bin/env bash
# OFSZ Tooling — meta-uninstaller
# Usage: bash ~/.config/ofsz-tooling/uninstall.sh
set -euo pipefail

INSTALL_DIR="$HOME/.config/ofsz-tooling"

if ! command -v gum &>/dev/null; then
    echo "gum is required. Install: brew install gum"
    exit 1
fi

header() {
    echo ""
    gum style --border rounded --border-foreground 214 --padding "0 2" --bold "$1"
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
    gum log --level info "Nincs telepített modul — repo törlése..."
    rm -rf "$INSTALL_DIR"
    echo "✓ Törölve."
    exit 0
fi

# ── Show & select modules ───────────────────────────────
echo ""
gum style --bold "Telepített modulok"
choices=()
for i in "${!mod_dirs[@]}"; do
    label="${mod_names[$i]}"
    [ -n "${mod_descs[$i]}" ] && label="${mod_names[$i]} — ${mod_descs[$i]}"
    gum log --level info --prefix "✓" "$label"
    choices+=("$label")
done

echo ""
selected=$(printf '%s\n' "${choices[@]}" | gum choose --no-limit --header "Eltávolítandó modulok:")

if [ -z "$selected" ]; then
    echo ""
    gum log --level info "Nincs kiválasztott modul"
    exit 0
fi

# ── Run selected module uninstallers ─────────────────────
removed=0
total=${#mod_dirs[@]}

while IFS= read -r sel; do
    [ -n "$sel" ] || continue
    for i in "${!choices[@]}"; do
        if [ "${choices[$i]}" = "$sel" ]; then
            header "Uninstalling: ${mod_names[$i]}"
            bash "$INSTALL_DIR/${mod_dirs[$i]}/uninstall.sh" || true
            ((removed++)) || true
            break
        fi
    done
done <<< "$selected"

# ── Full cleanup if all modules removed ──────────────────
if [ "$removed" -lt "$total" ]; then
    echo ""
    gum style --border double --border-foreground 76 --padding "0 2" --bold \
        "✓ Kiválasztott modulok eltávolítva" \
        "" \
        "Repo megmaradt: $INSTALL_DIR"
    echo ""
    exit 0
fi

# Remove brew dependencies we installed (tracked in .installed-deps)
DEPS_FILE="$INSTALL_DIR/.installed-deps"
remove_gum=false
if [ -f "$DEPS_FILE" ]; then
    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        case "$dep" in
            gum)
                remove_gum=true ;;  # removed last — we still need it for prompts
            swiftbar)
                killall SwiftBar 2>/dev/null || true
                brew uninstall --cask swiftbar 2>/dev/null || true
                gum log --level info --prefix "✓" "SwiftBar eltávolítva"
                ;;
            google-chrome)
                killall "Google Chrome" 2>/dev/null || true
                brew uninstall --cask google-chrome 2>/dev/null || true
                gum log --level info --prefix "✓" "Google Chrome eltávolítva"
                ;;
            *)
                brew uninstall "$dep" 2>/dev/null || true
                gum log --level info --prefix "✓" "$dep eltávolítva"
                ;;
        esac
    done < "$DEPS_FILE"
fi

rm -rf "$INSTALL_DIR"
echo ""
echo "✓ $INSTALL_DIR törölve"

if $remove_gum; then
    brew uninstall gum 2>/dev/null || true
    echo "✓ gum eltávolítva"
fi

echo ""
echo "✓ Kész."
