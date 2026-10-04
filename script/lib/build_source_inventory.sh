#!/usr/bin/env bash
# Shared, deterministic source inventory helpers for the compiler benchmark.

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
    for package_file in "$root/Package.swift" "$root/Package.resolved" "$root"/Modules/*/Package.swift; do
      [[ -f "$package_file" ]] && printf '%s\n' "$package_file"
    done
  } | LC_ALL=C sort -u
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
