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

