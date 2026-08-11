#!/usr/bin/env bash
# Regression tests for the defects found reviewing PR #2. Each case below
# reproduces a specific misclassification the review turned up, so a future
# change that reintroduces one fails here rather than in someone's worktree.
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
source "$BIN/lib.sh"
source "$BIN/summary-parser.sh"

SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "=== 1. residual deletion not in base -> score stays <= 100 ==="
# Branch deletes a file AND adds lines; base squash-lands only the additions.
# The deletion is NOT in base, so the branch must not read as content-merged.
T="$SCRATCH/score"; mkdir -p "$T"; cd "$T"
git init -q -b main .; git config user.email t@t.t; git config user.name t
printf 'l1\n' > f.txt; printf 'x\n' > del.txt; git add -A; git commit -qm base
git checkout -qb feat
git rm -q del.txt; printf 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n' >> f.txt
git add -A; git commit -qm 'delete a file, add lines'
git checkout -q main
printf 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n' >> f.txt; git add -A; git commit -qm 'squash: additions only'
out=$(coverage_score "$T" main feat)
pct="${out#SCORED }"
[[ "$out" == SCORED* ]] && [ "$pct" -le 100 ] \
  && ok "score within 0-100 contract ($out)" || bad "score out of range: $out"
[ "$pct" -lt 95 ] \
  && ok "unshipped deletion keeps it below the archive bar ($out)" \
  || bad "branch with an unshipped deletion scored as content-merged: $out"

echo "=== 2. validate_pct rejects values that overflow the arithmetic read ==="
[ "$(validate_pct 18446744073709551616)" = "invalid" ] \
  && ok "2^64 rejected" || bad "2^64 accepted as $(validate_pct 18446744073709551616)"
[ "$(validate_pct 18446744073709551711)" = "invalid" ] \
  && ok "2^64+95 rejected" || bad "2^64+95 accepted"
[ "$(validate_pct 95)" = "95" ] && ok "95 still valid" || bad "95 rejected"
[ "$(validate_pct 100)" = "100" ] && ok "100 still valid" || bad "100 rejected"
[ "$(validate_pct 0)" = "0" ] && ok "0 still validates as a percentage" || bad "0 rejected by validate_pct"

echo "=== 3. UNSCORED verdicts keep the documented 'UNSCORED <why>' shape ==="
r=$(printf -- '-\t-\tb.dat\n' | numstat_net)
[ "$r" = "UNSCORED binary" ] && ok "numstat_net shape" || bad "numstat_net shape: $r"
T2="$SCRATCH/bin"; mkdir -p "$T2"; cd "$T2"
git init -q -b main .; git config user.email t@t.t; git config user.name t
echo seed > s; git add -A; git commit -qm base
git checkout -qb b; printf '\x00\x01\x02' > blob.bin; git add -A; git commit -qm bin
git checkout -q main; echo other >> s; git add -A; git commit -qm other
out=$(coverage_score "$T2" main b)
[[ "$out" == "UNSCORED binary" ]] \
  && ok "no doubled prefix or -in-branch suffix ($out)" \
  || bad "non-canonical UNSCORED string: $out"

echo "=== 4. coverage_score does not arm errexit in its caller ==="
res=$(bash -c 'source "'"$BIN"'/lib.sh"; set +e; coverage_score "'"$T"'" main feat >/dev/null; case "$-" in *e*) echo leaked;; *) echo clean;; esac')
[ "$res" = "clean" ] && ok "caller errexit preserved" || bad "errexit leaked into caller"
res=$(bash -c 'set -e; source "'"$BIN"'/lib.sh"; coverage_score "'"$T"'" main feat >/dev/null; case "$-" in *e*) echo kept;; *) echo dropped;; esac')
[ "$res" = "kept" ] && ok "caller errexit restored when it was on" || bad "errexit dropped: $res"

echo "=== 5. a relative root scores the same as an absolute one ==="
T3="$SCRATCH/rel"; mkdir -p "$T3/r1"; cd "$T3/r1"
git init -q -b main .; git config user.email t@t.t; git config user.name t
echo base > f; git add -A; git commit -qm base
git checkout -qb sq; echo work >> f; git add -A; git commit -qm work
git checkout -q main; echo work >> f; git add -A; git commit -qm 'squash of sq'
cd "$T3"
abs=$(WORKTREE_AUDIT_INFLIGHT_SECS=0 bash "$BIN/audit-worktrees.sh" "$T3" 2>&1)
rel=$(WORKTREE_AUDIT_INFLIGHT_SECS=0 bash "$BIN/audit-worktrees.sh" . 2>&1)
printf '%s' "$abs" | rg -q 'likely-content-merged' \
  && ok "absolute root classifies content-merged" || bad "absolute root: $abs"
printf '%s' "$rel" | rg -q 'likely-content-merged' \
  && ok "relative root classifies content-merged" || bad "relative root regressed to: $rel"

echo "=== 6. threshold 0 is refused (it would archive provably-unmerged work) ==="
out=$(WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD=0 WORKTREE_AUDIT_INFLIGHT_SECS=0 \
  bash "$BIN/audit-worktrees.sh" "$T3" 2>&1)
printf '%s' "$out" | rg -q 'must be an integer 1-100' \
  && ok "threshold 0 rejected with a stated reason" || bad "threshold 0 accepted: $out"

echo "=== 7. --no-content is honored in any argument position ==="
out=$(WORKTREE_AUDIT_INFLIGHT_SECS=0 bash "$BIN/audit-worktrees.sh" "$T3" --no-content 2>&1)
printf '%s' "$out" | rg -q 'likely-content-merged' \
  && bad "trailing --no-content ignored: $out" || ok "trailing --no-content honored"
out=$(WORKTREE_AUDIT_INFLIGHT_SECS=0 bash "$BIN/audit-worktrees.sh" --no-content "$T3" 2>&1)
printf '%s' "$out" | rg -q 'likely-content-merged' \
  && bad "leading --no-content ignored" || ok "leading --no-content still honored"

echo "=== 8. summary parser attributes every bucket to itself ==="
report='=== /r/one (base: main) ===
  needs-triage:
    feat/y  [idle 5h] — unmerged
  couldn'"'"'t determine merge state (unrelated history / bad ref):
    orphan
  dangling worktree registrations (git worktree prune is safe):
    /some/path
'
sum=$(summary_parse "$report")
printf '%s' "$sum" | rg -q '1 triage' && ok "triage counts only its own lines" || bad "triage miscounted: $sum"
printf '%s' "$sum" | rg -q '1 unknown-merge' && ok "unknown-merge counted" || bad "unknown-merge missing: $sum"
printf '%s' "$sum" | rg -q '3 triage' && bad "other buckets leaked into triage: $sum" || ok "no bucket leak"
sum=$(summary_parse '=== /r/two (base: main) ===
  couldn'"'"'t determine merge state (unrelated history / bad ref):
    orphan
')
[ -n "$sum" ] && ok "unknown-merge-only repo still reported" || bad "unknown-merge-only repo dropped from summary"

echo "=== 9. a content-merged branch reports its uncommitted files ==="
T4="$SCRATCH/dirty"; mkdir -p "$T4/r1"; cd "$T4/r1"
git init -q -b main .; git config user.email t@t.t; git config user.name t
echo base > f; git add -A; git commit -qm base
git checkout -qb sq; echo work >> f; git add -A; git commit -qm work
git checkout -q main; echo work >> f; git add -A; git commit -qm 'squash of sq'
git worktree add -q "$T4/wt" sq 2>/dev/null
echo scratch > "$T4/wt/untracked.txt"
out=$(WORKTREE_AUDIT_INFLIGHT_SECS=0 bash "$BIN/audit-worktrees.sh" "$T4" 2>&1)
if printf '%s' "$out" | rg -q 'content-merged'; then
  printf '%s' "$out" | rg -q 'uncommitted file' \
    && ok "dirty count surfaced on the content-merged line" \
    || bad "dirty detail dropped: $out"
else
  bad "no content-merged bucket to check: $out"
fi

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
