#!/usr/bin/env bash
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
CLI="$BIN/coverage-score"

SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
T="$SCRATCH/repo"; mkdir -p "$T"; cd "$T"
git init -q -b main .
git config user.email t@t.t; git config user.name t
echo base > f; git add -A; git commit -qm base

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "=== 1. correct usage -> verdict line on stdout, exit 0 ==="
git checkout -qb feat main
echo feature > feat.txt; git add -A; git commit -qm feat
git checkout -q main
# squash the feature onto main so ancestry fails but coverage scores it high
echo feature > feat.txt; git add -A; git commit -qm "feat landing"
out=$("$CLI" "$PWD" main feat)
rc=$?
[[ $rc -eq 0 ]] && ok "exit 0" || bad "exit was $rc"
[[ "$out" == "SCORED 100" ]] && ok "verdict line: $out" || bad "verdict was '$out'"

echo "=== 2. wrong arg count -> error: + exit 2 ==="
out=$("$CLI" "$PWD" main); rc=$?
[[ $rc -eq 2 ]] && ok "exit 2" || bad "exit was $rc"
[[ "$out" == error:* ]] && ok "error message: $out" || bad "no error message: '$out'"
out=$("$CLI" "$PWD" main feat extra); rc=$?
[[ $rc -eq 2 ]] && ok "exit 2 (4 args)" || bad "exit was $rc"
[[ "$out" == error:* ]] && ok "error message (4 args): $out" || bad "no error message: '$out'"
out=$("$CLI"); rc=$?
[[ $rc -eq 2 ]] && ok "exit 2 (0 args)" || bad "exit was $rc"

echo "=== 3. --help -> usage block, exit 0 ==="
out=$("$CLI" --help); rc=$?
[[ $rc -eq 0 ]] && ok "exit 0" || bad "exit was $rc"
[[ "$out" == *"usage: coverage-score <repo> <base> <branch>"* ]] && ok "usage line" || bad "no usage line: '$out'"
[[ "$out" == *"SCORED"* && "$out" == *"UNSCORED"* && "$out" == *"UNKNOWN"* ]] && ok "verdict kinds documented" || bad "verdict kinds missing"
[[ "$out" == *"coverage-score \"\$PWD\" main feature"* ]] && ok "example present" || bad "no example"

echo "=== 4. unknown flag -> error: unknown flag + exit 2 ==="
out=$("$CLI" --bogus "$PWD" main feat); rc=$?
[[ $rc -eq 2 ]] && ok "exit 2" || bad "exit was $rc"
[[ "$out" == "error: unknown flag --bogus" ]] && ok "message: $out" || bad "message was '$out'"

echo "=== 5. UNSCORED verdict is a successful run (exit 0) ==="
git checkout -qb bin main
printf '\x00\x01\x02' > blob.bin; git add -A; git commit -qm binary
git checkout -q main
out=$("$CLI" "$PWD" main bin); rc=$?
[[ $rc -eq 0 ]] && ok "exit 0 on UNSCORED" || bad "exit was $rc"
[[ "$out" == "UNSCORED"* ]] && ok "verdict: $out" || bad "verdict was '$out'"

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
