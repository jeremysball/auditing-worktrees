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

Task 3: complete (commits 3b5c5ae..2a50e7c, review clean — Approved, fix round 1/1)
  - Implementer oc_msouzyup_bc5e8193 -> 8c49257 `feat(audit): classify content-merged branches
    into their own bucket` (9/9). Fixed 3 real defects in the brief's own Step 3 snippet before
    committing: `reason` unbound under `set -u` on the UNSCORED/UNKNOWN arm (would abort the
    whole scan on the first unscored branch), `local content_merged=false` shadowing the bucket
    array `content_merged=()` (renamed the per-branch flag to `is_content_merged`), and the
    coverage pass running for literal-ancestor branches too (guarded on `merged=false`).
  - Note: taskferry accept partially applied again (ambient `.claude/`/`.superpowers/sdd/*`
    untracked files choke the 3-way merge) — same recovery as Tasks 1-2: extracted the
    bin/tests/report hunks from `taskferry result --diff`, `git apply`, verified tests
    independently, committed manually.
  - Fix round 1/5 (oc_msov9rzb_2ecb7447, resumed implementer session): reviewer's one Important
    finding (execution-error) — test scenario 4 (binary-only branch, unscored-never-archaeology
    routing) passed vacuously because the branch wasn't archaeology-eligible (3h old vs.
    ARCHAEOLOGY_SECS=90d), so it never actually exercised the `elif [ "$unscored" = true ]`
    ordering. Fixed by dating that scenario's commit 100 days back; fix report confirms the
    reworked scenario genuinely fails when the elif ordering is reverted, then passes 9/9
    restored. Committed 2a50e7c. Scoped re-review (oc_msovctvg_f2960f05): Approved, no new
    breakage.
  - Regression: test-archive.sh 14/14, test-coverage.sh 10/10, test-lock.sh 5/5 all still pass.

Task 4: complete (commits f08454d..a26369b, review clean — Approved, fix round 1/1)
  - Implementer oc_msovexa8_2c230573 -> 1ac9d54 `feat(archive): add strict mode (refuse dirty,
    atomic tag)` (8/8, self-reported). `--strict` refuses a dirty worktree (no WIP commit) and
    tags atomically via `update-ref --stdin` (verify-before-create).
  - Fix round 1/5 (oc_msovlhqv_b1c9630c, resumed implementer session): reviewer's one Important
    finding (plan-error) — the brief's verbatim test scenarios 1 and 3 never reached the
    strict-specific code at all: the pre-existing 2h in-flight gate (`activity_age_secs` vs
    `IN_FLIGHT_SECS`) fired first because both scenarios' artifacts (a scratch file, a "moved"
    commit) carried current-wall-clock timestamps, so the assertions passed vacuously — the
    atomic transaction's core guarantee (abort on verify failure) was never actually exercised.
    Independently verified against `bin/archive-branch.sh:60-100` and `bin/lib.sh:110-127`
    before dispatching the fix. Fix: `WORKTREE_AUDIT_INFLIGHT_SECS=0` for the whole test file,
    plus a deeper fix the implementer found beyond the original ask — scenario 3's branch move
    happened before the script ran (not during), so `verify` had nothing to fail against; replaced
    with a `git` shim on `$PATH` that moves the branch *inside* the `update-ref --stdin` call, so
    the transaction's own verify step is what aborts. Also fixed 2 Minor findings (scenario 2 now
    checks the tag resolves to the exact classified tip OID; "close the post-tag race" comment
    reworded to "narrow", naming the residual `git worktree remove` gap). Committed a26369b.
    Scoped re-review (oc_msow0c6g_13755c8a): Approved, no new breakage.
  - Minor (deferred, non-blocking, noted by re-reviewer): fix report's stale commit-hash reference
    (cites the pre-recovery sandbox hash, not the actually-landed one) — cosmetic, same as Task 3's
    report; shim comment says "a tag ref is being created" but the condition matches any
    `update-ref --stdin` (harmless, only call of that shape in the script).
  - Regression: test-archive.sh 14/14, test-audit-content.sh 9/9, test-coverage.sh 10/10,
    test-lock.sh 5/5 all still pass.

Task 8: SCOPE EXPANDED 2026-08-11 (user decision) — not yet started, sequenced after Tasks 3-7.
  - Original Task 8 named only two PROSE consumers (orient-quick, finishing-a-development-branch-addendum).
    An ecosystem sweep found two CODE consumers with their own merge-detection implementations that the
    plan never touched: `orient/bin/scan-active.sh` (ancestry + exact tip-tree match; feeds `orient` AND
    `jeeves` via git-state.md) and `jeeves/bin/todos.py::_landed` (ancestry, then a GitHub API round-trip).
  - Gap proven empirically, not inferred: branch cut -> main advances -> branch squash-merged defeats BOTH
    ancestry and tip-tree match (tip tree = old-main+changes, squash tree = new-main+changes, never equal),
    while coverage_score returns SCORED 100. So orient and jeeves report that branch outstanding today.
  - USER DECISION (sharing mechanism): consumers source lib.sh via
    `${AUDIT_WORKTREES_LIB:-$HOME/.claude/skills/auditing-worktrees/bin/lib.sh}` and MUST degrade to their
    current behaviour when it is absent (`declare -F coverage_score`). Rejected: a new shared repo (too much
    churn, reopens reviewed Task 2 code) and vendoring copies (the cause of the 4-implementation sprawl).
  - USER DECISION (sequencing): after Tasks 3-7, because coverage_score's contract is unproven until Task 3
    wires the first real caller. Documented now so it survives a context loss.
  - New sub-steps 3a-3e added to the plan, incl. a `bin/coverage-score` CLI entry point (todos.py is Python
    and cannot source a Bash function) and an explicit check that clean-safe.sh is NOT changed.
