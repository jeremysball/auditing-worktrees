# Task 3 Report: Content-aware classification in `audit-worktrees.sh`

**Date:** 2026-08-11
**Branch:** `content-aware-impl-wt`
**Commit:** (see commit section)

## Summary

Wired Task 2's `coverage_score` into `bin/audit-worktrees.sh`'s classification
loop: non-ancestor branches now get a merge-tree coverage pass, high-coverage
branches land in a new `likely-content-merged` bucket (offered for archive,
never clean-safe), and unscored/unknown branches route to `needs-triage`
(never archaeology). Added the `--no-content` flag that skips the coverage
pass for the SessionStart hook (Task 6), and a fixed default
`CONTENT_MERGE_THRESHOLD=95` (Task 7 makes it env-configurable + validated).

## Tests

`tests/test-audit-content.sh` — 4 scenarios, 9 assertions:

1. Squash-merged branch (non-ancestor, content already in main) → appears
   under `likely-content-merged`, not `needs-triage` (3 assertions).
2. `--no-content` skips the coverage pass: no content bucket, branch back in
   `needs-triage` (2 assertions).
3. Genuinely unmerged branch (`SCORED 0`) stays in `needs-triage` (2
   assertions).
4. Binary-only branch (`UNSCORED binary`) routes to `needs-triage`, never
   archaeology (2 assertions).

**Command run:** `bash tests/test-audit-content.sh`

**Output (final run):**

```
=== 1. squash-merged branch reports as likely-content-merged ===
  PASS: content-merged bucket present
  PASS: sq listed under content-merged
  PASS: sq not in needs-triage
=== 2. --no-content skips the coverage pass (ancestry-only) ===
  PASS: no content bucket with --no-content
  PASS: sq back in needs-triage without content pass
=== 3. genuinely unmerged branch stays in needs-triage (SCORED 0) ===
  PASS: other in needs-triage
  PASS: other named in report
=== 4. binary-only branch (UNSCORED) routes to needs-triage, never archaeology ===
  PASS: bin in needs-triage
  PASS: bin not in archaeology

=== 9 passed, 0 failed ===
```

Exit code 0.

**Before/after (real repo, not mocked):** a throwaway repo with a
squash-merged branch `sq` (old, non-ancestor, content already in main):

```
--- BEFORE (pre-change audit-worktrees.sh) ---
=== /tmp/tmp.Vbpo7RlseI (base: main) ===
  needs-triage:
    sq  [idle 3h] — unmerged

--- AFTER ---
=== /tmp/tmp.Vbpo7RlseI (base: main) ===
  likely-content-merged (work already in base under a different hash — batch archive):
    sq  [idle 3h] — content-merged (work already in base, different hash)

--- NO-CONTENT (--no-content flag) ---
=== /tmp/tmp.Vbpo7RlseI (base: main) ===
  needs-triage:
    sq  [idle 3h] — unmerged
```

**Regression:** `tests/test-archive.sh` (14/14), `tests/test-coverage.sh`
(10/10), `tests/test-lock.sh` (5/5) all pass. Also exercised for real:
literal-ancestor branch → `safe-to-clean` (no content pass, no crash);
`--no-content` with no positional arg (flag consumed, `ROOT` defaults to
`$(pwd)`).

## Deviations from the brief

Three defects in the brief's Step 3 snippet were fixed; all were verified by
failing runs before fixing, and each is a `set -euo pipefail` abort of the
whole repo scan (violating the Global Constraint "must never abort the whole
repo scan on a single branch") or a wrong classification:

1. **`reason` unbound under `set -u`.** The snippet's UNSCORED/UNKNOWN arm
   (`reason="$reason, ${score%% *}"`) runs before the snippet's own
   `local reason="unmerged"` (which sits in the merged/unmerged branch,
   *after* the content pass). Any UNSCORED/UNKNOWN branch aborted the entire
   scan with `reason: unbound variable` (reproduced: binary-only branch,
   scenario 4). Fix: `reason` is initialized to `"unmerged"` alongside the
   flags before the content pass; the later `local` was dropped and the
   stale-lock override now assigns instead of declares. The brief's own prose
   ("after the ancestry check says `merged=false`") also implies the pass
   must not run for literal ancestors — see 2.

2. **`local content_merged=false` shadows the bucket array.** The snippet
   declares the per-branch flag with the *same name* as the bucket array
   (`content_merged=()` at the bucket declarations). `local content_merged`
   inside the loop redeclares the array as a scalar, so the report printed a
   bogus `likely-content-merged: false` entry for every merged branch
   (reproduced with a literal-ancestor repo). Fix: per-branch flag renamed to
   `is_content_merged`; the bucket array keeps the brief's name.

3. **Content pass ran for literal ancestors too.** The snippet's guard is
   only `NO_CONTENT`; the brief's prose says the pass goes "after the
   ancestry check says `merged=false`". Running it for merged branches is
   both wasted work (merge-tree on an ancestor) and wrong: a literal ancestor
   yields O==0 → `UNSCORED no-text-rows`, which would append `, UNSCORED` to
   the reason and (before fix 1) abort. Fix: guard is
   `[ "$NO_CONTENT" = false ] && [ "$merged" = false ]`. Verified: a
   literal-ancestor branch still lands in `safe-to-clean` with no content
   bucket and no crash.

No other transcript changes; the bucket heading, split logic, early-return
guard, and commit message follow the brief verbatim.

## Concerns

- **`SCORED 0` vs `UNSCORED no-text-rows` ambiguity** (inherited from Task 2):
  a genuinely unmerged branch scores `SCORED 0` and a replace-patch branch
  (add 1/delete 1) is `UNSCORED no-text-rows`. Both route to `needs-triage`
  here, so downstream behavior is fine — but the report text differs
  (`— unmerged` vs `— unmerged, UNSCORED`). Cosmetic only.
- **`--no-content` is positional-only.** `audit-worktrees.sh --no-content
  <root>` works; `<root> --no-content` would treat the flag as the root path.
  The hook (Task 6) controls the invocation, so this is acceptable; worth
  noting if the CLI ever grows more flags.
- **Threshold is hardcoded** per the brief; Task 7 replaces it with the
  validated env var. No action needed here.
- Shellcheck: only pre-existing pattern warnings (SC1091 source-not-followed,
  SC2164/SC2015 matching the brief's verbatim test and sibling harnesses). No
  new warning classes introduced.

## Commit

`feat(audit): classify content-merged branches into their own bucket` —
includes `bin/audit-worktrees.sh`, `tests/test-audit-content.sh`, and this
report.
