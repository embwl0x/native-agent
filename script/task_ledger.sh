#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Anchor the data root to the REPO (matching the retired Python task_ledger.py's
# `__file__.parent.parent / data` default), NOT the caller's cwd. The Swift CLI's
# bare fallback (resolveDataRoot) is cwd-relative, so an external agent invoking
# this wrapper from another directory without NATIVE_AGENT_DATA_ROOT set would
# otherwise write to a stray <cwd>/data and silently SPLIT the cross-agent ledger
# (different file + different flock sidecar than the in-app writer). ROOT comes
# from BASH_SOURCE, so it's the repo regardless of cwd. A pre-set
# NATIVE_AGENT_DATA_ROOT is honored; an explicit --data-root arg still wins.
exec env NATIVE_AGENT_DATA_ROOT="${NATIVE_AGENT_DATA_ROOT:-$ROOT/data}" \
  swift run --package-path "$ROOT/Modules/NativeAgentCore" task-ledger "$@"
