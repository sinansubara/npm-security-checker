#!/usr/bin/env bash
# test/test.sh — integration test suite for pkg-audit.sh
#
# Usage:
#   ./test/test.sh          # from repo root
#   cd test && ./test.sh    # from test dir
#
# All tests are network-independent: advisory URLs are redirected to local
# file:// paths pointing at test/advisories/, eliminating flakiness.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT="$REPO_DIR/pkg-audit.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; SKIP=0

_pass() { echo -e "  ${GREEN}✓ PASS${NC}  $1"; PASS=$(( PASS + 1 )); }
_fail() { echo -e "  ${RED}✗ FAIL${NC}  $1"; FAIL=$(( FAIL + 1 )); }
_skip() { echo -e "  ${YELLOW}⊘ SKIP${NC}  $1"; SKIP=$(( SKIP + 1 )); }

# ── Pre-flight checks ─────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}pkg-audit.sh — integration test suite${NC}"
echo ""

if [ ! -f "$SCRIPT" ]; then
  echo -e "${RED}ERROR: script not found at $SCRIPT${NC}"
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo -e "${RED}ERROR: python3 is required to run the tests${NC}"
  exit 1
fi

# ── Temp cache dir (cleaned up on exit) ───────────────────────────────────────

CACHE_DIR="$(mktemp -d)"
trap 'rm -rf "$CACHE_DIR"' EXIT

mkdir -p "$CACHE_DIR/pkg-audit"

# Redirect advisory fetches to local file:// URLs so no network is needed.
# curl and wget both support file:// URIs on Linux and macOS.
export XDG_CACHE_HOME="$CACHE_DIR"
export PKG_AUDIT_NPM_URL="file://$SCRIPT_DIR/advisories/npm.json"
export PKG_AUDIT_PIP_URL="file://$SCRIPT_DIR/advisories/pip.json"

# Shared flags: skip global npm (system-state) and pip (no pip fixtures yet)
BASE_FLAGS="--no-global --npm-only"

# ── Helper: run script and capture output + exit code ────────────────────────

run_script() {
  local flags="$1"
  _output=""
  _rc=0
  # shellcheck disable=SC2086
  _output=$("$SCRIPT" $flags 2>&1) || _rc=$?
}

# ── Advisory JSON validation ──────────────────────────────────────────────────

echo -e "${BOLD}── Advisory JSON ────────────────────────────────────────────${NC}"

for f in "$REPO_DIR/advisories/npm.json" "$REPO_DIR/advisories/pip.json" \
          "$SCRIPT_DIR/advisories/npm.json" "$SCRIPT_DIR/advisories/pip.json"; do
  label="${f#$REPO_DIR/}"
  if python3 -c "import json; json.load(open('$f'))" 2>/dev/null; then
    _pass "$label is valid JSON"
  else
    _fail "$label is invalid JSON"
  fi
done

# ── Working-tree scan: hit ────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}── Working-tree scan ────────────────────────────────────────${NC}"

run_script "-p $SCRIPT_DIR/fixtures/hit-npm $BASE_FLAGS -q"
if [ "$_rc" -gt 0 ]; then
  _pass "hit-npm: exit code $_rc (compromised package detected)"
else
  _fail "hit-npm: expected exit code > 0 (compromised), got 0"
fi

if echo "$_output" | grep -q "COMPROMISED"; then
  _pass "hit-npm: output contains COMPROMISED"
else
  _fail "hit-npm: output did not contain 'COMPROMISED'"
fi

# ── Working-tree scan: safe (monitored package, safe version) ────────────────

run_script "-p $SCRIPT_DIR/fixtures/safe-npm $BASE_FLAGS"
if [ "$_rc" -eq 0 ]; then
  _pass "safe-npm: exit code 0 (monitored package at safe version)"
else
  _fail "safe-npm: expected exit code 0, got $_rc"
fi

if ! echo "$_output" | grep -q "COMPROMISED"; then
  _pass "safe-npm: output does not contain COMPROMISED"
else
  _fail "safe-npm: output must not contain 'COMPROMISED' for a safe version"
fi

if echo "$_output" | grep -q "safe version"; then
  _pass "safe-npm: output contains 'safe version' warning"
else
  _fail "safe-npm: expected 'safe version' warning in output"
fi

# ── Working-tree scan: clean (no monitored packages) ─────────────────────────

run_script "-p $SCRIPT_DIR/fixtures/clean-npm $BASE_FLAGS"
if [ "$_rc" -eq 0 ]; then
  _pass "clean-npm: exit code 0 (no monitored packages)"
else
  _fail "clean-npm: expected exit code 0, got $_rc"
fi

if ! echo "$_output" | grep -q "COMPROMISED"; then
  _pass "clean-npm: output does not contain COMPROMISED"
else
  _fail "clean-npm: unexpected COMPROMISED in output for clean fixture"
fi

# ── --quiet flag ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}── Flags ────────────────────────────────────────────────────${NC}"

run_script "-p $SCRIPT_DIR/fixtures/safe-npm $BASE_FLAGS --quiet"
if ! echo "$_output" | grep -q "safe version"; then
  _pass "--quiet: 'safe version' warning suppressed"
else
  _fail "--quiet: 'safe version' warning should be suppressed"
fi

run_script "-p $SCRIPT_DIR/fixtures/hit-npm $BASE_FLAGS --quiet"
if echo "$_output" | grep -q "COMPROMISED"; then
  _pass "--quiet: COMPROMISED hit still printed"
else
  _fail "--quiet: COMPROMISED hit must still appear with --quiet"
fi

# ── Advisory source indicator ────────────────────────────────────────────────

echo ""
echo -e "${BOLD}── Advisory loading ─────────────────────────────────────────${NC}"

run_script "-p $SCRIPT_DIR/fixtures/clean-npm $BASE_FLAGS"
if echo "$_output" | grep -q "Advisories:"; then
  _pass "advisory source line printed in output"
else
  _fail "advisory source line missing from output"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
total=$(( PASS + FAIL + SKIP ))
if [ "$FAIL" -eq 0 ]; then
  echo -e "${BOLD}║  ${GREEN}✓  ${PASS}/${total} tests passed${NC}${BOLD}$(printf '%*s' $(( 38 - ${#PASS} - ${#total} )) '')║${NC}"
else
  echo -e "${BOLD}║  ${RED}✗  ${FAIL} failed, ${PASS} passed (${total} total)${NC}${BOLD}$(printf '%*s' $(( 26 - ${#FAIL} - ${#PASS} - ${#total} )) '')║${NC}"
fi
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

[ "$FAIL" -eq 0 ]
