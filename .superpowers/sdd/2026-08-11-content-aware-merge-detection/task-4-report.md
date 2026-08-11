# Task 4 Report — Strict archive path (refuse dirty + atomic tag)

Date: 2026-08-11
Branch: `content-aware-impl-wt`
Commit: `353029b` — `feat(archive): add strict mode (refuse dirty, atomic tag)`

## Summary

Implemented the strict archive path in `bin/archive-branch.sh` and a new
throwaway-repo test harness `tests/test-archive-strict.sh` (mirroring
`tests/test-archive.sh` conventions):

1. **`--strict` flag** parsed after the `--list` block, before `REPO`; sets
   `STRICT=true` and shifts.
2. **WIP-commit gate**: in the dirty-worktree block, strict mode refuses with
   rc=1 (`refusing <branch>: strict mode does not archive a dirty worktree ...`)
   and leaves branch + worktree untouched; the non-strict path is byte-for-byte
   unchanged (same `wip: archived with uncommitted changes` commit behavior).
3. **Atomic tag**: in strict mode the tag is created via a
   `git update-ref --stdin` transaction
   (`start / verify refs/heads/<b> <tip> / create refs/tags/<t> <tip> / prepare / commit`).
   Any verify failure aborts the whole transaction (rc 128 → caught, reported,
   branch and tag untouched). The non-strict path keeps its `git tag` +
   resolve-verify.
4. **Post-tag race close**: both paths re-verify `refs/heads/<branch>` still
   equals `tip` immediately before the destructive steps (worktree remove +
   `git branch -D`), refusing with rc=1 otherwise.

Constraints honored: strict/dirty never fabricates WIP history; the tag is
created against the exact classified OID atomically; non-strict behavior
unchanged; existing `lib.sh` helpers (`worktree_dirty_count`) reused.

## Test scenarios

Test file: `tests/test-archive-strict.sh` (8 assertions across 3 scenarios).

| # | Scenario | Verifies |
|---|----------|----------|
| 1 | strict refuses dirty worktree | rc=1, no WIP commit, branch kept, uncommitted file intact |
| 2 | strict archives a clean branch | rc=0, tag `archive/clean` created |
| 3 | branch moves mid-archive (concurrent commit) | rc=1, no tag, branch preserved |

## Test run — before (fails as expected)

Command: `bash tests/test-archive-strict.sh` (pre-implementation)

Output:

```
=== 1. strict refuses a dirty worktree (no WIP commit) ===
  FAIL: strict did not refuse (rc=2)
  PASS: branch kept
  PASS: uncommitted file intact
=== 2. strict archives a clean branch atomically ===
.../bin/archive-branch.sh: line 35: cd: --: invalid option
  FAIL: strict failed clean (rc=2)
  FAIL: no tag
=== 3. strict aborts atomically when the branch moves mid-archive ===
  FAIL: strict did not refuse moved branch (rc=2)
  PASS: no tag created for moved branch
  PASS: branch preserved

=== 4 passed, 4 failed ===
```

The four failures are the expected red: `--strict` was parsed as `$REPO`
(`cd --` failure), so nothing strict-specific happened.

## Test run — after (passes)

Command: `bash tests/test-archive-strict.sh`

Output:

```
=== 1. strict refuses a dirty worktree (no WIP commit) ===
  PASS: strict refuses dirty
  PASS: branch kept
  PASS: uncommitted file intact
=== 2. strict archives a clean branch atomically ===
start: ok
prepare: ok
commit: ok
  archived clean -> archive/clean (16e0d74)
  PASS: strict archives clean
  PASS: tag created
=== 3. strict aborts atomically when the branch moves mid-archive ===
  PASS: strict refuses a moved branch
  PASS: no tag created for moved branch
  PASS: branch preserved

=== 8 passed, 0 failed ===
```

Note: the `start/prepare/commit: ok` lines are git's own progress output from
`update-ref --stdin` on stdout — harmless, and the exit status path is what the
test asserts on.

## Regression

- `bash tests/test-archive.sh` → **14 passed, 0 failed** (dirty+old scenario 5
  still WIP-commits and archives: non-strict behavior unchanged).
- `bash tests/test-audit-content.sh`, `tests/test-coverage.sh`,
  `tests/test-lock.sh` → all pass.
- `bash -n bin/archive-branch.sh` → syntax OK.
- `shellcheck` (available on PATH) reports only pre-existing style patterns
  shared with the repo's existing harness (`A && B || C` in tests, `SC1091` on
  the lib.sh source, one unquoted-var info inside the brief's verbatim echo
  line). No errors.

## Deviations from the brief

- None in logic. Two cosmetic additions beyond the literal diff:
  1. Usage comment at the top of `bin/archive-branch.sh` extended to document
     the `--strict` form (the brief's step-3 snippet only added the flag parse).
  2. `tests/test-archive-strict.sh` made executable (`chmod 755`), matching the
     sibling harness convention (`5f0e5ca style(test): make test-lock.sh
     executable to match sibling harness`).
- The brief's exact `A && B || C` assertion style is kept verbatim (as
  required); shellcheck's SC2015/SC2034 notes on it are informational only and
  match the existing tests.
- `RACE_OID` in the brief's scenario 3 is assigned but unused (brief verbatim);
  kept as-is.

## Concerns

None.
