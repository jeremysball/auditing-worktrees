### Task 6: SessionStart hook — anchored parsers and explicit timeout

**Files:**
- Modify: `bin/session-hook.sh` — the awk parsers (lines 54-71) and the timeout line (44).
- Test: `tests/test-hook-parse.sh` (new file).

**Interfaces:**
- Consumes: `audit-worktrees.sh` output shape.
- Produces: anchored bucket parsers that do not conflate `likely-content-merged` with `content-merged`; an explicit timeout notice instead of silent whole-report swallow.

**Problem.** The awk substring matches (`/safe-to-clean/`, etc.) conflate a branch description that mentions a bucket name with the heading. A `likely-content-merged` heading would be caught by a bare `/content-merged/` match for the wrong bucket. And the `timeout` at line 44 exits silently on timeout, indistinguishable from "nothing to report."

**Keep the content pass out of the hook.** The hook must call `audit-worktrees.sh` with `--no-content` (from Task 3) so the expensive merge-tree pass never runs inside its 15s window.

- [ ] **Step 1: Write the failing test**

Create `tests/test-hook-parse.sh`. The test sources the REAL parser (`bin/summary-parser.sh`, added in Step 3) so it exercises production code, not a hand-copied awk program:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-hook-parse.sh`
Expected: with a bare `/content-merged/` matcher the branch line `content-merged (work already in base...)` would match before the heading logic resets `m`; the anchored matcher in Step 3 fixes it. Run once to see it fail, then fix.

- [ ] **Step 3: Extract the summary parser into a sourced unit**

Create `bin/summary-parser.sh` — a sourced file exposing `summary_parse`. The parser is anchored to heading position (exactly two leading spaces + the bucket name + colon), so a branch description that merely *contains* the word `content-merged` (four-space indent) can never set the bucket. This makes the parser a real tested unit rather than an inline awk that the test can only copy.

```bash
#!/usr/bin/env bash
# Sources, don't execute. summary_parse "$report" collapses a multi-repo audit
# report into one line per repo with per-bucket counts. Bucket headings are
# matched structurally (two-space indent + name + colon) so a branch description
# that mentions a bucket name can never set the current bucket.
#
# Usage: summary=$(summary_parse "$out")

summary_parse() {
  printf '%s\n' "$1" | awk '
    /^=== / { if (repo != "") emit(); repo=$2; s=t=a=h=cm=0; next }
    /^  safe-to-clean/           { m="s"; next }
    /^  needs-triage/            { m="t"; next }
    /^  archaeology/             { m="a"; next }
    /^  hands-off/               { m="h"; next }
    /^  likely-content-merged/   { m="cm"; next }
    /^  \(/                      { m="" }
    /^    / { if (m=="s") s++; else if (m=="t") t++; else if (m=="a") a++; else if (m=="h") h++; else if (m=="cm") cm++ }
    function emit(   parts) {
      parts=""
      if (t) parts = parts sprintf("%d triage, ", t)
      if (cm) parts = parts sprintf("%d content-merged, ", cm)
      if (a) parts = parts sprintf("%d archaeology, ", a)
      if (s) parts = parts sprintf("%d safe-to-clean, ", s)
      if (h) parts = parts sprintf("%d hands-off, ", h)
      if (parts != "") { sub(/, $/, "", parts); printf "  %s: %s\n", repo, parts }
    }
    END { if (repo != "") emit() }
  '
}
```

Then in `session-hook.sh`, replace the inline awk (lines 54-71) with a source + call:

```bash
# shellcheck source=summary-parser.sh
source "$(dirname "${BASH_SOURCE[0]}")/summary-parser.sh"
...
  summary=$(summary_parse "$out")
```

The heading matchers require exactly two leading spaces and the bucket name before the colon; a branch line (`    ...` — four spaces) is only counted under whatever heading `m` currently holds.

- [ ] **Step 4: Pass `--no-content` and surface the timeout explicitly**

Replace the timeout line (line 44):

```bash
out=$(timeout "$TIMEOUT" "$AUDIT" --no-content "$root" 2>/dev/null)
rc=$?
if [ "$rc" -eq 124 ]; then
  jq -n --arg ctx "Worktree audit exceeded its ${TIMEOUT}s budget in $(basename "$root") and was skipped. Run the auditing-worktrees skill manually for the full report." \
    '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$ctx}}'
  exit 0
fi
[ "$rc" -ne 0 ] && exit 0
[ -n "$out" ] || exit 0
```

(124 is `timeout`'s exit when the command exceeds the budget; any other nonzero still exits silently per the fail-silent contract. `--no-content` keeps the merge-tree pass out of the hook's window; the on-demand skill invocation omits the flag for full content awareness.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-hook-parse.sh`
Expected: the content-merged heading is counted, and the branch description mentioning `content-merged` no longer resets the bucket. All assertions pass.

- [ ] **Step 6: Commit**

```bash
git add bin/session-hook.sh tests/test-hook-parse.sh
git commit -m "fix(hook): anchor bucket parsers and surface the audit timeout"
```

---

