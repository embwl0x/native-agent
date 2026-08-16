#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../script/lib/generated_artifact_cleanup.sh
source "$ROOT/script/lib/generated_artifact_cleanup.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-generated-cleanup.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/repo"
mkdir -p "$FIXTURE/.runtime/user-mode-eval" "$FIXTURE/data" "$FIXTURE/dist"

for stamp in 1 2 3 4; do
  run="$FIXTURE/.runtime/user-mode-eval/$stamp"
  mkdir -p "$run"
  touch -t "20200101010$stamp" "$run"
done
selected=()
while IFS= read -r candidate; do
  [[ -n "$candidate" ]] && selected+=("$candidate")
done < <(generated_cleanup_collect_old_children "$FIXTURE/.runtime/user-mode-eval" 2 1)
[[ "${#selected[@]}" -eq 2 ]] || {
  echo "FAIL: retention did not select exactly the two oldest runs" >&2
  exit 1
}

generated_cleanup_is_allowed_path "$FIXTURE" "${selected[0]}" || {
  echo "FAIL: generated eval child was rejected" >&2; exit 1;
}
mkdir -p "$FIXTURE/.runtime/DerivedData-fixture"
generated_cleanup_is_allowed_path "$FIXTURE" "$FIXTURE/.runtime/DerivedData-fixture" || {
  echo "FAIL: explicitly allowlisted DerivedData cache was rejected" >&2; exit 1;
}
for forbidden in \
  "$FIXTURE/data" \
  "$FIXTURE/dist" \
  "$FIXTURE/.runtime/user-mode-eval" \
  "$FIXTURE/.runtime/user-mode-eval/../escape"; do
  if generated_cleanup_is_allowed_path "$FIXTURE" "$forbidden"; then
    echo "FAIL: forbidden cleanup target accepted: $forbidden" >&2
    exit 1
  fi
done
ln -s "$FIXTURE/data" "$FIXTURE/.runtime/user-mode-eval/link"
if generated_cleanup_is_allowed_path "$FIXTURE" "$FIXTURE/.runtime/user-mode-eval/link"; then
  echo "FAIL: symlink cleanup target accepted" >&2
  exit 1
fi

generated_cleanup_delete_allowed "$FIXTURE" "${selected[0]}"
[[ ! -e "${selected[0]}" && -d "$FIXTURE/data" && -d "$FIXTURE/dist" ]] || {
  echo "FAIL: allowlisted deletion crossed into protected state" >&2
  exit 1
}

if rg -n 'data/|persona/|dist/' "$ROOT/script/cleanup_generated_artifacts.sh" \
  | grep -v 'never traverses' >/dev/null; then
  echo "FAIL: generated cleanup script names a protected state root" >&2
  exit 1
fi

printf 'ok - generated artifact cleanup guards\n'
