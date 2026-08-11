### Task 8: Docs and downstream consumers

**Files:**
- Modify: `docs/design.md`, `SKILL.md` — confirm they match the implemented behavior (they already describe the design; adjust any drift).
- Add: a `coverage_score` CLI entry point in this repo, so non-Bash consumers can reach it (see Step 3a).
- Cross-repo (separate PRs, each its own submodule repo): `skills/orient-quick/SKILL.md`,
  `skills/finishing-a-development-branch-addendum/SKILL.md`, **`skills/orient/bin/scan-active.sh`**,
  and **`skills/jeeves/bin/todos.py`**.

**Interfaces:**
- Consumes: the four existing buckets plus the new `likely-content-merged` bucket and the strict archive path.
- Produces: downstream consumers that can name the new bucket and route it to archive (not clean-safe), with explicit bucket precedence.

**Problem.** Two separate problems, only the first of which the original draft of this task covered.

*Prose consumers.* `orient-quick` and `finishing-a-development-branch-addendum` understand only the four original buckets. Until updated, they will ignore content-merged branches.

*Code consumers (added 2026-08-11).* There are **four** independent implementations of "did this branch land" across the skill ecosystem, not one. Two of them are outside this repo, and both carry the exact false positive this plan exists to remove:

| # | Where | Method | Consumers | Action |
|---|---|---|---|---|
| 1 | `orient/bin/scan-active.sh:132-152` | ancestry + exact tip-tree match + transitive closure | `orient`, **`jeeves`** (via `~/.local/state/jeeves/git-state.md`) | adopt (Step 3b) |
| 2 | `jeeves/bin/todos.py:304-322` (`_landed`) | ancestry, then a **GitHub API round-trip** | jeeves todo ledger | adopt (Step 3c) |
| 3 | `auditing-worktrees/bin/audit-worktrees.sh` | ancestry today; `coverage_score` as of Task 3 | orient-quick, SessionStart hook | Task 3 |
| 4 | `auditing-worktrees/bin/clean-safe.sh` | literal ancestry, **deliberately** | the deletion path | **do not change** — Task 5 guards this |

**Evidence the gap is real** (run 2026-08-11, not inferred). The most common squash shape — branch cut, `main` advances, *then* the branch is squash-merged — defeats both existing offline detectors:

```bash
# main@root -> feature adds feat.txt -> main gains an unrelated commit
# -> feature squash-merged onto the ADVANCED main
git merge-base --is-ancestor feature main   # -> NO   (ancestry says outstanding)
git log main --format=%T | rg "^$(git rev-parse feature^{tree})$"
                                            # -> no match (tree-match says outstanding)
coverage_score "$PWD" main feature          # -> SCORED 100  (correct: landed)
```

`scan-active.sh`'s tree match requires the branch tip tree to be byte-identical to some commit tree in base history. Once `main` moves between the branch point and the squash, the squash commit's tree is `new-main + branch changes` while the branch tip tree is `old-main + branch changes` — never equal, so the match fails. `coverage_score` is unaffected because it scores residual content, not tree identity.

`todos.py` documents this same failure in its own docstring (ancestry misses squashes; `git cherry` patch-id matching does not rescue it — confirmed against jeeves PR #1, four commits unmatched) and works around it with a network call to GitHub. That call is unnecessary when the answer is computable offline, and it degrades to `UNKNOWN` for any repo whose origin is not GitHub — a case `coverage_score` answers fine.

- [ ] **Step 1: Verify this repo's docs match implementation**

Run (scoped to THIS repo, not `~/.claude`): `rg -n "likely-content-merged|strict|WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD" docs/design.md SKILL.md`
Expected: the design and SKILL.md already describe the content-merged bucket, strict archive, and threshold. If any naming drifted during implementation, fix it here.

- [ ] **Step 2: Update `SKILL.md` Configuration table and wire strict archive**

Add the new threshold to the config table (currently lines 186-192):

```markdown
| `WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD` | `95` | Coverage % above which a non-ancestor branch is treated as content-merged (batch archive) |
```

And in Step 5, where content-merged branches are routed to archive, name the strict path explicitly so a dirty content-merged worktree is refused rather than WIP-committed:

```markdown
Group every content-merged branch into one archive-and-delete confirmation using
`archive-branch.sh --strict <repo> <branch>...` (NOT the generic archive path):
strict mode refuses a dirty worktree instead of committing WIP, and tags atomically.
If strict refuses a branch (dirty worktree), resolve that branch by hand — do not
fall back to the generic WIP-committing archive path for it.
```

- [ ] **Step 3: Open follow-up PRs for the cross-repo consumers**

Every consumer lives in its own private submodule repo, so each gets its own worktree, branch, and PR. **Sequencing: do these only after Tasks 3-7 land** — `coverage_score`'s contract is not proven until Task 3 wires up the first real caller, and locking four external consumers to an unproven contract means redoing them.

**The sharing contract (decided 2026-08-11).** Consumers do not vendor a copy of the logic — that is how four implementations happened in the first place. They source this repo's `lib.sh` through an env-overridable path and **degrade to their current behavior when it is absent**, so no consumer hard-depends on this skill being installed:

```bash
AUDIT_LIB="${AUDIT_WORKTREES_LIB:-$HOME/.claude/skills/auditing-worktrees/bin/lib.sh}"
[ -r "$AUDIT_LIB" ] && . "$AUDIT_LIB"
```

The `$HOME`-relative default matches the precedent already in `orient-quick/SKILL.md` (`AUDIT_BIN="$HOME/.claude/skills/auditing-worktrees/bin"`). The `AUDIT_WORKTREES_LIB` override satisfies the env-var-override convention and lets a test point at a worktree copy.

Missing-lib degradation is **required, not optional**: guard every call with `declare -F coverage_score >/dev/null` and fall through to today's ancestry/tree-match result when it is not defined. A consumer that errors or reports a branch UNKNOWN because an unrelated skill is not installed is a regression.

- [ ] **Step 3a: Add a CLI entry point for non-Bash consumers**

`todos.py` is Python and cannot source a Bash function. Add a thin executable in this repo — `bin/coverage-score <repo> <base> <branch>` — that sources `lib.sh`, calls `coverage_score`, prints the same `SCORED <n>` / `UNSCORED <why>` / `UNKNOWN <why>` line on stdout, and exits non-zero only on usage error (an `UNKNOWN` verdict is a successful run, not a failure — per fail-fast, the verdict is the output, not the exit code). Follow the AXI conventions in `building-agent-clis`. This is the only new production code in Task 8 and it belongs to **this** repo's PR, not a consumer's.

- [ ] **Step 3b: `orient/bin/scan-active.sh`** — adopt content-aware detection

Add a third detection pass after the existing ancestry and tree-match passes (which stay first: both are cheaper and exact). Only branches still unmerged after those two reach `coverage_score`:

```bash
[ -n "${_merged[$_b]-}" ] && continue
if declare -F coverage_score >/dev/null; then
  case "$(coverage_score "$repo" "$base_branch" "$_b")" in
    "SCORED 100"|"SCORED 9"[0-9]) _merged["$_b"]="content-merged" ;;
  esac
fi
```

Match the threshold to `WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD` rather than hardcoding 95 in a second place. Run the transitive-closure pass *after* this one so a branch whose descendant is content-merged is also caught. This single change fixes `orient` and `jeeves`' git-state card together, since jeeves consumes this script's output.

Report a content-merged branch under a distinct label, not as plain `merged` — `orient`'s own SKILL.md tells the reader `potentially outstanding` means "investigate," and collapsing a scored guess into the same word as an exact tree match hides the difference in confidence.

- [ ] **Step 3c: `jeeves/bin/todos.py`** — try offline before the network

In `_landed`, insert a `bin/coverage-score` subprocess call between the ancestry check and the GitHub fallback. Ordering matters: ancestry (free, exact) → coverage (local, cheap) → GitHub (network, slow, needs auth). Keep the GitHub path as the final fallback for genuinely unscored/unknown verdicts. Treat `UNSCORED`/`UNKNOWN` as "keep asking," never as `OUTSTANDING`. This also repairs the no-GitHub-remote case that currently returns `UNKNOWN`.

- [ ] **Step 3d: prose consumers** — name the new bucket

Add `likely-content-merged` to:
- `skills/orient-quick/SKILL.md` — the safe-to-clean / needs-triage / hands-off / archaeology mapping and its "what to do" instructions.
- `skills/finishing-a-development-branch-addendum/SKILL.md` — the cleanup-flow handoff.

routing content-merged → archive with explicit precedence (content-merged → archive, never clean-safe).

- [ ] **Step 3e: confirm `clean-safe.sh` was left alone**

`rg -n 'coverage_score' bin/clean-safe.sh` must return nothing. The deletion path stays literal-ancestry only; Task 5's guard test covers this, and this step is the reminder that "adopt everywhere" explicitly excludes it.

- [ ] **Step 4: Commit this repo's doc changes**

```bash
git add docs/design.md SKILL.md
git commit -m "docs: align config table and downstream notes with content-aware detection"
```

---
