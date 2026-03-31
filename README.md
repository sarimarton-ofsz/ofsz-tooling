# OFSZ Tooling

VPN kezelő macOS-re — Tailscale, AWS VPN és GlobalProtect egy helyről.

- **Perzisztens AWS kapcsolat, böngésző nélkül** — az Entra ID SAML login háttérben fut (Playwright), a session megmarad újracsatlakozáskor
- **Perzisztens céges VPN** — a GlobalProtect app nem szükséges, headless `openconnect` kezeli a tunnelt
- **A VPN-ek nem akadnak össze** — az AWS connect automatikusan kezeli a Tailscale-t (route konfliktus elkerülése), a split-DNS biztosítja, hogy a céges DNS ne törje el a publikus feloldást

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

> **Fontos:** Az AWS VPN Client-hez csatlakozz egyszer kézzel a GUI-n keresztül a telepítő futtatása előtt. Ez létrehozza a szükséges profilt, amit a CLI utána átvesz.

## Használat

A menüsávban megjelenik egy VPN ikon — onnan mindent el tudsz érni.

Terminálból:

```
vpn preset all          # Mind a három (AWS → GlobalProtect → Tailscale)
vpn preset aws-ts       # AWS + Tailscale
vpn aws-up / aws-down   # AWS VPN
vpn ts-up / ts-down     # Tailscale
vpn gp-up / gp-down     # GlobalProtect
vpn kill-all            # Minden lecsatlakoztatása
vpn status              # Állapot
vpn check               # Hálózati diagnosztika
```

## Frissítés

Futtasd újra a telepítő parancsot.

## Eltávolítás

```bash
bash ~/.local/share/ofsz-tooling/uninstall.sh
```
