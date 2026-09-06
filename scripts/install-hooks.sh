#!/usr/bin/env bash
# Point this clone's git at the tracked hooks in .githooks/.
#
# core.hooksPath is local config, not something a clone inherits, so this is
# the one manual step: run it once per clone. Linked worktrees share the same
# config, so one run covers all of them.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
echo "core.hooksPath = $(git config core.hooksPath)"
echo "pre-commit will now run scripts/gate.sh before every commit."
