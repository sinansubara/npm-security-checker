#!/bin/bash

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║             NPM / Pip Security – Compromised Package Checker             ║
# ║                  Works on: Linux / Ubuntu / macOS                        ║
# ╠══════════════════════════════════════════════════════════════════════════╣
# ║  Usage:                                                                  ║
# ║    chmod +x pkg-audit.sh                                                 ║
# ║    ./pkg-audit.sh                                                        ║
# ║                                                                          ║
# ║  Flags (all optional, order-independent):                                ║
# ║    --path <dir>  / -p <dir>   scan only this dir (replaces config)      ║
# ║    --append      / -a         append --path dir on top of config dirs    ║
# ║    --branches    / -b         also scan all git branches (slow)          ║
# ║    --limit <n>   / -l <n>     override max lock files scanned (default: 300) ║
# ║                                                                          ║
# ║  Examples:                                                               ║
# ║    ./pkg-audit.sh -p /my/project                                         ║
# ║    ./pkg-audit.sh -p /my/project -a          # append to config dirs     ║
# ║    ./pkg-audit.sh -p /my/project -a -b       # + branch scan             ║
# ║    ./pkg-audit.sh --branches                 # config dirs + branches    ║
# ║    ./pkg-audit.sh -l 50                      # cap at 50 lock files       ║
# ╚══════════════════════════════════════════════════════════════════════════╝


# ┌──────────────────────────────────────────────────────────────────────────┐
# │  ✏️  USER CONFIG — edit only this section                                │
# └──────────────────────────────────────────────────────────────────────────┘

# Folders to scan for package-lock.json files.
# Each folder is searched recursively — no need to list individual repos.
# Adding ~/workspace will automatically scan every repository inside it.
# ~ is expanded automatically.
USER_SCAN_DIRS=(
  # "~"               # CAUTION: scanning your entire home can be slow — noisy dirs are auto-skipped (node_modules, .npm, .cache, .nvm…)
  "~/workspace"     # <- use a specific folder to speed things up
  # "~/side-projects" # <- uncomment or add more root folders as needed
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
# │  ⚠️  PACKAGE LISTS — update when new advisories arrive                  │
# │      Do not rename the variables or change the format.                  │
# │      Format: "package-name::bad_version1,bad_version2"                  │
# └──────────────────────────────────────────────────────────────────────────┘

NPM_COMPROMISED=(
  "@tanstack/router-utils::1.161.11,1.161.14"
  "@tanstack/router-core::1.169.5,1.169.8"
  "@opensearch-project/opensearch::3.6.2"
  "@uipath/docsai-tool::1.0.1"
  "@uipath/packager-tool-apiworkflow::0.0.19"
  "gsap::3.12.7"
)

PIP_COMPROMISED=(
  # Add compromised Python packages here as advisories arrive, e.g.:
  # "some-python-package::1.2.3"
)


# ┌──────────────────────────────────────────────────────────────────────────┐
# │  🔒  SCRIPT INTERNALS — do not edit below this line                     │
# └──────────────────────────────────────────────────────────────────────────┘

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

FOUND=0

# Parse CLI arguments
# --path/-p  : target directory (replaces USER_SCAN_DIRS unless --append is set)
# --append/-a: boolean — keep USER_SCAN_DIRS and add --path dir on top
# --branches/-b: enable branch scanning
# --limit/-l : override SCAN_LIMIT
CLI_PATH=""
CLI_APPEND=false
_args=("$@")
_i=0
while [ $_i -lt ${#_args[@]} ]; do
  arg="${_args[$_i]}"
  case "$arg" in
    --branches|-b) CHECK_ALL_BRANCHES=true ;;
    --append|-a)   CLI_APPEND=true ;;
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

# ── Helpers ───────────────────────────────────────────────────────────────────

flag_hit() {
  local label="$1" pkg="$2" ver="$3" location="$4"
  echo -e "  ${RED}${BOLD}✗ COMPROMISED${NC} ${RED}${label}: ${BOLD}${pkg}@${ver}${NC}"
  echo -e "    ${RED}↳ ${location}${NC}"
  FOUND=$((FOUND + 1))
}

flag_warn() {
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
  echo -e "${CYAN}▶ 1 / Global npm packages${NC}"

  if ! command -v npm &>/dev/null; then
    echo -e "  ${YELLOW}npm not found — skipping.${NC}\n"
    return
  fi

  GLOBAL_LIST=$(npm list -g --depth=0 2>/dev/null)

  for entry in "${NPM_COMPROMISED[@]}"; do
    pkg="${entry%%::*}"
    bad_versions="${entry##*::}"
    installed_ver=$(echo "$GLOBAL_LIST" | grep -F "${pkg}@" | sed "s|.*${pkg}@||" | tr -d ' \n')

    if [ -z "$installed_ver" ]; then
      echo -e "  ${GREEN}✓ Not installed (global): ${pkg}${NC}"
    elif check_version "$installed_ver" "$bad_versions"; then
      flag_hit "npm global" "$pkg" "$installed_ver" "$(npm root -g 2>/dev/null)/${pkg}"
    else
      flag_warn "npm global" "$pkg" "$installed_ver" "$bad_versions"
    fi
  done
  echo ""
}

# ── 2. Working tree — local package-lock.json files ───────────────────────────

check_npm_working_tree() {
  echo -e "${CYAN}▶ 2 / Working tree (checked-out branches)${NC}"

  if [ "${#RESOLVED_DIRS[@]}" -eq 0 ]; then
    echo -e "  ${YELLOW}No valid scan directories configured. Add paths in USER_SCAN_DIRS.${NC}\n"
    return
  fi

  echo -e "  Scanning recursively:"
  for d in "${RESOLVED_DIRS[@]}"; do echo -e "    • ${d}"; done
  echo ""

  mapfile -t LOCKFILES < <(
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

  total="${#LOCKFILES[@]}"
  if [ "$total" -eq 0 ]; then
    echo -e "  ${YELLOW}No package-lock.json files found.\n${NC}"
    return
  fi

  echo -e "  Found ${total} lock file(s).\n"

  for lockfile in "${LOCKFILES[@]}"; do
    dir=$(dirname "$lockfile")
    file_header_printed=0

    for entry in "${NPM_COMPROMISED[@]}"; do
      pkg="${entry%%::*}"
      bad_versions="${entry##*::}"

      grep -qF "\"${pkg}\"" "$lockfile" 2>/dev/null || continue

      installed_ver=$(parse_lockfile_stdin "$pkg" < "$lockfile")
      installed_ver="${installed_ver//[[:space:]]/}"
      [ -z "$installed_ver" ] && continue

      if [ "$file_header_printed" -eq 0 ]; then
        echo -e "  ${BLUE}📁 ${dir}${NC}"
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

  echo -e "${CYAN}▶ 3 / All git branches (non-checked-out)${NC}"

  if ! command -v git &>/dev/null; then
    echo -e "  ${YELLOW}git not found — skipping branch scan.${NC}\n"
    return
  fi

  if [ "${#RESOLVED_DIRS[@]}" -eq 0 ]; then
    echo -e "  ${YELLOW}No valid scan directories configured.${NC}\n"
    return
  fi

  # Find git repo roots only (where .git is a directory, not a file).
  # Worktrees have .git as a file — they are already covered by the working
  # tree scan above, so we intentionally skip them here.
  mapfile -t REPO_GIT_DIRS < <(
    find "${RESOLVED_DIRS[@]}" -name ".git" -type d 2>/dev/null | sort -u
  )

  if [ "${#REPO_GIT_DIRS[@]}" -eq 0 ]; then
    echo -e "  ${YELLOW}No git repositories found.\n${NC}"
    return
  fi

  echo -e "  Found ${#REPO_GIT_DIRS[@]} git repo(s).\n"

  for git_dir in "${REPO_GIT_DIRS[@]}"; do
    repo=$(dirname "$git_dir")
    repo_name=$(basename "$repo")

    # The branch currently checked out — already scanned in step 2, skip it.
    current_branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)

    # Collect local + remote branches, deduplicated, excluding current
    mapfile -t BRANCHES < <(
      {
        git -C "$repo" branch --format='%(refname:short)' 2>/dev/null
        git -C "$repo" branch -r --format='%(refname:short)' 2>/dev/null
      } | sort -u | grep -vF "$current_branch" | grep -v '^HEAD'
    )

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
          echo -e "  ${BLUE}📁 ${repo} ${BOLD}[${repo_name}]${NC}"
          repo_header_printed=1
        fi
        if [ "$branch_header_printed" -eq 0 ]; then
          echo -e "  ${MAGENTA}   ⎇  branch: ${branch}${NC}"
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
  echo ""
}

# ── 4. pip ────────────────────────────────────────────────────────────────────

check_pip() {
  [ "${#PIP_COMPROMISED[@]}" -eq 0 ] && return

  echo -e "${CYAN}▶ 4 / pip packages${NC}"

  local pip_cmd=""
  for cmd in pip3 pip; do
    command -v "$cmd" &>/dev/null && pip_cmd="$cmd" && break
  done

  if [ -z "$pip_cmd" ]; then
    echo -e "  ${YELLOW}pip not found — skipping.\n${NC}"
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
  echo ""
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

if [ ${#USER_SCAN_DIRS[@]} -eq 0 ] && [ ${#RESOLVED_DIRS[@]} -eq 0 ]; then
  echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║  ⚠  No scan directories configured!                      ║${NC}"
  echo -e "${YELLOW}║     Open pkg-audit.sh and add paths to USER_SCAN_DIRS.   ║${NC}"
  echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
fi

check_npm_global
check_npm_working_tree
check_npm_branches
check_pip
print_summary

exit $FOUND   # 0 = clean, >0 = issues found (useful in CI pipelines)