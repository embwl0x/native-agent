#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0="url.file://$HOME/Projects/NativeAgent/.build/checkouts/GRDB.swift/SQLiteCustom/src.insteadOf"
export GIT_CONFIG_VALUE_0="https://github.com/swiftlyfalling/SQLiteLib.git"
export GIT_CONFIG_KEY_1=protocol.file.allow
export GIT_CONFIG_VALUE_1=always
export BOTS_SHELF_SNAPSHOT_DIR="$PWD/mockups/bots-tab"
swift test --force-resolved-versions --skip-update --jobs 4 --filter 'BotsShelfTests|AppShellMenuPresentationTests'
