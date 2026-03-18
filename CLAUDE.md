# OFSZ Tooling

- **After every change**, ask the user to run uninstall then the hash-pinned curl setup.
- **IMPORTANT:** Always use the commit hash in the curl URL, not `main` — GitHub's raw CDN caches aggressively and `main` may serve stale content.
  ```bash
  bash ~/.local/share/ofsz-tooling/uninstall.sh --all 2>/dev/null; curl -fsSL https://raw.githubusercontent.com/sarimarton-ofsz/ofsz-tooling/<COMMIT_HASH>/setup.sh | bash
  ```
- Scripts live in `~/.local/share/ofsz-tooling/` (clone), runtime data lives in `~/.config/ofsz-tooling/`.
