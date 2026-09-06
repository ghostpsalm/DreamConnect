#!/usr/bin/env bash
# The repo gate, at the conventional path. Thin wrapper over ./run-tests.sh so
# tooling that looks for scripts/gate.sh finds it; run-tests.sh remains the
# real entry point.
set -euo pipefail
exec "$(cd "$(dirname "$0")/.." && pwd)/run-tests.sh" "$@"
