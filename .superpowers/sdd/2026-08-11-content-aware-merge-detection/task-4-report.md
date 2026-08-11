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

## Fix round 1

Date: 2026-08-11
Commit: `93d28a1` — `fix(archive): make strict tests actually exercise the strict paths`
Parent: `1ac9d54` (the actual landed Task 4 commit — the original report's
`353029b` hash above is stale; the production code shipped unchanged at
`1ac9d54`).

### Finding addressed (Important, plan-error)

Reviewer's diagnosis confirmed against the code and empirically:
`bin/archive-branch.sh` runs the in-flight gate (`activity_age_secs`, the
max of last-commit-time and newest-touched-file-mtime) at line 72 — BEFORE
the strict dirty check (line 93) and the atomic tag transaction (line 120).
The original scenarios 1 and 3 used now-timestamped files/commits, so the
gate refused first. Reproduction before the fix:

```
$ "$BIN/archive-branch.sh" --strict "$T" dirty   # scenario-1 shape
refusing dirty: active 0m ago, under the 2h in-flight threshold
```

(no "strict mode does not archive a dirty worktree" message at all).

On top of the reviewer's finding, scenario 3 was additionally broken in a
way the gate masked: the branch was moved to a new OID BEFORE the script
ran, so the script's own `tip=$(git rev-parse refs/heads/$branch)` re-read
the moved tip and the transaction's `verify` had nothing to fail. A
mid-archive race needs the branch to move BETWEEN that `tip` read and the
`update-ref --stdin` call.

### Fix (chosen option + why)

1. **`WORKTREE_AUDIT_INFLIGHT_SECS=0` exported for the whole test file.**
   Chose the env override over backdating mtimes because scenarios 1 and 3
   intentionally use current-time artifacts (a scratch file, a "concurrent
   commit") — backdating them would falsify exactly the timing property the
   race scenario depends on. Zeroing the threshold is what the env knob
   (`IN_FLIGHT_SECS="${WORKTREE_AUDIT_INFLIGHT_SECS:-7200}"`,
   `bin/lib.sh:11`) exists for, and the file-mtime signal still feeds
   `newest_change_mtime` for other classifications, so no coverage is lost.
2. **Scenario 3 now injects a REAL mid-transaction race via a git shim.**
   `tests/test-archive-strict.sh` writes a `$SCRATCH/git` shim that shadows
   the real git on `PATH` for the one `archive-branch.sh --strict` invocation.
   On the first `update-ref --stdin` call (exactly the atomic transaction,
   detected by arg shape) the shim checks out main, commits `race moved` with
   `$OLD` dates, and points `refs/heads/race` at the new commit — THEN execs
   the real `git update-ref --stdin`, whose `verify refs/heads/race <stale tip>`
   fails and aborts the transaction (rc 128). This is the only construction
   that exercises the verify-before-create guarantee with a genuine race
   window; a pre-moved branch would be archived cleanly.
3. **Minor #1 (plan-mandated):** scenario 2 now asserts
   `refs/tags/archive/clean^{commit}` resolves to the classified tip OID
   (`CLEAN_OID`), matching the non-strict path's resolve-and-compare
   (`bin/archive-branch.sh:129`). Plus a fourth scenario-3 assertion that the
   branch stays at the moved (new) tip — proving the abort didn't roll the
   branch back to the stale tip.
4. **Minor #2 (plan-mandated):** the post-tag re-check comment reworded from
   "Close the post-tag race" to "Narrow the post-tag race", naming the
   residual gap: `git worktree remove` still runs between the re-check and
   `git branch -D`, so a commit landing in that narrow window slips past and
   its tip is left unreachable.

### Regression-proof runs (broken code first, then restored)

The test now genuinely catches the regressions it protects. Both breaking
runs below were done by temporarily patching `bin/archive-branch.sh`; each
run's failing assertions are exactly the scenario the patch undermines.

Run A — scenario 1 regression proof: strict dirty-check body disabled
(`if [ "$STRICT" = true ] && false; then`). Command:

```
bash tests/test-archive-strict.sh; echo "exit=$?"
```

Output (scenario 1 fails its three strict assertions):

```
=== 1. strict refuses a dirty worktree (no WIP commit) ===
  dirty: committing 1 uncommitted file(s) before archiving
start: ok
prepare: ok
commit: ok
  archived dirty -> archive/dirty (7f556b1)
  FAIL: strict did not refuse (rc=0)
  FAIL: branch deleted!
  FAIL: uncommitted file gone!
=== 2. strict archives a clean branch atomically ===
  ... (all PASS)
=== 3. strict aborts atomically when the branch moves mid-archive ===
  ... (all PASS)

=== 7 passed, 3 failed ===
exit=3
```

Run B — scenario 3 regression proof: the strict atomic `update-ref --stdin`
block replaced with a plain non-atomic `git tag` (same invocation shape, so
the shim still moved the branch first). Command:

```
bash tests/test-archive-strict.sh; echo "exit=$?"
```

Output (scenario 3 fails its three race assertions):

```
=== 1. strict refuses a dirty worktree (no WIP commit) ===
  ... (all PASS)
=== 2. strict archives a clean branch atomically ===
  ... (all PASS)
=== 3. strict aborts atomically when the branch moves mid-archive ===
  archived race -> archive/race (a0041f0)
  FAIL: strict did not refuse moved branch (rc=0)
  FAIL: tag created despite branch move
  FAIL: branch deleted!
  PASS: branch still at the moved (new) tip

=== 7 passed, 3 failed ===
exit=3
```

(Run B also proves the earlier pre-move design was dead: with the shim's
mid-transaction move, a non-atomic tag tags the NEW tip and the whole
archive proceeds — exactly the stale-tag hazard the atomic transaction
exists to prevent. The final `git rev-parse refs/heads/race` "ambiguous"
fatal after the FAIL lines is the trailing `bad()`/`ok()` output of the last
assertion evaluating against the deleted branch; it does not affect the
pass/fail count.)

Both patches reverted via `cp` of the saved file; byte-identical restore
verified by `bash -n` and the passing run below.

### Final full-suite run (restored code)

Command:

```
bash tests/test-archive-strict.sh; echo "exit=$?"
```

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
  archived clean -> archive/clean (1073033)
  PASS: strict archives clean
  PASS: tag created
  PASS: tag resolves to the classified tip
=== 3. strict aborts atomically when the branch moves mid-archive ===
start: ok
  PASS: strict refuses a moved branch
  PASS: no tag created for moved branch
  PASS: branch preserved
  PASS: branch still at the moved (new) tip

=== 10 passed, 0 failed ===
exit=0
```

Note scenario 3's output ends at `start: ok` — the transaction aborts at
`verify` (no `prepare`/`commit` lines), confirming the race fires inside the
transaction. Sibling suites:

```
$ for t in test-archive-strict.sh test-archive.sh test-audit-content.sh test-coverage.sh test-lock.sh; do bash "tests/$t" >/dev/null 2>&1 && echo "$t: OK" || echo "$t: FAIL"; done
test-archive-strict.sh: OK
test-archive.sh: OK
test-audit-content.sh: OK
test-coverage.sh: OK
test-lock.sh: OK
```

Also `bash -n bin/archive-branch.sh` → syntax OK. Shellcheck (with the
repo's pre-existing SC1091 exclusion) reports only info-level notes already
present in the repo's harness style (SC2015 `A && B || C`, SC2164, SC2086,
and one SC2155 on the shim's `export SHIM_GIT=$(...)` assignment — harmless
here since `command -v git` cannot fail on a machine running the suite).

### Commit

`93d28a1` — `fix(archive): make strict tests actually exercise the strict paths`

### Updated concerns

- None new. The residual post-tag race (between the re-check and
  `git branch -D`) is documented in the code and in this report; closing it
  fully would require holding a lock across the destructive steps, which is
  out of scope for this task and not requested.
