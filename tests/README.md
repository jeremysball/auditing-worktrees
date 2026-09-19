# Tests

Run everything:

```bash
tests/run-all.sh
```

It runs every `test-*.sh` and `smoke-*.sh` and exits 1 if any suite fails.
Each suite builds its own throwaway repos under `mktemp -d`.

`env.sh` is sourced by every suite. It points `GIT_CONFIG_GLOBAL` at
`/dev/null` so your global git hooks, signing, and templates never reach a
fixture repo. Source it from any new suite, right after `set -uo pipefail`.

## The audit smoke test and its golden file

`smoke-audit.sh` runs the real `bin/audit-worktrees.sh` over a fixture repo
and diffs the whole report against `golden/audit.txt`. Scratch paths become
`<SCRATCH>` and idle ages become `<AGE>`, so the output is stable across runs.

A failure means the report changed. Read the diff and decide which case it is.

**The change is a bug.** Fix the code. Leave the golden file alone.

**The change is intended** (a new bucket, reworded line, new field). Update
the golden file in the same commit as the code change:

```bash
tests/smoke-audit.sh --update   # rewrites golden/audit.txt from the current code
git diff tests/golden/audit.txt # review every changed line before staging
tests/smoke-audit.sh            # passes
```

Say in the commit message which report lines changed and why. A golden
update with no explanation reads like the test was silenced.

**Generating the golden from a known-good version.** When a refactor must not
change output, build the golden from the version you trust instead of the one
under test. `AUDIT_BIN` overrides which `bin/` the smoke test runs:

```bash
git worktree add --detach /tmp/aw-base origin/main
AUDIT_BIN=/tmp/aw-base/bin tests/smoke-audit.sh --update
tests/smoke-audit.sh            # now checks the new code against main's output
git worktree remove /tmp/aw-base
```

**Committing.** The report contains em dashes, and the golden file must match
it byte for byte. The global pre-commit dash check will block it. Bypass that
check for this commit only:

```bash
SKIP_DASH_CHECK=1 git commit
```

Never reword the golden to get past the hook. That changes what the test
expects, not what the program prints.
