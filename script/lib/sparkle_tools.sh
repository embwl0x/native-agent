#!/usr/bin/env bash
# Shared Sparkle CLI discovery across version-dependent SwiftPM checkout and artifact paths.
#
# Usage:  source script/lib/sparkle_tools.sh
#         path="$(sparkle_tool_path generate_appcast)" || <handle missing>

# shellcheck disable=SC2034
SPARKLE_TOOLS_LIB_LOADED=1

# Validate feed-declared deltas and retain their exact paths for publication.
sparkle_validate_deltas() { # feed, release URL prefix, private key, optional sign_update
  local feed="$1" prefix="$2" key="$3" sign_tool="${4:-}" index node url name path signature length
  SPARKLE_DELTA_PATHS=()
  SPARKLE_DELTA_COUNT="$(xmllint --xpath 'count(//*[local-name()="deltas"]/*[local-name()="enclosure"])' "$feed")" || return 1
  [[ "$SPARKLE_DELTA_COUNT" != 0 ]] || return 0
  [[ -f "$key" ]] || { echo "ERROR: Sparkle key for delta verification is missing: $key" >&2; return 1; }
  [[ -n "$sign_tool" ]] || sign_tool="$(sparkle_tool_path_or_die sign_update)" || return 1
  for ((index=1; index<=SPARKLE_DELTA_COUNT; index++)); do
    node="(//*[local-name()='deltas']/*[local-name()='enclosure'])[$index]"
    url="$(xmllint --xpath "string($node/@url)" "$feed")" || return 1
    name="${url##*/}"
    [[ "$name" =~ ^[A-Za-z0-9_.-]+\.delta$ && "$url" == "$prefix$name" ]] \
      || { echo "ERROR: delta URL does not name a local release asset: $url" >&2; return 1; }
    path="$(dirname "$feed")/$name"
    [[ -s "$path" ]] || { echo "ERROR: delta asset is missing: $name" >&2; return 1; }
    length="$(xmllint --xpath "string($node/@length)" "$feed")" || return 1
    [[ "$length" == "$(stat -f%z "$path")" ]] || { echo "ERROR: delta size mismatch: $name" >&2; return 1; }
    signature="$(xmllint --xpath "string($node/@*[local-name()='edSignature'])" "$feed")" || return 1
    [[ -n "$signature" ]] || { echo "ERROR: unsigned delta: $name" >&2; return 1; }
    "$sign_tool" --verify --ed-key-file "$key" "$path" "$signature" >/dev/null \
      || { echo "ERROR: delta signature does not verify: $name" >&2; return 1; }
    SPARKLE_DELTA_PATHS+=("$path")
  done
}

# Echoes the absolute path to a Sparkle CLI tool, or returns 1 if not found.
# $1 — tool name (generate_keys | sign_update | generate_appcast)
# $2 — repo root (optional; defaults to the parent of this lib's directory)
sparkle_tool_path() {
  local tool="$1"
  local root="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  root="$(cd "$root" && pwd)"

  local candidates=(
    "$root/DerivedData/ReleaseBundle/SourcePackages/artifacts/sparkle/Sparkle/bin/$tool"
    "$root/.build/artifacts/sparkle/Sparkle/bin/$tool"
    "$root/.build/checkouts/Sparkle/bin/$tool"
    "$root/.build/checkouts/Sparkle/$tool"
    "$root/.build/checkouts/Sparkle/Autoupdate/$tool"
    "$HOME/.swiftpm/checkouts/Sparkle/bin/$tool"
  )
  local p
  for p in "${candidates[@]}"; do
    if [[ -x "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done

  # Broader search (Sparkle relocates these between releases). Exclude the legacy
  # DSA scripts directory — those tools sign with the retired algorithm.
  local found
  found="$(
    find "$root/.build/artifacts" "$root/.build/checkouts" \
      "$root/DerivedData/ReleaseBundle/SourcePackages/artifacts" \
      -name "$tool" -type f 2>/dev/null \
      | grep -v 'old_dsa_scripts' \
      | head -1 || true
  )"
  if [[ -n "$found" ]]; then
    chmod +x "$found" 2>/dev/null || true
    printf '%s\n' "$found"
    return 0
  fi
  return 1
}

# Echoes the base64 Ed25519 PUBLIC key derived from a Sparkle private key file.
# Returns 1 (with a reason on stderr) if it cannot be derived.
#
# CryptoKit key derivation is independent of Sparkle's warning prose.
# $1 — private key file path, $2 — repo root (optional)
sparkle_ed_public_key_from_file() {
  local key_file="$1"
  local root="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local helper="$root/script/sparkle_ed_public_key.swift"

  if [[ ! -f "$helper" ]]; then
    echo "ERROR: missing $helper — cannot derive the public half of the signing key." >&2
    return 1
  fi
  local out
  if ! out="$(swift "$helper" "$key_file")"; then
    return 1
  fi
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# Fails loudly with the exact remediation when a tool is missing.
# $1 — tool name, $2 — repo root
sparkle_tool_path_or_die() {
  local tool="$1" root="${2:-}"
  local p
  if p="$(sparkle_tool_path "$tool" "$root")"; then
    printf '%s\n' "$p"
    return 0
  fi
  echo "ERROR: Sparkle's '$tool' tool was not found." >&2
  echo "" >&2
  echo "REMEDIATION:" >&2
  echo "  Sparkle is a SwiftPM dependency; its CLI tools appear only after a build." >&2
  echo "  Run:  swift build --package-path \"${root:-.}\"" >&2
  echo "  Then re-run this script." >&2
  exit 1
}
