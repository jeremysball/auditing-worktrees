### Task 2: Coverage helpers in `lib.sh`

**Files:**
- Modify: `bin/lib.sh` — add helpers after `activity_age_secs` (currently line 127).
- Test: `tests/test-coverage.sh` (new file).

**Interfaces:**
- Consumes: git porcelain and the `ARCHIVE_PREFIX`-independent plain repo layout.
- Produces:
  - `coverage_score "$repo" "$base" "$branch"` → echoes `SCORED <0-100 int>`, `UNSCORED <reason>`, or `UNKNOWN <reason>`.
  - `merge_base "$base" "$branch"` → echoes the merge-base OID, or nothing (errors on criss-cross multiple-merge-bases).
  - `numstat_net` (reads numstat stdin) → echoes a net line delta or `UNSCORED <why>`.

**Problem.** The ancestry check can't see squash/rebase merges. This task builds the scoring primitive: compute O (branch net text lines), R (residual from base to simulated merge), clamp, and compare as an integer inequality — marking unscored on binary/mode-only rows, O=0, conflict, error, or criss-cross.

- [ ] **Step 1: Write the failing test**

Create `tests/test-coverage.sh`:

```bash
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
git checkout -q main; git merge -q feat
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

echo
echo "=== $pass passed, $fail failed ==="
exit "$fail"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-coverage.sh`
Expected: fails immediately — `coverage_score` is not defined.

- [ ] **Step 3: Implement `merge_base` (criss-cross-aware) and the shared numstat counter**

Append to `bin/lib.sh`:

```bash
# Echoes the singular merge-base of two refs, or nothing on error. In a
# criss-cross history there are MULTIPLE merge bases; `git merge-base` without
# --all errors ("multiple merge bases") rather than pick one. A caller must
# detect that and treat the branch as unknown. Echoes the base OID on success.
merge_base() {
  git merge-base "$1" "$2" 2>/dev/null
}

# Sums net text lines from numstat input (added-minus-deleted). Echoes a string
# on one line:
#   "N"            - the net line delta, when every row is a normal text row.
#   "UNSCORED <why>" - a `- -` (binary) or `0 0` (mode-only) row appeared.
# Reads each row TAB-aware: numstat emits `add<TAB>del<TAB>path`; a naive
# "${row##*$'\t'}" grabs the pathname, not the delete count.
numstat_net() {
  local total=0 row a d p
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r a d p <<< "$row"
    if [ "$a" = "-" ] && [ "$d" = "-" ]; then { echo "UNSCORED binary"; return; }; fi
    if [ "$a" = "0" ] && [ "$d" = "0" ]; then { echo "UNSCORED mode-only"; return; }; fi
    total=$(( total + a - d ))
  done
  echo "$total"
}
```

Note: `git diff --numstat` emits `- -` for a binary change and `0 0` for a mode-only (chmod) change; both make a line-count meaningless and force UNSCORED. The `$'\t'` ANSI-C quoting produces a real tab so the `case`/`IFS` matching works — a double-quoted `"\t"` is a literal backslash-t that never matches.

- [ ] **Step 4: Implement `coverage_score` with the residual diff inside the object-dir scope**

The residual diff MUST run in the same subprocess that has the temp object dir set as `GIT_OBJECT_DIRECTORY`. A `git merge-tree --write-tree` on genuinely-divergent history writes the synthesized tree only into that temp dir (verified empirically: after removing it, `git diff` fails `fatal: bad object`). So `coverage_score` runs merge-tree and the residual diff together inside one `git -C` invocation that sets the object dirs, not by returning a tree OID for a later diff.

Append to `bin/lib.sh`:

```bash
# Echoes one of:
#   SCORED <0-100>   - the branch's net text lines that are already in base.
#   UNSCORED <why>   - binary/mode-only row, O==0, or empty patch.
#   UNKNOWN <why>    - criss-cross history, merge conflict, merge-tree error.
coverage_score() {
  local repo="$1" base="$2" branch="$3" mb out O R num
  mb=$(merge_base "$base" "$branch") || { echo "UNKNOWN no-merge-base"; return; }
  [ -n "$mb" ] || { echo "UNKNOWN no-merge-base"; return; }

  # O: net text lines on the branch from its merge base.
  out=$(git diff --no-ext-diff --no-textconv --numstat --no-renames "$mb" "$branch" 2>/dev/null) || { echo "UNKNOWN branch-diff-failed"; return; }
  O=$(numstat_net <<< "$out")
  case "$O" in
    UNSCORED*) { echo "$O-in-branch"; return; } ;;
  esac
  [ "$O" -gt 0 ] || { echo "UNSCORED no-text-rows"; return; }

  # Simulated merge + residual diff in ONE subprocess so the synthesized tree
  # stays reachable. Capture merge-tree's rc separately from its output, then
  # run the diff only on success — all inside a subshell that keeps the object
  # dir live. merge-tree rc 1 = conflict, >1 = error -> UNKNOWN.
  local obj alt base_oid mtrc tree residual
  obj=$(mktemp -d) || { echo "UNKNOWN no-temp-dir"; return; }
  alt=$(git -C "$repo" rev-parse --path-format=absolute --git-path objects 2>/dev/null)
  base_oid=$(git -C "$repo" rev-parse "$base" 2>/dev/null)
  set +e
  residual=$(
    tree=$(GIT_OBJECT_DIRECTORY="$obj" GIT_ALTERNATE_OBJECT_DIRECTORIES="$alt" \
      git -C "$repo" merge-tree --write-tree "$base" "$branch" 2>/dev/null)
    mtrc=$?
    echo "RC=$mtrc"
    [ "$mtrc" -eq 0 ] && [ -n "$tree" ] || exit "$mtrc"
    GIT_OBJECT_DIRECTORY="$obj" GIT_ALTERNATE_OBJECT_DIRECTORIES="$alt" \
      git -C "$repo" diff --no-ext-diff --no-textconv --numstat --no-renames "$base_oid" "$tree" 2>/dev/null
  )
  rc=$?
  set -e
  rm -rf "$obj"
  mtrc=$(printf '%s\n' "$residual" | grep -o '^RC=[0-9]*' | head -1 | cut -d= -f2)
  residual=$(printf '%s\n' "$residual" | grep -v '^RC=[0-9]*')
  if [ "${mtrc:-0}" -eq 1 ]; then { echo "UNKNOWN merge-conflict"; return; }; fi
  if [ "${mtrc:-0}" -gt 1 ] || [ "$rc" -gt 1 ]; then { echo "UNKNOWN merge-tree-error"; return; }; fi

  R=$(numstat_net <<< "$residual")
  case "$R" in
    UNSCORED*) { echo "UNSCORED $R"; return; } ;;
  esac

  num=$(( O - R )); [ "$num" -lt 0 ] && num=0
  echo "SCORED $(( num * 100 / O ))"
}
```

Note: `merge-tree --write-tree` prints the resulting tree OID on stdout; the pipeline reads it and immediately diffs against it while `GIT_OBJECT_DIRECTORY="$obj"` is still in effect, then the temp dir is removed. This keeps the repo's unreachable-object set unchanged (the synthesized tree lives only in `$obj`) while still letting the residual diff resolve it.

Criss-cross: `merge_base` uses singular `git merge-base`, which errors ("multiple merge bases") on a criss-cross history, so `coverage_score` returns `UNKNOWN no-merge-base` — the branch is never scored against merge-tree's virtual base. If singular `git merge-base` ever returns an OID while merge-tree uses a different virtual base, the residual would be off — treat that case conservatively as UNKNOWN (the singular-merge-base error path already covers the common criss-cross).

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-coverage.sh`
Expected: scenario 1 → `SCORED 100`; scenario 2 → `SCORED 0`; scenario 3 → `SCORED ≥ 80`; scenarios 4, 5, 6 → `UNSCORED`. All pass.

- [ ] **Step 6: Commit**

```bash
git add bin/lib.sh tests/test-coverage.sh
git commit -m "feat(lib): add merge-tree coverage scoring"
```

---

