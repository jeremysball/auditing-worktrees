# Task 7 Report: Threshold config validation

Date: 2026-08-11
Branch: `content-aware-impl-wt`

## Summary

Implemented strict-decimal validation for `CONTENT_MERGE_THRESHOLD` per the
brief:

- Added `validate_pct` to `bin/lib.sh` — echoes the base-10 value or
  `invalid`. Rejects empty, non-numeric, leading-zero (`08`), and out-of-range
  (0-100) values. The `$((val))` read only happens after a `^[0-9]+$` match
  with no leading zero, so a Bash octal read is impossible.
- Replaced Task 3's hardcoded `CONTENT_MERGE_THRESHOLD=95` in
  `bin/audit-worktrees.sh` with the env-var-aware block that distinguishes
  unset (→ default 95) from set-but-invalid (→ hard error to stderr + fallback
  95, audit proceeds). The brief's line numbers didn't match the file's current
  state; the replacement was located by content (the Task 3 comment marker).
- Added `tests/test-threshold.sh` (verbatim from the brief).

## Test scenarios

### 1. Unit test: `bash tests/test-threshold.sh`

Before (Step 2, `validate_pct` not yet defined):

```
=== 1. a bare integer is accepted ===
tests/test-threshold.sh: line 11: validate_pct: command not found
tests/test-threshold.sh: line 14: validate_pct: command not found
tests/test-threshold.sh: line 17: validate_pct: command not found
tests/test-threshold.sh: line 20: validate_pct: command not found
tests/test-threshold.sh: line 23: validate_pct: command not found
  FAIL: 95 rejected
=== 2. leading-zero is rejected, not read as octal ===
  FAIL: 08 not rejected
=== 3. empty is rejected ===
  FAIL: empty not rejected
=== 4. non-numeric is rejected ===
  FAIL: abc not rejected
=== 5. out-of-range (0-100) is rejected ===
  FAIL: 101 not rejected

=== 0 passed, 5 failed ===
exit=5
```

After (Step 5):

```
=== 1. a bare integer is accepted ===
  PASS: 95 accepted
=== 2. leading-zero is rejected, not read as octal ===
  PASS: 08 rejected
=== 3. empty is rejected ===
  PASS: empty rejected
=== 4. non-numeric is rejected ===
  PASS: abc rejected
=== 5. out-of-range (0-100) is rejected ===
  PASS: 101 rejected

=== 5 passed, 0 failed ===
exit=0
```

### 2. End-to-end: audit script with the env var (throwaway repo with a
squash-merged branch, 3h-old commits so it isn't in-flight)

Command pattern:
`WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD=<val> bin/audit-worktrees.sh <repo>`

| Env value | `likely-content-merged` count | stderr |
|---|---|---|
| unset | 1 | — |
| `100` | 1 | — |
| `0` | 1 | — |
| `08` | 1 (fallback 95) | `(skipped: WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD must be an integer 0-100 with no leading zero, got '08')` |
| `101` | 1 (fallback 95) | `(skipped: ... got '101')` |
| `abc` | 1 (fallback 95) | `(skipped: ... got 'abc')` |
| empty | 1 (fallback 95) | `(skipped: ... got '')` |

The audit never aborts and never silently reinterprets a leading-zero value;
invalid input is a defined outcome (stderr + fallback 95).

### 3. Regression: full suite

`for t in tests/test-*.sh; do bash "$t"; done` — all 8 pass
(test-archive, test-archive-strict, test-audit-content,
test-clean-content-refuses, test-coverage, test-hook-parse, test-lock,
test-threshold).

## Deviations from the brief

None. The brief's Step 4 snippet was applied verbatim; the only adjustment was
locating the Task 3 line by content (its line number in the brief, 21, happened
to match, but the comment marker was used as the anchor per the task
instructions).

## Concerns

None.
