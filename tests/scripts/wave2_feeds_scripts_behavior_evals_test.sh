#!/usr/bin/env bash
# Hermetic behavior evals for the Wave 2 script rows.  Every mutating command
# operates on a copied fixture; neither the resident data root nor persona is
# ever opened.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-wave2-scripts.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# scripts.init_persona — a present but empty identity document is unusable. It
# must be repaired, while a nonempty personal document remains byte-identical.
PERSONA_ROOT="$TMP/persona-fixture"
mkdir -p "$PERSONA_ROOT/script" "$PERSONA_ROOT/persona"
cp "$ROOT/script/init_persona.sh" "$PERSONA_ROOT/script/init_persona.sh"
printf 'template soul\n' > "$PERSONA_ROOT/persona/SOUL.template.md"
printf 'template agents\n' > "$PERSONA_ROOT/persona/AGENTS.template.md"
printf 'template growth\n' > "$PERSONA_ROOT/persona/GROWTH.template.md"
: > "$PERSONA_ROOT/persona/SOUL.md"
printf 'personal instructions\n' > "$PERSONA_ROOT/persona/AGENTS.md"
bash "$PERSONA_ROOT/script/init_persona.sh" > "$TMP/init-persona.out"
[[ "$(cat "$PERSONA_ROOT/persona/SOUL.md")" == "template soul" ]] \
  || fail "scripts.init_persona did not repair a present-but-empty SOUL.md"
[[ "$(cat "$PERSONA_ROOT/persona/AGENTS.md")" == "personal instructions" ]] \
  || fail "scripts.init_persona overwrote a nonempty personal AGENTS.md"
[[ -d "$PERSONA_ROOT/data" && -f "$PERSONA_ROOT/workspace/.gitkeep" ]] \
  || fail "scripts.init_persona did not create the isolated runtime roots"

# scripts.lib.plist_types — missing, false and true are three distinct states;
# a string that happens to spell true must never acquire Boolean authority.
PLIST="$TMP/types.plist"
cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>actualTrue</key><true/>
<key>actualFalse</key><false/>
<key>stringTrue</key><string>true</string>
</dict></plist>
PLIST
# shellcheck source=../../script/lib/plist_types.sh
source "$ROOT/script/lib/plist_types.sh"
[[ "$(plist_bool_state "$PLIST" missing)" == "absent" ]] \
  || fail "plist type helper conflates an absent Boolean with a value"
[[ "$(plist_bool_state "$PLIST" actualFalse)" == "false" ]] \
  || fail "plist type helper lost false"
[[ "$(plist_bool_state "$PLIST" actualTrue)" == "true" ]] \
  || fail "plist type helper lost true"
[[ "$(plist_bool_state "$PLIST" stringTrue)" == "non-boolean:string" ]] \
  || fail "plist type helper granted a string Boolean authority"

# scripts.lib.nativeagent_bridge — the atomic descriptor wins the old token,
# while explicit caller overrides retain documented priority.  The token values
# are fixture-only, and this runs in a throwaway HOME.
BRIDGE_HOME="$TMP/bridge-home"
mkdir -p "$BRIDGE_HOME/.config/claude-bridge"
printf 'legacy-fixture-token\n' > "$BRIDGE_HOME/.config/claude-bridge/token"
/usr/libexec/PlistBuddy -c 'Add :url string https://descriptor.example.test' \
  -c 'Add :token string descriptor-fixture-token' \
  -x -c 'Save' "$BRIDGE_HOME/.config/claude-bridge/bridge.json" 2>/dev/null \
  || cat > "$BRIDGE_HOME/.config/claude-bridge/bridge.json" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>url</key><string>https://descriptor.example.test</string><key>token</key><string>descriptor-fixture-token</string></dict></plist>
PLIST
BRIDGE_RESULT="$(HOME="$BRIDGE_HOME" bash -c '
  source "$1/script/lib/nativeagent_bridge.sh"
  nativeagent_bridge_resolve
  printf "%s|%s|%s" "$BASE_URL" "$TOKEN" "$BRIDGE_CREDENTIAL_PATH"
' -- "$ROOT")"
[[ "$BRIDGE_RESULT" == "https://descriptor.example.test|descriptor-fixture-token|$BRIDGE_HOME/.config/claude-bridge/bridge.json" ]] \
  || fail "bridge descriptor did not win over the legacy token: $BRIDGE_RESULT"
printf 'explicit-fixture-token\n' > "$TMP/explicit-token"
BRIDGE_OVERRIDE="$(HOME="$BRIDGE_HOME" NATIVE_AGENT_BRIDGE_URL='https://override.example.test' NATIVE_AGENT_BRIDGE_TOKEN="$TMP/explicit-token" bash -c '
  source "$1/script/lib/nativeagent_bridge.sh"
  nativeagent_bridge_resolve
  printf "%s|%s|%s" "$BASE_URL" "$TOKEN" "$BRIDGE_CREDENTIAL_PATH"
' -- "$ROOT")"
[[ "$BRIDGE_OVERRIDE" == "https://override.example.test|explicit-fixture-token|$TMP/explicit-token" ]] \
  || fail "explicit bridge overrides did not win: $BRIDGE_OVERRIDE"

echo "PASS Wave 2 script behavior evals"
