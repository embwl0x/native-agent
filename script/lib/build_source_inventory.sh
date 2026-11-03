#!/usr/bin/env bash
# Exact declared build-input identity, without changing the user's index.
nativeagent_source_content_id() (
  set -euo pipefail
  local root="$1" source_index entry
  local -a inputs=()
  [[ -r "$root/script/build_inputs.txt" ]] || {
    echo '[source identity] ERROR: build-input inventory is missing or unreadable.' >&2
    return 1
  }
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -z "$entry" || "$entry" == \#* ]] && continue
    inputs+=("$entry")
  done < "$root/script/build_inputs.txt"
  if [[ ${#inputs[@]} -eq 0 ]]; then
    echo '[source identity] ERROR: build-input inventory is empty.' >&2
    return 1
  fi
  source_index="$(mktemp "${TMPDIR:-/tmp}/nativeagent-source.XXXXXX")" || return 1
  trap 'rm -f "$source_index"' EXIT
  rm -f "$source_index"
  GIT_INDEX_FILE="$source_index" git -C "$root" read-tree --empty || return 1
  git -C "$root" ls-files --cached --others --exclude-standard --deduplicate -z -- "${inputs[@]}" \
    | GIT_INDEX_FILE="$source_index" git -C "$root" update-index --add --remove -z --stdin || return 1
  GIT_INDEX_FILE="$source_index" git -C "$root" write-tree
)
