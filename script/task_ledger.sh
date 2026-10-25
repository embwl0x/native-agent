#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The CLI and app share PersistenceCore's root; --data-root still overrides it.
exec swift run --package-path "$ROOT/Modules/NativeAgentCore" task-ledger "$@"
