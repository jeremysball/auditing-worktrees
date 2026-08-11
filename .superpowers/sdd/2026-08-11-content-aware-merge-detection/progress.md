# SDD ledger — plan: .superpowers/plans/2026-08-11-content-aware-merge-detection.md
BASE: 47850ad539c4d5620b9f873bd0f82d22f036578f


Task 1: complete (commits 47850ad..a7a3862, review clean — Approved)
  - Minor (addressed): test-lock.sh mode 100644 vs sibling 100755 — chmod +x applied.
  - ⚠️ (addressed): task-1-report.md missing from worktree (lived in ferry overlay) — recovered from taskferry diff; now on disk.
  - Note: taskferry accept partially applied (gitignored .superpowers/sdd/* choked 3-way merge); production files bin/lib.sh + tests/test-lock.sh manually applied + committed as a7a3862, test verified 5/5.
