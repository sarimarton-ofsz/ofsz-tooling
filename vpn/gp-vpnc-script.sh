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
exec /opt/homebrew/etc/vpnc/vpnc-script "$@"
