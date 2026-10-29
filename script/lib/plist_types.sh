#!/usr/bin/env bash
# Assert plist value types as read by Swift, without stringifying other types.
#
# Usage:  source script/lib/plist_types.sh
#         plist_bool_state "$INFO" NativeAgentUpdateFeedPublished   # -> true|false|absent|non-boolean:<type>

# shellcheck disable=SC2034
PLIST_TYPES_LIB_LOADED=1

# Echoes one of: absent | true | false | non-boolean:<type>
# $1 — plist path, $2 — top-level key
plist_bool_state() {
  local plist="$1" key="$2" kind
  kind="$(/usr/bin/plutil -type "$key" "$plist" 2>/dev/null)" || { printf 'absent\n'; return 0; }
  if [[ "$kind" == bool ]]; then
    /usr/bin/plutil -extract "$key" raw -expect bool -o - "$plist"
  else
    printf 'non-boolean:%s\n' "$kind"
  fi
}

# Echoes string | other | absent for a key that must be a plist <string>.
# $1 — plist path, $2 — top-level key
plist_string_state() {
  local plist="$1" key="$2" kind
  kind="$(/usr/bin/plutil -type "$key" "$plist" 2>/dev/null)" || { printf 'absent\n'; return 0; }
  if [[ "$kind" == string ]]; then
    printf 'string\n'
  else
    printf 'other\n'
  fi
}
