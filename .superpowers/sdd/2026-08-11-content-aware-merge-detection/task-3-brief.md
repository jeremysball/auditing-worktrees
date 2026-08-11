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

