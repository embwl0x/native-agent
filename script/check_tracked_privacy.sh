#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v gitleaks >/dev/null 2>&1; then
    echo "[privacy] ERROR: gitleaks is required (brew install gitleaks)." >&2
    exit 1
fi

snapshot="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-tracked-privacy.XXXXXX")"
cleanup() { rm -rf "$snapshot"; }
trap cleanup EXIT

while IFS= read -r -d '' path; do
    source_path="$ROOT/$path"
    if [[ ! -e "$source_path" && ! -L "$source_path" ]]; then
        # A dirty but intentional deletion is absent from the logical next
        # tree and therefore has no bytes to scan. This also lets the release
        # gate validate deletion-led work before a commit exists.
        continue
    fi
    mkdir -p "$snapshot/$(dirname "$path")"
    cp -pP "$source_path" "$snapshot/$path"
done < <(git -C "$ROOT" ls-files --cached --others --exclude-standard -z)

gitleaks dir "$snapshot" --no-banner --redact -c "$ROOT/.gitleaks.toml"
echo "[privacy] tracked working tree is clean"
