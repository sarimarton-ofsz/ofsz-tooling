# OFSZ Tooling

- **After every change**, ask the user to run the local uninstall then the GitHub curl-based setup.
- **IMPORTANT:** Always use the commit hash in the curl URL, not `main` — GitHub's raw CDN caches aggressively and `main` may serve stale content.
  ```bash
  ~/.config/ofsz-tooling/vpn/uninstall.sh && curl -fsSL https://raw.githubusercontent.com/sarimarton-ofsz/ofsz-tooling/<COMMIT_HASH>/setup.sh | bash
  ```
- This ensures the installed version always matches the committed code — changes only take effect after push + reinstall.
