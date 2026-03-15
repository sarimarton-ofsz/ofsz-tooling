# OFSZ Tooling

- **After every change**, ask the user to run the local uninstall then setup from the repo.
- For local development (repo checkout):
  ```bash
  ./uninstall.sh   # from repo root
  ./setup.sh       # uses repo directly, no clone
  ```
- For remote install (curl), **IMPORTANT:** always use the commit hash, not `main` — GitHub's raw CDN caches aggressively:
  ```bash
  bash ~/.local/share/ofsz-tooling/uninstall.sh 2>/dev/null; curl -fsSL https://raw.githubusercontent.com/sarimarton-ofsz/ofsz-tooling/<COMMIT_HASH>/setup.sh | bash
  ```
- Scripts live in the repo (or `~/.local/share/ofsz-tooling` for curl install), runtime data lives in `~/.config/ofsz-tooling/`.
