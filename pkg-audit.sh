#!/bin/bash

# ╔═══════════════════════════════════════════════════════════════════════════════╗
# ║                  NPM / Pip Security – Compromised Package Checker             ║
# ║                       Works on: Linux / Ubuntu / macOS                        ║
# ╠═══════════════════════════════════════════════════════════════════════════════╣
# ║  Usage:                                                                       ║
# ║    chmod +x pkg-audit.sh                                                      ║
# ║    ./pkg-audit.sh                                                             ║
# ║                                                                               ║
# ║  Flags (all optional, order-independent):                                     ║
# ║    --path <dir>  / -p <dir>   scan only this dir (replaces config)            ║
# ║    --append      / -a         append --path dir on top of config dirs         ║
# ║    --branches    / -b         also scan all git branches (slow)               ║
# ║    --limit <n>   / -l <n>     override max lock files scanned (default: 300)  ║
# ║    --no-global                skip global npm package check                   ║
# ║    --quiet       / -q         only print hits and errors (no safe lines)      ║
# ║    --npm-only                 skip pip check entirely                         ║
# ║    --pip-only                 skip all npm checks (global + working tree)     ║
# ║                                                                               ║
# ║  Examples:                                                                    ║
# ║    ./pkg-audit.sh -p /my/project                                              ║
# ║    ./pkg-audit.sh -p /my/project -a          # append to config dirs          ║
# ║    ./pkg-audit.sh -p /my/project -a -b       # + branch scan                  ║
# ║    ./pkg-audit.sh --branches                 # config dirs + branches         ║
# ║    ./pkg-audit.sh -l 50                      # cap at 50 lock files           ║
# ║    ./pkg-audit.sh --no-global                # skip global npm check          ║
# ║    ./pkg-audit.sh -q                         # hits and errors only           ║
# ║    ./pkg-audit.sh --npm-only                 # skip pip                       ║
# ║    ./pkg-audit.sh --pip-only                 # skip all npm checks            ║
# ╚═══════════════════════════════════════════════════════════════════════════════╝


# ┌──────────────────────────────────────────────────────────────────────────┐
# │  ✏️  USER CONFIG — edit only this section                                │
# └──────────────────────────────────────────────────────────────────────────┘

# Folders to scan for package-lock.json files.
# Each folder is searched recursively — no need to list individual repos.
# Adding ~/workspace will automatically scan every repository inside it.
# ~ is expanded automatically.
USER_SCAN_DIRS=(
  # "$HOME"                 # CAUTION: scanning your entire home can be slow — noisy dirs are auto-skipped (node_modules, .npm, .cache, .nvm…)
  "$HOME/workspace"         # <- use a specific folder to speed things up
  # "$HOME/side-projects"   # <- uncomment or add more root folders as needed
  # "/opt/company"
)

# Set to true to also check package-lock.json across ALL git branches
# (not just the currently checked-out working tree).
# This uses "git show branch:package-lock.json" — no checkout needed.
# Can be slower on repos with many branches.
# Override any time with: ./pkg-audit.sh --branches
CHECK_ALL_BRANCHES=false

# Maximum number of package-lock.json files to inspect in the working tree
# (safety cap). Raise this if you have a very large number of repositories.
SCAN_LIMIT=300


# ┌──────────────────────────────────────────────────────────────────────────┐
# │  ➕  CUSTOM PACKAGES — optional user-defined additions                   │
# │      The compromised-package lists are fetched automatically from        │
# │      GitHub on each run and cached locally for offline use.              │
# │      Add entries here only for packages not yet in the remote list.      │
# │      Format: "package-name::bad_version1,bad_version2"                   │
# └──────────────────────────────────────────────────────────────────────────┘

# Extra npm packages to flag (merged on top of the remote advisory list).
USER_CUSTOM_NPM=(
  # "my-internal-package::1.0.0,1.0.1"
)

# Extra pip packages to flag (merged on top of the remote advisory list).
USER_CUSTOM_PIP=(
  # "my-internal-lib::2.3.4"
)

# Directories to exclude from all scans. Subdirectories are excluded too.
USER_EXCLUDE_DIRS=(
  "$HOME/workspace/npm-security-checker/test"  # exclude this tool's own test fixtures
  # "$HOME/workspace/my-project/vendor"
)


# ┌──────────────────────────────────────────────────────────────────────────┐
# │  🔒  SCRIPT INTERNALS — do not edit below this line                      │
# └──────────────────────────────────────────────────────────────────────────┘

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

FOUND=0

# Parse CLI arguments
# --path/-p  : target directory (replaces USER_SCAN_DIRS unless --append is set)
# --append/-a: boolean — keep USER_SCAN_DIRS and add --path dir on top
# --branches/-b: enable branch scanning
# --limit/-l : override SCAN_LIMIT
# --no-global: skip global npm check
# --quiet/-q : suppress safe/info lines, only show hits and errors
# --npm-only : skip pip
# --pip-only : skip all npm checks
CLI_PATH=""
CLI_APPEND=false
SKIP_GLOBAL=false
QUIET=false
NPM_ONLY=false
PIP_ONLY=false
_args=("$@")
_i=0
while [ $_i -lt ${#_args[@]} ]; do
  arg="${_args[$_i]}"
  case "$arg" in
    --branches|-b) CHECK_ALL_BRANCHES=true ;;
    --append|-a)   CLI_APPEND=true ;;
    --no-global)   SKIP_GLOBAL=true ;;
    --quiet|-q)    QUIET=true ;;
    --npm-only)    NPM_ONLY=true ;;
    --pip-only)    PIP_ONLY=true ;;
    --limit|-l)
      _i=$(( _i + 1 ))
      val="${_args[$_i]:-}"
      if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt 0 ]; then
        SCAN_LIMIT="$val"
      else
        echo -e "${YELLOW}  ⚠ --limit requires a positive integer: ${val} — ignoring.${NC}"
      fi ;;
    --limit=*|-l=*)
      val="${arg#*=}"
      if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt 0 ]; then
        SCAN_LIMIT="$val"
      else
        echo -e "${YELLOW}  ⚠ --limit requires a positive integer: ${val} — ignoring.${NC}"
      fi ;;
    --path|-p)
      _i=$(( _i + 1 ))
      val="${_args[$_i]:-}"
      if [ -d "$val" ]; then
        CLI_PATH="$val"
      else
        echo -e "${YELLOW}  ⚠ --path not found: ${val} — ignoring.${NC}"
      fi ;;
    --path=*|-p=*)
      val="${arg#*=}"
      if [ -d "$val" ]; then
        CLI_PATH="$val"
      else
        echo -e "${YELLOW}  ⚠ --path not found: ${val} — ignoring.${NC}"
      fi ;;
    -*) echo -e "${YELLOW}  ⚠ Unknown flag: ${arg} — ignoring.${NC}" ;;
    *)  if [ -d "$arg" ]; then
          CLI_PATH="$arg"
        else
          echo -e "${YELLOW}  ⚠ Path not found: ${arg} — ignoring.${NC}"
        fi ;;
  esac
  _i=$(( _i + 1 ))
done

# Build RESOLVED_DIRS:
#   - No --path given          → use USER_SCAN_DIRS
#   - --path only              → use only that path (replace USER_SCAN_DIRS)
#   - --path + --append        → use USER_SCAN_DIRS + that path
#   - --append without --path  → same as no args (--append alone is a no-op)
RESOLVED_DIRS=()
if [ -z "$CLI_PATH" ] || [ "$CLI_APPEND" = true ]; then
  for d in "${USER_SCAN_DIRS[@]}"; do
    expanded="${d/#\~/$HOME}"
    if [ -d "$expanded" ]; then
      RESOLVED_DIRS+=("$expanded")
    else
      echo -e "${YELLOW}  ⚠ Directory not found, skipping: ${expanded}${NC}"
    fi
  done
fi
[ -n "$CLI_PATH" ] && RESOLVED_DIRS+=("$CLI_PATH")

# ── Advisory loading ─────────────────────────────────────────────────────────

# Remote advisory URLs — raw GitHub content from the default branch.
# Override via env vars for testing: PKG_AUDIT_NPM_URL=file:///path/to/npm.json
REMOTE_NPM_URL="${PKG_AUDIT_NPM_URL:-https://raw.githubusercontent.com/sinansubara/npm-security-checker/master/advisories/npm.json}"
REMOTE_PIP_URL="${PKG_AUDIT_PIP_URL:-https://raw.githubusercontent.com/sinansubara/npm-security-checker/master/advisories/pip.json}"

# Parse a JSON advisory file (path $1) → prints "name::v1,v2" per package.
# Duplicate package entries within the file are merged (versions unioned).
_parse_advisory_json() {
  python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    seen = {}
    for p in data.get("packages", []):
        name = p.get("name", "").strip()
        if not name:
            continue
        for v in p.get("compromised_versions", []):
            v = v.strip()
            if v:
                seen.setdefault(name, [])
                if v not in seen[name]:
                    seen[name].append(v)
    for name, versions in seen.items():
        print(name + "::" + ",".join(versions))
except Exception:
    pass
' "$1" 2>/dev/null
}

# Deduplicate a list of "name::v1,v2" entries piped via stdin.
# Same package appearing multiple times → version lists are unioned.
# Also deduplicates versions within a single entry (e.g. "pkg::1.0,1.0" → "pkg::1.0").
_dedup_advisory_list() {
  python3 -c '
import sys
seen = {}
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    pkg, _, versions = line.partition("::")
    pkg = pkg.strip()
    if not pkg or not versions:
        continue
    for v in versions.split(","):
        v = v.strip()
        if v:
            seen.setdefault(pkg, [])
            if v not in seen[pkg]:
                seen[pkg].append(v)
for pkg, versions in seen.items():
    print(pkg + "::" + ",".join(versions))
'
}

# Portable array-from-stdin loader. Result is placed in the global array _RA.
# Uses mapfile on bash 4+ (fast built-in); falls back to while-read on bash 3.2 (macOS).
# No eval or dynamic variable names — fully ShellCheck-clean.
# Usage:  _readarray < <(command)
#         MY_ARRAY=("${_RA[@]:-}")
_RA=()
_readarray() {
  _RA=()
  if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
    mapfile -t _RA
  else
    while IFS= read -r _line; do _RA+=("$_line"); done
  fi
}

# Download URL $1 to file $2 using curl or wget. Returns 0 on success.
_fetch_url() {
  local url="$1" dest="$2"
  if command -v curl &>/dev/null; then
    curl -sf --max-time 8 --retry 1 "$url" -o "$dest" 2>/dev/null
  elif command -v wget &>/dev/null; then
    wget -q --timeout=8 --tries=2 -O "$dest" "$url" 2>/dev/null
  else
    return 1
  fi
}

# Populate NPM_COMPROMISED and PIP_COMPROMISED by merging:
#   1. remote JSON from GitHub  (fetched fresh on each run)
#   2. local cache              (used if remote is unreachable)
# then appends USER_CUSTOM_NPM / USER_CUSTOM_PIP on top.
# If neither source is available, prints a warning and continues with
# USER_CUSTOM_* entries only (which may be an empty list).
load_advisories() {
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/pkg-audit"
  local npm_cache="$cache_dir/npm.json"
  local pip_cache="$cache_dir/pip.json"
  local npm_source="unavailable" pip_source="unavailable"
  NPM_COMPROMISED=(); PIP_COMPROMISED=()

  mkdir -p "$cache_dir" 2>/dev/null

  # ── npm ──
  rm -f "${npm_cache}.tmp" 2>/dev/null
  if _fetch_url "$REMOTE_NPM_URL" "${npm_cache}.tmp" && \
     mv "${npm_cache}.tmp" "$npm_cache" 2>/dev/null; then
    npm_source="remote"
  else
    rm -f "${npm_cache}.tmp" 2>/dev/null
    [ -f "$npm_cache" ] && npm_source="cache"
  fi
  if [ "$npm_source" != "unavailable" ]; then
    _readarray < <(_parse_advisory_json "$npm_cache")
    NPM_COMPROMISED=("${_RA[@]:-}")
    [ "${#NPM_COMPROMISED[@]}" -eq 0 ] && npm_source="unavailable"
  fi

  # ── pip ──
  rm -f "${pip_cache}.tmp" 2>/dev/null
  if _fetch_url "$REMOTE_PIP_URL" "${pip_cache}.tmp" && \
     mv "${pip_cache}.tmp" "$pip_cache" 2>/dev/null; then
    pip_source="remote"
  else
    rm -f "${pip_cache}.tmp" 2>/dev/null
    [ -f "$pip_cache" ] && pip_source="cache"
  fi
  if [ "$pip_source" != "unavailable" ]; then
    _readarray < <(_parse_advisory_json "$pip_cache")
    PIP_COMPROMISED=("${_RA[@]:-}")
    [ "${#PIP_COMPROMISED[@]}" -eq 0 ] && pip_source="unavailable"
  fi

  # ── Merge user-custom entries, then dedup the full combined lists ──
  # Count how many package names are genuinely new after merging custom entries
  # (packages already in the remote list don't count as "new").
  local _pre_merge_npm=( "${NPM_COMPROMISED[@]:-}" )
  local _pre_merge_pip=( "${PIP_COMPROMISED[@]:-}" )

  NPM_COMPROMISED+=("${USER_CUSTOM_NPM[@]:-}")
  PIP_COMPROMISED+=("${USER_CUSTOM_PIP[@]:-}")

  _readarray < <(printf '%s\n' "${NPM_COMPROMISED[@]:-}" | _dedup_advisory_list)
  NPM_COMPROMISED=("${_RA[@]:-}")
  _readarray < <(printf '%s\n' "${PIP_COMPROMISED[@]:-}" | _dedup_advisory_list)
  PIP_COMPROMISED=("${_RA[@]:-}")

  # Net-new custom packages = packages in final list that weren't in the pre-merge list.
  local _pre_names _net_new=0
  _pre_names=$(printf '%s\n' "${_pre_merge_npm[@]:-}" "${_pre_merge_pip[@]:-}" | cut -d: -f1 | sort -u)
  while IFS= read -r entry; do
    pkg="${entry%%::*}"
    echo "$_pre_names" | grep -qxF "$pkg" || _net_new=$(( _net_new + 1 ))
  done < <(printf '%s\n' "${NPM_COMPROMISED[@]:-}" "${PIP_COMPROMISED[@]:-}")

  # ── Advisory source status line (suppressed by --quiet) ──
  if [ "$QUIET" = false ]; then
    local npm_label pip_label
    case "$npm_source" in
      remote)      npm_label="${GREEN}remote${NC}" ;;
      cache)       npm_label="${YELLOW}cache (offline)${NC}" ;;
      unavailable) npm_label="${RED}unavailable — no cache${NC}" ;;
    esac
    case "$pip_source" in
      remote)      pip_label="${GREEN}remote${NC}" ;;
      cache)       pip_label="${YELLOW}cache (offline)${NC}" ;;
      unavailable) pip_label="${YELLOW}none${NC}" ;;
    esac
    local custom_note=""
    [ "$_net_new" -gt 0 ] && \
      custom_note="  +${_net_new} custom $([ "$_net_new" -eq 1 ] && echo entry || echo entries)"
    echo -e "  ${CYAN}Advisories:${NC}  npm ← ${npm_label}  |  pip ← ${pip_label}${custom_note}"
    [ "$npm_source" = "unavailable" ] && \
      echo -e "  ${RED}⚠ npm advisory list unavailable. Run with internet access to warm the cache.${NC}"
    echo ""
  fi
}

# ── Helpers ───────────────────────────────────────────────────────────────────

flag_hit() {
  local label="$1" pkg="$2" ver="$3" location="$4"
  echo -e "  ${RED}${BOLD}✗ COMPROMISED${NC} ${RED}${label}: ${BOLD}${pkg}@${ver}${NC}"
  echo -e "    ${RED}↳ ${location}${NC}"
  FOUND=$((FOUND + 1))
}

flag_warn() {
  [ "$QUIET" = true ] && return
  local label="$1" pkg="$2" ver="$3" bad_versions="$4"
  echo -e "  ${YELLOW}⚠ Installed but safe version — ${label}: ${pkg}@${ver}${NC}"
  echo -e "    ${YELLOW}  (compromised versions: ${bad_versions})${NC}"
}

check_version() {
  local installed_ver="$1" bad_versions="$2"
  IFS=',' read -ra BADS <<< "$bad_versions"
  for bv in "${BADS[@]}"; do
    [ "$installed_ver" = "$bv" ] && return 0
  done
  return 1
}

# Return 0 if $1 matches any path in USER_EXCLUDE_DIRS (prefix match, ~ expanded).
# Set PKG_AUDIT_NO_EXCLUDES=1 to bypass (used by the test suite).
# Usage: _is_excluded_path "$dir" && continue
_is_excluded_path() {
  [ "${PKG_AUDIT_NO_EXCLUDES:-}" = "1" ] && return 1
  local path="$1" excl expanded
  for excl in "${USER_EXCLUDE_DIRS[@]}"; do
    expanded="${excl/#\~/$HOME}"
    case "$path" in
      "$expanded"/*|"$expanded") return 0 ;;
    esac
  done
  return 1
}

# Parse a package-lock.json from stdin and print the version for a given package.
# Uses -c so the script comes from an argument, leaving stdin free for lockfile content.
# Usage: cat file | parse_lockfile_stdin "package-name"
#        echo "$content" | parse_lockfile_stdin "package-name"
parse_lockfile_stdin() {
  local pkg="$1"
  python3 -c '
import json, sys
pkg = sys.argv[1]
try:
    data = json.load(sys.stdin)
    for section in ("packages", "dependencies"):
        for k, v in data.get(section, {}).items():
            name = k.lstrip("node_modules/").lstrip("/")
            if name == pkg:
                print(v.get("version", ""))
                raise SystemExit
except Exception:
    pass
' "$pkg" 2>/dev/null
}

# ── 1. Global npm ─────────────────────────────────────────────────────────────

check_npm_global() {
  [ "$QUIET" = false ] && echo -e "${CYAN}▶ 1 / Global npm packages${NC}"

  if ! command -v npm &>/dev/null; then
    [ "$QUIET" = false ] && echo -e "  ${YELLOW}npm not found — skipping.${NC}\n"
    return
  fi

  GLOBAL_LIST=$(npm list -g --depth=0 2>/dev/null)

  for entry in "${NPM_COMPROMISED[@]}"; do
    pkg="${entry%%::*}"
    bad_versions="${entry##*::}"
    installed_ver=$(echo "$GLOBAL_LIST" | grep -F "${pkg}@" | sed "s|.*${pkg}@||" | tr -d ' \n')

    if [ -z "$installed_ver" ]; then
      [ "$QUIET" = false ] && echo -e "  ${GREEN}✓ Not installed (global): ${pkg}${NC}"
    elif check_version "$installed_ver" "$bad_versions"; then
      flag_hit "npm global" "$pkg" "$installed_ver" "$(npm root -g 2>/dev/null)/${pkg}"
    else
      flag_warn "npm global" "$pkg" "$installed_ver" "$bad_versions"
    fi
  done
  [ "$QUIET" = false ] && echo ""
}

# ── 2. Working tree — local package-lock.json files ───────────────────────────

check_npm_working_tree() {
  [ "$QUIET" = false ] && echo -e "${CYAN}▶ 2 / Working tree (checked-out branches)${NC}"

  if [ "${#RESOLVED_DIRS[@]}" -eq 0 ]; then
    echo -e "  ${YELLOW}No valid scan directories configured. Add paths in USER_SCAN_DIRS.${NC}\n"
    return
  fi

  if [ "$QUIET" = false ]; then
    echo -e "  Scanning recursively:"
    for d in "${RESOLVED_DIRS[@]}"; do echo -e "    • ${d}"; done
    echo ""
  fi

  _readarray < <(
    find "${RESOLVED_DIRS[@]}" \
      \( \
        -name "node_modules" \
        -o -name ".git" \
        -o -name ".npm" \
        -o -name ".cache" \
        -o -name ".yarn" \
        -o -name ".nvm" \
        -o -name ".pnpm-store" \
        -o -name ".venv" \
        -o -name "venv" \
        -o -name ".docker" \
        -o -name ".m2" \
      \) -prune \
      -o -name "package-lock.json" -print \
      2>/dev/null | sort -u | head -n "$SCAN_LIMIT"
  )
  LOCKFILES=("${_RA[@]:-}")

  total="${#LOCKFILES[@]}"
  if [ "$total" -eq 0 ]; then
    [ "$QUIET" = false ] && echo -e "  ${YELLOW}No package-lock.json files found.\n${NC}"
    return
  fi

  [ "$QUIET" = false ] && echo -e "  Found ${total} lock file(s).\n"

  for lockfile in "${LOCKFILES[@]}"; do
    dir=$(dirname "$lockfile")
    _is_excluded_path "$dir" && continue
    file_header_printed=0

    for entry in "${NPM_COMPROMISED[@]}"; do
      pkg="${entry%%::*}"
      bad_versions="${entry##*::}"

      grep -qF "\"${pkg}\"" "$lockfile" 2>/dev/null || continue

      installed_ver=$(parse_lockfile_stdin "$pkg" < "$lockfile")
      installed_ver="${installed_ver//[[:space:]]/}"
      [ -z "$installed_ver" ] && continue

      if [ "$file_header_printed" -eq 0 ]; then
        [ "$QUIET" = false ] && echo -e "  ${BLUE}📁 ${dir}${NC}"
        file_header_printed=1
      fi

      if check_version "$installed_ver" "$bad_versions"; then
        flag_hit "npm working tree" "$pkg" "$installed_ver" "$lockfile"
      else
        flag_warn "npm working tree" "$pkg" "$installed_ver" "$bad_versions"
      fi
    done
  done
  echo ""
}

# ── 3. All git branches ───────────────────────────────────────────────────────

check_npm_branches() {
  [ "$CHECK_ALL_BRANCHES" = true ] || return

  [ "$QUIET" = false ] && echo -e "${CYAN}▶ 3 / All git branches (non-checked-out)${NC}"

  if ! command -v git &>/dev/null; then
    [ "$QUIET" = false ] && echo -e "  ${YELLOW}git not found — skipping branch scan.${NC}\n"
    return
  fi

  if [ "${#RESOLVED_DIRS[@]}" -eq 0 ]; then
    [ "$QUIET" = false ] && echo -e "  ${YELLOW}No valid scan directories configured.${NC}\n"
    return
  fi

  # Find git repo roots only (where .git is a directory, not a file).
  # Worktrees have .git as a file — they are already covered by the working
  # tree scan above, so we intentionally skip them here.
  _readarray < <(
    find "${RESOLVED_DIRS[@]}" -name ".git" -type d 2>/dev/null | sort -u
  )
  REPO_GIT_DIRS=("${_RA[@]:-}")

  if [ "${#REPO_GIT_DIRS[@]}" -eq 0 ]; then
    [ "$QUIET" = false ] && echo -e "  ${YELLOW}No git repositories found.\n${NC}"
    return
  fi

  [ "$QUIET" = false ] && echo -e "  Found ${#REPO_GIT_DIRS[@]} git repo(s).\n"

  for git_dir in "${REPO_GIT_DIRS[@]}"; do
    repo=$(dirname "$git_dir")
    repo_name=$(basename "$repo")

    # The branch currently checked out — already scanned in step 2, skip it.
    current_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)

    # Collect local + remote branches, deduplicated, excluding current
    _readarray < <(
      {
        git -C "$repo" branch --format='%(refname:short)' 2>/dev/null
        git -C "$repo" branch -r --format='%(refname:short)' 2>/dev/null
      } | sort -u | grep -vF "$current_branch" | grep -v '^HEAD'
    )
    BRANCHES=("${_RA[@]:-}")

    if [ "${#BRANCHES[@]}" -eq 0 ]; then
      continue
    fi

    repo_header_printed=0

    for branch in "${BRANCHES[@]}"; do
      # Read package-lock.json from git object store — no checkout needed
      lockfile_content=$(git -C "$repo" show "${branch}:package-lock.json" 2>/dev/null)
      [ -z "$lockfile_content" ] && continue

      branch_header_printed=0

      for entry in "${NPM_COMPROMISED[@]}"; do
        pkg="${entry%%::*}"
        bad_versions="${entry##*::}"

        echo "$lockfile_content" | grep -qF "\"${pkg}\"" || continue

        installed_ver=$(echo "$lockfile_content" | parse_lockfile_stdin "$pkg")
        installed_ver="${installed_ver//[[:space:]]/}"
        [ -z "$installed_ver" ] && continue

        if [ "$repo_header_printed" -eq 0 ]; then
          [ "$QUIET" = false ] && echo -e "  ${BLUE}📁 ${repo} ${BOLD}[${repo_name}]${NC}"
          repo_header_printed=1
        fi
        if [ "$branch_header_printed" -eq 0 ]; then
          [ "$QUIET" = false ] && echo -e "  ${MAGENTA}   ⎇  branch: ${branch}${NC}"
          branch_header_printed=1
        fi

        if check_version "$installed_ver" "$bad_versions"; then
          flag_hit "branch" "$pkg" "$installed_ver" "${repo} @ ${branch}"
        else
          flag_warn "branch" "$pkg" "$installed_ver" "$bad_versions"
        fi
      done
    done
  done
  [ "$QUIET" = false ] && echo ""
}

# ── 4. pip ────────────────────────────────────────────────────────────────────

check_pip() {
  [ "${#PIP_COMPROMISED[@]}" -eq 0 ] && return

  [ "$QUIET" = false ] && echo -e "${CYAN}▶ 4 / pip packages${NC}"

  local pip_cmd=""
  for cmd in pip3 pip; do
    command -v "$cmd" &>/dev/null && pip_cmd="$cmd" && break
  done

  if [ -z "$pip_cmd" ]; then
    [ "$QUIET" = false ] && echo -e "  ${YELLOW}pip not found — skipping.\n${NC}"
    return
  fi

  PIP_LIST=$("$pip_cmd" list --format=columns 2>/dev/null)

  for entry in "${PIP_COMPROMISED[@]}"; do
    pkg="${entry%%::*}"
    bad_versions="${entry##*::}"
    installed_ver=$(echo "$PIP_LIST" | awk -v p="$pkg" 'tolower($1)==tolower(p){print $2}')
    [ -z "$installed_ver" ] && continue

    if check_version "$installed_ver" "$bad_versions"; then
      flag_hit "pip ($pip_cmd)" "$pkg" "$installed_ver" "$pip_cmd"
    else
      flag_warn "pip ($pip_cmd)" "$pkg" "$installed_ver" "$bad_versions"
    fi
  done
  [ "$QUIET" = false ] && echo ""
}

# ── Header & Summary ──────────────────────────────────────────────────────────

print_header() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║         NPM / Pip Security Checker                       ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
  echo -e "  Date : $(date)"
  echo -e "  Host : $(hostname)  |  User: $(whoami)"
  echo ""
}

print_summary() {
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
  if [ "$FOUND" -eq 0 ]; then
    echo -e "${BOLD}║  ${GREEN}✓  No compromised packages found. You're clear!${NC}${BOLD}         ║${NC}"
  else
    printf -v _pad '%*s' $(( 20 - ${#FOUND} )) ""
    echo -e "${BOLD}║  ${RED}✗  ${FOUND} compromised package(s) detected!${NC}${BOLD}${_pad}║${NC}"
    echo -e "${BOLD}║  ${RED}   → Rotate ALL secrets in affected environments.${NC}${BOLD}       ║${NC}"
    echo -e "${BOLD}║  ${RED}   → Remove or downgrade the packages immediately.${NC}${BOLD}      ║${NC}"
  fi
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ── Run ───────────────────────────────────────────────────────────────────────

print_header
load_advisories

if [ ${#USER_SCAN_DIRS[@]} -eq 0 ] && [ ${#RESOLVED_DIRS[@]} -eq 0 ]; then
  echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║  ⚠  No scan directories configured!                      ║${NC}"
  echo -e "${YELLOW}║     Open pkg-audit.sh and add paths to USER_SCAN_DIRS.   ║${NC}"
  echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
fi

[ "$PIP_ONLY"  = false ] && [ "$SKIP_GLOBAL" = false ] && check_npm_global
[ "$PIP_ONLY"  = false ] && check_npm_working_tree
[ "$PIP_ONLY"  = false ] && check_npm_branches
[ "$NPM_ONLY" = false ] && check_pip
print_summary

exit $FOUND   # 0 = clean, >0 = issues found (useful in CI pipelines)