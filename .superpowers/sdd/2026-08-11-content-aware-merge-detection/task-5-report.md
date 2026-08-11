# Task 5 Report: `clean-safe.sh` stays literal-ancestry (guard test)

## Summary

Added `tests/test-clean-content-refuses.sh`, a regression guard pinning the
invariant that `clean-safe.sh` never deletes a branch whose work is
content-merged but which is not a literal ancestor of the base branch.

No production code was changed. `bin/clean-safe.sh` already refuses
non-ancestor branches via its own `git merge-base --is-ancestor` re-check
(`bin/clean-safe.sh:36`), so the test passes immediately against current
code, exactly as the brief's Step 2 expected.

The test scenario:
1. Create branch `sq` off `main`, commit `sq` with a backdated committer
   date (so it is not "recent").
2. Squash-land the same content onto `main` directly.
3. Invoke `clean-safe.sh <repo> sq` and assert exit code 1 (refused).
4. Assert the `sq` branch ref still exists.

## Test command + output

Command: `bash tests/test-clean-content-refuses.sh`

```
=== 1. content-merged but not literal ancestor -> refused ===
  PASS: clean-safe refuses non-ancestor
  PASS: branch kept

=== 2 passed, 0 failed ===
```

(Exit code 0; both assertions passed.)

## Commit

`d36ad0b3b576e1d0f32b5ceb767ad8e62b6ffe18` — `test(clean): pin that clean-safe stays literal-ancestry-only`

Only `tests/test-clean-content-refuses.sh` was added; no other files changed.

## Concerns

None.
