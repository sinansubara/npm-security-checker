# npm-security-checker

A lightweight Bash script that audits your local npm and pip packages against a
continuously-maintained list of known-compromised package versions.

## Features

- **Remote advisory list** — fetched automatically from this repo on every run and cached locally for offline use
- **npm global packages** — checks your globally installed npm packages
- **npm working tree** — recursively finds every `package-lock.json` under your configured scan directories
- **All git branches** — optionally reads `package-lock.json` from every non-checked-out branch via `git show` (no checkout needed)
- **pip packages** — checks installed Python packages via `pip3`/`pip`
- **Custom packages** — append your own private/internal package entries on top of the remote list
- **CI-friendly** — exits with the number of hits (0 = clean); works with `--quiet` and `--json`*(coming soon)*
- **No dependencies** — pure Bash; requires only `python3` (for JSON parsing), `git`, `npm`/`pip` as applicable, and `curl` or `wget` for advisory fetching

## Requirements

| Tool | Purpose |
|---|---|
| `bash` ≥ 4.0 | Script runtime (macOS ships bash 3 — install via Homebrew: `brew install bash`) |
| `python3` | Parsing `package-lock.json` and advisory JSON files |
| `curl` or `wget` | Fetching the remote advisory list |
| `npm` | Global npm check and working-tree scan |
| `git` | Branch scanning (optional) |
| `pip3` / `pip` | pip package check (optional) |

## Quick start

```bash
# Clone
git clone https://github.com/sinansubara/npm-security-checker.git
cd npm-security-checker

# Make executable
chmod +x pkg-audit.sh

# Edit the scan directories (one-time setup)
# Open pkg-audit.sh and set USER_SCAN_DIRS to your workspace root(s)

# Run
./pkg-audit.sh
```

## Configuration

Open `pkg-audit.sh` and edit the **USER CONFIG** section at the top:

```bash
# Directories to scan recursively for package-lock.json files
USER_SCAN_DIRS=(
  "~/workspace"
  # "~/side-projects"
)

# Set to true to also scan all git branches (slow on large repos)
CHECK_ALL_BRANCHES=false

# Cap on the number of lock files scanned (default: 300)
SCAN_LIMIT=300
```

### Custom packages

Add packages not yet in the remote advisory list to the **CUSTOM PACKAGES** section:

```bash
USER_CUSTOM_NPM=(
  "my-internal-package::1.0.0,1.0.1"
)

USER_CUSTOM_PIP=(
  "my-internal-lib::2.3.4"
)
```

## Flags

All flags are optional and order-independent.

| Flag | Short | Description |
|---|---|---|
| `--path <dir>` | `-p` | Scan only this directory (replaces `USER_SCAN_DIRS`) |
| `--append` | `-a` | Append `--path` dir on top of `USER_SCAN_DIRS` instead of replacing |
| `--branches` | `-b` | Also scan all git branches (slow) |
| `--limit <n>` | `-l` | Override `SCAN_LIMIT` |
| `--no-global` | | Skip the global npm package check |
| `--quiet` | `-q` | Print only hits and errors — no safe/info lines |
| `--npm-only` | | Skip all pip checks |
| `--pip-only` | | Skip all npm checks (global + working tree + branches) |

### Examples

```bash
# Scan a specific project only
./pkg-audit.sh -p /my/project

# Scan a project AND all configured directories
./pkg-audit.sh -p /my/project --append

# Scan configured directories plus all git branches
./pkg-audit.sh --branches

# CI mode — quiet, single project, exit code = hit count
./pkg-audit.sh -q -p /my/project
```

## Advisory list

The compromised package list lives in [`advisories/npm.json`](advisories/npm.json) and [`advisories/pip.json`](advisories/pip.json).

On each run the script:
1. Fetches the latest list from this repo (8 s timeout)
2. Caches it at `~/.cache/pkg-audit/` for offline use
3. Falls back to the cache if the remote is unreachable

The advisory source is printed in the header of every run:
```
Advisories:  npm ← remote  |  pip ← remote
```

## Adding a new advisory

1. Edit [`advisories/npm.json`](advisories/npm.json) (or `pip.json`)
2. Add an entry to the `packages` array — two forms are supported:

   **Specific compromised versions** (the package is safe at other versions):
   ```json
   {
     "name": "package-name",
     "source": "https://link-to-advisory",
     "compromised_versions": ["1.2.3", "1.2.4"]
   }
   ```

   **Entirely fake / malicious package** (any version installed → flag it):
   ```json
   {
     "name": "fake-package-name",
     "source": "https://link-to-advisory"
   }
   ```

   For incidents covering many packages at once, add a top-level `references` array:
   ```json
   {
     "schema": 1,
     "updated": "2026-05-20",
     "references": ["https://link-to-incident-report"],
     "packages": [ ... ]
   }
   ```

3. Open a PR — see [CONTRIBUTING.md](CONTRIBUTING.md)

## Exit codes

| Code | Meaning |
|---|---|
| `0` | No compromised packages found |
| `N > 0` | N compromised packages detected |

## Cache location

| Platform | Path |
|---|---|
| Linux / macOS (default) | `~/.cache/pkg-audit/` |
| Custom | `$XDG_CACHE_HOME/pkg-audit/` |

## License

[MIT](LICENSE)
