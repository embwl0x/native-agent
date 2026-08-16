#!/usr/bin/env bash
# Shared, deterministic source inventory helpers for SwiftPM build/test gates.
#
# The path-only digest repairs SwiftPM's stale local-dependency build plan only
# when a source/resource path is added, removed, or renamed. The content digest
# is deliberately stronger and is used to prove that a sharded test run did not
# execute stale binaries while the source tree changed underneath it.

nativeagent_inventory_files() {
  local root="$1"
  local inventory_root package_file
  {
    for inventory_root in \
      "$root/Sources" "$root/Tests" "$root/tests" "$root/Resources" \
      "$root"/Modules/*/Sources "$root"/Modules/*/Tests "$root"/Modules/*/Resources; do
      [[ -d "$inventory_root" && ! -L "$inventory_root" ]] || continue
      find "$inventory_root" \
        \( -path '*/.build' -o -path '*/.build/*' \) -prune -o \
        -type f -print
    done
    for package_file in "$root/Package.swift" "$root/Package.resolved" "$root"/Modules/*/Package.swift "$root"/Modules/*/Package.resolved; do
      [[ -f "$package_file" ]] && printf '%s\n' "$package_file"
    done
  } | LC_ALL=C sort -u
}

nativeagent_build_path_inventory_digest() {
  local root="$1" file
  while IFS= read -r file; do
    printf '%s\n' "${file#"${root%/}/"}"
  done < <(nativeagent_inventory_files "$root") \
    | shasum -a 256 \
    | awk '{print $1}'
}

nativeagent_source_state_digest() {
  local root="$1" file relative
  while IFS= read -r file; do
    relative="${file#"${root%/}/"}"
    printf '%s\0' "$relative"
    shasum -a 256 "$file" | awk '{printf "%s\0", $1}'
  done < <(nativeagent_inventory_files "$root") \
    | shasum -a 256 \
    | awk '{print $1}'
}

nativeagent_refresh_swiftpm_plan_if_inventory_changed() {
  local root="$1"
  local state_file="${2:-$root/.runtime/build-source-inventory.sha256}"
  local digest previous="" state_dir tmp
  digest="$(nativeagent_build_path_inventory_digest "$root")"
  [[ -f "$state_file" ]] && previous="$(tr -d '[:space:]' < "$state_file")"
  if [[ "$digest" == "$previous" ]]; then
    return 1
  fi

  touch "$root/Package.swift"
  state_dir="$(dirname "$state_file")"
  mkdir -p "$state_dir"
  tmp="$state_file.tmp.$$"
  printf '%s\n' "$digest" > "$tmp"
  mv -f "$tmp" "$state_file"
  return 0
}
