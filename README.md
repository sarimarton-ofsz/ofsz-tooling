# OFSZ Tooling

VPN eszközkészlet macOS-re — egységes CLI és menüsáv-vezérlés Tailscale, AWS VPN és WatchGuard számára.

## Telepítés

```bash
curl -fsSL https://raw.githubusercontent.com/sarimarton-ofsz/ofsz-tooling/main/setup.sh | bash
```

## Struktúra

```
ofsz-tooling/
├── setup.sh            # Meta-telepítő (állapot, modulválasztás, install)
└── vpn/
    ├── install.sh      # VPN modul telepítő (PATH, SwiftBar, előfeltételek)
    ├── vpn             # CLI bináris
    ├── lib.sh          # Megosztott VPN könyvtár
    ├── aws-connect.sh  # AWS VPN csatlakozó (SAML/CLI)
    ├── aws-saml-server.py  # SAML capture szerver
    ├── vpn.30s.sh      # SwiftBar menüsáv plugin
    └── run/            # Futásidejű adatok (gitignore-olt)
```

A repó a `~/.config/ofsz-tooling/` könyvtárba klónozódik. Minden eszköz saját könyvtárban él, saját `install.sh`-val és `.description` fájllal.

## Mit csinál

- Automatikusan telepíti a Homebrew-t és a gum-ot, ha hiányoznak
- Telepíti a `vpn` CLI-t a `~/.config/ofsz-tooling/vpn/` könyvtárba és hozzáadja a PATH-hoz
- Automatikusan telepíti a SwiftBar-t és belinkelni a menüsáv plugint
- Automatikusan konfigurálja a sudoers-t az AWS VPN-hez és bekéri a WatchGuard jelszót
- Figyelmeztet a kézzel telepítendő alkalmazásokra (Tailscale, AWS VPN Client, WatchGuard)

## Előfeltételek (ahol lehet, automatikusan települ)

| Eszköz | Telepítés |
|---|---|
| Homebrew | Automatikus (setup.sh) |
| gum | Automatikus (setup.sh) |
| SwiftBar | Automatikus (setup.sh) |
| AWS VPN Client | https://aws.amazon.com/vpn/client-vpn-download/ |
| Tailscale | https://tailscale.com/download/mac |
| WatchGuard Mobile VPN with SSL | IT osztály |

## Használat

```
vpn status              # Összes VPN állapota
vpn preset all          # Mind a három csatlakoztatása (biztonságos sorrend: AWS → WG → TS)
vpn preset aws-ts       # AWS + Tailscale csatlakoztatása
vpn ts-up / ts-down     # Tailscale vezérlés
vpn aws-up / aws-down   # AWS VPN vezérlés
vpn wg-up / wg-down     # WatchGuard vezérlés
vpn kill-all            # Minden lecsatlakoztatása
vpn check               # Teljes hálózati diagnosztika
vpn help                # Összes parancs
```

## Első használat

A telepítő automatikusan kezeli a sudoers-t és a WatchGuard jelszót. Csak ennyi kell kézzel:

1. Nyisd meg az AWS VPN Client GUI-t → File → Manage Profiles → Add Profile → csatlakozz egyszer. Ezután a CLI átveszi.

## SwiftBar menü

Ha a SwiftBar telepítve van, egy VPN ikon jelenik meg a menüsávban, ami mutatja hány VPN csatlakozik. A lenyíló menüben:
- Minden VPN állapota (interfész/IP tooltippel)
- Preset gombok (Cmd+Opt+1 = Mind a három, Cmd+Opt+2 = AWS+TS)
- Egyedi csatlakozás/lecsatlakozás gombok
- Kill All és Diagnosztika

## Preset sorrend

A presetek először lecsatlakoztatnak mindent, majd biztonságos sorrendben újracsatlakoztatnak:

1. **AWS VPN** először — agresszív route-okat állít be (10.254.x gateway)
2. **WatchGuard** másodszor — privát alhálózati route-okat ad hozzá (10.x, 172.x, 192.168.x)
3. **Tailscale** utoljára — CGNAT-ot használ (100.x), a legrugalmasabb, alkalmazkodik a meglévő route-okhoz

Így nincs route ütközés. Minden VPN saját `utun` interfészt kap.

## Frissítés

Futtasd újra a telepítő parancsot — ha már klónozva van, `git pull`-t csinál.
