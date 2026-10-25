#!/bin/bash
# check_module.sh [Module ...] — compile NativeAgentCore modules (all when none named)
# from any checkout or fresh worktree: the core resolves from the root's reviewed
# pins, and GRDB's optional custom-SQLite submodule (never used; the package links
# system SQLite) is not fetched. No app build, no signing, no launch.
set -euo pipefail
ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
ruby "$ROOT/script/sync_build_declarations.rb"
CORE="$ROOT/Modules/NativeAgentCore"
cmp -s "$ROOT/Package.resolved" "$CORE/Package.resolved" 2>/dev/null || cp "$ROOT/Package.resolved" "$CORE/Package.resolved"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=submodule.SQLiteCustom/src.update GIT_CONFIG_VALUE_0=none
cd "$CORE"
build() { swift build --disable-keychain --only-use-versions-from-resolved-file -j "${JOBS:-6}" "$@"; }
# swift build takes one --target: each module named builds in turn, stopping at the first that fails.
if [ $# -eq 0 ]; then build; exit; fi
for module in "$@"; do build --target "$module"; done
