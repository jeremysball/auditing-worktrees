# Task 8 Report: Docs and downstream consumers

Date: 2026-08-11
Branch: `content-aware-impl-wt`

## Summary

Task 8, scoped to THIS repo (cross-repo consumers `orient/bin/scan-active.sh`,
`jeeves/bin/todos.py`, `orient-quick/SKILL.md`,
`finishing-a-development-branch-addendum/SKILL.md` are handled by the
controller in their own repos — not touched here):

- **Step 1 (verify docs match implementation):** `rg -n
  "likely-content-merged|strict|WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD"
  docs/design.md SKILL.md` confirms `docs/design.md` already describes the
  content-merged bucket (`likely-content-merged` at line 385), the strict
  archive path (lines 200, 348, 444-452), and the threshold (default ≥ 95% at
  line 272, bucket semantics at 319, strict-decimal validation at 419-426).
  These match the implemented behavior (`audit-worktrees.sh` default 95,
  `validate_pct` in `lib.sh`, `--strict` in `archive-branch.sh`). `SKILL.md`
  already names the `likely-content-merged` heading. **No naming drift — zero
  diff to `docs/design.md`.**
- **Step 2 (SKILL.md):** Added the
  `WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD` row (default `95`) to the
  Configuration table after the existing three rows, and rewrote Step 5's
  content-merged archive instruction to name `archive-branch.sh --strict
  <repo> <branch>...` explicitly (NOT the generic path), with the
  refuse-dirty → resolve-by-hand wording, following the brief's exact
  pattern. `docs/design.md` untouched beyond Step 1's (empty) drift check.
- **Step 3a (CLI entry point):** Added `bin/coverage-score` —
  `#!/usr/bin/env bash`, `# Usage:` header block, `set -euo pipefail`,
  `source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"` (same pattern as
  `bin/archive-branch.sh`). Prints the `SCORED <n>` / `UNSCORED <why>` /
  `UNKNOWN <why>` verdict line verbatim; exit 0 on every successful run
  including UNSCORED/UNKNOWN; exit 2 with a one-line `error: ...` naming
  usage on wrong arg count; `--help` prints a usage block (purpose, three
  positional args, two examples) and exits 0; any other `-*` flag → `error:
  unknown flag <x>` on stdout, exit 2. No interactive prompts. Resolves
  `<repo>` to an absolute path and cds into it so the score is computed
  against the named repo regardless of the caller's cwd.
- **Step 3e:** `rg -n 'coverage_score' bin/clean-safe.sh` returns nothing —
  deletion path untouched.
- **Step 4 (commits):** two commits as instructed (see below).

## Commits

| Commit | Message |
|---|---|
| `48822b3` | `feat(audit): add coverage-score CLI entry point for non-bash consumers` |
| `20744fa` | `docs: align config table and downstream notes with content-aware detection` |

## Tests

Added `tests/test-cli.sh` (modeled on `tests/test-coverage.sh`'s harness —
`set -uo pipefail`, mktemp scratch repo, PASS/FAIL counters, exit = fail
count). Covers: correct usage → `SCORED 100` on stdout + exit 0; wrong arg
count (0/2/4 args) → `error:` + exit 2; `--help` → usage block + exit 0;
unknown flag (`--bogus`) → `error: unknown flag --bogus` + exit 2; an
`UNSCORED` verdict is a successful run (exit 0).

Full regression suite — all 9 suites pass, 73 assertions total:

```
tests/test-archive.sh               14 passed, 0 failed
tests/test-archive-strict.sh        10 passed, 0 failed
tests/test-audit-content.sh          9 passed, 0 failed
tests/test-clean-content-refuses.sh  2 passed, 0 failed
tests/test-cli.sh                   15 passed, 0 failed
tests/test-coverage.sh              10 passed, 0 failed
tests/test-hook-parse.sh             3 passed, 0 failed
tests/test-lock.sh                   5 passed, 0 failed
tests/test-threshold.sh              5 passed, 0 failed
```

## Deviations from the brief

None. The brief's Step 2 wording was applied as specified (its reference to
"lines 186-192" and "around line 118-137" matched the file's actual state).
`bin/coverage-score` error messages go to stdout and unknown flags are
rejected before the arg-count check, per the task instructions (the brief
itself left message-target unspecified; the task text required stdout).

## Concerns

None.

---

# Fix Report: reviewer findings on Task 8

Date: 2026-08-11 (second pass)

## What changed

**Important #1 — unknown flags rejected in ANY position.** `bin/coverage-score`
now scans all three positional args (before the arg-count check) and rejects
any arg starting with `-` with `error: unknown flag <x>` on stdout and exit 2.
Previously only position 1 was checked; `coverage-score "$PWD" --bogus feat`
slipped through and returned `UNKNOWN no-merge-base` with exit 0 — a silently
plausible wrong answer.

**Important #2 — report commit table corrected.** The actual committed hashes
(applied by the controller) are `48822b3` (feat) and `20744fa` (docs); the
table previously listed non-existent `9d17917`/`771ec99`. Fixed in the commit
table above.

**Minor — bad repo path is a usage error.** `cd` into the repo now suppresses
its own stderr (`2>/dev/null`) and a nonexistent `<repo>` exits 2 (not 1) with
`error: not a directory: <x>` on stdout. No raw bash error leaks.

**Minor — UNKNOWN-verdict test added.** `tests/test-cli.sh` gained a case
exercising an unrelated-history repo (no merge-base) → `UNKNOWN no-merge-base`,
exit 0. (The `--` end-of-options nit was left alone per the reviewer's own
note that it is a non-issue.)

## Tests

`bash tests/test-cli.sh` — 24 passed, 0 failed (was 15; +3 unknown-flag
positions, +1 UNKNOWN-verdict, +3 bad-repo-path assertions).

Full suite — all 9 suites green, 82 assertions total:

```
tests/test-archive.sh               14 passed, 0 failed
tests/test-archive-strict.sh        10 passed, 0 failed
tests/test-audit-content.sh          9 passed, 0 failed
tests/test-clean-content-refuses.sh  2 passed, 0 failed
tests/test-cli.sh                   24 passed, 0 failed
tests/test-coverage.sh              10 passed, 0 failed
tests/test-hook-parse.sh             3 passed, 0 failed
tests/test-lock.sh                   5 passed, 0 failed
tests/test-threshold.sh              5 passed, 0 failed
```

## Commit

- `fix(audit): reject unknown flags in any position for coverage-score`
  (the single fix commit covering findings above and the test additions).

## Concerns

None.

