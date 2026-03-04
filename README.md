# OFSZ Tooling

VPN toolkit for macOS — unified CLI and menu bar control for Tailscale, AWS VPN, and WatchGuard.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/sarimarton-ofsz/ofsz-tooling/main/install.sh | bash
```

Requires [gum](https://github.com/charmbracelet/gum) for the installer UI: `brew install gum`

## Structure

```
ofsz-tooling/
├── install.sh          # Meta-installer (runs all tool installers)
└── vpn/
    ├── install.sh      # VPN tool installer (PATH, SwiftBar, prereqs)
    ├── vpn             # CLI binary
    ├── lib.sh          # Shared VPN library
    ├── aws-connect.sh  # AWS VPN connector (SAML/CLI)
    ├── aws-saml-server.py  # SAML capture server
    ├── vpn.30s.sh      # SwiftBar menu bar plugin
    └── run/            # Runtime data (gitignored)
```

The repo is cloned to `~/.config/ofsz-tooling/`. Each tool lives in its own directory with its own `install.sh`.

## What it does

- Installs the `vpn` CLI to `~/.config/ofsz-tooling/vpn/` and adds it to PATH
- Symlinks a SwiftBar menu bar plugin (if SwiftBar is installed)
- Checks prerequisites and tells you what's missing

## Prerequisites

| Tool | Install |
|---|---|
| gum | `brew install gum` |
| AWS VPN Client | https://aws.amazon.com/vpn/client-vpn-download/ |
| Tailscale | https://tailscale.com/download/mac |
| WatchGuard Mobile VPN with SSL | IT department |
| SwiftBar (optional) | `brew install --cask swiftbar` |

## Usage

```
vpn status              # Show all VPN states
vpn preset all          # Connect all three (safe order: AWS → WG → TS)
vpn preset aws-ts       # Connect AWS + Tailscale
vpn ts-up / ts-down     # Individual Tailscale control
vpn aws-up / aws-down   # Individual AWS VPN control
vpn wg-up / wg-down     # Individual WatchGuard control
vpn kill-all            # Disconnect everything
vpn check               # Full network diagnostics
vpn help                # All commands
```

## First-time setup

After install, run these once:

```bash
vpn setup               # Configure passwordless sudo for AWS openvpn binary
vpn wg-set-password     # Store WatchGuard password in macOS Keychain
```

Then open AWS VPN Client GUI once → File → Manage Profiles → Add Profile → connect once. After that, the CLI takes over.

## SwiftBar menu

If SwiftBar is installed, a VPN icon appears in the menu bar showing how many VPNs are connected. The dropdown shows:
- Status of each VPN (with interface/IP tooltips)
- Preset buttons (Cmd+Opt+1 = All Three, Cmd+Opt+2 = AWS+TS)
- Individual connect/disconnect controls
- Kill All and Diagnostics

## Preset ordering

Presets force-disconnect all VPNs first, then reconnect in a safe order:

1. **AWS VPN** first — sets aggressive routes (10.254.x gateway)
2. **WatchGuard** second — adds private subnet routes (10.x, 172.x, 192.168.x)
3. **Tailscale** last — uses CGNAT (100.x), most resilient, adapts to existing routes

This ensures no route conflicts. Each VPN gets its own `utun` interface.

## Updating

Re-run the install command — it does `git pull` if already cloned.
