#!/usr/bin/env bash
# Smoke test: run the real audit-worktrees.sh end to end, no stubs, over a
# fixture covering every bucket, and compare its whole output to
# tests/golden/audit.txt. Unit tests check functions; this checks that a
# refactor left the report itself unchanged (it caught an untracked-dir
# expansion that moved a dirty count from 6 to 244).
# Regenerate after an intended output change: tests/smoke-audit.sh --update
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${AUDIT_BIN:-$HERE/../bin}"
GOLDEN="$HERE/golden/audit.txt"

SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
R="$SCRATCH/repo"; W="$SCRATCH/wt"; mkdir -p "$R" "$W"; cd "$R"
OLD=$(date -d "3 hours ago" --iso-8601=seconds)
export GIT_AUTHOR_DATE="$OLD" GIT_COMMITTER_DATE="$OLD"
git init -q -b main .
echo base > f; git add -A; git commit -qm base

# merged: literal ancestor of main
git branch merged; git -C "$R" switch -q merged; echo m > m; git add m; git commit -qm m
git switch -q main; git merge -q --ff-only merged
# squash-landed: content in main, not an ancestor
git switch -q -c squashed; echo s > s; git add s; git commit -qm s
git switch -q main; git merge -q --squash squashed; git commit -qm "squash s"
# unlanded: work that never reached main
git switch -q -c unlanded; echo u > u; git add u; git commit -qm u; git switch -q main
# a worktree on the unlanded branch, idle, with an untracked dir of many files
git worktree add -q "$W/unlanded" unlanded
mkdir -p "$W/unlanded/junk"; for i in $(seq 1 20); do echo "$i" > "$W/unlanded/junk/$i"; done
touch -d "$OLD" "$W/unlanded/junk" "$W/unlanded/junk/"*
# primary checkout dirty the same way
mkdir -p junk; for i in $(seq 1 20); do echo "$i" > "junk/$i"; done
touch -d "$OLD" junk junk/*

out=$(bash "$BIN/audit-worktrees.sh" "$R" 2>&1 | sed "s|$SCRATCH|<SCRATCH>|g; s|idle [0-9]*[smhd]|idle <AGE>|g")
if [ "${1:-}" = --update ]; then printf '%s\n' "$out" > "$GOLDEN"; echo "golden updated"; exit 0; fi
if diff -u "$GOLDEN" <(printf '%s\n' "$out"); then
  echo "=== 1 passed, 0 failed ==="
else
  echo "=== 0 passed, 1 failed ==="; exit 1
fi
