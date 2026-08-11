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

# Echoes one of: a start-time string, "missing", or "unknown".
#   missing - the process provably does not exist (procfs absence).
#   unknown - /proc/<pid>/stat could not be read for any other reason.
proc_start_ticks() {
  local pid="$1" stat rest
  if [ ! -d "/proc/$pid" ]; then echo "missing"; return; fi
  stat=$(cat "/proc/$pid/stat" 2>/dev/null) || { echo "unknown"; return; }
  rest="${stat##*) }"
  [ "$rest" != "$stat" ] || { echo "unknown"; return; }
  local -a f
  read -r -a f <<< "$rest"
  [ "${#f[@]}" -ge 20 ] || { echo "unknown"; return; }
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
  live_start=$(proc_start_ticks "$pid") || { echo "unknown"; return; }
  if [ "$live_start" = "missing" ]; then echo "stale"; return; fi
  if [ "$live_start" = "unknown" ]; then echo "unknown"; return; fi
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

# Echoes the singular merge-base of two refs, or nothing on error. In a
# criss-cross history there are MULTIPLE merge bases; `git merge-base` without
# --all errors ("multiple merge bases") rather than pick one. A caller must
# detect that and treat the branch as unknown. Echoes the base OID on success.
merge_base() {
  git merge-base "$1" "$2" 2>/dev/null
}

# Sums net text lines from numstat input (added-minus-deleted). Echoes a string
# on one line:
#   "N"            - the net line delta, when every row is a normal text row.
#   "UNSCORED <why>" - a `- -` (binary) or `0 0` (mode-only) row appeared.
# Reads each row TAB-aware: numstat emits `add<TAB>del<TAB>path`; a naive
# "${row##*$'\t'}" grabs the pathname, not the delete count.
numstat_net() {
  local total=0 row a d p
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r a d p <<< "$row"
    if [ "$a" = "-" ] && [ "$d" = "-" ]; then { echo "UNSCORED binary"; return; }; fi
    if [ "$a" = "0" ] && [ "$d" = "0" ]; then { echo "UNSCORED mode-only"; return; }; fi
    total=$(( total + a - d ))
  done
  echo "$total"
}

# Echoes one of:
#   SCORED <0-100>   - the branch's net text lines that are already in base.
#   UNSCORED <why>   - binary/mode-only row, O==0, or empty patch.
#   UNKNOWN <why>    - criss-cross history, merge conflict, merge-tree error.
coverage_score() {
  local repo="$1" base="$2" branch="$3" mb out O R num
  mb=$(merge_base "$base" "$branch") || { echo "UNKNOWN no-merge-base"; return; }
  [ -n "$mb" ] || { echo "UNKNOWN no-merge-base"; return; }

  # O: net text lines on the branch from its merge base.
  out=$(git diff --no-ext-diff --no-textconv --numstat --no-renames "$mb" "$branch" 2>/dev/null) || { echo "UNKNOWN branch-diff-failed"; return; }
  O=$(numstat_net <<< "$out")
  case "$O" in
    UNSCORED*) { echo "$O-in-branch"; return; } ;;
  esac
  [ "$O" -gt 0 ] || { echo "UNSCORED no-text-rows"; return; }

  # Simulated merge + residual diff in ONE subprocess so the synthesized tree
  # stays reachable. Capture merge-tree's rc separately from its output, then
  # run the diff only on success — all inside a subshell that keeps the object
  # dir live. merge-tree rc 1 = conflict, >1 = error -> UNKNOWN.
  local obj alt base_oid mtrc tree residual
  obj=$(mktemp -d) || { echo "UNKNOWN no-temp-dir"; return; }
  alt=$(git -C "$repo" rev-parse --path-format=absolute --git-path objects 2>/dev/null)
  base_oid=$(git -C "$repo" rev-parse "$base" 2>/dev/null)
  set +e
  residual=$(
    tree=$(GIT_OBJECT_DIRECTORY="$obj" GIT_ALTERNATE_OBJECT_DIRECTORIES="$alt" \
      git -C "$repo" merge-tree --write-tree "$base" "$branch" 2>/dev/null)
    mtrc=$?
    echo "RC=$mtrc"
    [ "$mtrc" -eq 0 ] && [ -n "$tree" ] || exit "$mtrc"
    GIT_OBJECT_DIRECTORY="$obj" GIT_ALTERNATE_OBJECT_DIRECTORIES="$alt" \
      git -C "$repo" diff --no-ext-diff --no-textconv --numstat --no-renames "$base_oid" "$tree" 2>/dev/null
  )
  rc=$?
  set -e
  rm -rf "$obj"
  mtrc=$(printf '%s\n' "$residual" | grep -o '^RC=[0-9]*' | head -1 | cut -d= -f2)
  residual=$(printf '%s\n' "$residual" | grep -v '^RC=[0-9]*' || true)
  if [ "${mtrc:-0}" -eq 1 ]; then { echo "UNKNOWN merge-conflict"; return; }; fi
  if [ "${mtrc:-0}" -gt 1 ] || [ "$rc" -gt 1 ]; then { echo "UNKNOWN merge-tree-error"; return; }; fi

  R=$(numstat_net <<< "$residual")
  case "$R" in
    UNSCORED*) { echo "UNSCORED $R"; return; } ;;
  esac

  num=$(( O - R )); [ "$num" -lt 0 ] && num=0
  echo "SCORED $(( num * 100 / O ))"
}
