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
# shellcheck disable=SC2034 # consumed by audit-worktrees.sh after sourcing
ARCHAEOLOGY_SECS="${WORKTREE_AUDIT_ARCHAEOLOGY_SECS:-7776000}" # 90 days

# shellcheck disable=SC2034 # consumed by archive-branch.sh after sourcing
ARCHIVE_PREFIX="${WORKTREE_AUDIT_ARCHIVE_PREFIX:-archive}"

declare -ag WORKTREE_PATHS=() WORKTREE_HEADS=() WORKTREE_BRANCHES=()
declare -ag WORKTREE_LOCKS=() WORKTREE_PRUNABLES=()
declare -Ag BRANCH_SIGNAL_STATE=() BRANCH_SIGNAL_NUMBER=()
PR_SIGNAL_SEP=$'\037'

# Read one git-config value. A missing key returns 1; malformed or unreadable
# configuration returns 2 with the original git error made explicit.
git_config_get() {
  local repo="$1" key="$2" value rc
  if value=$(git -C "$repo" config --get "$key" 2>&1); then
    printf '%s\n' "$value"
    return 0
  else
    rc=$?
    [ "$rc" -eq 1 ] && [ -z "$value" ] && return 1
    printf 'error: git config --get %s failed: %s\n' "$key" "$value" >&2
    return 2
  fi
}

# Refresh the remote-tracking refs used by classification. This is deliberately
# a separate primitive so callers cannot accidentally make a post-destruction
# fetch their first refresh.
fetch_remote_for_classification() {
  local repo="$1" remote="$2" rc
  if git -C "$repo" fetch --quiet --prune "$remote"; then
    return 0
  else
    rc=$?
    printf 'error: fetch of remote %s failed before classification (exit %s)\n' \
      "$remote" "$rc" >&2
    return "$rc"
  fi
}

# Resolve the configured remote's default branch to a full
# refs/remotes/<remote>/<branch> name. The local symref is preferred; the
# remote's HEAD symref is the authoritative fallback. No main/master guess is
# safe here because a repository may use any default branch name.
resolve_base_ref() {
  local repo="$1" remote="$2" sym candidate="" full tmp rc

  if sym=$(git -C "$repo" symbolic-ref --quiet "refs/remotes/$remote/HEAD" 2>/dev/null); then
    case "$sym" in
      "refs/remotes/$remote/"*) full="$sym" ;;
      "refs/heads/"*) full="refs/remotes/$remote/${sym#refs/heads/}" ;;
    esac
  fi

  if [ -z "${full:-}" ]; then
    tmp=$(mktemp) || {
      echo "error: could not create a temporary file to resolve $remote/HEAD" >&2
      return 1
    }
    if git -C "$repo" ls-remote --symref "$remote" HEAD >"$tmp" 2>"$tmp.err"; then
      :
    else
      rc=$?
      printf 'error: could not resolve %s/HEAD with git ls-remote (exit %s): %s\n' \
        "$remote" "$rc" "$(<"$tmp.err")" >&2
      rm -f "$tmp" "$tmp.err"
      return 1
    fi
    while IFS=$' \t' read -r marker target alias; do
      if [ "$marker" = ref: ] && [ "$alias" = HEAD ]; then
        candidate="$target"
      fi
    done <"$tmp"
    rm -f "$tmp" "$tmp.err"
    case "$candidate" in
      refs/heads/*) full="refs/remotes/$remote/${candidate#refs/heads/}" ;;
    esac
  fi

  if [ -z "${full:-}" ]; then
    echo "error: remote $remote has no discoverable HEAD symref" >&2
    return 1
  fi
  if ! git -C "$repo" rev-parse --verify --quiet "$full^{commit}" >/dev/null 2>&1; then
    echo "error: remote HEAD resolved to $full, but that ref is not available locally" >&2
    return 1
  fi
  printf '%s\n' "$full"
}

# Return yes/no/unknown for whether a ref exists. A missing ref is normal during
# PR cleanup; all other git failures remain unknown rather than becoming absent.
ref_exists() {
  local repo="$1" ref="$2" rc
  if git -C "$repo" show-ref --verify --quiet "$ref"; then
    echo yes
    return 0
  else
    rc=$?
  fi
  case "$rc" in
    1) echo no ;;
    *) echo unknown ;;
  esac
}

# Compare two commits with an explicit equality result. The relation is one of
# equal, ancestor, no, or unknown; callers can choose whether equality alone or
# ancestry is sufficient for their policy.
commit_relation() {
  local repo="$1" left="$2" right="$3" left_oid right_oid rc
  left_oid=$(git -C "$repo" rev-parse --verify --quiet --end-of-options "$left^{commit}" 2>/dev/null) || {
    echo unknown
    return 0
  }
  right_oid=$(git -C "$repo" rev-parse --verify --quiet --end-of-options "$right^{commit}" 2>/dev/null) || {
    echo unknown
    return 0
  }
  if [ "$left_oid" = "$right_oid" ]; then
    echo equal
    return 0
  fi
  if git -C "$repo" merge-base --is-ancestor "$left_oid" "$right_oid" >/dev/null 2>&1; then
    echo ancestor
    return 0
  else
    rc=$?
  fi
  case "$rc" in
    1) echo no ;;
    *) echo unknown ;;
  esac
}

# Determine whether a local branch is actually pushed: its tip must be equal
# to, or an ancestor of, the full remote-tracking branch ref.
branch_pushed() {
  local repo="$1" branch="$2" remote="$3" remote_ref relation exists
  remote_ref="refs/remotes/$remote/$branch"
  exists=$(ref_exists "$repo" "$remote_ref")
  case "$exists" in
    no) echo no; return 0 ;;
    unknown) echo unknown; return 0 ;;
  esac
  relation=$(commit_relation "$repo" "refs/heads/$branch" "$remote_ref")
  case "$relation" in
    equal|ancestor) echo yes ;;
    no) echo no ;;
    unknown) echo unknown ;;
  esac
}

# Classify literal branch ancestry against a base using the shared tri-state
# commit relation. This is the common branch classifier used by audit and drain.
classify_branch() {
  local repo="$1" branch="$2" base="$3" relation
  relation=$(commit_relation "$repo" "refs/heads/$branch" "$base")
  case "$relation" in
    equal|ancestor) echo LANDED ;;
    no) echo OUTSTANDING ;;
    unknown) echo UNKNOWN ;;
  esac
}

# Parse one NUL-delimited `git worktree list --porcelain -z` snapshot into the
# indexed arrays above. Paths can contain newlines and tabs; only NUL is a
# separator, as Git's format requires.
worktree_snapshot() {
  local repo="$1" tmp field path="" head="" branch="" lock="" prunable="" rc
  WORKTREE_PATHS=(); WORKTREE_HEADS=(); WORKTREE_BRANCHES=()
  WORKTREE_LOCKS=(); WORKTREE_PRUNABLES=()
  tmp=$(mktemp) || {
    echo "error: could not create a worktree snapshot" >&2
    return 1
  }
  if git -C "$repo" worktree list --porcelain -z >"$tmp"; then
    :
  else
    rc=$?
    echo "error: git worktree list failed (exit $rc)" >&2
    rm -f "$tmp"
    return "$rc"
  fi
  while IFS= read -r -d '' field; do
    if [ -z "$field" ]; then
      if [ -n "$path" ]; then
        WORKTREE_PATHS+=("$path")
        WORKTREE_HEADS+=("$head")
        WORKTREE_BRANCHES+=("${branch:-HEAD}")
        WORKTREE_LOCKS+=("$lock")
        WORKTREE_PRUNABLES+=("$prunable")
      fi
      path=""; head=""; branch=""; lock=""; prunable=""
      continue
    fi
    case "$field" in
      "worktree "*) path="${field#worktree }" ;;
      "HEAD "*) head="${field#HEAD }" ;;
      "branch refs/heads/"*) branch="${field#branch refs/heads/}" ;;
      detached) branch=HEAD ;;
      locked*) lock="${field#locked}"; [ -n "$lock" ] || lock=locked ;;
      prunable*) prunable="${field#prunable}"; [ -n "$prunable" ] || prunable=prunable ;;
    esac
  done <"$tmp"
  rm -f "$tmp"
  if [ -n "$path" ]; then
    WORKTREE_PATHS+=("$path")
    WORKTREE_HEADS+=("$head")
    WORKTREE_BRANCHES+=("${branch:-HEAD}")
    WORKTREE_LOCKS+=("$lock")
    WORKTREE_PRUNABLES+=("$prunable")
  fi
  [ "${#WORKTREE_PATHS[@]}" -gt 0 ]
}

# Return the primary worktree path from a fresh machine-readable snapshot.
worktree_primary_path() {
  local repo="$1"
  worktree_snapshot "$repo" || return 1
  printf '%s\n' "${WORKTREE_PATHS[0]}"
}

# Return the GitHub owner/repository slug for a remote URL. A non-GitHub
# remote returns 1 (there is no GitHub PR provider); a git failure returns 2.
remote_repo_slug() {
  local repo="$1" remote="$2" url path rc
  # Read the configured URL rather than `remote get-url`: the latter applies
  # url.*.insteadOf rewrites used by local test mirrors and can hide the actual
  # GitHub repository identity from the PR provider.
  if url=$(git_config_get "$repo" "remote.$remote.url"); then
    :
  else
    rc=$?
    printf 'error: could not read remote %s URL: %s\n' "$remote" "$url" >&2
    return "$rc"
  fi
  case "$url" in
    https://github.com/*) path="${url#https://github.com/}" ;;
    http://github.com/*) path="${url#http://github.com/}" ;;
    ssh://git@github.com/*) path="${url#ssh://git@github.com/}" ;;
    git@github.com:*) path="${url#git@github.com:}" ;;
    *) return 1 ;;
  esac
  path="${path%.git}"
  case "$path" in
    */*/*|/*) return 1 ;;
    */*) printf '%s\n' "$path" ;;
    *) return 1 ;;
  esac
}

# Resolve the repository that supplies a local branch's PR head. A branch with
# no upstream is treated as a local branch of the base repository; an upstream
# on a non-GitHub remote is deliberately unmatchable rather than guessed.
branch_source_repo() {
  local repo="$1" branch="$2" base_slug="$3" branch_remote rc slug
  if branch_remote=$(git_config_get "$repo" "branch.$branch.remote"); then
    :
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then
      printf '%s\n' "$base_slug"
      return 0
    fi
    return "$rc"
  fi
  [ "$branch_remote" = . ] && { printf '%s\n' "$base_slug"; return 0; }
  if slug=$(remote_repo_slug "$repo" "$branch_remote"); then
    printf '%s\n' "$slug"
  else
    rc=$?
    [ "$rc" -eq 1 ] && { printf 'unknown\n'; return 0; }
    return "$rc"
  fi
}

# Query all historical PRs for the remote repository and normalize their head
# signals into TSV rows: branch, head OID, head repository key, same/cross,
# state, number. A missing gh binary returns 127; an unsupported non-GitHub
# remote also returns 127. Once gh is selected, auth, network, and jq failures
# are fatal and never become a false "no PR" result.
fetch_pr_signals() {
  local repo="$1" remote="$2" output="$3" slug raw err rc
  : >"$output" || {
    echo "error: cannot write PR signal map $output" >&2
    return 1
  }
  command -v gh >/dev/null 2>&1 || return 127
  if slug=$(remote_repo_slug "$repo" "$remote"); then
    :
  else
    rc=$?
    [ "$rc" -eq 1 ] && {
      echo "gh PR lookup unavailable: remote $remote is not a GitHub repository" >&2
      return 127
    }
    return "$rc"
  fi
  command -v jq >/dev/null 2>&1 || {
    echo "error: jq is required to parse gh PR state" >&2
    return 1
  }
  raw=$(mktemp) || { echo "error: could not create a PR response file" >&2; return 1; }
  err="$raw.err"
  env -u GH_REPO -u GH_HOST gh pr list \
    --repo "$slug" --state all --limit 1000000 \
    --json headRefName,headRefOid,headRepositoryOwner,isCrossRepository,state,number \
    >"$raw" 2>"$err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'error: gh PR lookup failed for %s (exit %s): %s\n' \
      "$slug" "$rc" "$(<"$err")" >&2
    rm -f "$raw" "$err"
    return 1
  fi
  if ! jq -e '
      type == "array" and
      all(.[];
        (.headRefName | type) == "string" and
        (.headRefOid | type) == "string" and
        (.state | type) == "string" and
        (.number | type) == "number" and
        (.isCrossRepository | type) == "boolean" and
        ((.headRepositoryOwner == null) or
         ((.headRepositoryOwner | type) == "object" and
          (.headRepositoryOwner.login | type) == "string") or
         ((.headRepositoryOwner | type) == "string")))
    ' "$raw" >/dev/null; then
    echo "error: gh PR lookup returned invalid JSON or missing head fields" >&2
    rm -f "$raw" "$err"
    return 1
  fi
  if ! jq -r --arg base "$slug" '
      def owner:
        if .headRepositoryOwner == null then ""
        elif (.headRepositoryOwner | type) == "object" then .headRepositoryOwner.login
        else .headRepositoryOwner
        end;
      sort_by(.number) | reverse | .[] |
      [ .headRefName, .headRefOid,
        (if .isCrossRepository then owner else $base end),
        (if .isCrossRepository then "cross" else "same" end),
        .state, (.number | tostring) ] | @tsv
    ' "$raw" >"$output"; then
    echo "error: jq could not normalize gh PR state" >&2
    rm -f "$raw" "$err"
    return 1
  fi
  rm -f "$raw" "$err"
}

# Load one normalized PR signal map. The first row for a key wins because the
# provider response is sorted newest-first, so repeated historical records do
# not reintroduce branch-name-only matching.
load_pr_signals() {
  local map="$1" branch oid repo_key kind state number key
  BRANCH_SIGNAL_STATE=(); BRANCH_SIGNAL_NUMBER=()
  while IFS=$'\t' read -r branch oid repo_key kind state number; do
    [ -n "$branch" ] || continue
    [ -n "$oid" ] && [ -n "$repo_key" ] && [ -n "$kind" ] && [ -n "$state" ] && [ -n "$number" ] || {
      echo "error: malformed PR signal row" >&2
      return 1
    }
    key="${branch}${PR_SIGNAL_SEP}${oid}${PR_SIGNAL_SEP}${repo_key}${PR_SIGNAL_SEP}${kind}"
    if [ -z "${BRANCH_SIGNAL_STATE[$key]+set}" ]; then
      BRANCH_SIGNAL_STATE["$key"]="$state"
      BRANCH_SIGNAL_NUMBER["$key"]="$number"
    fi
  done <"$map"
}

# Look up a branch's current PR signal by branch, head SHA, and head repository.
# A missing signal returns 1; provider/config failures return a nonzero status
# greater than 1. On success, stdout is STATE<TAB>NUMBER<TAB>HEAD_OID.
lookup_branch_signal() {
  shift
  local repo="$1" branch="$2" tip="$3" base_slug="$4"
  local source owner kind key
  source=$(branch_source_repo "$repo" "$branch" "$base_slug") || return $?
  [ "$source" != unknown ] || return 1
  owner="${source%%/*}"
  if [ "$source" = "$base_slug" ]; then kind=same; else kind=cross; fi
  if [ "$kind" = same ]; then key="${branch}${PR_SIGNAL_SEP}${tip}${PR_SIGNAL_SEP}${base_slug}${PR_SIGNAL_SEP}same";
  else key="${branch}${PR_SIGNAL_SEP}${tip}${PR_SIGNAL_SEP}${owner}${PR_SIGNAL_SEP}cross"; fi
  if [ -z "${BRANCH_SIGNAL_STATE[$key]+set}" ]; then return 1; fi
  printf '%s\t%s\t%s\n' "${BRANCH_SIGNAL_STATE[$key]}" \
    "${BRANCH_SIGNAL_NUMBER[$key]}" "$tip"
}

# Return the common safety/action guard for one worktree. The result is one of
# BASE, CURRENT, PRIMARY, DETACHED, LOCKED, DIRTY, IN-FLIGHT, UNKNOWN, READY.
# The policy for PR state and branch actions remains in the caller.
classify_worktree() {
  local repo="$1" path="$2" branch="$3" base_branch="$4" here="$5" primary="$6"
  local gitdir lock dirty age rc
  [ "$branch" = "$base_branch" ] && { echo BASE; return; }
  [ "$path" = "$here" ] && { echo CURRENT; return; }
  [ "$path" = "$primary" ] && { echo PRIMARY; return; }
  [ "$branch" = HEAD ] && { echo DETACHED; return; }
  [ -d "$path" ] || { echo UNKNOWN; return; }
  if gitdir=$(worktree_gitdir "$path"); then
    if [ -f "$gitdir/locked" ]; then
      lock=$(lock_status "$gitdir/locked") || { echo UNKNOWN; return; }
      case "$lock" in
        live|unknown)
          echo "LOCKED $lock"
          return
          ;;
        stale) ;;
        *) echo UNKNOWN; return ;;
      esac
    fi
  else
    echo UNKNOWN
    return
  fi
  if dirty=$(worktree_dirty_count "$path"); then
    [ "$dirty" -eq 0 ] || { echo DIRTY; return; }
  else
    echo UNKNOWN
    return
  fi
  if ! git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    echo UNKNOWN
    return
  fi
  if age=$(cd "$repo" && activity_age_secs "$branch" "$path"); then
    if [ "$age" -lt "$IN_FLIGHT_SECS" ] 2>/dev/null; then
      echo IN-FLIGHT
      return
    fi
  else
    rc=$?
    [ "$rc" -eq 1 ] || { echo UNKNOWN; return; }
  fi
  echo READY
}

# Re-check branch tip, worktree HEAD, cleanliness, and lock state immediately
# before a worktree removal. The result is yes/no/unknown and never fails open.
verify_worktree_unchanged() {
  local repo="$1" path="$2" branch="$3" expected_tip="$4"
  local actual branch_at_path dirty gitdir
  [ -d "$path" ] || { echo unknown; return 0; }
  branch_at_path=$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null) || {
    echo unknown; return 0;
  }
  [ "$branch_at_path" = "$branch" ] || { echo no; return 0; }
  actual=$(git -C "$repo" rev-parse --verify --quiet --end-of-options "refs/heads/$branch^{commit}" 2>/dev/null) || {
    echo unknown; return 0;
  }
  [ "$actual" = "$expected_tip" ] || { echo no; return 0; }
  actual=$(git -C "$path" rev-parse --verify --quiet --end-of-options HEAD 2>/dev/null) || {
    echo unknown; return 0;
  }
  [ "$actual" = "$expected_tip" ] || { echo no; return 0; }
  dirty=$(worktree_dirty_count "$path") || { echo unknown; return 0; }
  [ "$dirty" -eq 0 ] || { echo no; return 0; }
  gitdir=$(worktree_gitdir "$path") || { echo unknown; return 0; }
  [ ! -f "$gitdir/locked" ] || { echo no; return 0; }
  echo yes
}

# Remove only a clean, unchanged non-primary worktree. This is the shared
# implementation for drain's OPEN/no-PR directory action.
remove_worktree_safe() {
  local repo="$1" path="$2" branch="$3" expected_tip="$4" verified
  local primary gitdir lock
  primary=$(worktree_primary_path "$repo") || {
    echo "refusing $branch: primary worktree could not be determined" >&2
    return 1
  }
  [ "$path" != "$primary" ] || {
    echo "refusing $branch: primary worktree is never removed" >&2
    return 1
  }
  gitdir=$(worktree_gitdir "$path") || {
    echo "refusing $branch: worktree metadata could not be read" >&2
    return 1
  }
  if [ -f "$gitdir/locked" ]; then
    lock=$(lock_status "$gitdir/locked") || return 1
    case "$lock" in
      stale) git -C "$repo" worktree unlock "$path" ;;
      *) echo "refusing $branch: worktree lock is $lock" >&2; return 1 ;;
    esac
  fi
  verified=$(verify_worktree_unchanged "$repo" "$path" "$branch" "$expected_tip")
  [ "$verified" = yes ] || {
    echo "refusing $branch: worktree changed or is not clean ($verified)" >&2
    return 1
  }
  git -C "$repo" worktree remove -- "$path"
}

# Convert a full local or remote ref into its branch name without losing slash-
# separated branch components. For example, refs/remotes/origin/release/next
# becomes release/next, not just next.
base_branch_from_ref() {
  local ref="$1" remainder
  case "$ref" in
    refs/heads/*) printf '%s\n' "${ref#refs/heads/}" ;;
    refs/remotes/*/*)
      remainder="${ref#refs/remotes/}"
      printf '%s\n' "${remainder#*/}"
      ;;
    refs/remotes/*) return 1 ;;
    *) printf '%s\n' "$ref" ;;
  esac
}

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
  # A missing /proc/<pid> only proves the process is gone when procfs itself
  # is mounted. In a container or chroot without /proc, EVERY pid looks absent,
  # which would turn every live lock into "stale" - i.e. into a deletion. Probe
  # procfs first and report "unknown" when it isn't there.
  if [ ! -d "/proc/self" ]; then echo "unknown"; return; fi
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

# Finds a worktree path from the shared NUL-safe snapshot. Paths containing
# spaces, tabs, and newlines remain intact.
worktree_path_for_branch() {
  local want="$1" repo="${2:-}" i
  [ -n "$repo" ] || repo=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  worktree_snapshot "$repo" || return 1
  for i in "${!WORKTREE_BRANCHES[@]}"; do
    if [ "${WORKTREE_BRANCHES[$i]}" = "$want" ]; then
      printf '%s\n' "${WORKTREE_PATHS[$i]}"
      return 0
    fi
  done
}

# Number of changed (modified, staged, deleted, or untracked) paths.
worktree_dirty_count() {
  local wt="$1" tmp entry count=0 status
  [ -n "$wt" ] && [ -d "$wt" ] || { echo 0; return; }
  tmp=$(mktemp) || { echo "error: could not create a status snapshot" >&2; return 1; }
  if git -C "$wt" status --porcelain=v1 -z >"$tmp"; then
    :
  else
    status=$?
    echo "error: git status failed for $wt (exit $status)" >&2
    rm -f "$tmp"
    return "$status"
  fi
  while IFS= read -r -d '' entry; do
    [ -n "$entry" ] || continue
    count=$((count + 1))
    case "${entry:0:2}" in
      R*|*R|C*|*C) IFS= read -r -d '' || true ;;
    esac
  done <"$tmp"
  rm -f "$tmp"
  echo "$count"
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

# Echoes the singular merge-base of two refs, or nothing on error. Runs every
# git call with -C "$1" so the result never depends on the caller's cwd. In a
# criss-cross history there are MULTIPLE merge bases; singular `git merge-base`
# does not error — it picks one arbitrarily, which would score against a
# possibly-wrong base. Count with --all first and treat >1 base as unknown.
# Echoes the base OID on success.
merge_base() {
  local repo="$1" base="$2" branch="$3" n
  n=$(git -C "$repo" merge-base --all "$base" "$branch" 2>/dev/null | wc -l)
  # >1 base = criss-cross history; singular merge-base would pick one
  # arbitrarily and score against a possibly-wrong base. Treat as unknown.
  [ "$n" -eq 1 ] || return 1
  git -C "$repo" merge-base "$base" "$branch" 2>/dev/null
}

# Sums net text lines from numstat input (added-minus-deleted). Echoes a string
# on one line:
#   "N"            - the net line delta, when every row is a normal text row.
#   "UNSCORED <why>" - a `- -` (binary) or `0 0` (mode-only) row appeared.
# Reads each row TAB-aware: numstat emits `add<TAB>del<TAB>path`; a naive
# "${row##*$'\t'}" grabs the pathname, not the delete count.
numstat_net() {
  local total=0 row a d
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r a d _ <<< "$row"
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
  mb=$(merge_base "$repo" "$base" "$branch") || { echo "UNKNOWN no-merge-base"; return; }
  [ -n "$mb" ] || { echo "UNKNOWN no-merge-base"; return; }

  # O: net text lines on the branch from its merge base.
  out=$(git -C "$repo" diff --no-ext-diff --no-textconv --numstat --no-renames "$mb" "$branch" 2>/dev/null) || { echo "UNKNOWN branch-diff-failed"; return; }
  O=$(numstat_net <<< "$out")
  # numstat_net already returns the documented "UNSCORED <why>" shape - echo it
  # verbatim. Decorating it here (a suffix on one path, a second "UNSCORED "
  # prefix on the other) produced three different strings for one verdict and
  # broke the contract the coverage-score CLI publishes to its consumers.
  case "$O" in
    UNSCORED*) { echo "$O"; return; } ;;
  esac
  [ "$O" -gt 0 ] || { echo "UNSCORED no-text-rows"; return; }

  # Simulated merge + residual diff in ONE subprocess so the synthesized tree
  # stays reachable. Capture merge-tree's rc separately from its output, then
  # run the diff only on success — all inside a subshell that keeps the object
  # dir live. merge-tree rc 1 = conflict, >1 = error -> UNKNOWN.
  local obj alt base_oid mtrc tree residual had_errexit=0
  obj=$(mktemp -d) || { echo "UNKNOWN no-temp-dir"; return; }
  alt=$(git -C "$repo" rev-parse --path-format=absolute --git-path objects 2>/dev/null)
  [ -n "$alt" ] || { rm -rf "$obj"; echo "UNKNOWN no-object-dir"; return; }
  base_oid=$(git -C "$repo" rev-parse "$base" 2>/dev/null)
  # Restore the caller's errexit rather than forcing it on: lib.sh is sourced
  # by consumers that deliberately run without `set -e`, and leaving errexit
  # armed behind us turns their next tolerated failure into an abort.
  case "$-" in *e*) had_errexit=1 ;; esac
  set +e
  residual=$(
    tree=$(GIT_OBJECT_DIRECTORY="$obj" GIT_ALTERNATE_OBJECT_DIRECTORIES="$alt" \
      git -C "$repo" merge-tree --write-tree "$base" "$branch" 2>/dev/null)
    mtrc=$?
    echo "RC=$mtrc"
    # An empty tree with rc 0 must NOT fall through: exiting 0 here would leave
    # an empty residual, which parses as R=0 and fails open to SCORED 100.
    if [ "$mtrc" -ne 0 ] || [ -z "$tree" ]; then
      [ "$mtrc" -ne 0 ] && exit "$mtrc"
      exit 2
    fi
    GIT_OBJECT_DIRECTORY="$obj" GIT_ALTERNATE_OBJECT_DIRECTORIES="$alt" \
      git -C "$repo" diff --no-ext-diff --no-textconv --numstat --no-renames "$base_oid" "$tree" 2>/dev/null
  )
  rc=$?
  [ "$had_errexit" -eq 1 ] && set -e
  rm -rf "$obj"
  mtrc=$(printf '%s\n' "$residual" | grep -o '^RC=[0-9]*' | head -1 | cut -d= -f2)
  residual=$(printf '%s\n' "$residual" | grep -v '^RC=[0-9]*' || true)
  if [ "${mtrc:-0}" -eq 1 ]; then { echo "UNKNOWN merge-conflict"; return; }; fi
  if [ "${mtrc:-0}" -gt 1 ] || [ "$rc" -gt 1 ]; then { echo "UNKNOWN merge-tree-error"; return; }; fi

  R=$(numstat_net <<< "$residual")
  case "$R" in
    UNSCORED*) { echo "$R"; return; } ;;
  esac

  # R is a NET line count, so it goes negative when the branch's own deletions
  # are missing from base (base ends up with more lines than the merged tree).
  # Subtracting a negative R inflated the score past O - a branch whose deletion
  # never shipped scored SCORED 111 and cleared the 95% bar. Residual work is
  # residual work whichever direction it points, so score against its magnitude
  # and clamp to the documented 0-100 range.
  local absR="${R#-}"
  num=$(( O - absR )); [ "$num" -lt 0 ] && num=0
  local pct=$(( num * 100 / O )); [ "$pct" -gt 100 ] && pct=100
  echo "SCORED $pct"
}

# Echoes the base-10 integer value, or "invalid". Strict decimal: rejects
# leading zeros ("08" is invalid, not 8 — a bare Bash arithmetic read would
# treat it as octal and silently change its meaning). Never emits a non-numeric
# string that a caller could feed to $(( )).
validate_pct() {
  local val="$1"
  case "$val" in
    ''|*[!0-9]*) echo invalid; return ;;
    # a leading zero with more than one digit is octal-looking -> invalid
    '0'*) [ "$val" = "0" ] || { echo invalid; return; } ;;
  esac
  # Reject anything too long to be a percentage BEFORE the arithmetic read:
  # $(( )) wraps modulo 2^64, so 18446744073709551616 would evaluate to 0 and
  # validate as a legal threshold - turning a nonsense value into "archive
  # everything" rather than into the intended rejection.
  [ "${#val}" -le 3 ] || { echo invalid; return; }
  local n
  n=$((val))            # safe: matched ^[0-9]+$ with no leading zero
  if [ "$n" -ge 0 ] && [ "$n" -le 100 ]; then echo "$n"; else echo invalid; fi
}

# Resolve the content-landing threshold from WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD.
# Echoes 1-100; unset gives 95. An invalid value (or 0, which would pass
# SCORED 0, a branch provably NOT in base) warns on stderr and falls back to 95.
content_merge_threshold() {
  local t
  if [ -z "${WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD+x}" ]; then echo 95; return; fi
  t=$(validate_pct "$WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD")
  if [ "$t" = invalid ] || [ "$t" = 0 ]; then
    echo "  (skipped: WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD must be an integer 1-100 with no leading zero, got '$WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD')" >&2
    t=95
  fi
  echo "$t"
}

# Containment primitive over coverage_score: did the branch's content land in
# base? Echoes "<yes|no|unknown>\t<coverage verdict>". yes means SCORED at or
# above the threshold; no means SCORED below it; UNSCORED and UNKNOWN are
# unknown, since neither proves the work shipped.
content_landed() {
  local repo="$1" base="$2" branch="$3" threshold="$4" score pct
  score=$(coverage_score "$repo" "$base" "$branch")
  case "$score" in
    SCORED*)
      pct="${score#SCORED }"
      if [[ "$pct" =~ ^[0-9]+$ ]] && [ "$pct" -ge "$threshold" ]; then
        printf 'yes\t%s\n' "$score"
      else
        printf 'no\t%s\n' "$score"
      fi ;;
    *) printf 'unknown\t%s\n' "$score" ;;
  esac
}
