#!/usr/bin/env bash
# Regression tests for the shared machinery used by git-drain-worktrees.
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
source "$BIN/lib.sh"

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

pass=0
fail=0
ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

# The repository-wide hooks are not part of these throwaway repositories.
git_local() { git -c core.hooksPath=/dev/null "$@"; }

repo="$SCRATCH/repo"
bare="$SCRATCH/remote.git"
mkdir -p "$repo"
git_local -C "$repo" init -q -b main
git_local -C "$repo" config user.email test@example.invalid
git_local -C "$repo" config user.name test
printf 'base\n' >"$repo/base.txt"
git_local -C "$repo" add base.txt
git_local -C "$repo" commit -qm 'test: create base'
git_local init -q --bare "$bare"
git_local -C "$repo" remote add origin "$bare"
git_local -C "$repo" push -q -u origin main
git_local -C "$bare" symbolic-ref HEAD refs/heads/main
git_local -C "$repo" fetch -q origin
git_local -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

echo '=== base/ref and relation helpers ==='
git_local -C "$repo" branch release/next main
git_local -C "$repo" push -q origin refs/heads/release/next:refs/heads/release/next
git_local -C "$bare" symbolic-ref HEAD refs/heads/release/next
git_local -C "$repo" symbolic-ref --delete refs/remotes/origin/HEAD
base_ref=$(resolve_base_ref "$repo" origin)
[ "$base_ref" = refs/remotes/origin/release/next ] \
  && ok 'remote HEAD resolves to the full slash-containing ref' \
  || bad "remote HEAD resolved to $base_ref"
[ "$(base_branch_from_ref "$base_ref")" = release/next ] \
  && ok 'base branch extraction preserves slash-containing names' \
  || bad 'base branch extraction dropped a path component'

git_local -C "$repo" checkout -q -b feature main
printf 'feature\n' >"$repo/feature.txt"
git_local -C "$repo" add feature.txt
git_local -C "$repo" commit -qm 'test: add feature'
tip=$(git_local -C "$repo" rev-parse HEAD)
git_local -C "$repo" checkout -q main
git_local -C "$repo" push -q origin feature
git_local -C "$repo" fetch -q origin
git_local -C "$repo" config drain.test value

[ "$(git_config_get "$repo" drain.test)" = value ] \
  && ok 'git_config_get reads configured values' \
  || bad 'git_config_get did not read a configured value'
if git_config_get "$repo" drain.missing >/dev/null 2>&1; then
  bad 'git_config_get treated a missing key as a value'
else
  [ "$?" -eq 1 ] && ok 'git_config_get distinguishes a missing key' \
    || bad 'git_config_get returned the wrong missing-key status'
fi
[ "$(commit_relation "$repo" refs/heads/main refs/heads/feature)" = ancestor ] \
  && ok 'commit_relation reports ancestry' \
  || bad 'commit_relation missed ancestry'
[ "$(commit_relation "$repo" refs/heads/feature refs/heads/feature)" = equal ] \
  && ok 'commit_relation reports equality' \
  || bad 'commit_relation missed equality'
[ "$(classify_branch "$repo" feature refs/remotes/origin/main)" = OUTSTANDING ] \
  && ok 'classify_branch reports an outstanding branch' \
  || bad 'classify_branch misclassified an outstanding branch'
[ "$(branch_pushed "$repo" feature origin)" = yes ] \
  && ok 'branch_pushed requires and recognizes remote containment' \
  || bad 'branch_pushed missed a pushed branch'
[ "$(ref_exists "$repo" refs/remotes/origin/feature)" = yes ] \
  && ok 'ref_exists reports an existing ref' \
  || bad 'ref_exists missed an existing ref'
[ "$(ref_exists "$repo" refs/remotes/origin/missing)" = no ] \
  && ok 'ref_exists reports a missing ref' \
  || bad 'ref_exists misclassified a missing ref'

echo '=== PR signal and remote identity helpers ==='
git_local -C "$repo" config remote.origin.url git@github.com:acme/project.git
base_slug=$(remote_repo_slug "$repo" origin)
[ "$base_slug" = acme/project ] \
  && ok 'remote_repo_slug normalizes GitHub SSH URLs' \
  || bad "remote_repo_slug returned $base_slug"
git_local -C "$repo" config branch.feature.remote origin
source_repo=$(branch_source_repo "$repo" feature "$base_slug")
[ "$source_repo" = acme/project ] \
  && ok 'branch_source_repo binds a branch to its upstream repository' \
  || bad "branch_source_repo returned $source_repo"
signals="$SCRATCH/signals.tsv"
printf 'feature\t%s\tacme/project\tsame\tOPEN\t7\n' "$tip" >"$signals"
load_pr_signals "$signals"
signal=$(lookup_branch_signal "$signals" "$repo" feature "$tip" "$base_slug")
[ "$signal" = $'OPEN\t7\t'"$tip" ] \
  && ok 'PR lookup matches branch, head SHA, and repository' \
  || bad "PR lookup returned $signal"

echo '=== NUL-safe worktree and action guards ==='
wt="$SCRATCH/worktree with
newline"
git_local -C "$repo" worktree add -q "$wt" feature
worktree_snapshot "$repo"
primary=$(worktree_primary_path "$repo")
[ "$primary" = "$repo" ] \
  && ok 'worktree_primary_path returns the first worktree' \
  || bad "worktree_primary_path returned $primary"
path=$(worktree_path_for_branch feature "$repo")
[ "$path" = "$wt" ] \
  && ok 'worktree_path_for_branch preserves a newline path' \
  || bad 'worktree_path_for_branch corrupted a newline path'
[ "$(worktree_dirty_count "$wt")" = 0 ] \
  && ok 'worktree_dirty_count recognizes a clean worktree' \
  || bad 'clean worktree was reported dirty'
printf 'scratch\n' >"$wt/untracked.txt"
[ "$(worktree_dirty_count "$wt")" = 1 ] \
  && ok 'worktree_dirty_count counts untracked paths' \
  || bad 'untracked path was not counted'
rm -f "$wt/untracked.txt"
# The sourced classifier reads this shared setting.
# shellcheck disable=SC2034
IN_FLIGHT_SECS=0
[ "$(classify_worktree "$repo" "$wt" feature main "$SCRATCH" "$repo")" = READY ] \
  && ok 'classify_worktree permits a clean idle worktree' \
  || bad 'classify_worktree rejected a clean idle worktree'
[ "$(verify_worktree_unchanged "$repo" "$wt" feature "$tip")" = yes ] \
  && ok 'verify_worktree_unchanged confirms the expected tip and path' \
  || bad 'verify_worktree_unchanged did not confirm an unchanged worktree'
if remove_worktree_safe "$repo" "$repo" main "$(git_local -C "$repo" rev-parse main)" >/dev/null 2>&1; then
  bad 'remove_worktree_safe allowed the primary worktree'
else
  ok 'remove_worktree_safe refuses the primary worktree'
fi
git_local -C "$repo" worktree lock --reason 'pid 999999 start 1' "$wt"
[ "$(classify_worktree "$repo" "$wt" feature main "$SCRATCH" "$repo")" = READY ] \
  && ok 'classify_worktree permits a provably stale lock' \
  || bad 'classify_worktree treated a stale lock as hands-off'
if remove_worktree_safe "$repo" "$wt" feature "$tip" >/dev/null 2>&1; then
  [ ! -e "$wt" ] && [ -n "$(git_local -C "$repo" show-ref --verify refs/heads/feature)" ] \
    && ok 'remove_worktree_safe removes only the worktree and keeps the branch' \
    || bad 'remove_worktree_safe removed the wrong state'
else
  bad 'remove_worktree_safe refused an unchanged non-primary worktree'
fi

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
