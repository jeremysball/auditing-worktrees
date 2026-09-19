#!/usr/bin/env bash
# Exercises archive-branch.sh's safety properties in a throwaway repo.
# Usage: tests/test-archive.sh   (exits non-zero on any failure)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
T="$SCRATCH/repo"
WT="$SCRATCH/worktrees"   # outside the repo: worktrees nested inside it get
                          # swallowed by `git add -A` as embedded repos
mkdir -p "$T" "$WT"; cd "$T"

git init -q -b main .
git config user.email t@t.t; git config user.name t
echo base > f; git add -A; git commit -qm base

# git's date env vars reject relative strings like "3 hours ago".
OLD=$(date -d "3 hours ago" --iso-8601=seconds)
NOW=$(date --iso-8601=seconds)

mk_branch() { # name, content, date
  git checkout -q -b "$1" main
  echo "$2" > "$1.txt"; git add -A
  GIT_COMMITTER_DATE="$3" GIT_AUTHOR_DATE="$3" git commit -qm "work on $1"
  git checkout -q main
}

pass=0; fail=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (wanted rc=$2 got rc=$3)"; }

echo "=== 1. archive an old, clean, unmerged branch ==="
mk_branch old-work precious "$OLD"
TIP=$(git rev-parse old-work)
"$BIN/archive-branch.sh" "$T" old-work; check "archive succeeds" 0 $?
git show-ref --verify --quiet refs/heads/old-work && bad "branch still exists" || ok "branch deleted"
git show-ref --verify --quiet refs/tags/archive/old-work && ok "tag created" || bad "no tag"

echo "=== 2. survives an aggressive gc, then recovers by name ==="
# The whole reason for tagging: a plain `branch -D` leaves the commit
# unreachable and gc eventually prunes it for good.
git reflog expire --expire-unreachable=now --all; git gc --prune=now -q 2>/dev/null
git cat-file -t "$TIP" >/dev/null 2>&1 && ok "commit survived gc --prune=now" || bad "commit was pruned"
git branch recovered archive/old-work 2>/dev/null
[ "$(git show recovered:old-work.txt 2>/dev/null)" = "precious" ] && ok "content recovered intact" || bad "content lost"
git branch -D recovered -q 2>/dev/null

echo "=== 3. refuses a fresh (in-flight) branch ==="
mk_branch fresh-work hot "$NOW"
"$BIN/archive-branch.sh" "$T" fresh-work 2>/dev/null; check "refuses in-flight" 1 $?
git show-ref --verify --quiet refs/heads/fresh-work && ok "branch untouched" || bad "branch was deleted!"

echo "=== 4. refuses the branch checked out in the primary worktree ==="
git checkout -q -b primary-branch main
"$BIN/archive-branch.sh" "$T" primary-branch 2>/dev/null; check "refuses primary worktree" 1 $?
git show-ref --verify --quiet refs/heads/primary-branch && ok "branch untouched" || bad "deleted!"
git checkout -q main

echo "=== 5. dirty+old worktree: commits before archiving (the omnisearch case) ==="
mk_branch dirty-work stuff "$OLD"
git worktree add -q "$WT/wt-dirty" dirty-work
echo "UNCOMMITTED PRECIOUS" > "$WT/wt-dirty/scratch.txt"
touch -d "28 days ago" "$WT/wt-dirty/scratch.txt"   # dirty but long idle
"$BIN/archive-branch.sh" "$T" dirty-work; check "archives dirty+old" 0 $?
git show-ref --verify --quiet refs/tags/archive/dirty-work && ok "tag created" || bad "no tag"
got=$(git show archive/dirty-work:scratch.txt 2>/dev/null)
[ "$got" = "UNCOMMITTED PRECIOUS" ] && ok "uncommitted file preserved in tag" || bad "uncommitted file LOST (got '$got')"

echo "=== 6. dirty+fresh worktree is refused, not committed ==="
# mtime must beat commit date: committed 3h ago, edited just now = active.
mk_branch dirty-fresh stuff2 "$OLD"
git worktree add -q "$WT/wt-fresh" dirty-fresh
echo "editing right now" > "$WT/wt-fresh/live.txt"
"$BIN/archive-branch.sh" "$T" dirty-fresh 2>/dev/null; check "refuses dirty+fresh (mtime beats commit date)" 1 $?
[ -f "$WT/wt-fresh/live.txt" ] && ok "worktree intact" || bad "worktree removed!"

echo "=== 7. --list ==="
"$BIN/archive-branch.sh" --list "$T" | sed 's/^/    /'

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
