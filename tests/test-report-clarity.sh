#!/usr/bin/env bash
# Report-clarity fixes: the "upstream deleted" scare, invisible primary dirt,
# the silent archive run, and hint-less SCORED/UNSCORED lines.
# Usage: tests/test-report-clarity.sh   (exits non-zero on any failure)
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

# Scratch repos are single-checkout /tmp dirs, never anyone's primary
# checkout: the global primary-checkout gate misfires on them, so bypass it.
export SKIP_PRIMARY_CHECK=1
export WORKTREE_AUDIT_INFLIGHT_SECS=0

SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

new_repo() {
  local d="$1"; mkdir -p "$d"; cd "$d" || exit 1
  git init -q -b main .
  git config user.email t@t.t; git config user.name t
  echo base > f; git add -A; git commit -qm base
}

echo "=== 1. absent tracking ref is labeled as a local fact, never a remote one ==="
new_repo "$SCRATCH/r1"
git checkout -qb gone1 main
echo x > x.txt; git add -A; git commit -qm x
# Point the branch at a remote-tracking ref that does not exist: for-each-ref
# reports upstream:track as [gone], while the commits never left this disk.
# ([gone] requires a remote named origin to exist; nothing is ever fetched.)
git remote add origin /nonexistent-path
git config branch.gone1.remote origin
git config branch.gone1.merge refs/heads/gone1
git checkout -q main
out=$("$BIN/audit-worktrees.sh" "$SCRATCH/r1")
printf '%s' "$out" | grep -q "upstream ref absent locally" && ok "local-fact label present" || bad "label missing: $out"
printf '%s' "$out" | grep -q "upstream deleted" && bad "deleted label leaked back in" || ok "no deleted label"
printf '%s' "$out" | grep -q "upstream gone" && bad "bare gone label leaked back in" || ok "no bare gone label"

echo "=== 1b. the label holds even when the remote branch provably exists ==="
# [gone] is local cache state: a stale tracking ref with a live remote branch
# must still get the label, because the label no longer claims remote absence.
git init -q --bare "$SCRATCH/remote.git"
new_repo "$SCRATCH/r1b"
git remote add origin "$SCRATCH/remote.git"
git push -q origin main
git checkout -qb feat3 main; echo x > x.txt; git add -A; git commit -qm x
git push -q origin feat3
git update-ref -d refs/remotes/origin/feat3   # simulate the stale fetch
git config branch.feat3.remote origin       # tracking configured, never fetched
git config branch.feat3.merge refs/heads/feat3
git checkout -q main
git ls-remote origin feat3 | grep -q "refs/heads/feat3" || { bad "fixture failed: remote lacks feat3"; }
out=$("$BIN/audit-worktrees.sh" "$SCRATCH/r1b")
printf '%s' "$out" | grep -q "feat3.*upstream ref absent locally" \
  && ok "stale-ref branch labeled as local fact" || bad "stale-ref label wrong: $out"

echo "=== 2. dirty primary checkout is reported, clean primary is quiet ==="
new_repo "$SCRATCH/r2"
echo dirty > untracked.txt
out=$("$BIN/audit-worktrees.sh" "$SCRATCH/r2")
printf '%s' "$out" | grep -q "primary checkout (main): 1 uncommitted" \
  && ok "primary dirt reported" || bad "primary dirt missing: $out"
rm untracked.txt
out=$("$BIN/audit-worktrees.sh" "$SCRATCH/r2")
printf '%s' "$out" | grep -q "primary checkout" \
  && bad "primary line printed for clean tree" || ok "clean primary stays quiet"

echo "=== 3. archive always ends with a summary trailer ==="
new_repo "$SCRATCH/r3"
git checkout -qb doomed main; echo x > x; git add -A; git commit -qm x
git checkout -q main
out=$("$BIN/archive-branch.sh" "$SCRATCH/r3" doomed 2>&1); rc=$?
printf '%s' "$out" | grep -q "(archive-branch: 1 archived, 0 skipped, 0 refused)" \
  && ok "success trailer" || bad "success trailer missing: $out"
[ "$rc" -eq 0 ] && ok "success rc 0" || bad "success rc was $rc"
out=$("$BIN/archive-branch.sh" "$SCRATCH/r3" nosuch 2>&1); rc=$?
printf '%s' "$out" | grep -q "(archive-branch: 0 archived, 1 skipped, 0 refused)" \
  && ok "skip trailer" || bad "skip trailer missing: $out"
[ "$rc" -eq 0 ] && ok "skip-only rc 0" || bad "skip-only rc was $rc"

echo "=== 4. score lines state what the number means ==="
new_repo "$SCRATCH/r4"
git checkout -qb other main; echo other > o.txt; git add -A; git commit -qm other
git checkout -q main
out=$("$BIN/audit-worktrees.sh" "$SCRATCH/r4")
printf '%s' "$out" | grep -q "SCORED 0 (only 0% of its lines are in base)" \
  && ok "SCORED hint present" || bad "SCORED hint missing: $out"
git checkout -qb bin main
printf '\x00\x01\x02' > blob.bin; git add -A; git commit -qm binary
git checkout -q main
out=$("$BIN/audit-worktrees.sh" "$SCRATCH/r4")
printf '%s' "$out" | grep -q "UNSCORED binary (binary-only change" \
  && ok "UNSCORED verdict plus hint" || bad "UNSCORED hint missing: $out"

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
