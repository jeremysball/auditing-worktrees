#!/usr/bin/env bash
# Shared helpers for the auditing-worktrees scripts. Source, don't execute.
#
# Thresholds are env-overridable so this works on machines with different
# working rhythms; never hardcode them at a call site.

# Activity newer than this means someone may be at the keyboard right now.
# In-flight beats every other classification, including safe-to-clean: the
# risk isn't only losing commits, it's yanking a directory out from under a
# live session.
IN_FLIGHT_SECS="${WORKTREE_AUDIT_INFLIGHT_SECS:-7200}"        # 2 hours

# Older than this with no upstream and the context is gone for good. These
# are offered as a batch archive rather than a per-branch judgment call.
ARCHAEOLOGY_SECS="${WORKTREE_AUDIT_ARCHAEOLOGY_SECS:-7776000}" # 90 days

ARCHIVE_PREFIX="${WORKTREE_AUDIT_ARCHIVE_PREFIX:-archive}"

detect_base() {
  if git show-ref --verify --quiet refs/heads/main; then
    echo main
  elif git show-ref --verify --quiet refs/heads/master; then
    echo master
  else
    git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@' || echo ""
  fi
}

proc_start_ticks() {
  # Field 22 of /proc/<pid>/stat is start time in clock ticks since boot.
  # Field 2 (comm) is parenthesized and may itself contain spaces or parens,
  # so field-count naively and it silently shifts. Strip through the *last*
  # ") " instead and index from there.
  local pid="$1" stat rest
  stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
  rest="${stat##*) }"
  [ "$rest" != "$stat" ] || return 1
  local -a f
  read -r -a f <<< "$rest"
  # rest starts at original field 3 (state); field 22 (starttime) is index 19.
  [ "${#f[@]}" -ge 20 ] || return 1
  echo "${f[19]}"
}

# Resolves a worktree's actual metadata dir via git itself rather than
# reconstructing it from the path's basename. Git disambiguates colliding
# basenames (two worktrees named "same" in different parents become
# .git/worktrees/same and .git/worktrees/same1) - deriving the name by hand
# reads the wrong worktree's lock file in that case.
worktree_gitdir() {
  git -C "$1" rev-parse --absolute-git-dir 2>/dev/null
}

# Echoes one of: live | stale | unknown.
#   live    - lock reason has a pid+start pair matching a running process.
#   stale   - lock reason has a pid+start pair, process is gone.
#   unknown - no lock file, or a lock reason that isn't a pid+start record
#             (e.g. a manual `git worktree lock --reason "..."`). Must be
#             treated the same as live - we cannot prove it's safe.
lock_status() {
  local lockfile="$1"
  [ -f "$lockfile" ] || { echo "unknown"; return; }
  local reason pid="" start=""
  reason=$(cat "$lockfile" 2>/dev/null) || { echo "unknown"; return; }
  [[ "$reason" =~ pid\ ([0-9]+) ]] && pid="${BASH_REMATCH[1]}"
  [[ "$reason" =~ start\ ([0-9]+) ]] && start="${BASH_REMATCH[1]}"
  if [ -z "$pid" ] || [ -z "$start" ]; then echo "unknown"; return; fi
  local live_start
  if ! live_start=$(proc_start_ticks "$pid"); then echo "stale"; return; fi
  if [ "$live_start" = "$start" ]; then echo "live"; else echo "stale"; fi
}

# Finds the worktree path for a branch by parsing porcelain line-by-line (not
# word-split), so paths containing spaces survive intact.
worktree_path_for_branch() {
  local want="refs/heads/$1" cur_path="" cur_branch=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) cur_path="${line#worktree }"; cur_branch="" ;;
      "branch "*) cur_branch="${line#branch }" ;;
      "")
        if [ "$cur_branch" = "$want" ]; then echo "$cur_path"; return; fi
        cur_path=""; cur_branch=""
        ;;
    esac
  done < <(git worktree list --porcelain; echo "")
}

# Number of changed (modified, staged, deleted, or untracked) paths.
worktree_dirty_count() {
  local wt="$1"
  [ -n "$wt" ] && [ -d "$wt" ] || { echo 0; return; }
  git -C "$wt" status --porcelain 2>/dev/null | wc -l
}

# Newest mtime among files the user has actually touched. A clean worktree's
# files carry checkout mtimes, which are not activity - so only changed files
# count. Echoes nothing when the worktree is clean or absent.
newest_change_mtime() {
  local wt="$1"
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  {
    git -C "$wt" ls-files -z --modified --others --exclude-standard 2>/dev/null
    git -C "$wt" diff --cached --name-only -z 2>/dev/null
  } | ( cd "$wt" 2>/dev/null && xargs -0 -r stat -c '%Y' -- 2>/dev/null ) \
    | sort -rn | head -1
}

# Seconds since ANY activity on this branch, committed or not:
# max(last commit time, newest touched-file mtime).
#
# Neither signal works alone, and both failures were observed live in this
# workspace. Last-commit-time called a clawmarks branch idle while its
# worktree was being edited 2 minutes prior. File mtime called an omnisearch
# worktree active when it had been dirty and untouched for 28 days. Taking the
# max of the two classifies both correctly.
activity_age_secs() {
  local branch="$1" wt="${2:-}"
  local now newest commit_ts m
  now=$(date +%s)
  commit_ts=$(git log -1 --format='%ct' "$branch" 2>/dev/null) || commit_ts=""
  [ -n "$commit_ts" ] || commit_ts=0
  newest="$commit_ts"
  m=$(newest_change_mtime "$wt")
  if [ -n "$m" ] && [ "$m" -gt "$newest" ] 2>/dev/null; then newest="$m"; fi
  echo $(( now - newest ))
}

human_age() {
  local s="$1"
  if   [ "$s" -lt 3600 ];   then echo "$(( s / 60 ))m"
  elif [ "$s" -lt 86400 ];  then echo "$(( s / 3600 ))h"
  else                           echo "$(( s / 86400 ))d"
  fi
}
