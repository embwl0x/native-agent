#!/usr/bin/env bash
# Compile exactly one shared Living Core composition with a platform frame.
set -euo pipefail

if [[ $# -ne 2 ]] || [[ "$1" != "mac" && "$1" != "ios" ]]; then
  echo "Usage: $0 <mac|ios> <output.png>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
case "$1" in
  mac) renderer="$SCRIPT_DIR/render_mac_icon.swift" ;;
  ios) renderer="$SCRIPT_DIR/render_ios_icon.swift" ;;
esac

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-icon-render.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
binary="$build_dir/render-icon"
swiftc "$SCRIPT_DIR/LivingCore.swift" "$renderer" -o "$binary"
"$binary" "$2"
