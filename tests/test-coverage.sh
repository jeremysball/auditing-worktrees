#!/usr/bin/env bash
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
source "$BIN/lib.sh"

SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
T="$SCRATCH/repo"; mkdir -p "$T"; cd "$T"
git init -q -b main .
git config user.email t@t.t; git config user.name t
echo base > f; git add -A; git commit -qm base

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "=== 1. fully merged (literal ancestor) -> SCORED ~100 ==="
git checkout -qb feat main
echo feature > feat.txt; git add -A; git commit -qm feat
git checkout -q main
# A literal ancestor merge makes merge-base == branch tip -> O == 0 -> UNSCORED
# (the O==0 rule), so "fully merged content" is landed on main directly: the
# branch is no longer an ancestor but every line it added is in base -> R == 0.
echo feature > feat.txt; git add -A; git commit -qm "feat landing"
out=$(coverage_score "$PWD" main feat)
[[ "$out" == SCORED* ]] && ok "scored" || bad "not scored: $out"
[[ "$out" == "SCORED 100" ]] && ok "100% coverage" || bad "coverage was '$out'"

echo "=== 2. genuinely unmerged -> SCORED 0 ==="
git checkout -qb other main
echo other > other.txt; git add -A; git commit -qm other
git checkout -q main
out=$(coverage_score "$PWD" main other)
[[ "$out" == "SCORED 0" ]] && ok "0% coverage" || bad "coverage was '$out'"

echo "=== 3. squash-merged (no ancestor) -> SCORED high ==="
git checkout -qb sq main
echo sq-work > sq.txt; git add -A; git commit -qm sq-work
git checkout -q main
git cherry-pick -q "$(git rev-parse sq)" 2>/dev/null || {
  # if cherry-pick isn't available, simulate: commit the same content fresh
  echo sq-work > sq.txt; git add -A; git commit -qm "sq landing"
}
out=$(coverage_score "$PWD" main sq)
[[ "$out" == SCORED* ]] && ok "squash scored" || bad "squash not scored: $out"
[[ "${out#SCORED }" -ge 80 ]] && ok "squash high coverage (${out#SCORED })" || bad "squash low: $out"

echo "=== 4. binary-only change -> UNSCORED ==="
git checkout -qb bin main
printf '\x00\x01\x02' > blob.bin; git add -A; git commit -qm binary
git checkout -q main
out=$(coverage_score "$PWD" main bin)
[[ "$out" == UNSCORED* ]] && ok "binary unscored" || bad "binary scored: $out"

echo "=== 5. mode-only change -> UNSCORED ==="
git checkout -qb mode main
touch mod.sh; git add -A; git commit -qm addmod
chmod +x mod.sh; git add -A; git commit -qm chmod
git checkout -q main
out=$(coverage_score "$PWD" main mode)
[[ "$out" == UNSCORED* ]] && ok "mode-only unscored" || bad "mode-only scored: $out"

echo "=== 6. empty diff (no text rows) -> UNSCORED ==="
git checkout -qb empty main
git commit -qm empty --allow-empty
git checkout -q main
out=$(coverage_score "$PWD" main empty)
[[ "$out" == UNSCORED* ]] && ok "O==0 unscored" || bad "O==0 not unscored: $out"

echo "=== 7. criss-cross history (two merge bases) -> UNKNOWN ==="
git checkout -qb A main
echo A1 > a.txt; git add -A; git commit -qm A1
A1=$(git rev-parse A)
git checkout -q main
echo M1 > m.txt; git add -A; git commit -qm M1
git checkout -q A; git merge -q --no-ff main      # A absorbs main's M1
git checkout -q main; git merge -q --no-ff "$A1"  # main absorbs the ORIGINAL A1
echo A2 > a.txt; git checkout -q A; git add -A; git commit -qm A2
echo M2 > m2.txt; git checkout -q main; git add -A; git commit -qm M2
n=$(git merge-base --all main A | wc -l)
[ "$n" -gt 1 ] && ok "criss-cross produced $n merge bases" || bad "expected >1 merge bases, got $n"
out=$(coverage_score "$PWD" main A)
[[ "$out" == UNKNOWN* ]] && ok "criss-cross unknown" || bad "criss-cross scored: $out"

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
