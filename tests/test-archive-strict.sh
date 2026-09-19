#!/usr/bin/env bash
# Exercises archive-branch.sh --strict's safety properties in a throwaway repo.
# Usage: tests/test-archive-strict.sh   (exits non-zero on any failure)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

# The strict dirty-check (scenario 1) and the atomic tag transaction
# (scenario 3) both sit BEHIND the in-flight gate (activity_age_secs vs
# IN_FLIGHT_SECS, default 2h) in archive-branch.sh. Scenario 1's scratch file
# and scenario 3's moved commit carry now-mtimes, so without this override
# the gate refuses first and the strict code never runs. Zero the threshold so
# the assertions actually exercise the strict-specific paths.
export WORKTREE_AUDIT_INFLIGHT_SECS=0

SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
T="$SCRATCH/repo"; WT="$SCRATCH/wt"; mkdir -p "$T" "$WT"; cd "$T"
git init -q -b main .; git config user.email t@t.t; git config user.name t
echo base > f; git add -A; git commit -qm base
OLD=$(date -d "3 hours ago" --iso-8601=seconds)

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# For scenario 3's race to reach the atomic transaction, the branch must move
# BETWEEN the script's `tip=$(git rev-parse refs/heads/$branch)` read and the
# `git update-ref --stdin` transaction - a pre-moved branch would just be
# re-read at its new tip and archived cleanly. The move happens inside
# `update-ref` itself: a shim intercepts the very transaction call, advances
# the branch, then runs the real update-ref (whose `verify` now fails against
# the stale tip the script captured). $1=repo, $2=real git path,
# $3=name of the branch the shim should move first. The shim only acts on the
# first update-ref --stdin invocation it sees (a tag ref is being created),
# so later plain calls pass straight through.
cat > "$SCRATCH/git" <<'SHIM'
#!/usr/bin/env bash
if [ "${1:-}" = "update-ref" ] && [ "$2" = "--stdin" ]; then
  if [ -z "${MOVE_DONE:-}" ]; then
    export MOVE_DONE=1
    git -C "$SHIM_REPO" checkout -q main
    git -C "$SHIM_REPO" config user.email t@t.t
    git -C "$SHIM_REPO" config user.name t
    echo moved > "$SHIM_REPO/moved.txt"
    git -C "$SHIM_REPO" add -A
    GIT_COMMITTER_DATE="$SHIM_OLD" GIT_AUTHOR_DATE="$SHIM_OLD" git -C "$SHIM_REPO" commit -qm "race moved"
    git -C "$SHIM_REPO" update-ref refs/heads/"$SHIM_BRANCH" HEAD
  fi
fi
exec "$SHIM_GIT" "$@"
SHIM
chmod +x "$SCRATCH/git"

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
CLEAN_OID=$(git rev-parse clean)
git checkout -q main
"$BIN/archive-branch.sh" --strict "$T" clean; check=$?
[ "$check" -eq 0 ] && ok "strict archives clean" || bad "strict failed clean (rc=$check)"
git show-ref --verify --quiet refs/tags/archive/clean && ok "tag created" || bad "no tag"
[ "$(git rev-parse "refs/tags/archive/clean^{commit}")" = "$CLEAN_OID" ] && ok "tag resolves to the classified tip" || bad "tag points at the wrong commit"

echo "=== 3. strict aborts atomically when the branch moves mid-archive ==="
git checkout -qb race main
echo r > r.txt; git add -A
GIT_COMMITTER_DATE="$OLD" GIT_AUTHOR_DATE="$OLD" git commit -qm race
RACE_OID=$(git rev-parse race)
git checkout -q main
# Intercept the update-ref --stdin transaction: move the branch to a NEW commit
# at that exact moment, so the transaction's `verify refs/heads/race <tip>`
# fails against the stale tip the script captured before the move. A non-atomic
# `git tag` would NOT catch this - the tag would be created against the moved
# tip and scenario 3 would fail its assertions.
export SHIM_GIT=$(command -v git) SHIM_REPO="$T" SHIM_OLD="$OLD" SHIM_BRANCH=race
export PATH="$SCRATCH:$PATH"
"$BIN/archive-branch.sh" --strict "$T" race 2>/dev/null; check=$?
export PATH=${PATH#*"$SCRATCH":}
[ "$check" -eq 1 ] && ok "strict refuses a moved branch" || bad "strict did not refuse moved branch (rc=$check)"
git show-ref --verify --quiet refs/tags/archive/race && bad "tag created despite branch move" || ok "no tag created for moved branch"
git show-ref --verify --quiet refs/heads/race && ok "branch preserved" || bad "branch deleted!"
[ "$(git rev-parse refs/heads/race)" != "$RACE_OID" ] && ok "branch still at the moved (new) tip" || bad "branch reverted to the pre-move tip!"

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
