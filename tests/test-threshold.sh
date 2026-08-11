#!/usr/bin/env bash
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
source "$BIN/lib.sh"

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "=== 1. a bare integer is accepted ==="
[ "$(validate_pct 95)" = "95" ] && ok "95 accepted" || bad "95 rejected"

echo "=== 2. leading-zero is rejected, not read as octal ==="
[ "$(validate_pct 08)" = "invalid" ] && ok "08 rejected" || bad "08 not rejected"

echo "=== 3. empty is rejected ==="
[ "$(validate_pct "")" = "invalid" ] && ok "empty rejected" || bad "empty not rejected"

echo "=== 4. non-numeric is rejected ==="
[ "$(validate_pct abc)" = "invalid" ] && ok "abc rejected" || bad "abc not rejected"

echo "=== 5. out-of-range (0-100) is rejected ==="
[ "$(validate_pct 101)" = "invalid" ] && ok "101 rejected" || bad "101 not rejected"

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
