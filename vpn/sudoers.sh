#!/usr/bin/env bash
# sudoers.sh — shared management of /etc/sudoers.d/vpn
# Source this file, do not execute directly. Defines functions only.
#
# Single source of truth for the NOPASSWD template — install.sh, `vpn setup`,
# aws-connect.sh and uninstall.sh all build/compare/write through here.
#
# Non-admin friendly (MDM machines where the login user is not an admin):
#   - content check reads the file via the NOPASSWD'd /usr/bin/sed rule,
#     so no password is needed once the current template is installed
#   - writes escalate exactly once: admins via plain sudo, non-admins via
#     the macOS admin-credentials dialog (osascript "with administrator
#     privileges"), which accepts ANY admin account's name + password
#   - if neither works (e.g. SSH session, dialog cancelled), a copy-paste
#     `su <admin>` recipe is printed as fallback

SUDOERS_FILE="/etc/sudoers.d/vpn"
SUDOERS_FILE_OLD="/etc/sudoers.d/vpn-aws"
SUDOERS_OVPN_BIN="/Applications/AWS VPN Client/AWS VPN Client.app/Contents/Resources/openvpn/acvc-openvpn"

# Must resolve to the same absolute path as lib.sh:_resolve_openconnect,
# or the installed NOPASSWD rule won't match the binary lib.sh invokes.
# Checks stable install paths, not just PATH — SwiftBar/launchd contexts
# don't see user-level homebrew (~/homebrew).
_sudoers_openconnect_bin() {
    local c
    for c in "$(command -v openconnect 2>/dev/null)" \
             "$HOME/homebrew/bin/openconnect" \
             /opt/homebrew/bin/openconnect \
             /usr/local/bin/openconnect; do
        [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return; }
    done
    echo /opt/homebrew/bin/openconnect
}

# The canonical template. Covers every sudo call the VPN tools make at
# runtime (lib.sh, aws-connect.sh, vpn.30s.sh, uninstall.sh).
sudoers_expected_content() {
    local ovpn_escaped="${SUDOERS_OVPN_BIN// /\\ }"
    printf '%s ALL=(ALL) NOPASSWD: %s *\n' \
        "$USER" "$ovpn_escaped" \
        "$USER" "$(_sudoers_openconnect_bin)" \
        "$USER" "/bin/kill" \
        "$USER" "/usr/bin/tee" \
        "$USER" "/bin/mkdir" \
        "$USER" "/bin/rm" \
        "$USER" "/usr/bin/sed" \
        "$USER" "/usr/sbin/dscacheutil" \
        "$USER" "/usr/bin/killall" \
        "$USER" "/usr/bin/pkill" \
        "$USER" "/sbin/route"
}

sudoers_user_is_admin() {
    id -Gn "$USER" 2>/dev/null | grep -qw admin
}

# Prints: current | outdated | missing
sudoers_status() {
    [ -f "$SUDOERS_FILE" ] || { echo "missing"; return; }
    local current
    # /usr/bin/sed is NOPASSWD'd by the current template → passwordless read
    # even for non-admin users. Read failure means a pre-sed template (or a
    # foreign file) → treat as outdated.
    if current=$(sudo -n /usr/bin/sed -n p "$SUDOERS_FILE" 2>/dev/null); then
        if [ "$current" = "$(sudoers_expected_content)" ]; then
            echo "current"
        else
            echo "outdated"
        fi
    else
        echo "outdated"
    fi
}

# Write/refresh the sudoers file in ONE privileged operation:
# visudo-validate first, install only if valid (no broken-file window),
# and clean up the legacy vpn-aws file in the same escalation.
sudoers_write() {
    local expected tmp priv_cmd rc=0
    expected="$(sudoers_expected_content)"
    tmp="$(mktemp)"
    printf '%s\n' "$expected" > "$tmp"
    chmod 644 "$tmp"
    priv_cmd="/usr/sbin/visudo -cf '$tmp' && /usr/bin/install -m 440 -o root -g wheel '$tmp' '$SUDOERS_FILE' && /bin/rm -f '$SUDOERS_FILE_OLD'"
    if sudoers_user_is_admin; then
        echo "[sudoers] sudo jelszó szükséges (a saját jelszavad)" >&2
        sudo /bin/sh -c "$priv_cmd" || rc=1
    else
        echo "[sudoers] Nem-admin user — macOS admin hitelesítés következik." >&2
        echo "[sudoers] A felugró ablakba egy ADMIN felhasználó nevét és jelszavát írd (nem a sajátodat)." >&2
        osascript -e "do shell script \"$priv_cmd\" with administrator privileges" > /dev/null || rc=1
    fi
    rm -f "$tmp"
    if [ $rc -ne 0 ]; then
        sudoers_print_admin_recipe
        return 1
    fi
}

# Remove the sudoers file(s). The current template NOPASSWD's /bin/rm, so
# the file authorizes its own passwordless removal; older templates fall
# back to the same escalation paths as sudoers_write.
sudoers_remove() {
    { [ -f "$SUDOERS_FILE" ] || [ -f "$SUDOERS_FILE_OLD" ]; } || return 0
    if sudo -n /bin/rm -f "$SUDOERS_FILE" "$SUDOERS_FILE_OLD" 2>/dev/null; then
        return 0
    fi
    local priv_cmd="/bin/rm -f '$SUDOERS_FILE' '$SUDOERS_FILE_OLD'"
    if sudoers_user_is_admin; then
        sudo /bin/sh -c "$priv_cmd"
    else
        osascript -e "do shell script \"$priv_cmd\" with administrator privileges" > /dev/null
    fi
}

# Manual fallback for sessions without GUI dialog (SSH) or cancelled auth.
sudoers_print_admin_recipe() {
    local expected
    expected="$(sudoers_expected_content)"
    cat >&2 <<EOF

Manuális beállítás admin fiókkal (pl. SSH-ból, ahol nincs GUI dialógus):
az admin user jelszavával átlépsz, a blokk pedig a TE useredre ($USER)
szóló szabályokat telepíti — utána a saját userednek nem kell jelszó.

  su <admin-user>
  sudo tee $SUDOERS_FILE > /dev/null <<'SUDOERS'
$expected
SUDOERS
  sudo chmod 440 $SUDOERS_FILE
  sudo visudo -cf $SUDOERS_FILE   # "parsed OK" kell
  sudo rm -f $SUDOERS_FILE_OLD
  exit

EOF
}
