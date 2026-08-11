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

Task 5: complete (commits 4d1a48b..4133e65, review clean — Approved, first pass)
  - Implementer oc_msow3631_bfe3071f -> d36ad0b (report's own claimed hash, stale/wrong per
    reviewer — actually landed as 4133e65 after the standard recovery: `taskferry accept`
    partially applied, production/test file manually extracted and applied from the diff,
    test verified independently, committed by hand). `test(clean): pin that clean-safe stays
    literal-ancestry-only` — guard test only, `bin/clean-safe.sh` genuinely untouched.
  - Reviewer (oc_msow4irv_691932f0): Approved, no Critical/Important. Minor (deferred): report's
    stale commit hash (same pattern as Tasks 3-4's reports); test would pass vacuously if
    clean-safe.sh crashed pre-refusal rc=1 (inherent to the brief's spec, not a real gap).
  - Test verified independently: `bash tests/test-clean-content-refuses.sh` -> 2/2 pass.

Task 6: complete (commits 99a8f6f..487d206, review clean — Approved, first pass)
  - Implementer oc_msow5xwl_afcf50c4 -> 487d206 `fix(hook): anchor bucket parsers and surface the
    audit timeout`. Extracted the inline awk into `bin/summary-parser.sh` (`summary_parse`, sourced
    by `session-hook.sh`, structural `/^  <name>/` anchors so a branch description mentioning a
    bucket name can never conflate with the heading); wired `--no-content` into the hook's
    `audit-worktrees.sh` call so the merge-tree pass never runs in the 15s window; distinguished
    timeout (rc 124, explicit jq notice) from every other non-zero exit (still silent per the
    fail-silent contract). Caught and fixed a brief gap itself: the brief's Step 6 `git add` only
    listed 2 files, omitting the new `bin/summary-parser.sh` (would have broken the hook at session
    start if committed as literally specified).
  - Reviewer (oc_msow8y9z_e6c2866f): Approved, no Critical/Important. Verified line-by-line: all 4
    binding constraints hold, and the test genuinely fails against the old bare-substring matcher
    (traced by hand) and passes against the anchored one. Minor (deferred, plan-mandated
    non-defects): heading matchers omit the literal trailing colon the plan's constraint prose
    describes (functionally moot — 2-space vs 4-space indent already disambiguates); report's stale
    commit hash (same pattern as prior tasks); test uses `grep` not `rg` (brief-verbatim).
  - Test verified independently: `bash tests/test-hook-parse.sh` -> 3/3 pass. Regression:
    test-archive.sh 14/14, test-audit-content.sh 9/9, test-archive-strict.sh 10/10,
    test-clean-content-refuses.sh 2/2, test-coverage.sh 10/10, test-lock.sh 5/5.

Task 7: complete (commits 56c6e7c..13c47ee, review clean — Approved, first pass)
  - Implementer oc_msowcedb_d828d4a3 -> 13c47ee `feat(audit): validate the content-merge threshold
    strict decimal`. Added `validate_pct` to `bin/lib.sh` (strict-decimal, base-10, 0-100, rejects
    leading-zero-as-octal); wired it into `audit-worktrees.sh`'s `CONTENT_MERGE_THRESHOLD`, sourced
    from `WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD` — unset -> default 95, set-but-invalid -> stderr
    notice + fallback 95, never a silent Bash octal read/abort.
  - Recovery note: `taskferry accept` failed the usual way (ambient `.claude/CONTINUATION*` and stray
    review-diff files break the 3-way apply) — hand-applied only the production hunks
    (`bin/lib.sh`, `bin/audit-worktrees.sh`, `tests/test-threshold.sh`, task-7 brief/report), verified
    independently, committed, then `taskferry reject`ed the changeset per the established recovery.
  - Reviewer oc_msowi3wr_1ac593e9 settled `done`/exit 0 but never reached its Assessment block or a
    `Status:` line (trailed off mid edge-case sweep, `finalMarker: null`) — resumed the same session
    (`--session-id`) to close it out rather than treating the truncated narration as a verdict.
  - Test verified independently: `bash tests/test-threshold.sh` -> 5/5 pass (95 accepted; 08, empty,
    abc, 101 rejected). Regression: test-archive.sh 14/14, test-archive-strict.sh 10/10,
    test-audit-content.sh 9/9, test-clean-content-refuses.sh 2/2, test-coverage.sh 10/10,
    test-hook-parse.sh 3/3, test-lock.sh 5/5 (8/8 test files total).
  - Minor (deferred): test doesn't explicitly exercise boundary values `0`/`100` (brief's test is
    verbatim; reviewer's own edge-case sweep confirmed both boundaries behave correctly).
  - Minor (deferred): `validate_pct` with no argument would trip `set -u` on `local val="$1"` —
    theoretical only, no caller in the codebase omits the argument.

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

Task 8 (this-repo scope: Steps 1, 2, 3a, 3e, 4): complete (commits 2c50a4c..2523a0f, fix round 1/5, review clean — Approved)
  - Implementer oc_msox1pcj_b7ba2636 -> `48822b3` `feat(audit): add coverage-score CLI entry point
    for non-bash consumers` + `20744fa` `docs: align config table and downstream notes with
    content-aware detection`. Step 1: zero drift in docs/design.md (already accurate). Step 2:
    SKILL.md config table gained WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD row; Step 5 text now names
    `archive-branch.sh --strict` explicitly. Step 3a: `bin/coverage-score` CLI wrapper around
    `coverage_score`, verdict on stdout, exit 0 on every verdict incl. UNSCORED/UNKNOWN, exit 2 on
    usage error, `--help`, `tests/test-cli.sh` new. Step 3e: confirmed no `coverage_score` in
    clean-safe.sh.
  - Reviewer oc_msoxbysn_3dfe5b21: Approved overall but flagged 2 Important + 3 Minor findings —
    Important findings enter the fix loop regardless of the overall Approved label (per process).
  - Fix round 1/5: resumed implementer session (oc_msoxgk8u_7853698a) -> `2523a0f`
    `fix(audit): reject unknown flags in any position for coverage-score`. Fixed: unknown-flag
    rejection now scans all 3 positional args (was position-1-only, a silent-wrong-answer gap);
    report's stale commit-hash table (9d17917/771ec99 -> 48822b3/20744fa); bad-repo-path now exits
    2 not 1 with no raw `cd` stderr leak; added an UNKNOWN-verdict-exit-0 test case.
  - Scoped re-review (oc_msoxj7w0_e636df91): all 4 findings ADDRESSED, no new breakage. Approved.
  - Test verified independently, twice (pre- and post-fix): `bash tests/test-cli.sh` 15/15 then
    24/24. Regression: all 8 sibling test files green both times (73 assertions pre-fix, 82
    post-fix, 9/9 suites).
  - Minor (deferred): `--` end-of-options marker rejected as `error: unknown flag --` — harmless
    nit, CLI has no other flags to need the marker for.
  - Minor (deferred): `tests/test-cli.sh` case 7 writes to a fixed `/tmp/cli-stderr` path instead
    of the test's own `$SCRATCH` — a parallel-test-run collision nit, test-suite-only, not
    production code.

Task 8 (cross-repo scope: Steps 3b, 3c, 3d — orient/bin/scan-active.sh, jeeves/bin/todos.py,
orient-quick/SKILL.md, finishing-a-development-branch-addendum/SKILL.md): NOT STARTED. Each lives
in its own private submodule repo per the plan's explicit "separate PRs, each its own submodule
repo" — handled as follow-up work in those repos' own worktrees/branches/PRs, not inside this
plan's SDD loop.

Final whole-branch review (commits 334769f..a03546e): complete — reviewer oc_msoxmihj_96790d90
(openai/gpt-5.6-luna, most-capable tier), verdict Needs fixes (1 Important, 1 Minor, no Critical).
  - Important, CONFIRMED against source before dispatching a fix: `coverage_score` in `bin/lib.sh`
    ignored `$repo` for the `merge_base` call and the branch-diff `git diff --numstat` call
    (bare `git`, no `-C`), relying on caller cwd — a latent contract violation. Every current
    caller (`audit_repo()`, `bin/coverage-score`) happened to `cd "$repo"` first, which is exactly
    why no test caught it — but the next caller (the cross-repo consumers Task 8 sets up) would
    not necessarily do that.
  - Minor: `bin/summary-parser.sh`'s bucket-heading regexes didn't require the trailing colon its
    own header comment claimed.
  - Fix wave (oc_msoxrsdu_ab8243a6, one fixer for both findings) -> `2089e59`
    `fix(audit): make coverage_score consistently repo-scoped` (merge_base now takes repo, every
    git call uses -C; new tests/test-coverage.sh scenario 8 calls from a foreign cwd) + `656155f`
    `fix(audit): tighten bucket-heading anchor to require the colon`.
  - Scoped re-review (oc_msoxvn0z_71d454a6): both findings ADDRESSED, no new breakage. Full suite
    9/9 files, 83 assertions, all passing.
  - No residual findings. Nothing parked, nothing BLOCKED.

All 8 tasks complete (Task 8 cross-repo consumers are follow-up work in their own repos, per the
plan's own "separate PRs, each its own submodule repo"). Final review clean. Ready for
finishing-a-development-branch.
