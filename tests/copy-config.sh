#!/usr/bin/env bash
# Usage: copy-config.sh <dest-dir>   copies reviewer.sh and its lib/ into <dest-dir>/scripts for the production-mutation test.
# WHY ${SPY_CONFIG_DIR:-$HOME/.claude/config}: the suite's prerequisite check and the launcher already honor SPY_CONFIG_DIR;
# copying from $HOME alone made an otherwise valid override fail (cc11-main-r1). Breaking this makes the suite need the real HOME.
set -euo pipefail
src="${SPY_CONFIG_DIR:-$HOME/.claude/config}/scripts"
dest="${1:?usage: copy-config.sh <dest-dir>}"
mkdir -p "$dest/scripts"
cp "$src/reviewer.sh" "$dest/scripts/"
cp -R "$src/lib" "$dest/scripts/lib"
