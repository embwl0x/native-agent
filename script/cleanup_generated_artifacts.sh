#!/usr/bin/env bash
# Opt-in cleanup for generated development artifacts only. Dry-run by default.
# This script never traverses NativeAgent data, persona, dist, release receipts,
# quarantine, credentials, or any other user/provenance store.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/generated_artifact_cleanup.sh
source "$ROOT/script/lib/generated_artifact_cleanup.sh"

DELETE=false
INCLUDE_CACHES=false
KEEP_LATEST=5
OLDER_DAYS=14
for arg in "$@"; do
  case "$arg" in
    --delete) DELETE=true ;;
    --include-caches) INCLUDE_CACHES=true ;;
    --keep-latest=*) KEEP_LATEST="${arg#*=}" ;;
    --older-than-days=*) OLDER_DAYS="${arg#*=}" ;;
    -h|--help)
      sed -n '2,9p' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ "$KEEP_LATEST" =~ ^[0-9]+$ && "$OLDER_DAYS" =~ ^[0-9]+$ ]] || {
  echo "keep/age values must be non-negative integers" >&2
  exit 2
}

candidates=()
for parent in \
  "$ROOT/.runtime/user-mode-eval" \
  "$ROOT/.runtime/user-mode-eval" \
  "$ROOT/.runtime/test-logs"; do
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] && candidates+=("$candidate")
  done < <(generated_cleanup_collect_old_children "$parent" "$KEEP_LATEST" "$OLDER_DAYS")
done

if $INCLUDE_CACHES; then
  if $DELETE && pgrep -f '/swift-(build|test)( |$)|/xcodebuild( |$)' >/dev/null 2>&1; then
    echo "[generated-cleanup] REFUSED cache deletion while a Swift/Xcode build is active" >&2
    exit 1
  fi
  cache_candidates=(
    "$ROOT/.runtime/ios-simulator-derived-data"
    "$ROOT/.runtime/clang-module-cache"
    "$ROOT/.runtime/swift-module-cache"
    "$ROOT/.build"
    "$ROOT/Modules/NativeAgentCore/.build"
    "$ROOT/Modules/NativeAgentShared/.build"
    "$ROOT/iOS/NativeAgentMobile/build/DerivedData"
  )
  while IFS= read -r derived; do
    [[ -n "$derived" ]] && cache_candidates+=("$derived")
  done < <(find "$ROOT/.runtime" -mindepth 1 -maxdepth 1 -type d -name 'DerivedData-*' -print 2>/dev/null || true)
  cutoff=$(( $(date +%s) - OLDER_DAYS * 86400 ))
  for candidate in "${cache_candidates[@]}"; do
    [[ -e "$candidate" && ! -L "$candidate" ]] || continue
    [[ "$(stat -f %m "$candidate")" -lt "$cutoff" ]] && candidates+=("$candidate")
  done
fi

if [[ "${#candidates[@]}" -eq 0 ]]; then
  echo "[generated-cleanup] no allowlisted artifacts match the retention policy"
  exit 0
fi

for candidate in "${candidates[@]}"; do
  generated_cleanup_is_allowed_path "$ROOT" "$candidate" || {
    echo "[generated-cleanup] REFUSED candidate outside allowlist: $candidate" >&2
    exit 1
  }
  size="$(du -sh "$candidate" 2>/dev/null | awk '{print $1}')"
  if $DELETE; then
    echo "[generated-cleanup] deleting ${size:-?}: $candidate"
    generated_cleanup_delete_allowed "$ROOT" "$candidate"
  else
    echo "[generated-cleanup] dry-run ${size:-?}: $candidate"
  fi
done

$DELETE || echo "[generated-cleanup] dry-run only; pass --delete to remove exactly these allowlisted paths"
