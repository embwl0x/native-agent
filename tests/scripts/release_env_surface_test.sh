#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE="$ROOT/script/release.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

bash -n "$RELEASE" || fail "release.sh does not parse"

surface="$(env -i PATH="$PATH" HOME="$HOME" bash "$RELEASE" --print-env-surface)"
for name in \
  NATIVEAGENT_DEVELOPER_ID \
  NATIVEAGENT_TEAM_ID \
  NATIVEAGENT_SPARKLE_ED_PRIV_KEY \
  NATIVEAGENT_PROVISIONING_PROFILE \
  NATIVEAGENT_APPCAST_URL \
  NATIVEAGENT_DMG_DOWNLOAD_URL \
  NATIVEAGENT_ICLOUD_BUILD \
  NATIVEAGENT_RELEASE_ENTITLEMENTS \
  NATIVEAGENT_SKIP_DMG_SIGN
do
  grep -Fxq "$name" <<<"$surface" || fail "environment surface omitted $name"
done

private_marker="not-for-output@example.test"
surface_with_value="$(env -i PATH="$PATH" HOME="$HOME" \
  NATIVEAGENT_APPLE_ID="$private_marker" \
  bash "$RELEASE" --print-env-surface)"
grep -Fq "$private_marker" <<<"$surface_with_value" \
  && fail "environment surface printed a configured value"

if conflict="$(env -i PATH="$PATH" HOME="$HOME" \
  NATIVEAGENT_DEVELOPER_ID=canonical NATIVE_AGENT_DEVELOPER_ID=legacy \
  bash "$RELEASE" --print-env-surface 2>&1)"; then
  fail "conflicting legacy and canonical names were accepted"
fi
grep -Fq "conflicting release environment values" <<<"$conflict" \
  || fail "conflicting names did not report the fail-closed contract"

matching="$(env -i PATH="$PATH" HOME="$HOME" \
  NATIVEAGENT_DEVELOPER_ID=same NATIVE_AGENT_DEVELOPER_ID=same \
  bash "$RELEASE" --print-env-surface)"
grep -Fxq "NATIVEAGENT_DEVELOPER_ID" <<<"$matching" \
  || fail "matching aliases did not preserve the canonical surface"

echo "Release environment surface tests passed."
