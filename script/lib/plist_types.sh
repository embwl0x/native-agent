#!/usr/bin/env bash
# A2.1 round 2 (2026-07-24, gpt-5.5 MED): plist TYPE assertions.
#
# THE BUG THIS EXISTS TO KILL
#   verify_release_artifact.sh compared PlistBuddy's *printed* value, and
#   PlistBuddy stringifies everything: <string>true</string> printed "true" and
#   satisfied the updater-honesty gates. UpdateController.swift reads
#   `info["NativeAgentUpdateFeedPublished"] as? Bool`, which is nil for a string —
#   so an artifact could pass verification with its updater silently disabled, the
#   exact dishonesty this wave removed.
#
# Lives in its own lib so the guard tests can exercise the SAME code the verifier
# runs, instead of re-implementing it (an assertion only the test knows about is
# not a guard).
#
# Usage:  source script/lib/plist_types.sh
#         plist_bool_state "$INFO" NativeAgentUpdateFeedPublished   # -> true|false|absent|non-boolean:<type>

# shellcheck disable=SC2034
PLIST_TYPES_LIB_LOADED=1

# Echoes one of: absent | true | false | non-boolean:<xml-type>
# $1 — plist path, $2 — top-level key
plist_bool_state() {
  local plist="$1" key="$2" xml
  xml="$(/usr/bin/plutil -extract "$key" xml1 -o - "$plist" 2>/dev/null)" || { printf 'absent\n'; return 0; }
  if printf '%s' "$xml" | grep -q '<true/>'; then
    printf 'true\n'
  elif printf '%s' "$xml" | grep -q '<false/>'; then
    printf 'false\n'
  else
    # grep -Eo, not sed: BSD sed has no \| alternation, and a silently
    # unrecognised type would have reported "unknown" for every violation.
    local kind
    kind="$(printf '%s' "$xml" | grep -Eo '<(string|integer|real|data|date|array|dict)[ />]' | head -1 | tr -d '<>/ ')"
    printf 'non-boolean:%s\n' "${kind:-unknown}"
  fi
}

# Echoes string | other | absent for a key that must be a plist <string>.
# $1 — plist path, $2 — top-level key
plist_string_state() {
  local plist="$1" key="$2"
  /usr/bin/plutil -extract "$key" xml1 -o - "$plist" >/dev/null 2>&1 || { printf 'absent\n'; return 0; }
  if /usr/bin/plutil -extract "$key" raw -expect string -o - "$plist" >/dev/null 2>&1; then
    printf 'string\n'
  else
    printf 'other\n'
  fi
}
