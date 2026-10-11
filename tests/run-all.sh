#!/usr/bin/env bash
# Runs every tests/test-*.sh and exits non-zero if any suite fails.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
failed=()
for t in test-*.sh smoke-*.sh; do
  [ "$t" = test-env.sh ] && continue
  if bash "$t" >/tmp/aw-test.$$ 2>&1; then
    printf 'ok    %s  %s\n' "$t" "$(tail -1 /tmp/aw-test.$$)"
  else
    printf 'FAIL  %s\n' "$t"; sed 's/^/      /' /tmp/aw-test.$$; failed+=("$t")
  fi
done
rm -f /tmp/aw-test.$$
[ "${#failed[@]}" -eq 0 ] || { echo "failed: ${failed[*]}"; exit 1; }
