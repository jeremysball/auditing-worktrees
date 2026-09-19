# Sourced by every test. Isolates fixture repos from the invoking user's git
# config: global hooks (primary-checkout guard, Conventional Commits check),
# signing, and templates would otherwise block fixture commits, and every
# suite would fail for reasons unrelated to the code under test.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.t
