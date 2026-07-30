#!/usr/bin/env bash
# Install the tracked git hooks into this clone's .git/hooks.
# Idempotent; safe to re-run. Run from anywhere in the repo.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
ln -sf ../../script/hooks/pre-commit "$ROOT/.git/hooks/pre-commit"
echo "[hooks] installed pre-commit -> script/hooks/pre-commit"
