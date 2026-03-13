# OFSZ Tooling

- **After every change**, ask the user to run the local uninstall then the GitHub curl-based setup:
  ```bash
  ~/.config/ofsz-tooling/vpn/uninstall.sh && curl -fsSL https://raw.githubusercontent.com/sarimarton-ofsz/ofsz-tooling/main/setup.sh | bash
  ```
- This ensures the installed version always matches the committed code — changes only take effect after push + reinstall.
