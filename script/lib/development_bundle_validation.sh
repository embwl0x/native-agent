#!/usr/bin/env bash
# Shared development build/install boundaries; callers own exemptions and diagnostics.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release_bundle_gates.sh"
# REPO_PATH identifies the live data checkout; a deleted checkout is not a conflict.
nativeagent_require_installed_checkout() {
  local bundle="$1" root="$2" force="$3" prefix="$4" consequence="$5"
  local installed_repo_path installed_repo_resolved root_resolved
  [[ "$force" != 1 && -f "$bundle/Contents/Resources/REPO_PATH" ]] || return 0
  installed_repo_path="$(head -n 1 "$bundle/Contents/Resources/REPO_PATH")"
  [[ -n "$installed_repo_path" && -d "$installed_repo_path" ]] || return 0
  installed_repo_resolved="$(cd "$installed_repo_path" 2>/dev/null && pwd -P || true)"
  root_resolved="$(cd "$root" && pwd -P)"
  if [[ -n "$installed_repo_resolved" && "$installed_repo_resolved" != "$root_resolved" ]]; then
    echo "$prefix ERROR: the installed app belongs to a different checkout:" >&2
    echo "  installed: $installed_repo_resolved" >&2
    echo "  this run : $root_resolved" >&2
    echo "$consequence" >&2
    echo "Pass --force-checkout-switch to switch the installed app to this checkout." >&2
    exit 2
  fi
}
