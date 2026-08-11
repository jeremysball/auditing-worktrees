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
