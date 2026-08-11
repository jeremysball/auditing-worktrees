### Task 7: Threshold config validation

**Files:**
- Modify: `bin/lib.sh` — add a `validate_pct` helper; `bin/audit-worktrees.sh` — use it for `CONTENT_MERGE_THRESHOLD`.
- Test: `tests/test-threshold.sh` (new file).

**Interfaces:**
- Consumes: env var `WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD`.
- Produces: `validate_pct "$val"` echoes the base-10 value or `invalid`; the audit treats an invalid threshold as a defined outcome (unknown classification), never a silent octal/abort.

**Problem.** Bash reads a leading-zero string (`08`) as octal and aborts or misbehaves at compare time. Validation must happen at parse time and produce a defined outcome.

- [ ] **Step 1: Write the failing test**

Create `tests/test-threshold.sh`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-threshold.sh`
Expected: fails — `validate_pct` is not defined.

- [ ] **Step 3: Implement `validate_pct` in `lib.sh`**

Append to `bin/lib.sh`:

```bash
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
  local n
  n=$((val))            # safe: matched ^[0-9]+$ with no leading zero
  if [ "$n" -ge 0 ] && [ "$n" -le 100 ]; then echo "$n"; else echo invalid; fi
}
```

- [ ] **Step 4: Use it in `audit-worktrees.sh` (distinguish unset from empty)**

Replace Task 3's hardcoded `CONTENT_MERGE_THRESHOLD=95` with one that distinguishes an **unset** variable (→ default 95, the common case) from an explicitly **set-but-invalid** value (empty string, `08`, `abc`, `101` → defined hard error to stderr + fallback 95, never a silent octal read):

```bash
if [ -z "${WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD+x}" ]; then
  CONTENT_MERGE_THRESHOLD=95                     # unset -> default
else
  CONTENT_MERGE_THRESHOLD=$(validate_pct "$WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD")
  if [ "$CONTENT_MERGE_THRESHOLD" = "invalid" ]; then
    echo "  (skipped: WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD must be an integer 0-100 with no leading zero, got '$WORKTREE_AUDIT_CONTENT_MERGE_THRESHOLD')" >&2
    CONTENT_MERGE_THRESHOLD=95
  fi
fi
```

(An invalid threshold is a defined outcome: the audit prints the misconfiguration to stderr, falls back to 95, and proceeds — never a Bash octal read, never a silently reinterpreted leading-zero value.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-threshold.sh`
Expected: all assertions pass (95 accepted; 08, empty, abc, 101 rejected).

- [ ] **Step 6: Commit**

```bash
git add bin/lib.sh bin/audit-worktrees.sh tests/test-threshold.sh
git commit -m "feat(audit): validate the content-merge threshold strict decimal"
```

---

