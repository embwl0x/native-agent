#!/usr/bin/env bash
# Working-tree content identity, without changing the user's index.
nativeagent_source_content_id() (
  local root="$1" source_index
  source_index="$(mktemp "${TMPDIR:-/tmp}/nativeagent-source.XXXXXX")" || return 1
  trap 'rm -f "$source_index"' EXIT
  rm -f "$source_index"
  GIT_INDEX_FILE="$source_index" git -C "$root" read-tree --empty || return 1
  git -C "$root" ls-files --cached --others --exclude-standard --deduplicate -z \
    | GIT_INDEX_FILE="$source_index" git -C "$root" update-index --add --remove -z --stdin || return 1
  GIT_INDEX_FILE="$source_index" git -C "$root" write-tree
)
