#!/bin/bash
# Wrapper around vpnc-script for GlobalProtect split-DNS.
#
# Problem: openconnect's default vpnc-script sets corporate DNS as the
# system-wide default resolver, breaking public DNS (github.com, etc.).
#
# Solution: strip DNS variables so vpnc-script only sets up routing.
# Corporate DNS is handled separately via /etc/resolver/ files that
# macOS reads natively for per-domain resolution.
unset INTERNAL_IP4_DNS
unset INTERNAL_IP6_DNS

# Runs as root (spawned by sudo openconnect), so $HOME is not the user's.
# User-level homebrew (non-admin machines) lives under the owner's home —
# derive it from this script's own installed path (/Users/<owner>/...).
owner_home=""
case "$0" in
    /Users/*)
        rest="${0#/Users/}"
        owner_home="/Users/${rest%%/*}"
        ;;
esac

for vpnc_script in \
    /opt/homebrew/etc/vpnc/vpnc-script \
    /usr/local/etc/vpnc/vpnc-script \
    "$owner_home/homebrew/etc/vpnc/vpnc-script"; do
    [ -x "$vpnc_script" ] && exec "$vpnc_script" "$@"
done

echo "gp-vpnc-script: vpnc-script not found (tried /opt/homebrew, /usr/local, $owner_home/homebrew)" >&2
exit 1
