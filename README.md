# OFSZ Tooling

VPN toolkit for macOS — unified CLI and menu bar control for Tailscale, AWS VPN, and WatchGuard.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/sarimarton-ofsz/ofsz-tooling/main/setup.sh | bash
```

## Structure

```
ofsz-tooling/
├── setup.sh            # Meta-installer (status, module selection, install)
└── vpn/
    ├── install.sh      # VPN tool installer (PATH, SwiftBar, prereqs)
    ├── vpn             # CLI binary
    ├── lib.sh          # Shared VPN library
    ├── aws-connect.sh  # AWS VPN connector (SAML/CLI)
    ├── aws-saml-server.py  # SAML capture server
    ├── vpn.30s.sh      # SwiftBar menu bar plugin
    └── run/            # Runtime data (gitignored)
```

The repo is cloned to `~/.config/ofsz-tooling/`. Each tool lives in its own directory with its own `install.sh` and `.description`.

## What it does

- Auto-installs Homebrew and gum if missing
- Installs the `vpn` CLI to `~/.config/ofsz-tooling/vpn/` and adds it to PATH
- Auto-installs SwiftBar and symlinks the menu bar plugin
- Auto-configures sudoers for AWS VPN and prompts for WatchGuard password
- Warns about native apps that need manual install (Tailscale, AWS VPN Client, WatchGuard)

## Prerequisites (auto-installed where possible)

| Tool | Install |
|---|---|
| Homebrew | Auto-installed by setup.sh |
| gum | Auto-installed by setup.sh |
| SwiftBar | Auto-installed by setup.sh |
| AWS VPN Client | https://aws.amazon.com/vpn/client-vpn-download/ |
| Tailscale | https://tailscale.com/download/mac |
| WatchGuard Mobile VPN with SSL | IT department |

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

The installer handles sudoers and WatchGuard password automatically. You only need to:

1. Open AWS VPN Client GUI once → File → Manage Profiles → Add Profile → connect once. After that, the CLI takes over.

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

Re-run the setup command — it does `git pull` if already cloned.
