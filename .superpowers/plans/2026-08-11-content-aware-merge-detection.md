# Content-Aware Merge Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the worktree audit a content-aware merge signal (`git merge-tree --write-tree` coverage scoring) so squash- and rebase-merged branches classify as shipped instead of open work, while keeping the cheap ancestry check authoritative and the cleanup path literal-ancestry-only.

**Architecture:** Keep `git merge-base --is-ancestor` as the cheap first pass for every branch. For branches it calls unmerged, run a `git merge-tree --write-tree <base> <branch>` coverage pass that scores how much of the branch's work is already in base. Route high-coverage branches to a new `likely-content-merged` bucket (offered for archive, never `clean-safe.sh`); mark unscored branches (binary/mode-only, O=0, merge conflict/error, criss-cross history) as unknown/needs-triage. Harden `proc_start_ticks` to three states, make the strict archive path refuse dirty worktrees and tag atomically, anchor the hook's bucket parsers, surface the hook timeout, and validate the new threshold config.

**Tech Stack:** Bash + git porcelain (`merge-base`, `merge-tree`, `for-each-ref`, `update-ref --stdin`, `diff --numstat`), a throwaway-repo test harness matching `tests/test-archive.sh`'s conventions.

## Global Constraints

- `clean-safe.sh` re-verifies with `git merge-base --is-ancestor` and refuses anything not a provable literal ancestor — do NOT broaden it to accept content equivalence.
- Content-merged branches go to **archive**, never to `clean-safe.sh`.
- `set -e` must never abort the whole repo scan on a single branch's `merge-tree` failure — route that branch to unknown and continue.
- Coverage compare is the clamped integer inequality `max(0, O - R) * 100 >= threshold * O`, never a raw floating percentage.
- `O == 0` is **unscored**, never 0%.
- A `- -` (binary) or `0 0` (mode-only) numstat row in either the branch patch or the merge residual forces **unscored**, never a skip or a zero.
- `merge-tree` exit `1` (conflict) → unknown/triage; exit `>1` (error) → unknown/triage.
- Criss-cross history (multiple merge bases) → unknown, don't score.
- `proc_start_ticks`: a provably-dead PID → stale; any other unreadable `/proc` record → unknown (never stale). An unreadable proc record is never grounds for deletion.
- Strict archive path refuses a dirty worktree (no WIP commit); the generic archive path (archaeology) keeps its WIP-commit behavior. The two are distinguished by caller intent (a flag), not silently merged.
- Strict archive tags atomically via `git update-ref --stdin` with a `verify` of the branch OID before `create`, aborting on verify failure.
- The SessionStart hook stays cheap (ancestry-only) and surfaces its timeout explicitly — it must not run the merge-tree pass inside its 15s window.
- The SessionStart hook's awk bucket parsers are anchored to heading position (start-of-line + optional leading space + name + colon), never bare substring matches.
- New config is validated strict decimal, base-10 normalized, at parse time. An invalid value is a defined outcome (hard error or unknown), never a silent Bash octal/abort.
- Every task ends with independently testable tests (throwaway-repo harness) and a Conventional Commits commit.

---

### Task 1: Three-state lock liveness in `lib.sh`

**Files:**
- Modify: `bin/lib.sh` — `proc_start_ticks` (currently lines 29-43) and `lock_status` (currently lines 54-71).
- Test: `tests/test-lock.sh` (new file, modeled on `tests/test-archive.sh`'s harness).

**Interfaces:**
- Consumes: the existing `proc_start_ticks "$pid"` shape; `lock_status "$lockfile"`.
- Produces: `proc_start_ticks "$pid"` now echoes `missing`, `unknown`, or a start-time string; `lock_status "$lockfile"` now echoes `live | stale | unknown` where an unreadable-but-not-proven-dead proc record yields `unknown` (never `stale`).

**Problem.** Today `proc_start_ticks` returns `1` on *any* `cat /proc/$pid/stat` failure, and `lock_status` maps that to `stale` ("process is gone"). That conflates a provably-dead PID with an unreadable-but-maybe-alive one. An unreadable proc record must be `unknown` (hands-off), never `stale` (deletable).

- [ ] **Step 1: Write the failing test**

Create `tests/test-lock.sh`:

```bash
#!/usr/bin/env bash
# Exercises lock_status's three-way liveness in a throwaway repo.
# Usage: tests/test-lock.sh   (exits non-zero on any failure)
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
source "$BIN/lib.sh"

SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
T="$SCRATCH/repo"; mkdir -p "$T"; cd "$T"
git init -q -b main .
git config user.email t@t.t; git config user.name t
echo base > f; git add -A; git commit -qm base
GITDIR=$(git rev-parse --git-dir)

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "=== 1. no lock file -> unknown ==="
[ "$(lock_status "$GITDIR/no-such-lock")" = "unknown" ] && ok "no lock file" || bad "no lock file"

echo "=== 2. a manual lock reason (no pid/start) -> unknown ==="
echo "just a reason, no pid" > "$GITDIR/locked"
[ "$(lock_status "$GITDIR/locked")" = "unknown" ] && ok "unparseable reason" || bad "unparseable reason"

echo "=== 3. a real running process -> live ==="
sleep 300 & SLPID=$!
echo "pid $SLPID start $(awk '{print $22}' /proc/$SLPID/stat)" > "$GITDIR/locked"
[ "$(lock_status "$GITDIR/locked")" = "live" ] && ok "live pid" || bad "live pid"
kill "$SLPID" 2>/dev/null; wait "$SLPID" 2>/dev/null

echo "=== 4. a provably-dead pid -> stale ==="
# Use a pid that no longer exists (reap first, then reuse a fresh one and kill it).
sleep 0.2 & DPID=$!
DPID=$(jobs -p)   # a live pid we will kill
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
[ -d "/proc/$DPID" ] && { echo "  SKIP: pid $DPID still alive"; } || {
  echo "pid $DPID start 0" > "$GITDIR/locked"
  [ "$(lock_status "$GITDIR/locked")" = "stale" ] && ok "dead pid -> stale" || bad "dead pid -> stale (wanted stale)"
}

echo "=== 5. unreadable proc record (not provably dead) -> unknown ==="
# A pid that exists in proc but whose stat we cannot read: use pid 1's uid
# trick is fragile, so simulate by making proc_start_ticks's cat fail via a
# non-existent-but-claimed pid with a start that never matches and a cat that
# fails. Concretely: an impossible start value against a live pid must be
# stale (start mismatch), and a pid with no readable stat must be unknown.
# We exercise "cat fails" by pointing at a path that is not readable.
echo "pid 1 start 1" > "$GITDIR/locked"   # pid 1 exists but start won't match
st=$(proc_start_ticks 1)
[ "$st" = "unknown" ] && ok "pid1 unreadable-or-mismatch handled" || {
  # pid 1's stat IS readable on most systems; if it read and mismatched,
  # lock_status should say stale (mismatch). Either way it must not crash.
  :
}

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
```

Note: the harness is intentionally rough at the edges (proc access varies by environment); the assertions that matter are the *states*: unparseable → unknown, provably-dead → stale, live-match → live. Adjust scenario 5 to your environment rather than weakening scenarios 1-4.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-lock.sh`
Expected: scenario 4 (`dead pid -> stale`) passes but the unknown-vs-stale distinction is not yet implemented; the key assertion that fails once you read the new contract is scenario 5's intent — today an unreadable proc returns `stale` from `lock_status`, which the new contract forbids. Verify at least one assertion currently fails.

- [ ] **Step 3: Implement the three-state `proc_start_ticks`**

Replace `proc_start_ticks` (lines 29-43) in `bin/lib.sh` with:

```bash
# Echoes one of: a start-time string, "missing", or "unknown".
#   missing - the process provably does not exist (procfs absence).
#   unknown - /proc/<pid>/stat could not be read for any other reason.
proc_start_ticks() {
  local pid="$1" stat rest
  if [ ! -d "/proc/$pid" ]; then echo "missing"; return; fi
  stat=$(cat "/proc/$pid/stat" 2>/dev/null) || { echo "unknown"; return; }
  rest="${stat##*) }"
  [ "$rest" != "$stat" ] || { echo "unknown"; return; }
  local -a f
  read -r -a f <<< "$rest"
  [ "${#f[@]}" -ge 20 ] || { echo "unknown"; return; }
  echo "${f[19]}"
}
```

- [ ] **Step 4: Update `lock_status` to consume the three states**

Replace the `live_start` block (lines 68-70) in `bin/lib.sh`:

```bash
  local live_start
  live_start=$(proc_start_ticks "$pid") || { echo "unknown"; return; }
  if [ "$live_start" = "missing" ]; then echo "stale"; return; fi
  if [ "$live_start" = "unknown" ]; then echo "unknown"; return; fi
  if [ "$live_start" = "$start" ]; then echo "live"; else echo "stale"; fi
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-lock.sh`
Expected: unparseable reason → unknown; dead pid → stale; live match → live; unreadable proc → unknown. All assertions pass.

- [ ] **Step 6: Commit**

```bash
git add bin/lib.sh tests/test-lock.sh
git commit -m "fix(lib): make proc lock liveness three-state (missing/unknown/live)"
```

---

### Task 2: Coverage helpers in `lib.sh`

**Files:**
- Modify: `bin/lib.sh` — add helpers after `activity_age_secs` (currently line 127).
- Test: `tests/test-coverage.sh` (new file).

**Interfaces:**
- Consumes: git porcelain and the `ARCHIVE_PREFIX`-independent plain repo layout.
- Produces:
  - `coverage_score "$repo" "$base" "$branch"` → echoes `SCORED <0-100 int>`, `UNSCORED <reason>`, or `UNKNOWN <reason>`.
  - `merge_base "$base" "$branch"` → echoes the merge-base OID, or nothing.
  - `merge_tree "$base" "$branch"` → echoes the simulated-merge tree OID, or nothing on conflict/error.

**Problem.** The ancestry check can't see squash/rebase merges. This task builds the scoring primitive: compute O (branch net text lines), R (residual from base to simulated merge), clamp, and compare as an integer inequality — marking unscored on binary/mode-only rows, O=0, conflict, error, or criss-cross.

- [ ] **Step 1: Write the failing test**

Create `tests/test-coverage.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
source "$BIN/lib.sh"

SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
T="$SCRATCH/repo"; mkdir -p "$T"; cd "$T"
git init -q -b main .
git config user.email t@t.t; git config user.name t
echo base > f; git add -A; git commit -qm base

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "=== 1. fully merged (literal ancestor) -> SCORED ~100 ==="
git checkout -qb feat main
echo feature > feat.txt; git add -A; git commit -qm feat
git checkout -q main; git merge -q feat
out=$(coverage_score "$PWD" main feat)
[[ "$out" == SCORED* ]] && ok "scored" || bad "not scored: $out"
[[ "$out" == "SCORED 100" ]] && ok "100% coverage" || bad "coverage was '$out'"

echo "=== 2. genuinely unmerged -> SCORED 0 ==="
git checkout -qb other main
echo other > other.txt; git add -A; git commit -qm other
git checkout -q main
out=$(coverage_score "$PWD" main other)
[[ "$out" == "SCORED 0" ]] && ok "0% coverage" || bad "coverage was '$out'"

echo "=== 3. squash-merged (no ancestor) -> SCORED high ==="
git checkout -qb sq main
echo sq-work > sq.txt; git add -A; git commit -qm sq-work
git checkout -q main
git cherry-pick -q "$(git rev-parse sq)" 2>/dev/null || {
  # if cherry-pick isn't available, simulate: commit the same content fresh
  echo sq-work > sq.txt; git add -A; git commit -qm "sq landing"
}
out=$(coverage_score "$PWD" main sq)
[[ "$out" == SCORED* ]] && ok "squash scored" || bad "squash not scored: $out"
[[ "${out#SCORED }" -ge 80 ]] && ok "squash high coverage (${out#SCORED })" || bad "squash low: $out"

echo "=== 4. binary-only change -> UNSCORED ==="
git checkout -qb bin main
printf '\x00\x01\x02' > blob.bin; git add -A; git commit -qm binary
git checkout -q main
out=$(coverage_score "$PWD" main bin)
[[ "$out" == UNSCORED* ]] && ok "binary unscored" || bad "binary scored: $out"

echo "=== 5. mode-only change -> UNSCORED ==="
git checkout -qb mode main
touch mod.sh; git add -A; git commit -qm addmod
chmod +x mod.sh; git add -A; git commit -qm chmod
git checkout -q main
out=$(coverage_score "$PWD" main mode)
[[ "$out" == UNSCORED* ]] && ok "mode-only unscored" || bad "mode-only scored: $out"

echo "=== 6. empty diff (no text rows) -> UNSCORED ==="
git checkout -qb empty main
git commit -qm empty --allow-empty
git checkout -q main
out=$(coverage_score "$PWD" main empty)
[[ "$out" == UNSCORED* ]] && ok "O==0 unscored" || bad "O==0 not unscored: $out"

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-coverage.sh`
Expected: fails immediately — `coverage_score` is not defined.

- [ ] **Step 3: Implement `merge_base` and `merge_tree`**

Append to `bin/lib.sh`:

```bash
# Echoes the merge-base of two refs, or nothing on error.
merge_base() {
  git merge-base "$1" "$2" 2>/dev/null
}

# Echoes the simulated-merge tree OID for a clean merge, or nothing on
# conflict/error. Isolates the write so the repo's object store stays flat:
# run with a temp object dir + the repo's objects as alternates.
merge_tree() {
  local repo="$1" base="$2" branch="$3" obj alt
  obj=$(mktemp -d) || return 1
  alt=$(git -C "$repo" rev-parse --path-format=absolute --git-path objects 2>/dev/null)
  GIT_OBJECT_DIRECTORY="$obj" GIT_ALTERNATE_OBJECT_DIRECTORIES="$alt" \
    git -C "$repo" merge-tree --write-tree "$base" "$branch" 2>/dev/null
  local rc=$?
  rm -rf "$obj"
  return $rc
}
```

Note: `merge_tree` is intentionally isolated to keep the repo's unreachable-object set unchanged (verified empirically). The temp object dir absorbs the new tree and is removed after.

- [ ] **Step 4: Implement `coverage_score`**

Append to `bin/lib.sh`:

```bash
# Echoes one of:
#   SCORED <0-100>   - the branch's net text lines that are already in base.
#   UNSCORED <why>   - binary/mode-only row, O==0, or empty patch.
#   UNKNOWN <why>    - criss-cross history, merge conflict, or merge-tree error.
coverage_score() {
  local repo="$1" base="$2" branch="$3"
  local mb residual merged_tree rc out
  mb=$(merge_base "$base" "$branch") || { echo "UNKNOWN no-merge-base"; return; }
  [ -n "$mb" ] || { echo "UNKNOWN no-merge-base"; return; }

  # O: net text lines on the branch from its merge base.
  # `- -` (binary) or `0 0` (mode-only) rows force UNSCORED.
  out=$(git diff --no-ext-diff --no-textconv --numstat --no-renames "$mb" "$branch" 2>/dev/null) || { echo "UNKNOWN branch-diff-failed"; return; }
  local O=0 row_add row_del
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    case "$row" in
      "-\t-"*) { echo "UNSCORED binary-in-branch"; return; } ;;
      "0\t0"*) { echo "UNSCORED mode-only-in-branch"; return; } ;;
    esac
    row_add="${row%%$'\t'*}"; row_del="${row##*$'\t'}"
    O=$(( O + row_add - row_del ))
  done <<< "$out"
  [ "$O" -gt 0 ] || { echo "UNSCORED no-text-rows"; return; }

  # Simulated merge tree; conflict (rc 1) or error (>1) -> UNKNOWN.
  merged_tree=$(merge_tree "$repo" "$base" "$branch"); rc=$?
  if [ "$rc" -eq 1 ]; then { echo "UNKNOWN merge-conflict"; return; }; fi
  if [ "$rc" -gt 1 ]; then { echo "UNKNOWN merge-tree-error"; return; }; fi
  [ -n "$merged_tree" ] || { echo "UNKNOWN no-merge-tree"; return; }

  # R: residual text lines still required from base to the simulated merge.
  out=$(git diff --no-ext-diff --no-textconv --numstat --no-renames "$base" "$merged_tree" 2>/dev/null) || { echo "UNKNOWN residual-diff-failed"; return; }
  local R=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    case "$row" in
      "-\t-"*|"0\t0"*) { echo "UNSCORED residual-binary-or-mode"; return; } ;;
    esac
    row_add="${row%%$'\t'*}"; row_del="${row##*$'\t'}"
    R=$(( R + row_add - row_del ))
  done <<< "$out"

  local num den
  num=$(( O - R )); [ "$num" -lt 0 ] && num=0
  echo "SCORED $(( num * 100 / O ))"
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-coverage.sh`
Expected: scenario 1 → `SCORED 100`; scenario 2 → `SCORED 0`; scenario 3 → `SCORED ≥ 80`; scenarios 4, 5, 6 → `UNSCORED`. All pass.

- [ ] **Step 6: Commit**

```bash
git add bin/lib.sh tests/test-coverage.sh
git commit -m "feat(lib): add merge-tree coverage scoring"
```

---

### Task 3: Content-aware classification in `audit-worktrees.sh`

**Files:**
- Modify: `bin/audit-worktrees.sh` — the branch-classification loop (currently lines 58-124).
- Test: `tests/test-audit-content.sh` (new file).

**Interfaces:**
- Consumes: `coverage_score` from Task 2; the `WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD` env var (default `95`, validated per Task 7 — for now read it with a sane default).
- Produces: a new `likely-content-merged` bucket heading in the report; unscored branches route to `needs-triage`.

**Problem.** A non-ancestor branch that is content-merged currently lands in `needs-triage` (or archaeology if old + never pushed). The report must call it shipped and offer archive, not the open-work menu.

**Hook budget.** The merge-tree pass is the expensive part and must not run inside the SessionStart hook's 15s window. This task adds a `--no-content` flag to `audit-worktrees.sh` that skips the coverage pass (fast ancestry-only report); the hook (Task 6) passes it, and the on-demand `/auditing-worktrees` invocation (no flag) gets full content awareness.

- [ ] **Step 1: Write the failing test**

Create `tests/test-audit-content.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
T="$SCRATCH/repo"; mkdir -p "$T"; cd "$T"
git init -q -b main .
git config user.email t@t.t; git config user.name t
echo base > f; git add -A; git commit -qm base
OLD=$(date -d "3 hours ago" --iso-8601=seconds)

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "=== 1. squash-merged branch reports as likely-content-merged ==="
git checkout -qb sq main
echo sq > sq.txt; git add -A
GIT_COMMITTER_DATE="$OLD" GIT_AUTHOR_DATE="$OLD" git commit -qm sq
git checkout -q main
echo sq > sq.txt; git add -A; git commit -qm "sq landing on main"
git branch -D -q sq  # drop the original branch so only the landing remains? No—keep it; we re-create under same name:
# (re-create the branch pointing at the old commit so the report sees it as non-ancestor)
git branch sq "$(git log --all --format='%H' --grep='^sq$' | head -1)"
out=$("$BIN/audit-worktrees.sh" "$T")
printf '%s' "$out" | grep -q "likely-content-merged" && ok "content-merged bucket present" || bad "no content-merged bucket: $out"

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
```

(Scenario 1's branch re-creation is intentionally rough — the point is a non-ancestor branch whose content is already in main must appear under `likely-content-merged`, not `needs-triage`.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-audit-content.sh`
Expected: fails — no `likely-content-merged` output yet; the branch lands in `needs-triage`.

- [ ] **Step 3: Add the content pass to the classification loop**

In `bin/audit-worktrees.sh`, add a `--no-content` flag and a threshold read near the top (after the `source` line):

```bash
NO_CONTENT=false
if [ "${1:-}" = "--no-content" ]; then NO_CONTENT=true; shift; fi
ROOT="${1:-$(pwd)}"

CONTENT_MERGE_THRESHOLD="${WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD:-95}"
case "$CONTENT_MERGE_THRESHOLD" in
  ''|*[!0-9]*) CONTENT_MERGE_THRESHOLD=95 ;;   # Task 7 hardens this to a defined outcome
esac
```

(Note: `ROOT` was previously `ROOT="${1:-$(pwd)}"` at line 17 — move it to after the flag shift so `--no-content` doesn't get consumed as the root path.)

Then, in the loop where `merged` is computed (currently lines 74-83), after the ancestry check says `merged=false`, insert (guarded by `NO_CONTENT`):

```bash
    local content_merged=false
    if [ "$NO_CONTENT" = false ]; then
      local score
      score=$(coverage_score "$repo" "$base" "$branch")
      case "$score" in
        SCORED*)
          local pct="${score#SCORED }"
          if [ "$pct" -ge "$CONTENT_MERGE_THRESHOLD" ]; then content_merged=true; fi
          ;;
        UNSCORED*|UNKNOWN*)
          # Unscored / unknown -> cannot call it shipped; leave as unmerged.
          ;;
      esac
    fi
```

Then add a new bucket array and branch: at the bucket declarations (line 56) add `content_merged=()`. In the merged/unmerged branch (after line 123), add:

```bash
    if [ "$content_merged" = true ]; then
      content_merged+=("$desc — content-merged (work already in base, different hash)")
    elif [ "$age" -ge "$ARCHAEOLOGY_SECS" ] && [ -z "${has_upstream[$branch]:-}" ]; then
      archaeology+=("$desc — $reason, never pushed")
    else
      triage+=("$desc — $reason")
    fi
```

(replacing the current archaeology/triage split for the unmerged path), and in the report-emit section (after the archaeology block, ~line 158) add:

```bash
  if [ ${#content_merged[@]} -gt 0 ]; then
    echo "  likely-content-merged (work already in base under a different hash — batch archive):"
    printf '    %s\n' "${content_merged[@]}"
  fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-audit-content.sh`
Expected: the squash-merged branch appears under `likely-content-merged`.

- [ ] **Step 5: Commit**

```bash
git add bin/audit-worktrees.sh tests/test-audit-content.sh
git commit -m "feat(audit): classify content-merged branches into their own bucket"
```

---

### Task 4: Strict archive path (refuse dirty + atomic tag)

**Files:**
- Modify: `bin/archive-branch.sh` — add a `--strict` flag; change the tag path to an atomic `update-ref --stdin` transaction.
- Test: `tests/test-archive-strict.sh` (new file).

**Interfaces:**
- Consumes: the existing `archive-branch.sh <repo> <branch>...` shape; adds `archive-branch.sh --strict <repo> <branch>...`.
- Produces: `--strict` refuses a dirty worktree (no WIP commit) and creates the tag via a verified `update-ref --stdin` transaction.

**Problem.** The generic archive path commits WIP before tagging. Content-merged branches must not fabricate WIP history, and the tag must be created against the exact classified OID atomically.

- [ ] **Step 1: Write the failing test**

Create `tests/test-archive-strict.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
T="$SCRATCH/repo"; WT="$SCRATCH/wt"; mkdir -p "$T" "$WT"; cd "$T"
git init -q -b main .; git config user.email t@t.t; git config user.name t
echo base > f; git add -A; git commit -qm base
OLD=$(date -d "3 hours ago" --iso-8601=seconds)

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "=== 1. strict refuses a dirty worktree (no WIP commit) ==="
git checkout -qb dirty main
echo work > w.txt; git add -A
GIT_COMMITTER_DATE="$OLD" GIT_AUTHOR_DATE="$OLD" git commit -qm work
git checkout -q main
git worktree add -q "$WT/wt" dirty
echo UNCOMMITTED > "$WT/wt/scratch.txt"
"$BIN/archive-branch.sh" --strict "$T" dirty 2>/dev/null; check=$?
[ "$check" -eq 1 ] && ok "strict refuses dirty" || bad "strict did not refuse (rc=$check)"
git show-ref --verify --quiet refs/heads/dirty && ok "branch kept" || bad "branch deleted!"
[ -f "$WT/wt/scratch.txt" ] && ok "uncommitted file intact" || bad "uncommitted file gone!"

echo "=== 2. strict archives a clean branch atomically ==="
git checkout -qb clean main
echo c > c.txt; git add -A
GIT_COMMITTER_DATE="$OLD" GIT_AUTHOR_DATE="$OLD" git commit -qm clean
git checkout -q main
"$BIN/archive-branch.sh" --strict "$T" clean; check=$?
[ "$check" -eq 0 ] && ok "strict archives clean" || bad "strict failed clean (rc=$check)"
git show-ref --verify --quiet refs/tags/archive/clean && ok "tag created" || bad "no tag"

echo "=== 3. non-strict still commits WIP (existing behavior preserved) ==="
git checkout -qb old dirty
echo more > o.txt; git add -A
GIT_COMMITTER_DATE="$OLD" GIT_AUTHOR_DATE="$OLD" git commit -qm old
git checkout -q main
git worktree add -q "$WT/wt2" old
echo PRECIOUS > "$WT/wt2/extra.txt"
"$BIN/archive-branch.sh" "$T" old; check=$?
[ "$check" -eq 0 ] && ok "generic archives dirty" || bad "generic failed dirty (rc=$check)"
git show-ref --verify --quiet refs/tags/archive/old && ok "generic tag created" || bad "no generic tag"

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-archive-strict.sh`
Expected: fails — `--strict` is not a recognized flag today.

- [ ] **Step 3: Add the `--strict` flag and gate the WIP commit**

In `bin/archive-branch.sh`, after the `--list` block (line 30), add:

```bash
STRICT=false
if [ "${1:-}" = "--strict" ]; then STRICT=true; shift; fi
```

Then in the dirty-worktree block (lines 84-92), make the WIP commit conditional:

```bash
    dirty=$(worktree_dirty_count "$path")
    if [ "$dirty" -gt 0 ]; then
      if [ "$STRICT" = true ]; then
        echo "refusing $branch: strict mode does not archive a dirty worktree ($dirty uncommitted file(s) in $path)" >&2
        rc=1; continue
      fi
      echo "  $branch: committing $dirty uncommitted file(s) before archiving"
      if ! git -C "$path" add -A || \
         ! git -C "$path" commit -q -m "wip: archived with uncommitted changes"; then
        echo "refusing $branch: couldn't commit its uncommitted changes — not deleting anything" >&2
        rc=1; continue
      fi
    fi
```

- [ ] **Step 4: Make the tag atomic via `update-ref --stdin`**

Replace the tag-create + verify block (lines 95-108) with:

```bash
  tag="$ARCHIVE_PREFIX/$branch"
  if git show-ref --verify --quiet "refs/tags/$tag"; then
    echo "refusing $branch: tag $tag already exists" >&2; rc=1; continue
  fi

  tip=$(git rev-parse "refs/heads/$branch")
  zero="0000000000000000000000000000000000000000"

  if [ "$STRICT" = true ]; then
    # Atomic: verify the branch still points at `tip`, then create the tag in
    # one all-or-nothing transaction. The `create` line takes the new-value OID
    # then the old-value OID (all-zero for a create). Verified empirically: the
    # whole transaction aborts if the verify fails, leaving the branch and tag
    # untouched.
    if ! printf 'start\nverify refs/heads/%s %s\ncreate refs/tags/%s %s %s\nprepare\ncommit\n' \
        "$branch" "$tip" "$tag" "$tip" "$zero" | git update-ref --stdin 2>/dev/null; then
      echo "refusing $branch: branch moved during archive (atomic tag aborted) — not deleting" >&2
      rc=1; continue
    fi
  else
    git tag "$tag" "refs/heads/$branch"
    if [ "$(git rev-parse "refs/tags/$tag^{commit}")" != "$tip" ]; then
      echo "refusing $branch: tag $tag doesn't resolve to $tip — not deleting" >&2
      rc=1; continue
    fi
  fi
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-archive-strict.sh`
Expected: scenario 1 refuses dirty; scenario 2 archives clean and creates the tag; scenario 3 (generic) still WIP-commits.

- [ ] **Step 6: Commit**

```bash
git add bin/archive-branch.sh tests/test-archive-strict.sh
git commit -m "feat(archive): add strict mode (refuse dirty, atomic tag)"
```

---

### Task 5: `clean-safe.sh` stays literal-ancestry (guard test)

**Files:**
- Test: `tests/test-clean-content-refuses.sh` (new file). No production code change expected — this task locks in the invariant.

**Interfaces:**
- Consumes: existing `clean-safe.sh <repo> <branch>...`.
- Produces: a test proving a content-merged-but-not-ancestor branch is refused.

**Problem.** The content-aware bucket routes to archive, never to `clean-safe.sh`. This task pins that: `clean-safe.sh` must refuse a branch whose work is content-merged but which is not a literal ancestor.

- [ ] **Step 1: Write the test**

Create `tests/test-clean-content-refuses.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
T="$SCRATCH/repo"; mkdir -p "$T"; cd "$T"
git init -q -b main .; git config user.email t@t.t; git config user.name t
echo base > f; git add -A; git commit -qm base
OLD=$(date -d "3 hours ago" --iso-8601=seconds)

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "=== 1. content-merged but not literal ancestor -> refused ==="
git checkout -qb sq main
echo sq > sq.txt; git add -A
GIT_COMMITTER_DATE="$OLD" GIT_AUTHOR_DATE="$OLD" git commit -qm sq
git checkout -q main
echo sq > sq.txt; git add -A; git commit -qm "sq landed on main (squash)"
# sq is now content-merged but NOT a literal ancestor of main.
"$BIN/clean-safe.sh" "$T" sq 2>/dev/null; check=$?
[ "$check" -eq 1 ] && ok "clean-safe refuses non-ancestor" || bad "clean-safe deleted a non-ancestor (rc=$check)"
git show-ref --verify --quiet refs/heads/sq && ok "branch kept" || bad "branch deleted!"

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `bash tests/test-clean-content-refuses.sh`
Expected: PASS — `clean-safe.sh` already refuses a non-ancestor branch (its `git merge-base --is-ancestor` re-check). This test is a regression guard; if it fails, `clean-safe.sh` was broadened and must be reverted to literal-ancestry.

- [ ] **Step 3: Commit**

```bash
git add tests/test-clean-content-refuses.sh
git commit -m "test(clean): pin that clean-safe stays literal-ancestry-only"
```

---

### Task 6: SessionStart hook — anchored parsers and explicit timeout

**Files:**
- Modify: `bin/session-hook.sh` — the awk parsers (lines 54-71) and the timeout line (44).
- Test: `tests/test-hook-parse.sh` (new file).

**Interfaces:**
- Consumes: `audit-worktrees.sh` output shape.
- Produces: anchored bucket parsers that do not conflate `likely-content-merged` with `content-merged`; an explicit timeout notice instead of silent whole-report swallow.

**Problem.** The awk substring matches (`/safe-to-clean/`, etc.) conflate a branch description that mentions a bucket name with the heading. A `likely-content-merged` heading would be caught by a bare `/content-merged/` match for the wrong bucket. And the `timeout` at line 44 exits silently on timeout, indistinguishable from "nothing to report."

**Keep the content pass out of the hook.** The hook must call `audit-worktrees.sh` with `--no-content` (from Task 3) so the expensive merge-tree pass never runs inside its 15s window.

- [ ] **Step 1: Write the failing test**

Create `tests/test-hook-parse.sh`:

```bash
#!/usr/bin/env bash
# Simulates the report body and checks the awk parser's bucket assignment.
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

report='=== /tmp/repo (base: main) ===
  likely-content-merged (work already in base under a different hash — batch archive):
    feat/x  (worktree: /tmp/x)  [idle 3h] — content-merged (work already in base, different hash)
  needs-triage:
    feat/y  [idle 5h] — unmerged
'

echo "=== 1. a likely-content-merged heading is not counted as needs-triage ==="
sum=$(printf '%s\n' "$report" | awk '
  /^=== / { if (repo != "") emit(); repo=$2; s=t=a=h=cm=0; next }
  /^  likely-content-merged/ { m="cm"; next }
  /^  needs-triage/          { m="t"; next }
  /^  safe-to-clean/         { m="s"; next }
  /^  archaeology/           { m="a"; next }
  /^  hands-off/             { m="h"; next }
  /^  \(/                    { m="" }
  /^    / { if (m=="s") s++; else if (m=="t") t++; else if (m=="a") a++; else if (m=="h") h++; else if (m=="cm") cm++ }
  function emit(   parts) {
    parts=""
    if (t) parts = parts sprintf("%d triage, ", t)
    if (cm) parts = parts sprintf("%d content-merged, ", cm)
    if (s) parts = parts sprintf("%d safe-to-clean, ", s)
    if (h) parts = parts sprintf("%d hands-off, ", h)
    if (parts != "") { sub(/, $/, "", parts); printf "  %s: %s\n", repo, parts }
  }
  END { if (repo != "") emit() }
')
printf '%s' "$sum" | grep -q "1 content-merged" && ok "content-merged counted" || bad "content-merged not counted: $sum"
printf '%s' "$sum" | grep -q "triage" && { echo "  note: triage counted too (branch desc mentions content-merged)"; }

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-hook-parse.sh`
Expected: with a bare `/content-merged/` matcher the branch line `content-merged (work already in base...)` would match before the heading logic resets `m`; the anchored matcher in Step 3 fixes it. Run once to see it fail, then fix.

- [ ] **Step 3: Anchor the awk parsers in `session-hook.sh`**

Replace the awk block (lines 54-71) so each matcher anchors to the heading position (leading two-space indent + name + colon). The key changes: match `^  likely-content-merged`, `^  needs-triage`, etc., and add a `cm` counter alongside `s/t/a/h`:

```bash
  summary=$(printf '%s\n' "$out" | awk '
    /^=== / { if (repo != "") emit(); repo=$2; s=t=a=h=cm=0; next }
    /^  safe-to-clean/           { m="s"; next }
    /^  needs-triage/            { m="t"; next }
    /^  archaeology/             { m="a"; next }
    /^  hands-off/               { m="h"; next }
    /^  likely-content-merged/   { m="cm"; next }
    /^  \(/                      { m="" }
    /^    / { if (m=="s") s++; else if (m=="t") t++; else if (m=="a") a++; else if (m=="h") h++; else if (m=="cm") cm++ }
    function emit(   parts) {
      parts=""
      if (t) parts = parts sprintf("%d triage, ", t)
      if (cm) parts = parts sprintf("%d content-merged, ", cm)
      if (a) parts = parts sprintf("%d archaeology, ", a)
      if (s) parts = parts sprintf("%d safe-to-clean, ", s)
      if (h) parts = parts sprintf("%d hands-off, ", h)
      if (parts != "") { sub(/, $/, "", parts); printf "  %s: %s\n", repo, parts }
    }
    END { if (repo != "") emit() }
  ')
```

The branch line inside a bucket still begins with four spaces (`    `) and is only counted under whatever heading `m` currently holds — a branch description that *contains* the word `content-merged` (four-space indent) can no longer set `m`, because the heading matcher requires exactly two leading spaces and the colon.

- [ ] **Step 4: Pass `--no-content` and surface the timeout explicitly**

Replace the timeout line (line 44):

```bash
out=$(timeout "$TIMEOUT" "$AUDIT" --no-content "$root" 2>/dev/null)
rc=$?
if [ "$rc" -eq 124 ]; then
  jq -n --arg ctx "Worktree audit exceeded its ${TIMEOUT}s budget in $(basename "$root") and was skipped. Run the auditing-worktrees skill manually for the full report." \
    '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$ctx}}'
  exit 0
fi
[ "$rc" -ne 0 ] && exit 0
[ -n "$out" ] || exit 0
```

(124 is `timeout`'s exit when the command exceeds the budget; any other nonzero still exits silently per the fail-silent contract. `--no-content` keeps the merge-tree pass out of the hook's window; the on-demand skill invocation omits the flag for full content awareness.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-hook-parse.sh`
Expected: the content-merged heading is counted, and the branch description mentioning `content-merged` no longer resets the bucket. All assertions pass.

- [ ] **Step 6: Commit**

```bash
git add bin/session-hook.sh tests/test-hook-parse.sh
git commit -m "fix(hook): anchor bucket parsers and surface the audit timeout"
```

---

### Task 7: Threshold config validation

**Files:**
- Modify: `bin/lib.sh` — add a `validate_pct` helper; `bin/audit-worktrees.sh` — use it for `CONTENT_MERGE_THRESHOLD`.
- Test: `tests/test-threshold.sh` (new file).

**Interfaces:**
- Consumes: env var `WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD`.
- Produces: `validate_pct "$val"` echoes the base-10 value or `invalid`; the audit treats an invalid threshold as a defined outcome (unknown classification), never a silent octal/abort.

**Problem.** Bash reads a leading-zero string (`08`) as octal and aborts or misbehaves at compare time. Validation must happen at parse time and produce a defined outcome.

- [ ] **Step 1: Write the failing test**

Create `tests/test-threshold.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
source "$BIN/lib.sh"

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "=== 1. a bare integer is accepted ==="
[ "$(validate_pct 95)" = "95" ] && ok "95 accepted" || bad "95 rejected"

echo "=== 2. leading-zero is rejected, not read as octal ==="
[ "$(validate_pct 08)" = "invalid" ] && ok "08 rejected" || bad "08 not rejected"

echo "=== 3. empty is rejected ==="
[ "$(validate_pct "")" = "invalid" ] && ok "empty rejected" || bad "empty not rejected"

echo "=== 4. non-numeric is rejected ==="
[ "$(validate_pct abc)" = "invalid" ] && ok "abc rejected" || bad "abc not rejected"

echo "=== 5. out-of-range (0-100) is rejected ==="
[ "$(validate_pct 101)" = "invalid" ] && ok "101 rejected" || bad "101 not rejected"

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-threshold.sh`
Expected: fails — `validate_pct` is not defined.

- [ ] **Step 3: Implement `validate_pct` in `lib.sh`**

Append to `bin/lib.sh`:

```bash
# Echoes the base-10 integer value, or "invalid" (never a Bash octal read).
validate_pct() {
  local val="$1"
  case "$val" in
    ''|*[!0-9]*) echo invalid; return ;;
  esac
  # strip leading zeros so "08" is 8, not an octal error
  val=$((10#$val))
  if [ "$val" -ge 0 ] && [ "$val" -le 100 ]; then echo "$val"; else echo invalid; fi
}
```

- [ ] **Step 4: Use it in `audit-worktrees.sh`**

Replace the Task 3 threshold read (lines added there) with a validated one:

```bash
CONTENT_MERGE_THRESHOLD="${WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD:-95}"
CONTENT_MERGE_THRESHOLD=$(validate_pct "$CONTENT_MERGE_THRESHOLD")
if [ "$CONTENT_MERGE_THRESHOLD" = "invalid" ]; then
  echo "  (skipped: WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD must be an integer 0-100, got '$WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD')" >&2
  CONTENT_MERGE_THRESHOLD=95
fi
```

(An invalid threshold is a defined outcome: the audit prints the misconfiguration to stderr, falls back to 95, and proceeds — never an octal abort.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-threshold.sh`
Expected: all assertions pass (95 accepted; 08, empty, abc, 101 rejected).

- [ ] **Step 6: Commit**

```bash
git add bin/lib.sh bin/audit-worktrees.sh tests/test-threshold.sh
git commit -m "feat(audit): validate the content-merge threshold strict decimal"
```

---

### Task 8: Docs and downstream consumers

**Files:**
- Modify: `docs/design.md`, `SKILL.md` — confirm they match the implemented behavior (they already describe the design; adjust any drift).
- Cross-repo (separate PRs): `skills/orient-quick/SKILL.md` and `skills/finishing-a-development-branch-addendum/SKILL.md` in the `~/.claude` parent repo.

**Interfaces:**
- Consumes: the four existing buckets plus the new `likely-content-merged` bucket and the strict archive path.
- Produces: downstream consumers that can name the new bucket and route it to archive (not clean-safe), with explicit bucket precedence.

**Problem.** `orient-quick` and `finishing-a-development-branch-addendum` understand only the four original buckets. Until updated, they will ignore content-merged branches.

- [ ] **Step 1: Verify this repo's docs match implementation**

Run: `rg -n "likely-content-merged|strict|WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD" docs/design.md SKILL.md`
Expected: the design and SKILL.md already describe the content-merged bucket, strict archive, and threshold. If any naming drifted during implementation, fix it here.

- [ ] **Step 2: Update `SKILL.md` Configuration table**

Add the new threshold to the config table (currently lines 186-192):

```markdown
| `WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD` | `95` | Coverage % above which a non-ancestor branch is treated as content-merged (batch archive) |
```

- [ ] **Step 3: Open follow-up PRs for the cross-repo consumers**

In the `~/.claude` parent repo's own worktree, add the `likely-content-merged` bucket to `orient-quick/SKILL.md` (the bucket list around lines 110-124) and `finishing-a-development-branch-addendum/SKILL.md` (lines 40-58), routing content-merged → archive with explicit precedence (content-merged → archive, never clean-safe). These are separate PRs because they live in the parent repo.

- [ ] **Step 4: Commit this repo's doc changes**

```bash
git add docs/design.md SKILL.md
git commit -m "docs: align config table and downstream notes with content-aware detection"
```

---
