#!/usr/bin/env bash
# Exercises lock_status's three-way liveness in a throwaway repo.
# Usage: tests/test-lock.sh   (exits non-zero on any failure)
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
source "$BIN/lib.sh"

SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
T="$SCRATCH/repo"; mkdir -p "$T"; cd "$T"
git init -q -b main .
git config user.email t@t.t; git config user.name t
echo base > f; git add -A; git commit -qm base
GITDIR=$(git rev-parse --git-dir)

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "=== 1. no lock file -> unknown ==="
[ "$(lock_status "$GITDIR/no-such-lock")" = "unknown" ] && ok "no lock file" || bad "no lock file"

echo "=== 2. a manual lock reason (no pid/start) -> unknown ==="
echo "just a reason, no pid" > "$GITDIR/locked"
[ "$(lock_status "$GITDIR/locked")" = "unknown" ] && ok "unparseable reason" || bad "unparseable reason"

echo "=== 3. a real running process -> live ==="
sleep 300 & SLPID=$!
echo "pid $SLPID start $(awk '{print $22}' /proc/$SLPID/stat)" > "$GITDIR/locked"
[ "$(lock_status "$GITDIR/locked")" = "live" ] && ok "live pid" || bad "live pid"
kill "$SLPID" 2>/dev/null; wait "$SLPID" 2>/dev/null

echo "=== 4. a provably-dead pid -> stale ==="
# Use a pid that no longer exists (reap first, then reuse a fresh one and kill it).
sleep 0.2 & DPID=$!
DPID=$(jobs -p)   # a live pid we will kill
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
[ -d "/proc/$DPID" ] && { echo "  SKIP: pid $DPID still alive"; } || {
  echo "pid $DPID start 0" > "$GITDIR/locked"
  [ "$(lock_status "$GITDIR/locked")" = "stale" ] && ok "dead pid -> stale" || bad "dead pid -> stale (wanted stale)"
}

echo "=== 5. unreadable proc record (not provably dead) -> unknown, never stale ==="
# Deterministic: override proc_start_ticks to simulate an unreadable /proc
# (cat fails) and assert lock_status must return `unknown`, NOT `stale`.
# A regression that maps unreadable->stale would let cleanup delete a
# possibly-live lock, so this assertion is the load-bearing safety check.
stub_unknown() { echo unknown; }
proc_start_ticks() { stub_unknown; }
echo "pid 99999 start 1" > "$GITDIR/locked"
[ "$(lock_status "$GITDIR/locked")" = "unknown" ] \
  && ok "unreadable proc -> unknown" \
  || bad "unreadable proc mapped to something other than unknown"
# restore the real function for any later scenarios
unset -f proc_start_ticks stub_unknown

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
