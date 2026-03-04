# OFSZ Tooling

VPN kezelő macOS-re — Tailscale, AWS VPN és WatchGuard egy helyről.

- Mind a 3 VPN csatlakoztatása biztonságos sorrendben, egy kattintással
- Az AWS VPN Client GUI-ra nincs többé szükség — nincs több AWS ikon a Dockban

![VPN menüsáv](vpn-menu.png)

## Telepítés

```bash
curl -fsSL https://raw.githubusercontent.com/sarimarton-ofsz/ofsz-tooling/main/setup.sh | bash
```

A telepítő mindent elintéz: letölti a szükséges eszközöket, bekéri a jelszavakat, és beállítja a menüsáv ikont.

### Előfeltételek

Ezeket kézzel kell telepíteni a futtatás előtt:

| Alkalmazás | Honnan |
|---|---|
| AWS VPN Client | https://self-service.clientvpn.amazonaws.com/endpoints/cvpn-endpoint-022755a701a9c6b8c |
| Tailscale | https://tailscale.com/download/mac |
| WatchGuard Mobile VPN with SSL | IT osztály |

> **Fontos:** A telepítő futtatása előtt mindhárom VPN-hez csatlakozz egyszer kézzel a saját alkalmazásán keresztül. Ez létrehozza a szükséges profilokat és konfigurációkat, amiket a CLI utána átvesz.

## Használat

A menüsávban megjelenik egy VPN ikon — onnan mindent el tudsz érni.

Terminálból:

```
vpn preset all          # Mind a három (AWS → WatchGuard → Tailscale)
vpn preset aws-ts       # AWS + Tailscale
vpn aws-up / aws-down   # AWS VPN
vpn ts-up / ts-down     # Tailscale
vpn wg-up / wg-down     # WatchGuard
vpn kill-all            # Minden lecsatlakoztatása
vpn status              # Állapot
vpn check               # Hálózati diagnosztika
```

## Frissítés

Futtasd újra a telepítő parancsot.
