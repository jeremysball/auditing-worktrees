# Final-Review Fix Report — content-aware merge detection

Date: 2026-08-11
Branch: `content-aware-impl-wt`

## Finding 1 (Important) — `coverage_score` not consistently repo-scoped

**Commit:** `2089e59 fix(audit): make coverage_score consistently repo-scoped`

### What changed

`bin/lib.sh`:
- `merge_base()` signature changed from `merge_base base branch` to
  `merge_base repo base branch`; both of its `git` calls now run with
  `git -C "$repo"` instead of relying on the caller's cwd.
- `coverage_score()` (the only caller of `merge_base`) now passes `$repo`
  through, and its O-diff (`git diff ... "$mb" "$branch"`) also runs with
  `git -C "$repo"`.

`merge_base` had exactly one caller (`coverage_score` itself), so no other
callers were affected. Both remaining bare calls in `coverage_score`
(merge-base + O-diff) now read the repo passed as `$1`, consistent with the
merge-tree/residual-diff steps that already used `-C "$repo"`.

`tests/test-coverage.sh`:
- New scenario 8: creates a branch, then `cd "$SCRATCH"` (a directory that is
  NOT the target repo), and calls `coverage_score "$T" main foreign` with the
  repo's absolute path. Asserts `SCORED 0`.

### Verification of regression coverage

- Pre-fix (only `bin/lib.sh` stashed): scenario 8 failed with
  `FAIL: foreign-cwd call got 'UNKNOWN no-merge-base'` (10 passed, 1 failed).
- Post-fix: scenario 8 passes.

## Finding 2 (Minor) — bucket-heading anchor did not match the comment's claim

**Commit:** `656155f fix(audit): tighten bucket-heading anchor to require the colon`

### What changed

`bin/summary-parser.sh`: the five heading patterns
(`safe-to-clean`, `needs-triage`, `archaeology`, `hands-off`,
`likely-content-merged`) were tightened from a bare indent-prefix match
(`/^  safe-to-clean/`) to require the trailing colon with optional
parenthetical text between name and colon (`/^  safe-to-clean[^:]*:/`), so the
code now matches what the header comment claims ("two-space indent + name +
colon").

The real headings carry parenthetical text before the colon
(e.g. `  archaeology (older than ...):`), so the `[^:]*` span keeps them
matching while a branch description line that merely mentions a bucket name
without a 2-space-indent + colon heading shape is rejected.

## Full suite run (post-fix)

Command:

```
for f in tests/test-*.sh; do bash "$f"; done
```

Every file's own pass/fail line:

```
=== 14 passed, 0 failed ===   (test-archive.sh)
=== 10 passed, 0 failed ===   (test-archive-strict.sh)
=== 9 passed, 0 failed ===    (test-audit-content.sh)
=== 2 passed, 0 failed ===    (test-clean-content-refuses.sh)
=== 24 passed, 0 failed ===   (test-cli.sh)
=== 11 passed, 0 failed ===   (test-coverage.sh)
=== 3 passed, 0 failed ===    (test-hook-parse.sh)
=== 5 passed, 0 failed ===    (test-lock.sh)
=== 5 passed, 0 failed ===    (test-threshold.sh)
```

Total: 83 passed, 0 failed.
