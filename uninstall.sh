#!/usr/bin/env bash
# OFSZ Tooling — meta-uninstaller
# Usage: bash uninstall.sh         (interactive — select modules)
#        bash uninstall.sh --all   (non-interactive — remove everything)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$HOME/.config/ofsz-tooling"
SHARE_DIR="$HOME/.local/share/ofsz-tooling"
ALL=false
[[ "${1:-}" == "--all" ]] && ALL=true

if ! $ALL && ! command -v gum &>/dev/null; then
    echo "gum is required. Install: brew install gum"
    exit 1
fi

header() {
    echo ""
    if $ALL; then
        echo "── $1 ──"
    else
        gum style --border rounded --border-foreground 214 --padding "0 2" --bold "$1"
    fi
}

header "OFSZ Tooling Uninstaller"

# ── Discover installed modules ───────────────────────────
mod_dirs=()
mod_names=()
mod_descs=()

for uninstaller in "$SCRIPT_DIR"/*/uninstall.sh; do
    [ -f "$uninstaller" ] || continue
    mod="$(basename "$(dirname "$uninstaller")")"
    mod_dirs+=("$mod")
    desc_file="$SCRIPT_DIR/$mod/.description"
    if [ -f "$desc_file" ]; then
        mod_names+=("$(sed -n '1p' "$desc_file")")
        mod_descs+=("$(sed -n '2p' "$desc_file")")
    else
        mod_names+=("$mod")
        mod_descs+=("")
    fi
done

if [ ${#mod_dirs[@]} -eq 0 ]; then
    echo "Nincs telepített modul — adatok törlése..."
    rm -rf "$DATA_DIR"
    [ -d "$SHARE_DIR" ] && rm -rf "$SHARE_DIR"
    echo "✓ Törölve."
    exit 0
fi

# ── Select modules ───────────────────────────────────────
removed=0
total=${#mod_dirs[@]}

if $ALL; then
    # Non-interactive: uninstall all modules
    for i in "${!mod_dirs[@]}"; do
        header "Uninstalling: ${mod_names[$i]}"
        bash "$SCRIPT_DIR/${mod_dirs[$i]}/uninstall.sh" || true
        ((removed++)) || true
    done
else
    # Interactive: let user pick
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

    while IFS= read -r sel; do
        [ -n "$sel" ] || continue
        for i in "${!choices[@]}"; do
            if [ "${choices[$i]}" = "$sel" ]; then
                header "Uninstalling: ${mod_names[$i]}"
                bash "$SCRIPT_DIR/${mod_dirs[$i]}/uninstall.sh" || true
                ((removed++)) || true
                break
            fi
        done
    done <<< "$selected"
fi

# ── Full cleanup if all modules removed ──────────────────
if [ "$removed" -lt "$total" ]; then
    echo ""
    gum style --border double --border-foreground 76 --padding "0 2" --bold \
        "✓ Kiválasztott modulok eltávolítva"
    echo ""
    exit 0
fi

# Remove brew dependencies we installed (tracked in .installed-deps)
DEPS_FILE="$DATA_DIR/.installed-deps"
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

# Clean up data directory
rm -rf "$DATA_DIR"
echo "✓ $DATA_DIR törölve"

# Clean up clone directory (curl-based install) — only if not the current repo
if [ -d "$SHARE_DIR" ]; then
    rm -rf "$SHARE_DIR"
    echo "✓ $SHARE_DIR törölve"
fi

if $remove_gum; then
    brew uninstall gum 2>/dev/null || true
    echo "✓ gum eltávolítva"
fi

echo ""
echo "✓ Kész."
