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
export PKG_AUDIT_NO_EXCLUDES=1  # run against fixtures regardless of USER_EXCLUDE_DIRS

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

# ── Advisory source indicator ─────────────────────────────────────────────────

echo ""
echo -e "${BOLD}── Advisory loading ─────────────────────────────────────────${NC}"

run_script "-p $SCRIPT_DIR/fixtures/clean-npm $BASE_FLAGS"
if echo "$_output" | grep -q "Advisories:"; then
  _pass "advisory source line printed in output"
else
  _fail "advisory source line missing from output"
fi

# ── Deduplication ─────────────────────────────────────────────────────────────
# The test advisory has @tanstack/router-utils listed TWICE:
#   entry 1: versions 1.161.11, 1.161.14
#   entry 2: versions 1.161.14, 1.161.15  (1.161.14 duplicated; 1.161.15 is new)
# After dedup the effective list must be 1.161.11, 1.161.14, 1.161.15.

echo ""
echo -e "${BOLD}── Deduplication ────────────────────────────────────────────${NC}"

# 1. Version that only exists after merging the two duplicate entries (1.161.15)
#    must still be detected as compromised.
run_script "-p $SCRIPT_DIR/fixtures/hit-dedup-npm $BASE_FLAGS -q"
if [ "$_rc" -gt 0 ]; then
  _pass "dedup/hit: version from merged duplicate entry detected (exit code $_rc)"
else
  _fail "dedup/hit: version only present after merging duplicates was missed"
fi
if echo "$_output" | grep -q "COMPROMISED"; then
  _pass "dedup/hit: COMPROMISED in output for merged version"
else
  _fail "dedup/hit: COMPROMISED missing from output for merged version"
fi

# 2. Scanning the hit-dedup fixture must produce exactly ONE hit, not two
#    (the package must not appear twice in the compromised list).
run_script "-p $SCRIPT_DIR/fixtures/hit-dedup-npm $BASE_FLAGS -q"
hit_count=$(echo "$_output" | grep -c "COMPROMISED" || true)
if [ "$hit_count" -eq 1 ]; then
  _pass "dedup/count: exactly 1 COMPROMISED line (no double-counting)"
else
  _fail "dedup/count: expected 1 COMPROMISED line, got $hit_count"
fi

# 3. USER_CUSTOM_NPM duplicate of an advisory-list package must not double-count.
#    We re-run the hit fixture with gsap (also in the advisory) added as a custom entry.
run_script "-p $SCRIPT_DIR/fixtures/hit-npm $BASE_FLAGS -q"
base_hits=$(echo "$_output" | grep -c "COMPROMISED" || true)

PKG_AUDIT_CUSTOM_TEST=1 \
  PKG_AUDIT_NPM_URL="file://$SCRIPT_DIR/advisories/npm.json" \
  PKG_AUDIT_PIP_URL="file://$SCRIPT_DIR/advisories/pip.json" \
  XDG_CACHE_HOME="$CACHE_DIR" \
  USER_CUSTOM_NPM_INJECT="@tanstack/router-utils::1.161.11" \
  bash -c "
    # Inject a custom entry identical to the advisory, then run the scan.
    # We source the script with overridden USER_CUSTOM_NPM to test merge dedup.
    # Simplest approach: run with a wrapper that prepends the variable.
    sed 's|^USER_CUSTOM_NPM=(|USER_CUSTOM_NPM=(\"@tanstack/router-utils::1.161.11\" |' \
      '$SCRIPT' > /tmp/_pkg_audit_dedup_test.sh 2>/dev/null
  " 2>/dev/null || true

if [ -f /tmp/_pkg_audit_dedup_test.sh ]; then
  chmod +x /tmp/_pkg_audit_dedup_test.sh 2>/dev/null
  _dedup_out=$(PKG_AUDIT_NPM_URL="file://$SCRIPT_DIR/advisories/npm.json" \
               PKG_AUDIT_PIP_URL="file://$SCRIPT_DIR/advisories/pip.json" \
               XDG_CACHE_HOME="$CACHE_DIR" \
               /tmp/_pkg_audit_dedup_test.sh -p "$SCRIPT_DIR/fixtures/hit-npm" $BASE_FLAGS -q 2>&1) || true
  rm -f /tmp/_pkg_audit_dedup_test.sh
  dedup_hits=$(echo "$_dedup_out" | grep -c "COMPROMISED" || true)
  if [ "$dedup_hits" -le "$base_hits" ]; then
    _pass "dedup/custom: custom duplicate of advisory entry does not inflate hit count"
  else
    _fail "dedup/custom: custom duplicate inflated hit count ($base_hits \u2192 $dedup_hits)"
  fi
else
  _skip "dedup/custom: sed rewrite unavailable, skipping custom-merge dedup test"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
total=$(( PASS + FAIL + SKIP ))
if [ "$FAIL" -eq 0 ]; then
  printf -v _pad '%*s' $(( 39 - ${#PASS} - ${#total} )) ''
  echo -e "${BOLD}║  ${GREEN}✓  ${PASS}/${total} tests passed${NC}${BOLD}${_pad}║${NC}"
else
  printf -v _pad '%*s' $(( 28 - ${#FAIL} - ${#PASS} - ${#total} )) ''
  echo -e "${BOLD}║  ${RED}✗  ${FAIL} failed, ${PASS} passed (${total} total)${NC}${BOLD}${_pad}║${NC}"
fi
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

[ "$FAIL" -eq 0 ]
