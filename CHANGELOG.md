# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

---

## [1.2.0] — 2026-05-15

### Added
- Remote advisory fetching: `advisories/npm.json` and `advisories/pip.json` are now
  fetched from GitHub on every run (8 s timeout, `curl`/`wget`) and cached locally at
  `~/.cache/pkg-audit/` for offline use.
- `USER_CUSTOM_NPM` / `USER_CUSTOM_PIP` arrays in the user config section — append
  private/internal packages on top of the remote list without editing the internals.
- Advisory source indicator printed in the run header (`remote` / `cache (offline)` /
  `unavailable — no cache`) so the user always knows which list was used.
- Warning printed when the npm advisory list is unavailable with no local cache.

### Removed
- Hard-coded `NPM_COMPROMISED` / `PIP_COMPROMISED` arrays from the script internals —
  `advisories/npm.json` is now the single source of truth.

---

## [1.1.0] — 2026-05-14

### Added
- `--npm-only` flag: skip all pip checks.
- `--pip-only` flag: skip all npm checks (global + working tree + branches).
- `--quiet` / `-q` flag: suppress safe/info lines, show only hits and errors.
- `--no-global` flag: skip the global npm package check.
- `--limit` / `-l <n>` flag: override `SCAN_LIMIT` at runtime.
- `--branches` / `-b` flag: enable all-branch scanning without editing the config.
- `--path` / `-p <dir>` flag: specify a scan directory without editing the config.
- `--append` / `-a` flag: add `--path` dir on top of `USER_SCAN_DIRS` instead of replacing.
- Dynamic padding in the summary box so the hit count aligns regardless of digit length.

### Changed
- `USER_SCAN_DIRS` defaults to `~/workspace` — users add their own paths in the config section.
- `CHECK_ALL_BRANCHES` defaults to `false`; enable with `--branches`.
- Branch scanning skips the currently checked-out branch (already covered by the working-tree scan) and skips git worktrees (`.git` as a file).
- `find` prunes known noise directories: `node_modules`, `.git`, `.npm`, `.cache`, `.yarn`, `.nvm`, `.pnpm-store`, `.venv`, `venv`, `.docker`, `.m2`.

### Fixed
- Positional path argument replaced by proper flag parsing so argument order no longer matters.

---

## [1.0.0] — 2026-05-01

### Added
- Initial release.
- npm global package check via `npm list -g --depth=0`.
- Working-tree scan: recursive `find` for `package-lock.json` files with `SCAN_LIMIT` cap.
- All-branch scan: `git show <branch>:package-lock.json` with no checkout required.
- pip check via `pip3`/`pip list --format=columns`.
- Inline `python3` parser for `package-lock.json` (`packages` and `dependencies` sections).
- ANSI colour output: red hits, yellow warnings, green safe, cyan section headers, blue folder paths, magenta branch names.
- `flag_hit()` / `flag_warn()` helpers distinguishing compromised versions from safe installs of monitored packages.
- Summary box with remediation advice; exit code equals the number of hits (CI-friendly).
- Works on Linux and macOS.
