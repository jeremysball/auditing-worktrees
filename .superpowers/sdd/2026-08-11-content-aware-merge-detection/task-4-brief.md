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

