# auditing-worktrees — design

## Problem

`using-git-worktrees` creates isolation for one piece of work. `finishing-a-development-branch`
closes out one branch when its work is done. Both are single-branch, in-the-moment tools. Neither
catches drift: a branch that gets merged by hand, via PR, or in a session that died before Step 6
cleanup ran, leaves its worktree and branch sitting on disk indefinitely. A 2026-07-15 manual audit
of six repos under `/workspace` found 22 merged branches with dead worktrees/branches, 4 dangling
worktree registrations, a merged-but-locked worktree with a dead session PID, an unmerged-but-locked
worktree with a dead session PID (real at-risk work), and a locked worktree with a live session PID
(correctly left untouched).

`auditing-worktrees` is the missing third piece: a workspace-wide sweep for that drift.

## What the first version got wrong (2026-07-17)

Two days after the skill shipped, `/workspace` still held 35 stranded branches. The sweep ran
fine and found all of them. Detection was never the bottleneck. Three separate faults:

1. **Everything landed in one bucket.** 28 of 35 went to `needs-triage`, which only empties by
   handing each branch to `finishing-a-development-branch` one interactive session at a time.
   28 items, 28 sessions. Nobody does that, so the bucket only ever grows. The skill produced a
   list, and lists don't merge code.

2. **The buckets conflated three different animals.** A clawmarks branch whose last commit was 9
   minutes ago (in flight *right now*) sat in the same list as hearth branches idle 5-21 days
   (genuinely stranded, context recoverable) and 16 alfred-prd branches idle 3-5 months
   (archaeology, context gone). Flagging live work as needing triage is a false positive, and
   false positives are how a report teaches you to ignore it. The archaeology inflated a
   tractable 12-item list into a hopeless 28-item wall.

3. **Nothing made the sweep happen.** The skill's trigger was "audit my worktrees" — it fired
   when the user remembered to ask, and remembering is exactly the thing that fails. Its trigger
   condition and its failure mode were the same event. No description rewrite fixes that; skills
   are matched when the model is already deciding what to do. Only a harness-level hook runs
   without being remembered.

The underlying mechanism: **the merge decision is cheap exactly once, when the work lands and
the context is still in your head, and it gets more expensive every day after.** alfred-prd is
that curve's endpoint — at 5 months the decision cost is high enough that it will never be paid.
So the fix targets the decision, not the sweep: grade by age so defaults fire instead of
questions waiting, and make "keep" and "delete" the same action so there's nothing to decide.

## Why the popular cleanup scripts don't transfer

The widely-cited approach (brtkwr's, and tools like `git-worktree-cli`) deletes any branch whose
remote tracking ref is gone: if the remote branch vanished, the work was merged or intentionally
abandoned. That cleared 256 worktrees and 700 branches in two minutes.

That heuristic is structurally unavailable here. Of the 35 stranded branches, only 3 were
`[gone]`; most alfred-prd branches had **no upstream at all** and had never been pushed. There is
no remote to consult and no external authority that already knows the answer. Copying those
scripts would delete real work. Local-only branches need a local-only decision rule, which is
what the age grading and archive tags provide.

## Scope vs. existing skills

- `using-git-worktrees`: creates one worktree.
- `finishing-a-development-branch`: closes one branch (merge/PR/keep/discard).
- `auditing-worktrees`: finds every branch/worktree across a workspace that needs one of those
  two skills applied, or is safe to delete outright. It never creates or merges. Its only side
  effect (in cleanup mode) is deleting things already proven safe.

## Invocation

Two paths, because on-demand alone was fault 3.

**On demand:** "audit my worktrees," "clean up stale branches," or `/auditing-worktrees [root-dir]`.
Root defaults to cwd. Finds every repo one level down (`fd -t d '^\.git$'`, non-recursive into
nested repos) and audits each.

**SessionStart hook** (`bin/session-hook.sh`, wired in `~/.claude/settings.json`). This is the
part that fixes "the skill never gets triggered." A skill description is matched when the model is
already deciding what to do; if worktrees never come up, nothing ever matches. Only a
harness-level hook runs without being remembered.

- **Report only.** It never archives, deletes, commits, or moves anything. A hook that mutated git
  state on session start would be a worse problem than the drift it reports. Acting still requires
  the skill and an explicit confirmation.
- **Two modes.** Inside a repo: the full report for that repo (~60ms). Above one (e.g. a
  `/workspace` session, which is not itself a repo): one line per repo with counts (~0.75s for ~50
  repos). The summary is load-bearing — dumping all 36 stranded branches at every session start
  would rebuild exactly the wall of noise that made the original report ignorable.
- **Fails silent.** No output and rc 0 when there's nothing to report, when git/jq/the audit script
  are missing, on malformed stdin, or on timeout. A broken hook must never block a session from
  starting.

## Data collection, per repo

1. `git worktree list --porcelain` — every worktree, its branch, locked/prunable flags.
2. `git for-each-ref refs/heads` — every local branch, including ones with no worktree.
3. Detect base branch the same way `finishing-a-development-branch` does
   (`git merge-base HEAD main` / `master` fallback).
4. Per branch: `git merge-base --is-ancestor <branch> <base>` to classify merged/unmerged.
5. Per worktree, resolve its metadata dir via `git -C <path> rev-parse --absolute-git-dir`, not
   by reconstructing `.git/worktrees/<basename>` by hand. Git disambiguates worktrees that share
   a basename in different parent directories (`same` and `same1`) — deriving the name from the
   path instead of asking git reads the wrong worktree's lock file whenever two worktrees in the
   sweep happen to share a basename.
6. Per locked worktree: read `<gitdir>/locked`, parse `pid N start M`. Compare both PID and
   start time against the live process. Start time comes from `/proc/N/stat` field 22 (clock
   ticks since boot) — PIDs get reused, so a match requires both fields, not just a running PID.
   Field 22 must be counted from the last `") "` in the stat line, not by naive whitespace
   splitting: field 2 (`comm`) is parenthesized and can itself contain spaces or parens, which
   shifts a naive field count and produces a false "stale" reading for a live process.
   A lock reason that doesn't parse into a pid/start pair at all (e.g. a manual
   `git worktree lock --reason "..."`) is **unknown**, not stale — it must be treated the same
   as live, since there's no way to prove it's safe.
7. Per branch: check `%(upstream:track)` via `git for-each-ref`, not by grepping `git branch -vv`
   text — the porcelain track field can only ever contain `[gone]` as a literal marker, whereas
   grepping the human-readable `-vv` line can false-match a commit subject that happens to
   contain the string `: gone]`.

## Choosing the in-flight signal

"Is someone working on this right now?" gates everything else, so the signal has to be right.
Three candidates were measured against the live workspace:

- **Worktree lock (live PID + start).** Rejected as the primary signal. Exactly one worktree in
  ~50 repos was locked at all, and that one was a *stale* lock from a dead session. Every other
  worktree — clawmarks ×2, omnisearch, tts-research, hearth/sprightly — carried no lock. A signal
  present in 1 of 6 relevant cases can't carry the classification. It's still used where it
  exists, since a live lock is authoritative when present.
- **Last commit time.** Insufficient alone. clawmarks `feat/sulfur-proof-shared-shell` had
  committed 20 minutes prior but had files edited 2 minutes prior. Committed history lags the
  keyboard.
- **Working-tree dirtiness.** Insufficient alone, and wrong in the opposite direction. omnisearch
  `fix/bfcache-overlay` had 4 uncommitted files whose newest mtime was 28 days old. Dirty means
  unfinished, not active.

Chosen: **activity age = `max(last commit time, newest touched-file mtime)`**. It classifies all
three observed cases correctly. Only *changed* files count toward the mtime — a clean worktree's
files carry checkout mtimes, which are not activity — so the scan costs one `stat` per changed
file, and a clean tree costs nothing. Full sweep of ~50 repos: 1.3s.

The threshold is 2h. It only ever gates **visibility**, never destruction, which is what makes a
hard cutoff acceptable: a branch flickering across the boundary between two runs changes whether
it appears in a list, not whether it survives. If the threshold gated deletion, a sharp time-based
cut would be indefensible.

## Report: buckets, per repo

- **in-flight** — activity age under `IN_FLIGHT_SECS`. Hidden entirely, surfaced only as a count.
  Wins over every other bucket including safe-to-clean: the hazard isn't only losing commits, it's
  removing a directory a live session is sitting in. "Merged" and "idle" are separate questions
  and both must pass before anything is touched.
- **safe-to-clean** — merged, clean, idle, unlocked or stale-locked (dead PID/start mismatch).
- **needs-triage** — unmerged and idle. The "possible lost work" bucket. Also catches a *merged*
  branch with a dirty worktree: merged proves every commit is in base and says nothing about
  uncommitted files, which are in no commit and would die with the worktree.
- **archaeology** — unmerged, idle beyond `ARCHAEOLOGY_SECS`, and never pushed (no upstream at
  all, distinct from `[gone]`). Offered as a batch archive. Requiring "never pushed" keeps
  branches with any remote trace out of the batch — those have an external record and deserve
  the triage path.
- **hands-off** — live-locked (PID + start both match a running process), or locked with an
  unparseable reason. Listed for visibility only. Never touched, no exceptions, no override flag.
- **couldn't determine merge state** — `git merge-base --is-ancestor` exited with something other
  than 0 (merged) or 1 (not merged) — unrelated history, bad ref, repo error. Flagged rather than
  defaulted into either other bucket.

Output is a terminal report, not a written file — a point-in-time check, not a durable artifact.

## Archive tags

The archaeology bucket exists because triage lists don't drain, and they don't drain because
every entry is a question: "is this still worth something?" Under uncertainty the safe answer is
always "leave it for now," so entries accumulate forever. Archive tags remove the question rather
than making it easier to answer — if nothing is lost either way, there's nothing to weigh.

`git tag archive/<branch> <branch>` then `git branch -D <branch>`.

Why the tag is load-bearing, verified empirically rather than assumed:

- `git branch -D` alone drops only the ref. The commits persist as unreachable objects and stay
  reflog-findable, which is why "git never loses anything" feels true.
- It's a timer, not a guarantee. `gc.reflogExpireUnreachable` defaults to 30 days;
  `gc.pruneExpire` defaults to 2 weeks. `gc` runs on its own via `gc.auto` during ordinary
  commits and fetches. A test forcing that moment (`git reflog expire --expire-unreachable=now
  --all; git gc --prune=now`) confirmed the commit is then **unrecoverable**.
- A tag is a real ref. Refs make commits reachable, and reachable objects are never pruned. The
  same forced gc left a tagged commit fully intact, recoverable by name with
  `git branch <name> archive/<name>`.

Cost: a ~40-byte ref that never appears in `git branch`. Tags are listed via
`archive-branch.sh --list`, which reads `refs/tags/archive` rather than polluting the daily
branch view.

**A tag saves commits, not uncommitted files.** This is the one case where "nothing is ever lost"
would be a lie. Uncommitted changes are in no commit, so the tag doesn't capture them and
`git worktree remove` destroys them outright — not even reflog-recoverable. omnisearch had 4 such
files sitting for 28 days, i.e. the hazard was live in the workspace, not hypothetical.
`archive-branch.sh` therefore commits a dirty worktree as `wip: archived with uncommitted
changes` *before* tagging, and refuses to delete anything if that commit fails.

The tag is also verified to resolve to the branch tip before the branch is deleted — prove the
parachute opened before jumping.

This WIP-commit-and-verify behavior is the **generic** archive path, used by archaeology. The
content-aware path (see "Content-aware merge detection (hardened v2)") is the strict one: it
refuses dirty worktrees instead of committing WIP, and it makes the tag atomic via an
`update-ref --stdin` transaction that verifies the branch OID before creating the tag. The two
paths are distinguished by caller intent.

## Cleanup mode

Explicit confirmation required; never runs automatically as part of a report.

- safe-to-clean is merged by construction, so every entry is 0 commits ahead of base — no diff
  exists to test. Cleanup is direct: `git worktree remove` (unlock first if needed) + `git worktree
  prune` + `git branch -d`. No test run, reusing `finishing-a-development-branch`'s Step 6
  mechanics for the worktree-removal sequencing (cd to main root first, remove, prune, then delete
  branch) but skipping its test-verification step since there's nothing to verify.
- archaeology is archived as a batch via `archive-branch.sh`, on confirmation. Every branch is
  re-verified independently (idle, unlocked, not primary-worktree, tag resolves) before deletion.
- needs-triage is never auto-cleaned. After the report, offer inline handoff: for each item, ask
  whether to invoke `finishing-a-development-branch` right there to resolve it (merge/PR/keep/
  discard), one branch at a time.
- hands-off is never offered for cleanup under any mode.

### The primary-worktree guard

Both cleanup scripts refuse a branch checked out in the repo's primary worktree (the repo root
itself). Four repos in the workspace were in exactly this state — alfred-prd, pypitui, portico,
superfile each had a feature branch checked out at the root rather than in a `.worktrees/` subdir.

Git already blocks the mechanics (`git worktree remove` rejects the primary worktree; `git branch
-d/-D` rejects a checked-out branch), so the scripts would fail rather than corrupt anything. They
refuse explicitly instead, with a message naming the path, because the only way to proceed would
be to switch the user's main working directory to base — a surprising mutation that a sweep should
never make on its own. alfred-prd's case is the sharpest: its root checkout held 34 uncommitted
files, 91 days idle.

## Error handling

- A repo with no worktrees beyond its primary checkout is skipped silently — nothing to report.
- A repo where `merge-base` fails (unrelated histories, detached-HEAD base) is flagged as
  "couldn't determine merge state," not guessed at.

## Content-aware merge detection (hardened v2)

The v1 ancestry check (`git merge-base --is-ancestor`) is authoritative for the common case — a
cleanly merged branch *is* an ancestor, so its work is provably in base. But it returns a hard
"no" for any branch whose work shipped under a different commit shape: a squash-merged or
rebase-merged branch is not a literal ancestor of base even when every line it added is already
there. `SKILL.md` Step 5 already had to work around this by hand (`git diff <branch>
<suspected-landing> --stat`). The hardened design moves that judgment into the report itself.

### The coverage calculation

For a branch whose ancestry check says "unmerged," compute how much of the branch's work is
already in base:

```
coverage = max(0, O - R) / O × 100
```

where:

- **O** = the branch's net text-line footprint — `git diff --numstat --no-renames
  <merge-base> <branch>`, summed as added-minus-deleted over text rows.
- **R** = the residual text lines still required to get from base to the simulated merge —
  `git diff --numstat --no-renames <base> <simulated-tree>`, where `<simulated-tree>` is the
  tree `git merge-tree --write-tree <base> <branch>` reports for a clean merge.
- `git merge-base <base> <branch>` gives the merge base for O; `git merge-tree --write-tree`
  computes its own virtual base for the merge.

Intuition, verified empirically (probe scripts in the taskferry worktree's `.review/`): base's
own forward commits are present on both sides of the second diff, so they cancel; only the
branch's unmerged work — present in the simulated merge tree, absent from base — shows up as R.
A fully merged branch yields R ≈ 0 → coverage near 100%. A genuinely unmerged branch yields
R ≈ O → coverage near 0%. A branch above a configured threshold (default: treat ≥ 95% as
shipped) is content-merged.

**Compare clamped, never as a raw percentage.** Compute `max(0, original - residual) * 100 >=
threshold * original` rather than dividing first. The clamp keeps a base that has drifted ahead of
the branch (R momentarily larger than O) from producing a negative numerator that Bash then
mishandles; the integer multiply-before-divide avoids float and precedence surprises. This is the
one place the comparison is specified: as a clamped integer inequality, not a floating-point
ratio.

**O = 0 is unscored, not 0%.** A branch with no text rows at all — a binary- or mode-only-only
change, or an empty diff — has O = 0 and must be marked **unscored** (→ needs-triage/unknown)
before any division runs. The binary/mode-only unscored rules below cover the individual-row case;
this is the same rule stated for the all-rows-empty case, where `max(0, O - R) / O` would otherwise
divide by zero.

### When a branch is unscored, not low-coverage

A branch is **unscored** (→ needs-triage/unknown, never auto-cleaned) if *either* its own patch
or the merge residual contains a numstat row the line-count can't interpret:

- `- -` — a binary change. Line counts are meaningless for it.
- `0 0` — a mode-only (chmod) change. Zero lines but a real change.

These rows must **force** an unscored flag, not be skipped or treated as zero. A branch whose
only change is a chmod, or whose merge conflict touches a binary, is exactly the case where a
line-based coverage number would silently lie. The same rule applies to `merge-tree`'s exit code
per branch: exit `1` (conflict) → unknown/triage; exit `>1` (error) → unknown/triage. A conflict
means the simulated merge didn't produce a usable tree, so there is no residual to measure. The
branch-level `set -e` must never abort the whole repo scan on a single branch's merge-tree
failure — the failure routes that one branch to unknown and the loop continues.

Criss-cross history (multiple merge bases — where singular `git merge-base` and `merge-tree`'s
virtual base disagree) is also unscored. O is measured against the singular merge base while R is
measured against merge-tree's virtual base; when those two bases differ, the two sides of the
ratio are computed against different ancestors and the number is meaningless.

### Bucket semantics with content awareness

The content-aware score does **not** replace the ancestry check; it is the fallback the report
reaches for only when ancestry is ambiguous. "Always filter, then process": the cheap
`merge-base --is-ancestor` runs for every branch; the expensive `merge-tree` computation runs
only for the branches it says are unmerged. This keeps the hot path (the SessionStart hook's
budget) on the cheap signal.

- **Literal ancestor** → the v1 rules apply unchanged: merged → safe-to-clean (if clean, idle,
  unlocked/stale-locked) or needs-triage (if dirty); unmerged → triage/archaeology/hands-off.
- **Not an ancestor, content-merged** (score ≥ threshold, no unscored flags) → the branch's work
  is effectively shipped under a different commit hash. It is surfaced like the squash-merge
  false positive in `SKILL.md` Step 5: offered for the archive-and-delete batch (tag first,
  nothing is lost either way). It does **not** join the safe-to-clean bucket.
- **Not an ancestor, low/zero coverage, no unscored flags** → genuinely unmerged → the v1
  triage/archaeology rules apply.
- **Unscored** (binary, mode-only, conflict, merge-tree error, criss-cross) → needs-triage/
  unknown, never auto-cleaned, never auto-archived.

**`clean-safe.sh` stays literal-ancestry only.** It re-verifies with `git merge-base
--is-ancestor` and refuses anything that is not a provable ancestor. It is deliberately *not*
broadened to accept content equivalence: deleting a worktree and branch is the irreversible end
of the pipeline, and there it demands a stronger guarantee than the report's heuristic. The
content-aware path routes to archive (which preserves work under a tag) precisely because archive
is reversible and safe-to-clean is not. A content-merged branch is never deleted outright; it is
archived, so a wrong coverage call costs a mislabeled tag, not lost work.

### Archive: refuse dirty, and make the tag atomic

Two changes to `archive-branch.sh`:

**Strict content-archive mode refuses a dirty worktree** rather than committing WIP. The current
generic path commits a dirty tree as `wip: archived with uncommitted changes` before tagging
("A tag saves commits, not uncommitted files" — see the Archive tags section). For the
content-aware archive path, that WIP commit is wrong: it fabricates history for files that were
never in a real commit and silently changes the meaning of what's preserved. Strict mode refuses
dirty worktrees and reports them for separate handling instead. The generic
`archive-branch.sh` path (used by archaeology, where the context is already gone and the WIP
commit is the only way to capture the uncommitted files at all) keeps its current behavior; the
strict path is the one used for content-merged branches, which by definition are clean-merge
results and should be clean on disk. The two paths are distinguished by caller intent, not
silently merged.

**Capture the base and branch OIDs and tag atomically.** The tag must be created against the
exact commit the branch pointed at when it was classified, not whatever the branch happens to
resolve to moments later. Before tagging/deleting, record `base` and `branch` tips, then create
the `archive/<branch>` tag inside a single `git update-ref --stdin` transaction that *verifies*
the branch still points at the recorded OID before committing the tag — `start`, `verify
<ref> <oid>`, `create refs/tags/archive/<branch> <oid>`, `prepare`, `commit`, aborting the whole
transaction if the verify fails. This closes the branch-moved-after-check race the v1 design's
"Known limitations" section flags as theoretical; it is still theoretical for a single operator,
but the transaction is cheap and removes the class entirely.

### `proc_start_ticks`: separate missing-PID from unreadable `/proc`

`lib.sh`'s `proc_start_ticks` currently maps every read failure to `stale` (via `return 1`), which
`lock_status` then treats as a provably dead lock. That is wrong for the unreadable-proc case: a
PID whose `/proc` entry cannot be read (permissions, a vanished-then-reused race, a procfs
quirk) is not the same as a PID that provably no longer exists. The hardened design returns three
states:

- **missing** — the process does not exist (a `kill -0` / procfs absence proves it), → stale.
- **unknown** — `/proc` could not be read for any other reason → the lock stays hands-off, never
  treated as provably dead.
- **start-time-match** — the proc record read and its start time equals the lock's → live.

The current `lock_status` collapse of every failure to `stale` must be replaced so that only a
provably-dead PID yields `stale`; every unreadable-but-not-proven-dead record yields `unknown`.
An unreadable proc record is never grounds for deletion.

### SessionStart hook: anchored parsers and an explicit timeout

Two fixes to `session-hook.sh`:

**Anchor the awk bucket parsers.** The current substring matches (`/safe-to-clean/`,
`/needs-triage/`, etc.) conflate any line *containing* a bucket name with a bucket heading. Once
the report can name a content-merged bucket (e.g. a `likely-content-merged` heading), the bare
`/content-merged/`-style match would silently swallow it. Anchor each matcher to the heading
position (start-of-line, leading whitespace, colon) so a heading and a branch description that
mentions the same word do not collide. This is the same class of bug the v1 design already fixed
for `git branch -vv` text-grepping — a substring match is a false-positive vector and headings
must be matched structurally.

**Surface the audit timeout, don't swallow the report.** The hook's `timeout "$TIMEOUT"` currently
exits silently on any timeout, indistinguishable from "nothing to report." A branch that makes the
audit exceed its budget looks identical to a clean repo. The hardened design distinguishes them:
a timeout emits an explicit one-line notice ("audit exceeded its N-second budget; run
`/auditing-worktrees` manually for the full report") rather than vanishing. Failing to do so
trains the reader to believe drift is gone when it is merely uncomputed.

**Budget the content analysis out of the hook.** The merge-tree computation is the expensive part
and must not run inside the hook's 15s window. The hook keeps the cheap ancestry-only report; the
content-aware pass runs on demand (`/auditing-worktrees`) only. If content awareness must reach
the hook, it gets its own sub-budget with the same explicit-timeout surface — never folded into
the silent whole-report swallow.

### Downstream consumers

Four downstream artifacts understand only the four existing buckets and must be updated together
with any bucket rename or new bucket, or they will mislabel or mishandle content-merged branches:

- `skills/orient-quick/SKILL.md` (the safe-to-clean / needs-triage / hands-off / archaeology
  mapping and its "what to do" instructions).
- `skills/finishing-a-development-branch-addendum/SKILL.md` (the cleanup-flow handoff).
- `skills/auditing-worktrees/SKILL.md` (this skill's own Step 5 already handles squash-merge false
  positives; it must name the new content-merged bucket and route it to archive, with explicit
  bucket precedence — content-merged → archive, never clean-safe — and the cleanup instructions
  for it).
- `skills/auditing-worktrees/docs/design.md` (this document).

### Threshold config: strict decimal, validated

The coverage threshold (and any new numeric config) is validated strict decimal, base-10
normalized, before use. An invalid value (a bare octal like `08`, a float where an int is
required, an empty string) is a **defined** outcome — a hard error or an unknown classification
— never a silent Bash octal/abort or a value silently reinterpreted in a different base. Bash
treats a leading-zero string as octal, so an unvalidated `08` threshold would abort or misbehave
at compare time; validation happens at parse time and names the offending value.

## Out of scope

- No cron/loop-based sweeps. The original "on-demand only" stance is **superseded** — see
  "Invocation" below. A sweep you must remember to ask for doesn't run.
- No recursion into nested repos beyond one level under the given root.
- No remote-branch cleanup (deleting `origin/x`) — local-only, matching the two skills this
  extends.
- No handling for bare repositories or submodules as sweep targets — the tool is built for a
  workspace of ordinary checkouts, matching how this workspace is actually laid out.

## Known limitations (accepted, not fixed)

- **Check-then-act race:** `clean-safe.sh` re-verifies merge state and lock liveness
  immediately before acting, which narrows but does not close the window between "confirmed
  safe" and "deleted" — another process could theoretically lock or force-move a branch in
  that gap. There's no cross-process mutex. Acceptable for a single operator running cleanup
  interactively; not safe for unattended or concurrent invocation. The strict content-aware
  archive path closes this for its tag step with an atomic `update-ref --stdin` transaction
  (see "Content-aware merge detection (hardened v2)"); `clean-safe.sh` and the generic archive
  path still carry the gap.
- **`git branch -d` is not transactional against its own re-check:** the merge-base check and
  the branch deletion are two separate git invocations, not one atomic operation. In the
  single-operator case this gap is theoretical; closing it for real would mean building ref
  transactions (`git update-ref --stdin` with old-value verification), which is more mechanism
  than the generic path's actual usage pattern justifies. The strict content-aware archive path
  does use that transaction for its tag step, because there the tag-and-verify is the whole
  point (prove the parachute opened before jumping) and the cost is trivial.
