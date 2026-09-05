---
name: auditing-worktrees
description: "Use to sweep a workspace for git worktree/branch drift across many repos — branches merged or abandoned without cleanup ever running (dead session, manual merge, PR merged on GitHub). Triggers on \"audit my worktrees\", \"clean up stale branches\", \"check for leftover worktrees\". To create one worktree use using-git-worktrees; to close one branch use finishing-a-development-branch."
---

# Auditing Worktrees

## What this is for

`using-git-worktrees` creates isolation for one piece of work. `finishing-a-development-branch`
closes out one branch when its work is done. Neither catches drift between those two: a branch
merged by hand, via PR, or in a session that died before cleanup ran, leaves its worktree and
branch sitting on disk indefinitely. This skill sweeps a workspace root for that drift and
buckets it by what you'd actually do about it. It never creates or merges anything on its own.

See `docs/design.md` for the full design rationale, including which signals were tried and
rejected and why the buckets are shaped this way.

## How this gets invoked

Two ways. On demand ("audit my worktrees"), and automatically via a **SessionStart hook**
(`bin/session-hook.sh`, wired in `~/.claude/settings.json`) that reports drift for whatever repo
you start in. The hook exists because a skill only fires when you remember to ask for it, and
remembering is the thing that fails.

**The hook reports; it never mutates.** Everything below still requires explicit confirmation.

## Step 1: Run the report

```bash
$HOME/.claude/skills/auditing-worktrees/bin/audit-worktrees.sh [root-dir]
```

Defaults to the current directory as root. Scans every repo one level down (does not recurse
into nested repos). Pass a single repo path to audit just that repo. Buckets, per repo:

- **safe-to-clean** — merged into base, clean, idle, unlocked or stale-locked (dead session PID).
- **needs-triage** — unmerged and idle. Possible lost work. Also catches a *merged* branch whose
  worktree holds uncommitted files, since those files are in no commit and base doesn't have them.
- **archaeology** — unmerged, idle longer than the archaeology threshold (90d), and never pushed.
  Offered as a batch archive rather than a per-branch judgment call, because at that age the
  context needed to triage it is gone.
- **hands-off** — locked by a still-running session (PID + start time both match a live
  process), *or* locked with a reason the tooling doesn't recognize (e.g. a manual
  `git worktree lock --reason "..."` with no pid/start record). An unrecognized lock is treated
  as live, not as safe — never touch these, no exceptions.
- **couldn't determine merge state** — `git merge-base` errored (unrelated history, bad ref)
  rather than cleanly saying yes/no. Flagged, not guessed at.
- **dangling worktree registrations** — `prunable` entries from `git worktree list`; pointing
  at directories already deleted outside git. `git worktree prune` is always safe for these.

Branches active within the in-flight threshold (2h) are **hidden entirely** and reported only as
a count. They aren't drift, they're work in progress, and listing them is what trains you to
ignore the report.

## The two rules that make this safe

**1. In-flight beats every other bucket, including safe-to-clean.** The hazard isn't only losing
commits. Removing a worktree someone is sitting in breaks their session even when the branch is
0 commits ahead of base. "Merged" and "idle" are separate questions and both must pass.

Activity age is `max(last commit time, newest touched-file mtime)`, not last commit time.
Neither signal works alone, and both failure modes were observed live: a branch committed 20
minutes ago but edited 2 minutes ago is *active*, and a worktree left dirty for 28 days is *not*.

**2. A tag saves commits, not uncommitted files.** Archiving a dirty worktree must commit first.
`git tag` + `git branch -D` + `git worktree remove` on a dirty tree destroys the uncommitted
files outright, and unlike a deleted branch they aren't even reflog-recoverable.
`archive-branch.sh` commits them as `wip: archived with uncommitted changes` before tagging, and
refuses to delete anything if that commit fails.

## Step 2: Present the report, get confirmation

Show the buckets to the user as-is. Do not delete or archive anything without explicit
confirmation — this is a report-only tool by default.

## Step 3: Clean the safe-to-clean bucket (only on confirmation)

```bash
$HOME/.claude/skills/auditing-worktrees/bin/clean-safe.sh <repo-path> <branch> [<branch>...]
```

Only pass branches the user has confirmed from the **safe-to-clean** bucket. The script
independently re-verifies each branch is merged, idle, clean, and its lock (if any) is dead
before touching anything — it refuses and reports rather than deleting if the state changed
since the report ran (e.g., a lock went live in the meantime). It removes the worktree
(unlocking first if needed), prunes, and deletes the branch. No test run — these branches are 0
commits ahead of base by construction, so there's no diff to verify.

## Step 4: Archive the archaeology bucket (only on confirmation)

```bash
$HOME/.claude/skills/auditing-worktrees/bin/archive-branch.sh <repo-path> <branch> [<branch>...]
$HOME/.claude/skills/auditing-worktrees/bin/archive-branch.sh --list <repo-path>
```

Tags each branch as `archive/<branch>`, then deletes the branch and its worktree. The commits
survive permanently and are recoverable by name:

```bash
git branch <name> archive/<name>
```

**Why the tag matters.** `git branch -D` alone only drops the ref. The commits become unreachable
but linger, which is why "git never loses anything" *feels* true. It's a timer, not a guarantee:
reflog entries for unreachable commits expire at 30 days by default, and `git gc` prunes
unreachable objects older than 2 weeks. gc runs on its own via `gc.auto` during ordinary commits
and fetches, so that deletion is silent and eventually total. A tag is a real ref; refs make
commits reachable; reachable objects are never pruned. The tag converts "gone in two weeks,
findable meanwhile only by reflog forensics in the right clone" into "kept forever, recoverable
by name, from anywhere" — at the cost of a ~40-byte ref that never appears in `git branch`.

This is what makes archaeology a batch operation rather than a pile of decisions. Every branch in
a triage list is a question ("is this still worth something?"), and under uncertainty the answer
is always "leave it for now" — which is how the pile got there. Archive tags delete the question:
nothing is lost either way, so there is nothing to weigh.

## Step 5: Resolve needs-triage and content-merged branches

The report now distinguishes three merge states, not two (see `docs/design.md`,
"Content-aware merge detection (hardened v2)"):

- **Literal ancestor** — the v1 rules apply. Merged → safe-to-clean / needs-triage (dirty);
  unmerged → triage/archaeology.
- **Content-merged** — not a literal ancestor, but the coverage score says the branch's work is
  effectively shipped under a different commit hash (squash- or rebase-merge). Surfaced under a
  `likely-content-merged` heading.
- **Unscored** — a binary/mode-only change, a merge-tree conflict or error, or criss-cross
  history made the line-count coverage meaningless. Sent to needs-triage/unknown, never
  auto-cleaned or auto-archived. The triage line carries the full verdict plus a plain-words
  hint (e.g. `unmerged, UNSCORED binary (binary-only change, text can't be compared,
  needs a human call)`).
- **Scored below threshold** — the coverage score ran and returned a concrete percentage
  below the content-merge threshold (e.g. `SCORED 0`), which *proves* the branch's work is
  NOT in base. Surfaced in the needs-triage line as `unmerged, SCORED <pct> (only <pct>% of
  its lines are in base)`. This is the
  strongest "genuinely outstanding" signal the report can give — treat it as open work that
  needs a merge/PR/archive decision, not as a maybe-landed branch. (The score is only dropped
  when it clears the threshold, which routes to content-merged instead.)

Three more line shapes to know when reading a report:

- `upstream ref absent locally`: the branch's configured upstream ref is missing from
  local tracking refs. That covers a deleted remote branch and a never-pushed branch, but
  also a stale tracking ref. The remote branch can still exist when no fetch has refreshed
  it, and the audit never fetches, so the label deliberately says nothing about the remote.
- `(primary checkout (<base>): N uncommitted file(s), ...)`: uncommitted files in the
  primary checkout belong to no branch, so no per-branch line ever shows them. A dirty
  primary prints this parenthetical even when every other bucket is empty.
- `(archive-branch: X archived, Y skipped, Z refused)`: every `archive-branch.sh` run
  ends with this trailer on stdout, so a run that did nothing is still distinguishable
  from a run that never happened.

For each **content-merged** item, the work is already in base — it is a squash-merge false
positive, not open work. Group every content-merged branch into one archive-and-delete confirmation using
`archive-branch.sh --strict <repo> <branch>...` (NOT the generic archive path):
strict mode refuses a dirty worktree instead of committing WIP, and tags atomically.
If strict refuses a branch (dirty worktree), resolve that branch by hand — do not
fall back to the generic WIP-committing archive path for it. Content-merged branches go to
**archive**, never to `clean-safe.sh`, because the coverage score is a heuristic and archive
preserves the work under a tag if the score is ever wrong.

For each **needs-triage** item, it is genuinely open (or unscored, which means the report could
not prove either way — treat that as open and look at the branch before deciding anything). As a
manual backstop for a branch the report missed, `git diff <branch> <suspected-landing-or-base>
--stat` still tells you whether its lines shipped under a different hash — an empty diff means the
work is already in base and that branch belongs with the content-merged archive batch above.

If the repo carries a `working-set` label (see `scaffolding-repos`), check it
before treating a branch as abandoned: `gh-axi issue list --label working-set`
and `gh-axi pr list --label working-set`. A branch whose issue or PR is still
in that set is claimed work, however idle it looks — report it, don't offer it
up for cleanup. The reverse doesn't hold: an unlabeled branch isn't
automatically stale, since the label is hand-maintained and easy to forget.
While you're there, strip `working-set` from anything the sweep confirms has
merged — this pass is the natural place to catch labels that outlived their
work.

For every branch that's genuinely still open, resolve it with the same options
`finishing-a-development-branch` uses for one branch — inlined here so a triage sweep doesn't
have to leave this skill to close each one out:

```
<branch> — <one-line what it is, from its commits> — <idle time>

1. Merge back to <base> locally
2. Push and create a Pull Request
3. Keep as-is (resolve later)
4. Archive-tag and delete
```

- **Option 1 (merge locally):** verify the project's test suite passes on the merge result before
  touching anything else, then clean up the same way `clean-safe.sh` does — worktree removed from
  the main repo root (never from inside the worktree being removed), then `git worktree prune`,
  then delete the branch.
- **Option 2 (push + PR):** push and open the PR; never remove the worktree for this option — the
  user needs it alive to iterate on review feedback.
- **Option 3 (keep as-is):** touch nothing. Report the branch and worktree path back and move on.
- **Option 4 (archive-tag and delete):** use `archive-branch.sh`, not a bare `git branch -D` —
  same tag-then-delete safety this skill already uses for the archaeology bucket, so an open-work
  branch someone changes their mind about later is still recoverable by name.

If the branch has no live worktree (just a local ref sitting in the primary repo, e.g. an old
branch nobody ever ran `using-git-worktrees` for), skip any worktree step above — there's nothing
to remove.

**Never** offer to clean up a **hands-off** item, regardless of what the user asks — a live
lock means another session owns that worktree right now.

## Rules for the cleanup scripts

**All cleanup goes through `clean-safe.sh` or `archive-branch.sh` — never
`git worktree unlock`/`remove`, `git branch -d/-D`, or `git tag` by hand to "help it along."**
If a script refuses a branch or exits partway through the list, that branch stays as-is; don't
manually finish what it declined to do. A refusal means its own re-check disagrees with the
report, which is exactly the case where a script should stop and a human should look.

Both scripts refuse a branch checked out in the repo's **primary worktree** (the repo root
itself). Archiving it would have to switch that checkout to base, and silently moving someone's
main working directory is not a thing a sweep should do. Handle those by hand.

For dangling registrations, `git worktree prune` is always safe to run directly in that repo —
but treat it as part of the same confirmed cleanup step, not something to run unprompted while
just showing the report.

## Configuration

All thresholds are env-overridable; never hardcode them at a call site.

| Variable | Default | Meaning |
|---|---|---|
| `WORKTREE_AUDIT_INFLIGHT_SECS` | `7200` (2h) | Activity newer than this = in flight, hidden, untouchable |
| `WORKTREE_AUDIT_ARCHAEOLOGY_SECS` | `7776000` (90d) | Idle longer than this + never pushed = archaeology |
| `WORKTREE_AUDIT_ARCHIVE_PREFIX` | `archive` | Tag namespace for archived branches |
| `WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD` | `95` | Coverage % above which a non-ancestor branch is treated as content-merged (batch archive) |

## Known limitations

Re-verification narrows but does not fully close the gap between "checked" and "deleted" —
another process could theoretically lock or force-move a branch in that window. This tool has no
cross-process mutex; it's built for a single operator running cleanup interactively, not for
unattended or concurrent use.

The in-flight signal is heuristic. It reads committed history and working-tree mtimes, so an
agent that is thinking, running a long test, or waiting on the network without touching disk for
over 2h looks idle. That's why in-flight only ever gates *visibility* and never triggers a
deletion on its own: being wrong about it costs a line in a report, not your work.
