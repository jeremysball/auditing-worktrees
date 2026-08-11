### Task 1: Three-state lock liveness in `lib.sh`

**Files:**
- Modify: `bin/lib.sh` — `proc_start_ticks` (currently lines 29-43) and `lock_status` (currently lines 54-71).
- Test: `tests/test-lock.sh` (new file, modeled on `tests/test-archive.sh`'s harness).

**Interfaces:**
- Consumes: the existing `proc_start_ticks "$pid"` shape; `lock_status "$lockfile"`.
- Produces: `proc_start_ticks "$pid"` now echoes `missing`, `unknown`, or a start-time string; `lock_status "$lockfile"` now echoes `live | stale | unknown` where an unreadable-but-not-proven-dead proc record yields `unknown` (never `stale`).

**Problem.** Today `proc_start_ticks` returns `1` on *any* `cat /proc/$pid/stat` failure, and `lock_status` maps that to `stale` ("process is gone"). That conflates a provably-dead PID with an unreadable-but-maybe-alive one. An unreadable proc record must be `unknown` (hands-off), never `stale` (deletable).

- [ ] **Step 1: Write the failing test**

Create `tests/test-lock.sh`:

```bash
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
```

Note: the harness is intentionally rough at the edges (proc access varies by environment); the assertions that matter are the *states*: unparseable → unknown, provably-dead → stale, live-match → live. Adjust scenario 5 to your environment rather than weakening scenarios 1-4.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-lock.sh`
Expected: scenario 4 (`dead pid -> stale`) passes but the unknown-vs-stale distinction is not yet implemented; the key assertion that fails once you read the new contract is scenario 5's intent — today an unreadable proc returns `stale` from `lock_status`, which the new contract forbids. Verify at least one assertion currently fails.

- [ ] **Step 3: Implement the three-state `proc_start_ticks`**

Replace `proc_start_ticks` (lines 29-43) in `bin/lib.sh` with:

```bash
# Echoes one of: a start-time string, "missing", or "unknown".
#   missing - the process provably does not exist (procfs absence).
#   unknown - /proc/<pid>/stat could not be read for any other reason.
proc_start_ticks() {
  local pid="$1" stat rest
  if [ ! -d "/proc/$pid" ]; then echo "missing"; return; fi
  stat=$(cat "/proc/$pid/stat" 2>/dev/null) || { echo "unknown"; return; }
  rest="${stat##*) }"
  [ "$rest" != "$stat" ] || { echo "unknown"; return; }
  local -a f
  read -r -a f <<< "$rest"
  [ "${#f[@]}" -ge 20 ] || { echo "unknown"; return; }
  echo "${f[19]}"
}
```

- [ ] **Step 4: Update `lock_status` to consume the three states**

Replace the `live_start` block (lines 68-70) in `bin/lib.sh`:

```bash
  local live_start
  live_start=$(proc_start_ticks "$pid") || { echo "unknown"; return; }
  if [ "$live_start" = "missing" ]; then echo "stale"; return; fi
  if [ "$live_start" = "unknown" ]; then echo "unknown"; return; fi
  if [ "$live_start" = "$start" ]; then echo "live"; else echo "stale"; fi
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-lock.sh`
Expected: unparseable reason → unknown; dead pid → stale; live match → live; unreadable proc → unknown. All assertions pass.

- [ ] **Step 6: Commit**

```bash
git add bin/lib.sh tests/test-lock.sh
git commit -m "fix(lib): make proc lock liveness three-state (missing/unknown/live)"
```

---

