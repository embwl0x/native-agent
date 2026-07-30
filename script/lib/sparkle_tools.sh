#!/usr/bin/env bash
# A2.1-2026-07-24: shared discovery for Sparkle's CLI tools.
#
# Sparkle ships generate_keys / sign_update / generate_appcast inside the SwiftPM
# checkout + binary artifact, at paths that move between Sparkle versions. This
# was already duplicated in script/sparkle_keygen.sh; the appcast pipeline needs
# the same lookup, so it lives here once.
#
# Usage:  source script/lib/sparkle_tools.sh
#         path="$(sparkle_tool_path generate_appcast)" || <handle missing>

# shellcheck disable=SC2034
SPARKLE_TOOLS_LIB_LOADED=1

# Echoes the absolute path to a Sparkle CLI tool, or returns 1 if not found.
# $1 — tool name (generate_keys | sign_update | generate_appcast)
# $2 — repo root (optional; defaults to the parent of this lib's directory)
sparkle_tool_path() {
  local tool="$1"
  local root="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  root="$(cd "$root" && pwd)"

  local candidates=(
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
# A2.1 round 2: this is what makes the "signing with the wrong key" guard
# independent of Sparkle's warning prose — see script/sparkle_ed_public_key.swift.
# Swift (CryptoKit), not a scripting-language helper: this repo is under a
# zero-Python source mandate enforced by NoPythonRegressionTests.
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
