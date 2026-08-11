# Task 2 Report: Coverage helpers in `lib.sh`

**Date:** 2026-08-11
**Branch:** `content-aware-impl-wt`
**Commit:** `c707605` — `feat(lib): add merge-tree coverage scoring`

## Summary

Implemented `merge_base`, `numstat_net`, and `coverage_score` in `bin/lib.sh` per the brief
(transcribed verbatim, with one defect fix described below), plus a new `tests/test-coverage.sh`
harness following the sibling `tests/test-lock.sh` / `test-archive.sh` conventions.

## Tests

`tests/test-coverage.sh` — 6 scenarios, 8 assertions:

1. Fully-merged content → `SCORED 100` (2 assertions)
2. Genuinely unmerged → `SCORED 0`
3. Squash-merged (no ancestor) → `SCORED 100` (≥ 80)
4. Binary-only change → `UNSCORED`
5. Mode-only change → `UNSCORED`
6. Empty diff (O == 0) → `UNSCORED`

**Command run:** `bash tests/test-coverage.sh`

**Output (final run):**

```
=== 1. fully merged (literal ancestor) -> SCORED ~100 ===
  PASS: scored
  PASS: 100% coverage
=== 2. genuinely unmerged -> SCORED 0 ===
  PASS: 0% coverage
=== 3. squash-merged (no ancestor) -> SCORED high ===
  PASS: squash scored
  PASS: squash high coverage (100)
=== 4. binary-only change -> UNSCORED ===
  PASS: binary unscored
=== 5. mode-only change -> UNSCORED ===
  PASS: mode-only unscored
=== 6. empty diff (no text rows) -> UNSCORED ===
  PASS: O==0 unscored

=== 8 passed, 0 failed ===
```

Exit code 0. Also exercised for real (not just the harness): conflict → `UNKNOWN merge-conflict`
on a genuinely additive conflict, O==0 paths, and the residual diff resolving the synthesized
merge-tree blob from the temp `GIT_OBJECT_DIRECTORY` (verified via `git ls-tree` on the
merge-tree output; the residual diff fails `fatal: bad object` when run outside that subprocess).

## Deviations from the brief

1. **Scenario 1 test construction (test file only, not lib code).** The brief's scenario 1
   (`git merge -q feat`, branch remains a literal ancestor) can never produce `SCORED 100`:
   for a literal ancestor, `merge-base(main, feat)` *is* `feat`, so the branch patch
   `diff mb..feat` is empty → O == 0 → `UNSCORED no-text-rows`, per the brief's own binding
   constraint "O == 0 is UNSCORED, never 0%". The brief's Step 5 expectation ("scenario 1 →
   SCORED 100") contradicts the brief's Step 4 code and the design doc's "O = 0 is unscored"
   rule. The test was repaired at the *construction* level only — the assertions
   (`SCORED*`, `SCORED 100`) are unchanged: `feat`'s content is landed on `main` directly
   (same file, same content, different commit), so the branch is a non-ancestor whose full
   footprint is in base → O = 1, R = 0, `SCORED 100`. This is exactly the shape Task 3's
   consumer actually calls (non-ancestor only). A comment in the test explains the change.

2. **One code fix: `|| true` on the residual `grep -v`.** The transcribed
   `residual=$(printf ... | grep -v '^RC=[0-9]*')` aborts the function silently (rc=1, empty
   output) whenever the merge is clean — `grep -v` exits 1 on a fully-filtered stream, and
   `set -e` was restored two lines earlier. A fully merged branch is the *common* case for
   this pass, so this fired constantly and would have aborted the whole repo scan in Task 3's
   loop. Fix: `residual=$(printf '%s\n' "$residual" | grep -v '^RC=[0-9]*' || true)`. No other
   transcript changes.

3. **Scenario 3's cherry-pick fallback always fires on git 2.55.** `git cherry-pick -q <oid>`
   fails (rc=129) on modern git — `-q` must follow the commit. The brief's `||` fallback
   (fresh commit with identical content) then runs, which produces the same coverage result
   (`SCORED 100`) via a non-ancestor with identical content. Behavior is unchanged; worth
   noting for future briefs (use `git cherry-pick <oid> -q`).

## Concerns (empirical, on git 2.55.0)

- **Criss-cross is NOT detected by the transcribed code on modern git.** The brief's premise
  is that singular `git merge-base` errors ("multiple merge bases") on a criss-cross history,
  so `merge_base` returns nothing and `coverage_score` echoes `UNKNOWN no-merge-base`. I built
  a canonical criss-cross (both tips merge each other; `git merge-base --all` reports two
  bases) and singular `git merge-base main A` returned one base with **rc=0** — no error. The
  man page confirms "when `--all` is not given, it is unspecified which best one is output",
  not an error. Consequently `coverage_score` scores such branches (`SCORED 0` in my probe)
  instead of returning UNKNOWN. Per the brief's own note, this is the case that "would be off —
  treat conservatively as UNKNOWN"; the error path it relies on does not fire on git 2.55.
  Transcribed as-is per "don't redesign" — flagged here and in Task 3's report so the criss-cross
  guard can be revisited (e.g. `git merge-base --all | wc -l` check) before this lands in
  production scanning.
- **`SCORED 0` vs `UNSCORED no-text-rows` ambiguity:** a branch whose merge-base patch is a
  replace (add 1/delete 1) yields O == 0 → `UNSCORED no-text-rows`, while a genuinely unmerged
  branch yields `SCORED 0`. Both route to triage in Task 3, so downstream behavior is fine.
- Shellcheck: only pre-existing/pattern warnings (SC2034 env vars that pre-date this change,
  SC2015 `ok`/`bad` test style matching the sibling harness, SC1091/SC2164 present in the brief's
  verbatim test). No new warning classes introduced by the transcript beyond the brief's own.
- The commit also includes the already-staged Task 1/2 SDD docs
  (`.superpowers/sdd/2026-08-11-content-aware-merge-detection/*`) that were in the index before
  this task started; `bin/lib.sh` and `tests/test-coverage.sh` are the task's own changes.

## Fix round 1 (criss-cross guard)

**Date:** 2026-08-11
**Commit:** `fix(lib): treat criss-cross merge history as unscored (UNKNOWN)`

### What changed

`merge_base` in `bin/lib.sh` now counts merge bases with `git merge-base --all` before
emitting the singular base; `>1` base (criss-cross history) → `return 1` (echoes nothing), so
`coverage_score`'s existing `[ -n "$mb" ] || { echo "UNKNOWN no-merge-base"; return; }` path
fires. The function comment was updated to reflect that singular `git merge-base` does not
error on criss-cross — it picks one base arbitrarily — so the guard is explicit rather than
relying on an error that never comes.

```bash
merge_base() {
  local n
  n=$(git merge-base --all "$1" "$2" 2>/dev/null | wc -l)
  # >1 base = criss-cross history; singular merge-base would pick one
  # arbitrarily and score against a possibly-wrong base. Treat as unknown.
  [ "$n" -eq 1 ] || return 1
  git merge-base "$1" "$2" 2>/dev/null
}
```

### Criss-cross construction used (deterministic, verified)

In the throwaway repo, with `main` and branch `A`:

```
git checkout -qb A main; echo A1 > a.txt; git add -A; git commit -qm A1; A1=$(git rev-parse A)
git checkout -q main; echo M1 > m.txt; git add -A; git commit -qm M1
git checkout -q A; git merge -q --no-ff main      # A absorbs main's M1
git checkout -q main; git merge -q --no-ff "$A1"  # main absorbs the ORIGINAL A1
echo A2 > a.txt; git checkout -q A; git add -A; git commit -qm A2
echo M2 > m2.txt; git checkout -q main; git add -A; git commit -qm M2
```

Key detail: `main` merges the *original* `A1` commit (not A's merged tip), so neither tip is
an ancestor of the other and `git merge-base --all main A` reports **two** bases. Verified
before asserting: `git merge-base --all main A | wc -l` → 2. (Merging the other side's *tip*
instead collapses the criss-cross into a single base — that is why the earlier probes in the
original report showed one base.)

### Test

New scenario 7 in `tests/test-coverage.sh` (asserts the two-base precondition, then
`UNKNOWN*` from `coverage_score`), matching the sibling harness conventions.

**Command run:** `bash tests/test-coverage.sh`

**Output:**

```
=== 1. fully merged (literal ancestor) -> SCORED ~100 ===
  PASS: scored
  PASS: 100% coverage
=== 2. genuinely unmerged -> SCORED 0 ===
  PASS: 0% coverage
=== 3. squash-merged (no ancestor) -> SCORED high ===
  PASS: squash scored
  PASS: squash high coverage (100)
=== 4. binary-only change -> UNSCORED ===
  PASS: binary unscored
=== 5. mode-only change -> UNSCORED ===
  PASS: mode-only unscored
=== 6. empty diff (no text rows) -> UNSCORED ===
  PASS: O==0 unscored
=== 7. criss-cross history (two merge bases) -> UNKNOWN ===
  PASS: criss-cross produced 2 merge bases
  PASS: criss-cross unknown

=== 10 passed, 0 failed ===
```

Exit code 0. Also sanity-checked for real: unrelated histories (no merge base at all) still
route to `UNKNOWN no-merge-base`, and a normal non-criss-cross branch still scores
(`SCORED 0`).

### Commit

`fix(lib): treat criss-cross merge history as unscored (UNKNOWN)` — includes `bin/lib.sh`,
`tests/test-coverage.sh`, and this report.
