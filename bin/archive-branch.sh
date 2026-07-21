#!/usr/bin/env bash
# Archives unmerged branches: preserves their commits under a permanent tag,
# then removes the branch and its worktree.
#
# Usage: archive-branch.sh <repo-path> <branch> [<branch>...]
#        archive-branch.sh --list <repo-path>
#
# Why a tag rather than just `git branch -D`: deleting a branch only drops the
# ref. The commits linger as unreachable objects until gc collects them -
# reflog entries for unreachable commits expire at 30 days (default), and gc
# prunes unreachable objects older than 2 weeks (default). gc runs on its own
# via gc.auto, so that deletion is silent and unrecoverable once it lands. A
# tag is a real ref, and refs make commits reachable; reachable objects are
# never pruned. So the tag turns "gone in two weeks, recoverable only by
# reflog forensics" into "kept forever, recoverable by name".
#
# Recover one with:  git branch <name> archive/<name>

set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${1:-}" = "--list" ]; then
  cd "${2:?usage: archive-branch.sh --list <repo-path>}"
  git for-each-ref --sort=-creatordate \
    --format='%(refname:short)  %(objectname:short)  %(creatordate:short)' \
    "refs/tags/$ARCHIVE_PREFIX" 2>/dev/null
  exit 0
fi

REPO="${1:?usage: archive-branch.sh <repo-path> <branch> [<branch>...]}"; shift
[ "$#" -ge 1 ] || { echo "usage: archive-branch.sh <repo-path> <branch> [<branch>...]" >&2; exit 1; }

cd "$REPO"
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

BASE=$(detect_base)
[ -n "$BASE" ] || { echo "refusing: can't determine base branch for $REPO_ROOT" >&2; exit 1; }

# The primary worktree is the first entry git lists. Its checkout can't be
# removed and its branch can't be deleted while checked out.
PRIMARY=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')

rc=0
for branch in "$@"; do
  if [ "$branch" = "$BASE" ]; then
    echo "refusing $branch: this is the base branch" >&2; rc=1; continue
  fi
  if ! git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "skip $branch: no such local branch" >&2; continue
  fi

  path=$(worktree_path_for_branch "$branch")

  # Never switch someone's main checkout out from under them.
  if [ -n "$path" ] && [ "$path" = "$PRIMARY" ]; then
    echo "refusing $branch: checked out in the primary worktree ($path)." >&2
    echo "    Archiving it would have to switch that checkout to $BASE. Do it by hand if that's what you want." >&2
    rc=1; continue
  fi

  # Re-check liveness rather than trusting a report that may be minutes old.
  age=$(activity_age_secs "$branch" "$path")
  if [ "$age" -lt "$IN_FLIGHT_SECS" ]; then
    echo "refusing $branch: active $(human_age "$age") ago, under the $(human_age "$IN_FLIGHT_SECS") in-flight threshold" >&2
    rc=1; continue
  fi

  if [ -n "$path" ]; then
    gitdir=$(worktree_gitdir "$path") || gitdir=""
    if [ -n "$gitdir" ] && [ -f "$gitdir/locked" ]; then
      status=$(lock_status "$gitdir/locked")
      if [ "$status" != "stale" ]; then
        echo "refusing $branch: worktree lock is $status, not provably dead" >&2
        rc=1; continue
      fi
    fi

    # A tag only captures commits. Uncommitted files are in no commit, so the
    # tag would not save them and removing the worktree would destroy them
    # outright - not even reflog-recoverable. Commit first or don't touch it.
    dirty=$(worktree_dirty_count "$path")
    if [ "$dirty" -gt 0 ]; then
      echo "  $branch: committing $dirty uncommitted file(s) before archiving"
      if ! git -C "$path" add -A || \
         ! git -C "$path" commit -q -m "wip: archived with uncommitted changes"; then
        echo "refusing $branch: couldn't commit its uncommitted changes — not deleting anything" >&2
        rc=1; continue
      fi
    fi
  fi

  tag="$ARCHIVE_PREFIX/$branch"
  if git show-ref --verify --quiet "refs/tags/$tag"; then
    echo "refusing $branch: tag $tag already exists" >&2; rc=1; continue
  fi

  tip=$(git rev-parse "refs/heads/$branch")
  git tag "$tag" "refs/heads/$branch"

  # Prove the parachute opened before jumping: confirm the tag resolves to the
  # same commit the branch points at. Only then is deleting the branch safe.
  if [ "$(git rev-parse "refs/tags/$tag^{commit}")" != "$tip" ]; then
    echo "refusing $branch: tag $tag doesn't resolve to $tip — not deleting" >&2
    rc=1; continue
  fi

  if [ -n "$path" ]; then
    [ -f "${gitdir:-}/locked" ] && git worktree unlock "$path"
    git worktree remove "$path"
  fi
  git branch -D "$branch" >/dev/null

  echo "  archived $branch -> $tag ($(git rev-parse --short "$tip"))"
done

git worktree prune
exit "$rc"
