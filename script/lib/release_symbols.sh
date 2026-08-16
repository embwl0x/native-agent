#!/usr/bin/env bash
# Release-symbol ownership: archive a matching private dSYM, strip local symbols
# from the staged executable, and prove the UUID/symbol-table contract before
# the bundle is signed.

release_executable_uuids() {
  /usr/bin/dwarfdump --uuid "$1" 2>/dev/null \
    | awk '{print $2}' \
    | LC_ALL=C sort
}

release_assert_executable_stripped() {
  local executable="$1" local_count
  [[ -f "$executable" && -x "$executable" ]] || {
    echo "[release-symbols] ERROR: executable missing or not executable: $executable" >&2
    return 1
  }
  local_count="$(/usr/bin/nm -m "$executable" 2>/dev/null | awk '/non-external/{n++} END{print n+0}')"
  if [[ "$local_count" != "0" ]]; then
    echo "[release-symbols] ERROR: executable retains $local_count non-external symbols: $executable" >&2
    return 1
  fi
}

release_archive_symbols_and_strip() (
  local executable="$1" archive_root="$2" product="$3"
  local archive="$archive_root/$product.dSYM"
  local staging="$archive_root/.$product.dSYM.staging.$$"
  local dwarf="$staging/Contents/Resources/DWARF/$product"
  local before_bytes after_bytes binary_uuids dsym_uuids

  [[ -f "$executable" && -x "$executable" ]] || {
    echo "[release-symbols] ERROR: executable missing or not executable: $executable" >&2
    return 1
  }
  command -v dsymutil >/dev/null 2>&1 || {
    echo "[release-symbols] ERROR: dsymutil is required before stripping a release." >&2
    return 1
  }
  command -v strip >/dev/null 2>&1 || {
    echo "[release-symbols] ERROR: strip is required for the release executable." >&2
    return 1
  }

  mkdir -p "$archive_root"
  rm -rf "$staging"
  trap 'rm -rf "$staging"' EXIT
  /usr/bin/dsymutil "$executable" -o "$staging"
  [[ -s "$dwarf" ]] || {
    echo "[release-symbols] ERROR: dsymutil produced no DWARF executable." >&2
    return 1
  }

  binary_uuids="$(release_executable_uuids "$executable")"
  dsym_uuids="$(release_executable_uuids "$dwarf")"
  [[ -n "$binary_uuids" && "$binary_uuids" == "$dsym_uuids" ]] || {
    echo "[release-symbols] ERROR: dSYM UUIDs do not match the staged executable." >&2
    return 1
  }

  before_bytes="$(stat -f %z "$executable")"
  /usr/bin/strip -x "$executable"
  after_bytes="$(stat -f %z "$executable")"
  [[ "$after_bytes" -lt "$before_bytes" ]] || {
    echo "[release-symbols] ERROR: strip -x did not reduce the executable." >&2
    return 1
  }
  [[ "$(release_executable_uuids "$executable")" == "$binary_uuids" ]] || {
    echo "[release-symbols] ERROR: strip changed the executable UUID." >&2
    return 1
  }
  release_assert_executable_stripped "$executable"

  rm -rf "$archive"
  mv "$staging" "$archive"
  trap - EXIT
  shasum -a 256 "$archive/Contents/Resources/DWARF/$product" \
    | awk '{print $1}' > "$archive_root/$product.dSYM.sha256"
  printf '%s\n' "$binary_uuids" > "$archive_root/$product.uuid"
  echo "[release-symbols] archived matching dSYM: $archive"
  echo "[release-symbols] stripped local symbols: $before_bytes -> $after_bytes bytes"
)
