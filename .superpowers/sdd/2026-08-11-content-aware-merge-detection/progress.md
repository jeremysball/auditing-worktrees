# SDD ledger — plan: .superpowers/plans/2026-08-11-content-aware-merge-detection.md
BASE: 47850ad539c4d5620b9f873bd0f82d22f036578f


Task 1: complete (commits 47850ad..a7a3862, review clean — Approved)
  - Minor (addressed): test-lock.sh mode 100644 vs sibling 100755 — chmod +x applied.
  - ⚠️ (addressed): task-1-report.md missing from worktree (lived in ferry overlay) — recovered from taskferry diff; now on disk.
  - Note: taskferry accept partially applied (gitignored .superpowers/sdd/* choked 3-way merge); production files bin/lib.sh + tests/test-lock.sh manually applied + committed as a7a3862, test verified 5/5.

Task 2: complete (commits 5f0e5ca..d2ea9da, tests/test-coverage.sh 10/10)
  - Implementer oc_mso6rt6j_e1832c5e -> c707605 `feat(lib): add merge-tree coverage scoring` (8/8).
  - Fix round oc_mso7psjk_ba7bda9e -> criss-cross guard. That ferry settled 2026-08-11 01:23 EDT but its
    diff was never applied: the driving session hit an ollama 429 mid-apply and died. Recovered
    2026-08-11 10:38 EDT from `taskferry result --diff` and committed as d2ea9da.
  - PLAN ERROR corrected: the plan asserted singular `git merge-base` errors on a criss-cross history.
    It does not (git 2.55: exits 0, picks a base arbitrarily). Verified independently in a throwaway
    two-base repo, and by reverting the guard and re-running scenario 7 — without it the branch comes
    back `SCORED 100`, i.e. a genuinely unmerged branch would be classified as landed and offered for
    deletion. `merge_base` now counts with `--all` and returns 1 on >1 base.
    NOTE for Task 3 and Task 8: the plan's lib.sh comment and any prose repeating the "merge-base
    errors" premise are wrong wherever else they appear — check before transcribing.
  - Not done: no independent reviewer round ran on Task 2 (the 429 killed the session before one was
    dispatched). Regressions checked by hand instead: test-lock.sh 5/5, test-archive.sh 14/14.
  - Deviations accepted from the implementer report (see task-2-report.md): scenario 1 rebuilt as a
    non-ancestor (a literal ancestor yields O==0 -> UNSCORED, so the plan's "scenario 1 -> SCORED 100"
    was self-contradictory); `|| true` added to the residual `grep -v` (it exits 1 on a clean merge,
    which under `set -e` aborted the common case).
