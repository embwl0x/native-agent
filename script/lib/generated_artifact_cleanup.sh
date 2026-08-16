#!/usr/bin/env bash
# Allowlist and selection helpers for generated-development-artifact cleanup.
# Deliberately knows nothing about data/, persona/, dist/, release quarantine,
# receipts, or any other user/provenance store.

generated_cleanup_is_allowed_path() {
  local root="${1%/}" target="${2%/}" relative
  [[ -n "$root" && "$root" != "/" && "$target" == "$root/"* ]] || return 1
  [[ ! -L "$target" ]] || return 1
  relative="${target#"$root/"}"
  case "$relative" in
    .runtime/user-mode-eval/*|.runtime/user-mode-eval/*|.runtime/test-logs/*)
      [[ "$relative" != *'/../'* && "$relative" != '../'* ]]
      ;;
    .runtime/DerivedData-*|.runtime/ios-simulator-derived-data|.runtime/clang-module-cache|.runtime/swift-module-cache)
      local runtime_relative="${relative#.runtime/}"
      [[ "$runtime_relative" != */* ]]
      ;;
    .build|Modules/NativeAgentCore/.build|Modules/NativeAgentShared/.build|iOS/NativeAgentMobile/build/DerivedData)
      return 0
      ;;
    *) return 1 ;;
  esac
}

generated_cleanup_collect_old_children() {
  local parent="$1" keep_latest="$2" older_days="$3"
  local now cutoff line index=0
  [[ -d "$parent" && ! -L "$parent" ]] || return 0
  now="$(date +%s)"
  cutoff=$((now - older_days * 86400))
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    index=$((index + 1))
    [[ "$index" -gt "$keep_latest" ]] || continue
    local mtime="${line%%$'\t'*}" path="${line#*$'\t'}"
    [[ "$mtime" -lt "$cutoff" ]] && printf '%s\n' "$path"
  done < <(
    find "$parent" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null \
      | while IFS= read -r path; do
          printf '%s\t%s\n' "$(stat -f %m "$path")" "$path"
        done \
      | LC_ALL=C sort -rn
  )
}

generated_cleanup_delete_allowed() {
  local root="$1" target="$2"
  generated_cleanup_is_allowed_path "$root" "$target" || {
    echo "[generated-cleanup] REFUSED non-allowlisted path: $target" >&2
    return 1
  }
  [[ -e "$target" ]] || return 0
  find "$target" -depth -delete
}
