#!/usr/bin/env bash
# Install the tracked git hooks into this clone's .git/hooks.
# Idempotent; safe to re-run. Run from anywhere in the repo.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HOOKS="$(git rev-parse --path-format=absolute --git-path hooks)"
mkdir -p "$HOOKS"
ln -sf "$ROOT/script/hooks/pre-commit" "$HOOKS/pre-commit"
echo "[hooks] installed pre-commit -> script/hooks/pre-commit"
