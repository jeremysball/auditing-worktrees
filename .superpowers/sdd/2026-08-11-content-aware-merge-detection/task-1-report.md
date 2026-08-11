# Task 1 Report: Three-state lock liveness in `lib.sh`

## Summary
Made `proc_start_ticks` three-state (`missing` / `unknown` / start-time string) and updated `lock_status` to echo `live | stale | unknown`, so an unreadable-but-not-proven-dead proc record yields `unknown` (never `stale`).

## Tests
- New file: `tests/test-lock.sh` (transcribed verbatim from the brief).
- Test scenarios:
  1. no lock file -> unknown
  2. manual lock reason (no pid/start) -> unknown
  3. real running process -> live
  4. provably-dead pid -> stale
  5. unreadable proc record (stubbed `proc_start_ticks` -> `unknown`) -> unknown, never stale

## Test command and results
Before implementation (`bash tests/test-lock.sh`):
```
=== 1. no lock file -> unknown ===
  PASS: no lock file
=== 2. a manual lock reason (no pid/start) -> unknown ===
  PASS: unparseable reason
=== 3. a real running process -> live ===
  PASS: live pid
=== 4. a provably-dead pid -> stale ===
  PASS: dead pid -> stale
=== 5. unreadable proc record (not provably dead) -> unknown, never stale ===
  FAIL: unreadable proc mapped to something other than unknown

=== 4 passed, 1 failed ===
```
Confirmed failing as expected (scenario 5).

After implementation (`bash tests/test-lock.sh`):
```
=== 1. no lock file -> unknown ===
  PASS: no lock file
=== 2. a manual lock reason (no pid/start) -> unknown ===
  PASS: unparseable reason
=== 3. a real running process -> live ===
  PASS: live pid
=== 4. a provably-dead pid -> stale ===
  PASS: dead pid -> stale
=== 5. unreadable proc record (not provably dead) -> unknown, never stale ===
  PASS: unreadable proc -> unknown

=== 5 passed, 0 failed ===
```
All assertions pass.

## Implementation
- `bin/lib.sh` `proc_start_ticks`: now checks `/proc/$pid` directory existence first (`missing`), and any other read/parse failure echoes `unknown` instead of returning non-zero.
- `bin/lib.sh` `lock_status`: consumes the three states — `missing` -> `stale`, `unknown` -> `unknown`, matching start -> `live`, mismatch -> `stale`.

## Commit
- `78e236e` — `fix(lib): make proc lock liveness three-state (missing/unknown/live)`

## Concerns
- None. Scenario 4 ran without the SKIP path (the killed pid was reaped and `/proc/$DPID` was absent), so the stale path was exercised for real.
