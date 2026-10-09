#!/bin/bash
set -euo pipefail

# Release-time dependency, never a download on the user's Mac.
root="$(cd "$(dirname "$0")/.." && pwd)"
version=0.161.0
arch="${1:-$(uname -m)}"
case "$arch" in
  arm64) triple=aarch64-apple-darwin; digest=bd83479f3ae21474c407ec2164fbc2a63fa763f7afbbd123fb6a69c5201cfd38 ;;
  x86_64) triple=x86_64-apple-darwin; digest=cb3d72225b15f070eabf1b0e3602014ca8bf067e20f11e3b73c88db7b2463853 ;;
  *) echo "Unsupported Codex architecture: $arch" >&2; exit 1 ;;
esac
cache="$root/extras/codex/$version/$arch"
mkdir -p "$cache"
archive="$cache/codex.tar.gz"
if [[ ! -f "$archive" ]]; then
  curl --fail --location --silent --show-error \
    "https://github.com/openai/codex/releases/download/rust-v$version/codex-$triple.tar.gz" \
    -o "$archive.download"
  mv "$archive.download" "$archive"
fi
printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 -c - >&2
tar -xzf "$archive" -C "$cache" "codex-$triple"
chmod 755 "$cache/codex-$triple"
printf '%s\n' "$cache/codex-$triple"
