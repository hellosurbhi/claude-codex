# shellcheck shell=bash
# Sourced by tests/test-checkers.sh. Makes every throwaway fixture repo independent of the machine it runs on.
# WHY (r29): the global hooks directory is injected through GIT_CONFIG_PARAMETERS (and user/system config), so a plain `git commit` in a
# fixture ran the real pre-commit gates ("Deterministic gates passed.") and could block on a missing Verified: line. That made results depend
# on the machine and on the commit message wording. Dropping the injected config, pointing global config at /dev/null and supplying the
# identity from the environment keeps fixtures hook-free and identical everywhere. Do not rely on user git config inside a test.
unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_EXTERNAL_DIFF GIT_DIFF_OPTS
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
