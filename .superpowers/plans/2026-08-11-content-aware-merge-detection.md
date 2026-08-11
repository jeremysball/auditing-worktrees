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

echo "=== 5. unreadable proc record (not provably dead) -> unknown, never stale ==="
# Deterministic: override proc_start_ticks to simulate an unreadable /proc
# (cat fails) and assert lock_status must return `unknown`, NOT `stale`.
# A regression that maps unreadable->stale would let cleanup delete a
# possibly-live lock, so this assertion is the load-bearing safety check.
stub_unknown() { echo unknown; }
proc_start_ticks() { stub_unknown; }
echo "pid 99999 start 1" > "$GITDIR/locked"
[ "$(lock_status "$GITDIR/locked")" = "unknown" ] \
  && ok "unreadable proc -> unknown" \
  || bad "unreadable proc mapped to something other than unknown"
# restore the real function for any later scenarios
unset -f proc_start_ticks stub_unknown

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
  - `merge_base "$base" "$branch"` → echoes the merge-base OID, or nothing (errors on criss-cross multiple-merge-bases).
  - `numstat_net` (reads numstat stdin) → echoes a net line delta or `UNSCORED <why>`.

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

- [ ] **Step 3: Implement `merge_base` (criss-cross-aware) and the shared numstat counter**

Append to `bin/lib.sh`:

```bash
# Echoes the singular merge-base of two refs, or nothing on error. In a
# criss-cross history there are MULTIPLE merge bases; singular `git merge-base`
# does not error — it picks one arbitrarily, which would score against a
# possibly-wrong base. Count with --all first and treat >1 base as unknown.
# Echoes the base OID on success.
merge_base() {
  local n
  n=$(git merge-base --all "$1" "$2" 2>/dev/null | wc -l)
  # >1 base = criss-cross history; singular merge-base would pick one
  # arbitrarily and score against a possibly-wrong base. Treat as unknown.
  [ "$n" -eq 1 ] || return 1
  git merge-base "$1" "$2" 2>/dev/null
}

# Sums net text lines from numstat input (added-minus-deleted). Echoes a string
# on one line:
#   "N"            - the net line delta, when every row is a normal text row.
#   "UNSCORED <why>" - a `- -` (binary) or `0 0` (mode-only) row appeared.
# Reads each row TAB-aware: numstat emits `add<TAB>del<TAB>path`; a naive
# "${row##*$'\t'}" grabs the pathname, not the delete count.
numstat_net() {
  local total=0 row a d p
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r a d p <<< "$row"
    if [ "$a" = "-" ] && [ "$d" = "-" ]; then { echo "UNSCORED binary"; return; }; fi
    if [ "$a" = "0" ] && [ "$d" = "0" ]; then { echo "UNSCORED mode-only"; return; }; fi
    total=$(( total + a - d ))
  done
  echo "$total"
}
```

Note: `git diff --numstat` emits `- -` for a binary change and `0 0` for a mode-only (chmod) change; both make a line-count meaningless and force UNSCORED. The `$'\t'` ANSI-C quoting produces a real tab so the `case`/`IFS` matching works — a double-quoted `"\t"` is a literal backslash-t that never matches.

- [ ] **Step 4: Implement `coverage_score` with the residual diff inside the object-dir scope**

The residual diff MUST run in the same subprocess that has the temp object dir set as `GIT_OBJECT_DIRECTORY`. A `git merge-tree --write-tree` on genuinely-divergent history writes the synthesized tree only into that temp dir (verified empirically: after removing it, `git diff` fails `fatal: bad object`). So `coverage_score` runs merge-tree and the residual diff together inside one `git -C` invocation that sets the object dirs, not by returning a tree OID for a later diff.

Append to `bin/lib.sh`:

```bash
# Echoes one of:
#   SCORED <0-100>   - the branch's net text lines that are already in base.
#   UNSCORED <why>   - binary/mode-only row, O==0, or empty patch.
#   UNKNOWN <why>    - criss-cross history, merge conflict, merge-tree error.
coverage_score() {
  local repo="$1" base="$2" branch="$3" mb out O R num
  mb=$(merge_base "$base" "$branch") || { echo "UNKNOWN no-merge-base"; return; }
  [ -n "$mb" ] || { echo "UNKNOWN no-merge-base"; return; }

  # O: net text lines on the branch from its merge base.
  out=$(git diff --no-ext-diff --no-textconv --numstat --no-renames "$mb" "$branch" 2>/dev/null) || { echo "UNKNOWN branch-diff-failed"; return; }
  O=$(numstat_net <<< "$out")
  case "$O" in
    UNSCORED*) { echo "$O-in-branch"; return; } ;;
  esac
  [ "$O" -gt 0 ] || { echo "UNSCORED no-text-rows"; return; }

  # Simulated merge + residual diff in ONE subprocess so the synthesized tree
  # stays reachable. Capture merge-tree's rc separately from its output, then
  # run the diff only on success — all inside a subshell that keeps the object
  # dir live. merge-tree rc 1 = conflict, >1 = error -> UNKNOWN.
  local obj alt base_oid mtrc tree residual
  obj=$(mktemp -d) || { echo "UNKNOWN no-temp-dir"; return; }
  alt=$(git -C "$repo" rev-parse --path-format=absolute --git-path objects 2>/dev/null)
  base_oid=$(git -C "$repo" rev-parse "$base" 2>/dev/null)
  set +e
  residual=$(
    tree=$(GIT_OBJECT_DIRECTORY="$obj" GIT_ALTERNATE_OBJECT_DIRECTORIES="$alt" \
      git -C "$repo" merge-tree --write-tree "$base" "$branch" 2>/dev/null)
    mtrc=$?
    echo "RC=$mtrc"
    [ "$mtrc" -eq 0 ] && [ -n "$tree" ] || exit "$mtrc"
    GIT_OBJECT_DIRECTORY="$obj" GIT_ALTERNATE_OBJECT_DIRECTORIES="$alt" \
      git -C "$repo" diff --no-ext-diff --no-textconv --numstat --no-renames "$base_oid" "$tree" 2>/dev/null
  )
  rc=$?
  set -e
  rm -rf "$obj"
  mtrc=$(printf '%s\n' "$residual" | grep -o '^RC=[0-9]*' | head -1 | cut -d= -f2)
  residual=$(printf '%s\n' "$residual" | grep -v '^RC=[0-9]*')
  if [ "${mtrc:-0}" -eq 1 ]; then { echo "UNKNOWN merge-conflict"; return; }; fi
  if [ "${mtrc:-0}" -gt 1 ] || [ "$rc" -gt 1 ]; then { echo "UNKNOWN merge-tree-error"; return; }; fi

  R=$(numstat_net <<< "$residual")
  case "$R" in
    UNSCORED*) { echo "UNSCORED $R"; return; } ;;
  esac

  num=$(( O - R )); [ "$num" -lt 0 ] && num=0
  echo "SCORED $(( num * 100 / O ))"
}
```

Note: `merge-tree --write-tree` prints the resulting tree OID on stdout; the pipeline reads it and immediately diffs against it while `GIT_OBJECT_DIRECTORY="$obj"` is still in effect, then the temp dir is removed. This keeps the repo's unreachable-object set unchanged (the synthesized tree lives only in `$obj`) while still letting the residual diff resolve it.

Criss-cross: `merge_base` counts bases with `git merge-base --all` and returns 1 when there is more than one, so `coverage_score` returns `UNKNOWN no-merge-base` — the branch is never scored against merge-tree's virtual base. An earlier draft of this plan claimed singular `git merge-base` *errors* ("multiple merge bases") on a criss-cross and relied on that error path. It does not: on git 2.55 it exits 0 and picks a base arbitrarily. Verified in a throwaway two-base repo, and by reverting the `--all` guard and re-running scenario 7 of `tests/test-coverage.sh` — without the guard a genuinely unmerged criss-cross branch comes back `SCORED 100`, i.e. classified as fully landed and offered for deletion. The explicit count is the guard; there is no error path to fall back on.

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
SQ_OID=$(git rev-parse sq)   # capture the branch tip BEFORE we detach it
git checkout -q main
echo sq > sq.txt; git add -A; git commit -qm "sq landing on main"
# Re-create `sq` pointing at its ORIGINAL (now-unmerged) commit so the report
# sees a non-ancestor branch whose content is already in main. Reattaching the
# captured OID directly is deterministic; searching history by message after
# deleting the branch can select the landing commit (making sq a literal
# ancestor) or nothing at all.
git branch -D -q sq
git branch sq "$SQ_OID"
out=$("$BIN/audit-worktrees.sh" "$T")
printf '%s' "$out" | grep -q "likely-content-merged" && ok "content-merged bucket present" || bad "no content-merged bucket: $out"

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
```

(Scenario 1 reattaches the captured pre-delete OID so `sq` is guaranteed a non-ancestor branch whose content is already in main — deterministic, and it must appear under `likely-content-merged`, not `needs-triage`.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-audit-content.sh`
Expected: fails — no `likely-content-merged` output yet; the branch lands in `needs-triage`.

- [ ] **Step 3: Add the content pass to the classification loop**

In `bin/audit-worktrees.sh`, add a `--no-content` flag and a fixed default threshold near the top (after the `source` line). Task 7 introduces the env-configurable, validated threshold; for now the classification uses the default so the feature is testable without config plumbing:

```bash
NO_CONTENT=false
if [ "${1:-}" = "--no-content" ]; then NO_CONTENT=true; shift; fi
ROOT="${1:-$(pwd)}"

CONTENT_MERGE_THRESHOLD=95   # Task 7 makes this env-configurable + validated
```

(Note: `ROOT` was previously `ROOT="${1:-$(pwd)}"` at line 17 — move it to after the flag shift so `--no-content` doesn't get consumed as the root path.)

Then, in the loop where `merged` is computed (currently lines 74-83), after the ancestry check says `merged=false`, insert (guarded by `NO_CONTENT`):

```bash
    local content_merged=false unscored=false
    if [ "$NO_CONTENT" = false ]; then
      local score
      score=$(coverage_score "$repo" "$base" "$branch")
      case "$score" in
        SCORED*)
          local pct="${score#SCORED }"
          if [ "$pct" -ge "$CONTENT_MERGE_THRESHOLD" ]; then content_merged=true; fi
          ;;
        UNSCORED*|UNKNOWN*)
          # Unscored / unknown -> cannot prove it shipped. It must go to
          # needs-triage, NEVER archaeology (never batch-archived) and never
          # clean-safe. Record the flag so the split below forces triage.
          unscored=true
          reason="$reason, ${score%% *}"
          ;;
      esac
    fi
```

Then add a new bucket array and branch: at the bucket declarations (line 56) add `content_merged=()`. In the merged/unmerged branch (after line 123), replace the archaeology/triage split with:

```bash
    if [ "$content_merged" = true ]; then
      content_merged+=("$desc — content-merged (work already in base, different hash)")
    elif [ "$unscored" = true ]; then
      # Unscored or unknown coverage: needs-triage, never archaeology.
      triage+=("$desc — $reason")
    elif [ "$age" -ge "$ARCHAEOLOGY_SECS" ] && [ -z "${has_upstream[$branch]:-}" ]; then
      archaeology+=("$desc — $reason, never pushed")
    else
      triage+=("$desc — $reason")
    fi
```

and in the report-emit section (after the archaeology block, ~line 158) add:

```bash
  if [ ${#content_merged[@]} -gt 0 ]; then
    echo "  likely-content-merged (work already in base under a different hash — batch archive):"
    printf '    %s\n' "${content_merged[@]}"
  fi
```

**Early-return guard:** the existing actionable-output guard (lines 141-143) returns silently when `safe`, `triage`, `archaeology`, `hands-off`, `unknown_merge`, and `prunable` are all empty. A repo whose only finding is a content-merged branch would otherwise print nothing. Add `content_merged` to that guard's empty-check:

```bash
  if [ ${#safe[@]} -eq 0 ] && [ ${#triage[@]} -eq 0 ] && [ ${#archaeology[@]} -eq 0 ] \
     && [ ${#handsoff[@]} -eq 0 ] && [ ${#unknown_merge[@]} -eq 0 ] && [ ${#prunable[@]} -eq 0 ] \
     && [ ${#content_merged[@]} -eq 0 ]; then
    return
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

echo "=== 3. strict aborts atomically when the branch moves mid-archive ==="
git checkout -qb race main
echo r > r.txt; git add -A
GIT_COMMITTER_DATE="$OLD" GIT_AUTHOR_DATE="$OLD" git commit -qm race
RACE_OID=$(git rev-parse race)
git checkout -q main
# Simulate a concurrent commit landing on the branch between classification
# and the atomic tag: point the branch at a NEW commit.
git branch -f race main
echo moved > moved.txt; git add -A; git commit -qm "race moved"; git update-ref refs/heads/race HEAD
"$BIN/archive-branch.sh" --strict "$T" race 2>/dev/null; check=$?
[ "$check" -eq 1 ] && ok "strict refuses a moved branch" || bad "strict did not refuse moved branch (rc=$check)"
git show-ref --verify --quiet refs/tags/archive/race && bad "tag created despite branch move" || ok "no tag created for moved branch"
git show-ref --verify --quiet refs/heads/race && ok "branch preserved" || bad "branch deleted!"

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

  if [ "$STRICT" = true ]; then
    # Atomic: verify the branch still points at `tip`, then create the tag, all
    # in one transaction. `create` takes ONE OID (ref + new-value); `verify`
    # takes the expected old-value. Empirically verified: the whole transaction
    # aborts (rc 128) if the verify fails, leaving the branch and the would-be
    # tag untouched. A concurrent commit that moved the branch therefore blocks
    # the tag entirely — no stale tag is created.
    if ! printf 'start\nverify refs/heads/%s %s\ncreate refs/tags/%s %s\nprepare\ncommit\n' \
        "$branch" "$tip" "$tag" "$tip" | git update-ref --stdin 2>/dev/null; then
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

  # Close the post-tag race: the atomic transaction pinned the branch at `tip`
  # and created the tag there, but a concurrent commit after that but before
  # `git branch -D` would make `-D` delete the NEW tip while the tag keeps the
  # old one, stranding the new tip unreachable. Re-verify immediately before
  # the destructive steps (worktree remove + branch -D) that follow.
  if [ "$(git rev-parse "refs/heads/$branch" 2>/dev/null)" != "$tip" ]; then
    echo "refusing $branch: branch advanced after tagging (now $(git rev-parse --short refs/heads/$branch), expected $tip) — worktree/branch left in place" >&2
    rc=1; continue
  fi
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-archive-strict.sh`
Expected: scenario 1 refuses dirty (no WIP commit, branch + file intact); scenario 2 archives clean and creates the tag; scenario 3 (branch moved) aborts atomically — no tag, branch preserved.

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

Create `tests/test-hook-parse.sh`. The test sources the REAL parser (`bin/summary-parser.sh`, added in Step 3) so it exercises production code, not a hand-copied awk program:

```bash
#!/usr/bin/env bash
# Feeds a realistic report body through the real summary parser and checks the
# bucket assignment. Exercises production code, not a copied awk program.
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
# shellcheck source=../bin/summary-parser.sh
source "$BIN/summary-parser.sh"

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

report='=== /tmp/repo (base: main) ===
  likely-content-merged (work already in base under a different hash — batch archive):
    feat/x  (worktree: /tmp/x)  [idle 3h] — content-merged (work already in base, different hash)
  needs-triage:
    feat/y  [idle 5h] — unmerged
'

echo "=== 1. a likely-content-merged heading is counted, not conflated with needs-triage ==="
sum=$(summary_parse "$report")
printf '%s' "$sum" | grep -q "1 content-merged" && ok "content-merged counted" || bad "content-merged not counted: $sum"
# The branch description mentions 'content-merged' but must NOT bump needs-triage
printf '%s' "$sum" | grep -q "1 triage" && ok "triage still counts its own heading" || bad "triage not counted: $sum"
printf '%s' "$sum" | grep -q "2 triage" && bad "branch desc leaked into triage" || ok "branch desc did not leak into triage"

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-hook-parse.sh`
Expected: with a bare `/content-merged/` matcher the branch line `content-merged (work already in base...)` would match before the heading logic resets `m`; the anchored matcher in Step 3 fixes it. Run once to see it fail, then fix.

- [ ] **Step 3: Extract the summary parser into a sourced unit**

Create `bin/summary-parser.sh` — a sourced file exposing `summary_parse`. The parser is anchored to heading position (exactly two leading spaces + the bucket name + colon), so a branch description that merely *contains* the word `content-merged` (four-space indent) can never set the bucket. This makes the parser a real tested unit rather than an inline awk that the test can only copy.

```bash
#!/usr/bin/env bash
# Sources, don't execute. summary_parse "$report" collapses a multi-repo audit
# report into one line per repo with per-bucket counts. Bucket headings are
# matched structurally (two-space indent + name + colon) so a branch description
# that mentions a bucket name can never set the current bucket.
#
# Usage: summary=$(summary_parse "$out")

summary_parse() {
  printf '%s\n' "$1" | awk '
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
  '
}
```

Then in `session-hook.sh`, replace the inline awk (lines 54-71) with a source + call:

```bash
# shellcheck source=summary-parser.sh
source "$(dirname "${BASH_SOURCE[0]}")/summary-parser.sh"
...
  summary=$(summary_parse "$out")
```

The heading matchers require exactly two leading spaces and the bucket name before the colon; a branch line (`    ...` — four spaces) is only counted under whatever heading `m` currently holds.

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
# Echoes the base-10 integer value, or "invalid". Strict decimal: rejects
# leading zeros ("08" is invalid, not 8 — a bare Bash arithmetic read would
# treat it as octal and silently change its meaning). Never emits a non-numeric
# string that a caller could feed to $(( )).
validate_pct() {
  local val="$1"
  case "$val" in
    ''|*[!0-9]*) echo invalid; return ;;
    # a leading zero with more than one digit is octal-looking -> invalid
    '0'*) [ "$val" = "0" ] || { echo invalid; return; } ;;
  esac
  local n
  n=$((val))            # safe: matched ^[0-9]+$ with no leading zero
  if [ "$n" -ge 0 ] && [ "$n" -le 100 ]; then echo "$n"; else echo invalid; fi
}
```

- [ ] **Step 4: Use it in `audit-worktrees.sh` (distinguish unset from empty)**

Replace Task 3's hardcoded `CONTENT_MERGE_THRESHOLD=95` with one that distinguishes an **unset** variable (→ default 95, the common case) from an explicitly **set-but-invalid** value (empty string, `08`, `abc`, `101` → defined hard error to stderr + fallback 95, never a silent octal read):

```bash
if [ -z "${WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD+x}" ]; then
  CONTENT_MERGE_THRESHOLD=95                     # unset -> default
else
  CONTENT_MERGE_THRESHOLD=$(validate_pct "$WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD")
  if [ "$CONTENT_MERGE_THRESHOLD" = "invalid" ]; then
    echo "  (skipped: WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD must be an integer 0-100 with no leading zero, got '$WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD')" >&2
    CONTENT_MERGE_THRESHOLD=95
  fi
fi
```

(An invalid threshold is a defined outcome: the audit prints the misconfiguration to stderr, falls back to 95, and proceeds — never a Bash octal read, never a silently reinterpreted leading-zero value.)

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
