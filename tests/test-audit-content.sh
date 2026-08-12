#!/usr/bin/env bash
# Exercises audit-worktrees.sh's content-aware classification in a throwaway
# repo: squash-merged branches land in likely-content-merged, --no-content
# skips the coverage pass, and unscored/unknown branches route to
# needs-triage (never archaeology, never clean-safe).
# Usage: tests/test-audit-content.sh   (exits non-zero on any failure)
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"

SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
T="$SCRATCH/repo"; mkdir -p "$T"; cd "$T"
git init -q -b main .
git config user.email t@t.t; git config user.name t
echo base > f; git add -A; git commit -qm base
OLD=$(date -d "3 hours ago" --iso-8601=seconds)

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "=== 1. squash-merged branch reports as likely-content-merged ==="
git checkout -qb sq main
echo sq > sq.txt; git add -A
GIT_COMMITTER_DATE="$OLD" GIT_AUTHOR_DATE="$OLD" git commit -qm sq
SQ_OID=$(git rev-parse sq)   # capture the branch tip BEFORE we detach it
git checkout -q main
echo sq > sq.txt; git add -A; git commit -qm "sq landing on main"
# Re-create `sq` pointing at its ORIGINAL (now-unmerged) commit so the report
# sees a non-ancestor branch whose content is already in main. Reattaching the
# captured OID directly is deterministic; searching history by message after
# deleting the branch can select the landing commit (making sq a literal
# ancestor) or nothing at all.
git branch -D -q sq
git branch sq "$SQ_OID"
out=$("$BIN/audit-worktrees.sh" "$T")
printf '%s' "$out" | grep -q "likely-content-merged" && ok "content-merged bucket present" || bad "no content-merged bucket: $out"
printf '%s' "$out" | grep -q "content-merged (work already in base" && ok "sq listed under content-merged" || bad "sq not under content-merged: $out"
printf '%s' "$out" | grep -q "needs-triage" && bad "sq leaked into needs-triage: $out" || ok "sq not in needs-triage"

echo "=== 2. --no-content skips the coverage pass (ancestry-only) ==="
out=$("$BIN/audit-worktrees.sh" --no-content "$T")
printf '%s' "$out" | grep -q "likely-content-merged" && bad "content bucket present with --no-content: $out" || ok "no content bucket with --no-content"
printf '%s' "$out" | grep -q "needs-triage" && ok "sq back in needs-triage without content pass" || bad "sq missing from needs-triage: $out"

echo "=== 3. genuinely unmerged branch stays in needs-triage (SCORED 0) ==="
git checkout -qb other main
echo other > other.txt; git add -A
GIT_COMMITTER_DATE="$OLD" GIT_AUTHOR_DATE="$OLD" git commit -qm other
git checkout -q main
out=$("$BIN/audit-worktrees.sh" "$T")
printf '%s' "$out" | grep -q "needs-triage" && ok "other in needs-triage" || bad "other not in needs-triage: $out"
printf '%s' "$out" | grep -q "other" && ok "other named in report" || bad "other missing from report: $out"
# The SCORED 0 must be surfaced, not dropped: a below-threshold score proves the
# work is NOT in base, which is the strongest "genuinely outstanding" signal the
# report can give. A bare "unmerged" (no score) would hide that distinction.
printf '%s' "$out" | grep -q "SCORED 0" && ok "SCORED 0 surfaced for genuinely-unmerged branch" || bad "SCORED 0 not surfaced: $out"

echo "=== 4. binary-only branch (UNSCORED) routes to needs-triage, never archaeology ==="
# The commit must be archaeology-eligible (older than ARCHAEOLOGY_SECS, never
# pushed) so this scenario actually exercises the unscored-never-archaeology
# ordering: without the `elif [ "$unscored" = true ]` branch, `bin` would land
# in archaeology via the age+no-upstream check, not in needs-triage.
OLD_ARCH=$(date -d "100 days ago" --iso-8601=seconds)
git checkout -qb bin main
printf '\x00\x01\x02' > blob.bin; git add -A
GIT_COMMITTER_DATE="$OLD_ARCH" GIT_AUTHOR_DATE="$OLD_ARCH" git commit -qm binary
git checkout -q main
out=$("$BIN/audit-worktrees.sh" "$T")
printf '%s' "$out" | grep -q "needs-triage" && ok "bin in needs-triage" || bad "bin not in needs-triage: $out"
printf '%s' "$out" | grep -q "archaeology" && bad "bin leaked into archaeology: $out" || ok "bin not in archaeology"

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
