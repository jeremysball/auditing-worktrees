#!/usr/bin/env bash
# Feeds a realistic report body through the real summary parser and checks the
# bucket assignment. Exercises production code, not a copied awk program.
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
# shellcheck source=../bin/summary-parser.sh
source "$BIN/summary-parser.sh"

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

report='=== /tmp/repo (base: main) ===
  likely-content-merged (work already in base under a different hash — batch archive):
    feat/x  (worktree: /tmp/x)  [idle 3h] — content-merged (work already in base, different hash)
  needs-triage:
    feat/y  [idle 5h] — unmerged
'

echo "=== 1. a likely-content-merged heading is counted, not conflated with needs-triage ==="
sum=$(summary_parse "$report")
printf '%s' "$sum" | grep -q "1 content-merged" && ok "content-merged counted" || bad "content-merged not counted: $sum"
# The branch description mentions 'content-merged' but must NOT bump needs-triage
printf '%s' "$sum" | grep -q "1 triage" && ok "triage still counts its own heading" || bad "triage not counted: $sum"
printf '%s' "$sum" | grep -q "2 triage" && bad "branch desc leaked into triage" || ok "branch desc did not leak into triage"

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
