#!/bin/bash
# check_app.sh — compile the Mac app's own sources (Sources/NativeAgentApp) through the
# root SwiftPM package: no Xcode build, no signing, no launch. The first run in a
# checkout builds every module (tens of minutes under load); later runs rebuild
# what changed (about 2 minutes after an app-file edit).
set -euo pipefail
ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
ruby "$ROOT/script/sync_build_declarations.rb"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=submodule.SQLiteCustom/src.update GIT_CONFIG_VALUE_0=none
cd "$ROOT"
swift build --disable-keychain --only-use-versions-from-resolved-file -j "${JOBS:-6}" --target NativeAgentApp
