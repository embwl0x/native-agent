#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/script/lib/release_bundle_gates.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-release-gates.XXXXXX")"
# Some cases below chmod a fixture directory to 000 to model a find that fails
# partway. Restore traversal before deleting, or the cleanup itself fails.
trap 'chmod -R u+rwX "$TMP" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
BUNDLE="$TMP/NativeAgent.app"
BIN_DIR="$BUNDLE/Contents/MacOS"
mkdir -p "$BIN_DIR"
BIN="$BIN_DIR/NativeAgentApp"

printf '%s\n' 'NativeAgent supports Claude Code and ordinary agent workflows.' > "$BIN"
chmod +x "$BIN"

if NATIVEAGENT_LOCAL_IDENTITY_RE='' NATIVEAGENT_PRIVACY_RE='' \
  NATIVEAGENT_PRIVACY_DENYLIST_FILE='' \
  release_assert_no_identity_strings "$BUNDLE" >/dev/null 2>&1; then
  echo "FAIL: missing maintainer denylist was accepted" >&2
  exit 1
fi

DENYLIST="$TMP/privacy_denylist.regex"
printf '%s\n' 'private_fixture_identity' > "$DENYLIST"
NATIVEAGENT_PRIVACY_DENYLIST_FILE="$DENYLIST" \
  release_assert_no_identity_strings "$BUNDLE" >/dev/null

# A general model vocabulary legitimately contains ordinary names. Exempt only
# the exact verified MemoryV2 payload; app content and lookalikes stay scanned.
mkdir -p "$BUNDLE/Contents/Resources/NativeAgentCore_MemoryV2.bundle/minilm.mlpackage/Data"
printf '%s\n' 'private_fixture_identity' \
  > "$BUNDLE/Contents/Resources/NativeAgentCore_MemoryV2.bundle/minilm_vocab.txt"
printf '%s\n' 'private_fixture_identity' \
  > "$BUNDLE/Contents/Resources/NativeAgentCore_MemoryV2.bundle/minilm.mlpackage/Data/model.mlmodel"
if [[ -n "$(release_personal_identity_hit_files "$BUNDLE" 'private_fixture_identity')" ]]; then
  echo "FAIL: verified MiniLM payload was not exempted" >&2
  exit 1
fi

printf '%s\n' 'private_fixture_identity' > "$BUNDLE/Contents/Resources/app-owned.txt"
personal_hits="$(release_personal_identity_hit_files "$BUNDLE" 'private_fixture_identity')"
if [[ "$personal_hits" != *'/app-owned.txt' ]]; then
  echo "FAIL: app-owned resource identity was not detected" >&2
  exit 1
fi
rm -f "$BUNDLE/Contents/Resources/app-owned.txt"

mkdir -p "$BUNDLE/Contents/Resources/Lookalike.bundle"
printf '%s\n' 'private_fixture_identity' \
  > "$BUNDLE/Contents/Resources/Lookalike.bundle/minilm_vocab.txt"
personal_hits="$(release_personal_identity_hit_files "$BUNDLE" 'private_fixture_identity')"
if [[ "$personal_hits" != *'/Lookalike.bundle/minilm_vocab.txt' ]]; then
  echo "FAIL: lookalike model resource was incorrectly exempted" >&2
  exit 1
fi
rm -rf "$BUNDLE/Contents/Resources/Lookalike.bundle"

# Signature metadata is generated after the pre-signing scan and is opaque to
# the app. The mounted-artifact verifier uses this same helper and must not
# interpret signature bytes as app-owned text.
mkdir -p "$BUNDLE/Contents/_CodeSignature"
printf '%s\n' 'private_fixture_identity' > "$BUNDLE/Contents/_CodeSignature/CodeResources"
if [[ -n "$(release_personal_identity_hit_files "$BUNDLE" 'private_fixture_identity')" ]]; then
  echo "FAIL: signature metadata was not exempted" >&2
  exit 1
fi
rm -rf "$BUNDLE/Contents/_CodeSignature"

printf '%s\n' 'private_fixture_identity' >> "$BIN"
if NATIVEAGENT_PRIVACY_DENYLIST_FILE="$DENYLIST" \
  release_assert_no_identity_strings "$BUNDLE" >/dev/null 2>&1; then
  echo "FAIL: configured private identity was accepted" >&2
  exit 1
fi

# A three-byte identity-shaped run in opaque executable bytes is not evidence
# of a compiled string literal. The Mach-O-aware scan owns real short strings;
# the raw fallback must not reject coincidental ARM64/model bytes. Stub strings
# here to model a synthetic triplet that is absent from every recognized string
# section. Keep this token independent of maintainer identity: the public
# exporter deliberately rewrites real private names, which can change their
# byte length and invalidate this exact three-byte boundary fixture.
SHORT_BUNDLE="$TMP/ShortTriplet.app"
SHORT_BIN="$SHORT_BUNDLE/Contents/MacOS/NativeAgentApp"
FAKE_BIN="$TMP/fake-bin"
mkdir -p "$(dirname "$SHORT_BIN")" "$FAKE_BIN"
printf '\000Qzx\000' > "$SHORT_BIN"
chmod +x "$SHORT_BIN"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/strings"
chmod +x "$FAKE_BIN/strings"
printf '%s\n' 'Qzx' > "$TMP/short_denylist.regex"
PATH="$FAKE_BIN:$PATH" \
  NATIVEAGENT_PRIVACY_DENYLIST_FILE="$TMP/short_denylist.regex" \
  release_assert_no_identity_strings "$SHORT_BUNDLE" >/dev/null

# The section-agnostic fallback still rejects substantial printable identity
# data outside Mach-O string sections.
printf '\000private_fixture_identity\000' >> "$SHORT_BIN"
if PATH="$FAKE_BIN:$PATH" NATIVEAGENT_PRIVACY_DENYLIST_FILE="$DENYLIST" \
  release_assert_no_identity_strings "$SHORT_BUNDLE" >/dev/null 2>&1; then
  echo "FAIL: substantial raw identity data outside string sections was accepted" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# SCANNER INTEGRITY CONTRACT (2026-08-21)
# ---------------------------------------------------------------------------
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# A bundle that is clean by construction. Callers mutate copies of it.
make_bundle() {
  local dest="$1"
  mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources"
  printf 'ordinary release binary content, nothing private here\n' \
    > "$dest/Contents/MacOS/NativeAgentApp"
  chmod +x "$dest/Contents/MacOS/NativeAgentApp"
  printf 'ordinary bundled resource text\n' > "$dest/Contents/Resources/strings.txt"
}

GOOD_DENYLIST="$TMP/good_denylist.regex"
printf '%s\n' '# maintainer patterns' 'private_fixture_identity' > "$GOOD_DENYLIST"

run_self_test() {
  # Runs the real release.sh gate entry point. stdout+stderr -> $LAST_OUTPUT,
  # exit status -> $LAST_RC. Never aborts the test on a nonzero status.
  local bundle="$1"
  shift
  LAST_RC=0
  LAST_OUTPUT="$(
    env "$@" "$ROOT/script/release.sh" --self-test-gates "$bundle" 2>&1
  )" || LAST_RC=$?
}

# ---------------------------------------------------------------------------
# (d) A clean fixture still passes end to end. Asserted FIRST so a later
# refusal cannot be mistaken for a gate that rejects everything.
# ---------------------------------------------------------------------------
CLEAN_BUNDLE="$TMP/Clean.app"
make_bundle "$CLEAN_BUNDLE"
run_self_test "$CLEAN_BUNDLE" \
  "NATIVEAGENT_PRIVACY_DENYLIST_FILE=$GOOD_DENYLIST" \
  "NATIVEAGENT_PRIVACY_RE=" \
  "NATIVEAGENT_LOCAL_IDENTITY_RE=private_fixture_identity"
[[ "$LAST_RC" -eq 0 ]] \
  || fail "clean bundle was rejected (rc $LAST_RC):"$'\n'"$LAST_OUTPUT"
[[ "$LAST_OUTPUT" == *"leak guard passed"* ]] \
  || fail "clean bundle did not report a passing leak guard:"$'\n'"$LAST_OUTPUT"

# ---------------------------------------------------------------------------
# (a) A broken ERE in the runtime-assembled denylist must ABORT, and must name
# the offending file:line. Before the fix, grep rejected the pattern with
# rc 2, the `|| true` ate it, and the empty result read as CLEAN.
# ---------------------------------------------------------------------------
BROKEN_DENYLIST="$TMP/broken_denylist.regex"
printf '%s\n' '# maintainer patterns' 'private_fixture_identity' 'unbalanced(paren' \
  > "$BROKEN_DENYLIST"
run_self_test "$CLEAN_BUNDLE" \
  "NATIVEAGENT_PRIVACY_DENYLIST_FILE=$BROKEN_DENYLIST" \
  "NATIVEAGENT_PRIVACY_RE=" \
  "NATIVEAGENT_LOCAL_IDENTITY_RE=private_fixture_identity"
[[ "$LAST_RC" -ne 0 ]] \
  || fail "a broken denylist ERE was accepted as a clean release:"$'\n'"$LAST_OUTPUT"
[[ "$LAST_OUTPUT" != *"leak guard passed"* ]] \
  || fail "a broken denylist ERE still printed a passing leak guard:"$'\n'"$LAST_OUTPUT"
[[ "$LAST_OUTPUT" == *"$BROKEN_DENYLIST:3"* ]] \
  || fail "the refusal did not name the offending denylist file:line:"$'\n'"$LAST_OUTPUT"

# The same must hold for the standalone assembler and for the A1.1 gate that
# consumes it.
assemble_rc=0
release_denylist_regex_from_file "$BROKEN_DENYLIST" >/dev/null 2>&1 || assemble_rc=$?
[[ "$assemble_rc" -ne 0 ]] || fail "release_denylist_regex_from_file accepted a broken pattern"
gate_rc=0
NATIVEAGENT_LOCAL_IDENTITY_RE='' NATIVEAGENT_PRIVACY_RE='' \
  NATIVEAGENT_PRIVACY_DENYLIST_FILE="$BROKEN_DENYLIST" \
  release_assert_no_identity_strings "$CLEAN_BUNDLE" >/dev/null 2>&1 || gate_rc=$?
[[ "$gate_rc" -ne 0 ]] || fail "the A1.1 gate passed while its denylist was unusable"

# ---------------------------------------------------------------------------
# (b) A missing or empty scan subject must ABORT, never report CLEAN.
# ---------------------------------------------------------------------------
NO_RES_BUNDLE="$TMP/NoResources.app"
make_bundle "$NO_RES_BUNDLE"
rm -rf "$NO_RES_BUNDLE/Contents/Resources"
run_self_test "$NO_RES_BUNDLE" \
  "NATIVEAGENT_PRIVACY_DENYLIST_FILE=$GOOD_DENYLIST" \
  "NATIVEAGENT_PRIVACY_RE=" \
  "NATIVEAGENT_LOCAL_IDENTITY_RE=private_fixture_identity"
[[ "$LAST_RC" -ne 0 ]] \
  || fail "a bundle with no Contents/Resources was certified clean:"$'\n'"$LAST_OUTPUT"
[[ "$LAST_OUTPUT" != *"leak guard passed"* ]] \
  || fail "a missing scan directory printed a passing leak guard:"$'\n'"$LAST_OUTPUT"

EMPTY_RES_BUNDLE="$TMP/EmptyResources.app"
make_bundle "$EMPTY_RES_BUNDLE"
rm -f "$EMPTY_RES_BUNDLE/Contents/Resources/strings.txt"
run_self_test "$EMPTY_RES_BUNDLE" \
  "NATIVEAGENT_PRIVACY_DENYLIST_FILE=$GOOD_DENYLIST" \
  "NATIVEAGENT_PRIVACY_RE=" \
  "NATIVEAGENT_LOCAL_IDENTITY_RE=private_fixture_identity"
[[ "$LAST_RC" -ne 0 ]] \
  || fail "a bundle with an EMPTY Contents/Resources was certified clean:"$'\n'"$LAST_OUTPUT"

scan_rc=0
release_scan_dir_for_regex "$TMP/definitely-not-here" "missing" cs 'x' >/dev/null 2>&1 || scan_rc=$?
[[ "$scan_rc" -eq 2 ]] || fail "a missing scan directory returned $scan_rc, expected the 2 = scanner-error code"

# ---------------------------------------------------------------------------
# (c) A planted credential must be REFUSED, with the hit path reported intact
# even though it contains spaces. Word-splitting `for f in $hits` used to
# shred such paths into fragments.
# ---------------------------------------------------------------------------
LEAKY_BUNDLE="$TMP/Leaky.app"
make_bundle "$LEAKY_BUNDLE"
LEAK_DIR="$LEAKY_BUNDLE/Contents/Resources/vendor config"
mkdir -p "$LEAK_DIR"
printf 'api_key = "%s"\n' "$(release_canary_token)" > "$LEAK_DIR/provider token.txt"
run_self_test "$LEAKY_BUNDLE" \
  "NATIVEAGENT_PRIVACY_DENYLIST_FILE=$GOOD_DENYLIST" \
  "NATIVEAGENT_PRIVACY_RE=" \
  "NATIVEAGENT_LOCAL_IDENTITY_RE=private_fixture_identity"
[[ "$LAST_RC" -ne 0 ]] \
  || fail "a planted credential shipped as a clean bundle:"$'\n'"$LAST_OUTPUT"
[[ "$LAST_OUTPUT" == *"vendor config/provider token.txt"* ]] \
  || fail "the planted-credential path was not reported intact (spaces shredded?):"$'\n'"$LAST_OUTPUT"

# Same for a personal identifier in a spaced path: the hit must be reported as
# one whole path, not as split words.
IDENTITY_BUNDLE="$TMP/Identity.app"
make_bundle "$IDENTITY_BUNDLE"
mkdir -p "$IDENTITY_BUNDLE/Contents/Resources/some dir"
printf '%s\n' 'private_fixture_identity' \
  > "$IDENTITY_BUNDLE/Contents/Resources/some dir/leaked notes.txt"
run_self_test "$IDENTITY_BUNDLE" \
  "NATIVEAGENT_PRIVACY_DENYLIST_FILE=$GOOD_DENYLIST" \
  "NATIVEAGENT_PRIVACY_RE=" \
  "NATIVEAGENT_LOCAL_IDENTITY_RE=private_fixture_identity"
[[ "$LAST_RC" -ne 0 ]] \
  || fail "a personal identifier shipped as a clean bundle:"$'\n'"$LAST_OUTPUT"
[[ "$LAST_OUTPUT" == *"some dir/leaked notes.txt"* ]] \
  || fail "the identity hit path was not reported intact:"$'\n'"$LAST_OUTPUT"

# ---------------------------------------------------------------------------
# The negative control must have teeth: with a sabotaged grep that always
# reports "no match", the canary must FAIL rather than bless the sabotage.
# ---------------------------------------------------------------------------
release_assert_scanner_canary "healthy pipeline" >/dev/null 2>&1 \
  || fail "the negative control failed against a healthy scan pipeline"

SABOTAGE_BIN="$TMP/sabotage-bin"
mkdir -p "$SABOTAGE_BIN"
printf '#!/bin/sh\nexit 1\n' > "$SABOTAGE_BIN/grep"
chmod +x "$SABOTAGE_BIN/grep"
canary_rc=0
PATH="$SABOTAGE_BIN:$PATH" release_assert_scanner_canary "sabotaged pipeline" >/dev/null 2>&1 \
  || canary_rc=$?
[[ "$canary_rc" -ne 0 ]] \
  || fail "the negative control passed with a grep that can never match anything"

# ---------------------------------------------------------------------------
# Regression pin: the collapsed pipeline must not come back to any scan site.
# ---------------------------------------------------------------------------
for guarded in \
  "$ROOT/script/release.sh" \
  "$ROOT/script/lib/release_bundle_gates.sh" \
  "$ROOT/script/verify_release_artifact.sh"; do
  # Comments explaining the bug are allowed; live code is not.
  if grep -n 'xargs -0 grep' "$guarded" | grep -qv '^[0-9]*:[[:space:]]*#'; then
    fail "$guarded still pipes a scan through xargs (its 123 hides grep's real status)"
  fi
  if grep -n 'grep .*2>/dev/null || true' "$guarded" | grep -qv '^[0-9]*:[[:space:]]*#'; then
    fail "$guarded still swallows a scanner's stderr AND its exit code"
  fi
  if grep -n 'find .*2>/dev/null' "$guarded" | grep -qv '^[0-9]*:[[:space:]]*#'; then
    fail "$guarded still discards a find diagnostic (a partial walk then reads as clean)"
  fi
done

# ---------------------------------------------------------------------------
# ROUND 2 (2026-08-21) — review findings 2-5.
# ---------------------------------------------------------------------------

# (2a) BATCHING: a hit that lands past the first 200-file batch must still be
# found. release_scan_files_for_regex consumes RELEASE_SCAN_FILES directly, so
# the array is built by hand here — that pins the hit's INDEX deterministically
# instead of hoping find enumerates a directory in the order we want.
BATCH_DIR="$TMP/batch"
mkdir -p "$BATCH_DIR"
RELEASE_SCAN_FILES=()
for i in $(seq 0 249); do
  printf 'benign release content %s\n' "$i" > "$BATCH_DIR/f$i.txt"
  RELEASE_SCAN_FILES+=("$BATCH_DIR/f$i.txt")
done
LATE_HIT="$BATCH_DIR/f240.txt"
printf 'api_key = "%s"\n' "$(release_canary_token)" > "$LATE_HIT"
[[ "${RELEASE_SCAN_FILES[240]}" == "$LATE_HIT" ]] \
  || fail "fixture is wrong: the planted hit is not at index 240"
batch_hits="$(release_scan_files_for_regex "$RELEASE_SECRET_VALUE_RE" cs "late batch")" \
  || fail "the batched scan aborted on a clean-plus-one-hit fixture"
[[ "$batch_hits" == *"f240.txt"* ]] \
  || fail "a planted hit in file #241 was MISSED — batching drops late files:"$'\n'"${batch_hits:-<none>}"

# (2b) A grep failure in a LATER batch must abort. The earlier batch returning a
# clean rc 1 must not be allowed to stand as the verdict for the whole scan.
LATER_FAIL_BIN="$TMP/later-fail-bin"
mkdir -p "$LATER_FAIL_BIN"
REAL_GREP="$(command -v grep)"
cat > "$LATER_FAIL_BIN/grep" <<GREPEOF
#!/bin/sh
# Batch 1 behaves normally; every later invocation reports grep's "scanner
# error" status. Models an unreadable file / rejected pattern that only shows up
# after the first chunk has already come back clean.
count_file="\${NATIVEAGENT_TEST_GREP_COUNT:?}"
n=\$(cat "\$count_file" 2>/dev/null || echo 0)
n=\$((n + 1))
printf '%s' "\$n" > "\$count_file"
if [ "\$n" -ge 2 ]; then
  echo "grep: simulated scanner failure in batch \$n" >&2
  exit 2
fi
exec "$REAL_GREP" "\$@"
GREPEOF
chmod +x "$LATER_FAIL_BIN/grep"
GREP_COUNT_FILE="$TMP/grep-count"
: > "$GREP_COUNT_FILE"
RELEASE_SCAN_FILES=()
for i in $(seq 0 249); do
  RELEASE_SCAN_FILES+=("$BATCH_DIR/f$i.txt")
done
later_rc=0
later_out="$(
  PATH="$LATER_FAIL_BIN:$PATH" NATIVEAGENT_TEST_GREP_COUNT="$GREP_COUNT_FILE" \
    release_scan_files_for_regex "$RELEASE_SECRET_VALUE_RE" cs "later batch failure" 2>&1
)" || later_rc=$?
[[ "$(cat "$GREP_COUNT_FILE")" -ge 2 ]] \
  || fail "the fixture never reached a second batch; the late-failure case proved nothing"
[[ "$later_rc" -eq 2 ]] \
  || fail "a grep failure in a LATER batch returned $later_rc, expected the 2 = scanner-error code:"$'\n'"$later_out"
[[ "$later_out" == *"scanner FAILED"* ]] \
  || fail "the later-batch failure produced no diagnostic:"$'\n'"$later_out"

# (2c) BINARY RESOURCES. `grep -I` reports rc 1 (no match) for any file with NUL
# bytes, so a credential inside a binary plist / compiled asset used to read as
# clean while the text-only canary happily passed. Prove the raw blind spot
# exists, then prove the pipeline now closes it.
BIN_FIXTURE="$TMP/binary-fixture"
mkdir -p "$BIN_FIXTURE"
printf 'BPLIST\000\001\002api_key\000%s\000\377\376tail' "$(release_canary_token)" \
  > "$BIN_FIXTURE/Settings.plist"
printf 'ordinary release text\n' > "$BIN_FIXTURE/notes.txt"
raw_text_rc=0
grep -IlE -e "$RELEASE_SECRET_VALUE_RE" -- "$BIN_FIXTURE/Settings.plist" >/dev/null 2>&1 || raw_text_rc=$?
[[ "$raw_text_rc" -eq 1 ]] \
  || fail "fixture is wrong: grep -I already reads this binary file (rc $raw_text_rc), so the case proves nothing"
bin_hits="$(release_scan_dir_for_secret_values "$BIN_FIXTURE" "binary resource")" \
  || fail "the secret-value scan aborted on the binary fixture"
[[ "$bin_hits" == *"Settings.plist"* ]] \
  || fail "a credential inside a BINARY resource was MISSED:"$'\n'"${bin_hits:-<none>}"
[[ "$bin_hits" != *"notes.txt"* ]] \
  || fail "the binary pass produced a false positive on a benign text file:"$'\n'"$bin_hits"

# End to end through the real release.sh gate entry point.
BINARY_BUNDLE="$TMP/BinaryLeak.app"
make_bundle "$BINARY_BUNDLE"
printf 'BPLIST\000\001\002api_key\000%s\000\377\376tail' "$(release_canary_token)" \
  > "$BINARY_BUNDLE/Contents/Resources/Assets.plist"
run_self_test "$BINARY_BUNDLE" \
  "NATIVEAGENT_PRIVACY_DENYLIST_FILE=$GOOD_DENYLIST" \
  "NATIVEAGENT_PRIVACY_RE=" \
  "NATIVEAGENT_LOCAL_IDENTITY_RE=private_fixture_identity"
[[ "$LAST_RC" -ne 0 ]] \
  || fail "a credential in a binary bundle resource shipped as a clean bundle:"$'\n'"$LAST_OUTPUT"
[[ "$LAST_OUTPUT" == *"Assets.plist"* ]] \
  || fail "the binary-resource leak was not reported by path:"$'\n'"$LAST_OUTPUT"

# The canary itself must now carry a binary plant: a control that only tests the
# text path cannot certify the binary path.
canary_src="$(declare -f release_assert_scanner_canary)"
[[ "$canary_src" == *'canary binary.bin'* ]] \
  || fail "release_assert_scanner_canary no longer plants a BINARY negative control"

# ...and it must have teeth on that path too: with the binary pass amputated
# (strings stubbed to emit nothing), the canary must refuse rather than pass.
NO_STRINGS_BIN="$TMP/no-strings-bin"
mkdir -p "$NO_STRINGS_BIN"
printf '#!/bin/sh\nexit 0\n' > "$NO_STRINGS_BIN/strings"
chmod +x "$NO_STRINGS_BIN/strings"
canary_bin_rc=0
PATH="$NO_STRINGS_BIN:$PATH" release_assert_scanner_canary "amputated binary pass" >/dev/null 2>&1 \
  || canary_bin_rc=$?
[[ "$canary_bin_rc" -ne 0 ]] \
  || fail "the negative control passed while the binary string-table pass was amputated"

# (5) FILENAME SHAPES. Spaces and a leading dash are covered above and here; a
# NEWLINE in the filename is included because the whole enumeration path is
# find -print0 / read -r -d '', which is newline-safe. NOTE: grep -l delimits
# its OUTPUT with newlines, so such a hit is reported as two lines — the gate
# still REFUSES, which is the property that matters, and both fragments appear.
ODD_DIR="$TMP/odd names"
mkdir -p "$ODD_DIR"
printf 'api_key = "%s"\n' "$(release_canary_token)" > "$ODD_DIR/-leading-dash.txt"
NEWLINE_FILE="$ODD_DIR/$(printf 'new\nline.txt')"
printf 'api_key = "%s"\n' "$(release_canary_token)" > "$NEWLINE_FILE"
odd_hits="$(release_scan_dir_for_secret_values "$ODD_DIR" "odd filenames")" \
  || fail "the secret-value scan aborted on odd filenames"
[[ "$odd_hits" == *"-leading-dash.txt"* ]] \
  || fail "a credential in a LEADING-DASH filename was missed:"$'\n'"${odd_hits:-<none>}"
[[ "$odd_hits" == *"new"* && "$odd_hits" == *"line.txt"* ]] \
  || fail "a credential in a NEWLINE filename was missed:"$'\n'"${odd_hits:-<none>}"
# The enumerator must see it as ONE file, not two.
release_collect_scan_files "$ODD_DIR" "odd filenames"
[[ "${#RELEASE_SCAN_FILES[@]}" -eq 2 ]] \
  || fail "newline filename split the enumeration into ${#RELEASE_SCAN_FILES[@]} entries, expected 2"

# (3/4) PARTIAL FIND FAILURE. An unreadable subdirectory makes find scan a
# SUBSET and exit nonzero; before round 2 that subset was certified clean.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "NOTE: running as root — skipping the unreadable-directory cases (root reads 000)." >&2
else
  UNREADABLE_ROOT="$TMP/partial"
  mkdir -p "$UNREADABLE_ROOT/visible" "$UNREADABLE_ROOT/locked"
  printf 'benign\n' > "$UNREADABLE_ROOT/visible/ok.txt"
  printf 'api_key = "%s"\n' "$(release_canary_token)" > "$UNREADABLE_ROOT/locked/hidden token.txt"
  chmod 000 "$UNREADABLE_ROOT/locked"

  partial_rc=0
  partial_out="$(release_collect_scan_files "$UNREADABLE_ROOT" "partial walk" 2>&1)" || partial_rc=$?
  [[ "$partial_rc" -eq 2 ]] \
    || fail "a partially-failed find returned $partial_rc, expected the 2 = scanner-error code:"$'\n'"$partial_out"

  partial_rc=0
  partial_out="$(release_scan_dir_for_secret_values "$UNREADABLE_ROOT" "partial walk" 2>&1)" || partial_rc=$?
  [[ "$partial_rc" -eq 2 ]] \
    || fail "the secret-value scan certified a partially-readable tree (rc $partial_rc):"$'\n'"$partial_out"

  # release_find_checked is the shared primitive behind the verifier's walks.
  partial_rc=0
  partial_out="$(release_find_checked "partial" "$UNREADABLE_ROOT" -type f -print 2>&1)" || partial_rc=$?
  [[ "$partial_rc" -eq 2 ]] \
    || fail "release_find_checked accepted a partially-failed walk (rc $partial_rc):"$'\n'"$partial_out"

  # A1.1: an unreadable Contents/MacOS must abort, not report "no identity".
  UNREADABLE_BUNDLE="$TMP/UnreadableMacOS.app"
  make_bundle "$UNREADABLE_BUNDLE"
  chmod 000 "$UNREADABLE_BUNDLE/Contents/MacOS"
  gate_rc=0
  gate_out="$(NATIVEAGENT_PRIVACY_DENYLIST_FILE="$GOOD_DENYLIST" \
    release_assert_no_identity_strings "$UNREADABLE_BUNDLE" 2>&1)" || gate_rc=$?
  chmod 755 "$UNREADABLE_BUNDLE/Contents/MacOS"
  [[ "$gate_rc" -ne 0 ]] \
    || fail "the A1.1 gate passed on an unreadable Contents/MacOS:"$'\n'"$gate_out"
  [[ "$gate_out" != *"leak-gate] passed"* ]] \
    || fail "the A1.1 gate printed a PASS for a directory it could not read:"$'\n'"$gate_out"

  # A1.5: same for the user-state assertion's two walks.
  STATE_BUNDLE="$TMP/UnreadableState.app"
  make_bundle "$STATE_BUNDLE"
  mkdir -p "$STATE_BUNDLE/Contents/Resources/locked"
  chmod 000 "$STATE_BUNDLE/Contents/Resources/locked"
  state_rc=0
  state_out="$(release_assert_no_user_state_in_bundle "$STATE_BUNDLE" 2>&1)" || state_rc=$?
  chmod 755 "$STATE_BUNDLE/Contents/Resources/locked"
  [[ "$state_rc" -ne 0 ]] \
    || fail "the A1.5 bundle assertion passed on a partially-unreadable bundle:"$'\n'"$state_out"

  # CALL SITE, not just the lib: the artifact verifier's own process must abort
  # on a partially-failed walk. --verify-no-derived-context-state is the one
  # verifier mode that runs a real scan without a signed/notarized artifact.
  chmod 000 "$UNREADABLE_ROOT/locked"
  verifier_rc=0
  verifier_out="$("$ROOT/script/verify_release_artifact.sh" \
    --verify-no-derived-context-state "$UNREADABLE_ROOT" 2>&1)" || verifier_rc=$?
  chmod 755 "$UNREADABLE_ROOT/locked"
  [[ "$verifier_rc" -ne 0 ]] \
    || fail "verify_release_artifact.sh certified a partially-readable tree:"$'\n'"$verifier_out"
  [[ "$verifier_out" == *"did not run correctly"* ]] \
    || fail "the verifier's refusal did not name a failed scan:"$'\n'"$verifier_out"

  chmod 755 "$UNREADABLE_ROOT/locked"
fi

# ---------------------------------------------------------------------------
# ARTIFACT-VERIFIER CALL-SITE COVERAGE. The lib function being correct is not
# the same claim as the verifier CALLING the correct function: a revert of that
# one line to the text-only entry point would leave every lib test green. So
# extract the verifier's actual secret-value scan line and run it against a
# fixture whose only credential lives in a binary file.
# ---------------------------------------------------------------------------
VERIFIER="$ROOT/script/verify_release_artifact.sh"
verifier_call="$(
  grep -n 'secret_value_hits="\$(release_scan_dir_for_secret_values' "$VERIFIER" | head -1
)"
[[ -n "$verifier_call" ]] \
  || fail "verify_release_artifact.sh no longer scans secret VALUES through the binary-aware entry point"
verifier_call="${verifier_call#*:}"
verifier_call="${verifier_call%\\}"

VERIFIER_FIXTURE="$TMP/verifier-resources"
mkdir -p "$VERIFIER_FIXTURE"
printf 'ordinary bundled resource text\n' > "$VERIFIER_FIXTURE/strings.txt"
printf 'BPLIST\000\001\002api_key\000%s\000\377\376tail' "$(release_canary_token)" \
  > "$VERIFIER_FIXTURE/Prefs.plist"
# shellcheck disable=SC2034  # read by the verifier line eval'd below
RESOURCES="$VERIFIER_FIXTURE"
secret_value_hits=""
call_rc=0
eval "$verifier_call" || call_rc=$?
[[ "$call_rc" -eq 0 ]] \
  || fail "the verifier's own secret-value scan line aborted on the fixture (rc $call_rc)"
[[ "$secret_value_hits" == *"Prefs.plist"* ]] \
  || fail "the VERIFIER CALL SITE missed a credential in a binary resource:"$'\n'"${secret_value_hits:-<none>}"

# And the value scans on both sides must keep the binary pass switched on.
for value_site in "$ROOT/script/lib/release_bundle_gates.sh" "$VERIFIER"; do
  grep -q 'release_scan_dir_for_secret_values' "$value_site" \
    || fail "$value_site no longer routes its secret-value scan through the binary-aware helper"
done
grep -q 'release_scan_files_for_regex "\$RELEASE_SECRET_VALUE_RE" cs "\$label" binary' \
  "$ROOT/script/lib/release_bundle_gates.sh" \
  || fail "release_scan_dir_for_secret_values no longer requests the binary pass"

# ---------------------------------------------------------------------------
# ARTIFACT-VERIFIER REQUIRE-FLAG CONTRACT. Exercise the real verifier process
# against one hermetic bundle while fake platform trust tools report controlled
# evidence. The bundle contents still cross every ordinary verifier gate; only
# codesign/notarization are substituted because these tests must not need Apple
# credentials, a notarization ticket, or a mounted production DMG.
# ---------------------------------------------------------------------------
REQUIRE_ROOT="$TMP/require-flags"
REQUIRE_BUNDLE="$REQUIRE_ROOT/NativeAgent.app"
REQUIRE_RESOURCES="$REQUIRE_BUNDLE/Contents/Resources"
REQUIRE_INFO="$REQUIRE_BUNDLE/Contents/Info.plist"
REQUIRE_DMG="$REQUIRE_ROOT/NativeAgent-fixture.dmg"
REQUIRE_FAKE_BIN="$REQUIRE_ROOT/fake-bin"
REQUIRE_CALL_LOG="$REQUIRE_ROOT/platform-calls.log"
REQUIRE_SOURCE_RESOURCES="$ROOT/Modules/NativeAgentCore/Sources/MemoryV2/Resources"
REQUIRE_MODEL_BUNDLE="$REQUIRE_RESOURCES/NativeAgentCore_MemoryV2.bundle"
REQUIRE_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
REQUIRE_REVISION="0123456789abcdef0123456789abcdef01234567"
REQUIRE_VALID_SPARKLE_KEY="$(printf '0123456789abcdef0123456789abcdef' | base64)"

mkdir -p \
  "$REQUIRE_BUNDLE/Contents/MacOS" \
  "$REQUIRE_MODEL_BUNDLE" \
  "$REQUIRE_RESOURCES/docs" \
  "$REQUIRE_FAKE_BIN"
cp -R "$REQUIRE_SOURCE_RESOURCES/." "$REQUIRE_MODEL_BUNDLE/"
cp \
  "$ROOT/script/codex_thread_wakeup.js" \
  "$ROOT/script/claude_thread_wakeup.js" \
  "$ROOT/script/omp_thread_wakeup.js" \
  "$REQUIRE_RESOURCES/"
printf '%s\n' 'bounded release fixture data' > "$REQUIRE_RESOURCES/docs/data-bounds.md"
printf '%s\n' "$REQUIRE_VERSION" > "$REQUIRE_RESOURCES/VERSION"
printf '%s\n' "$REQUIRE_REVISION" > "$REQUIRE_RESOURCES/VERSION_SHA"
cat > "$REQUIRE_ROOT/fixture-main.c" <<'C'
#include <stdio.h>
int main(void) {
  puts("public_release_data_root.json");
  puts("NativeAgent.pre-public-backup.");
  return 0;
}
C
xcrun clang -Os -Wl,-x \
  "$REQUIRE_ROOT/fixture-main.c" \
  -o "$REQUIRE_BUNDLE/Contents/MacOS/NativeAgentApp"
chmod -R a+rX "$REQUIRE_BUNDLE"
printf '%s\n' 'synthetic dmg payload' > "$REQUIRE_DMG"

cat > "$REQUIRE_FAKE_BIN/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'codesign %s\n' "$*" >> "$FAKE_PLATFORM_CALL_LOG"
if [[ "${1:-}" == "-dv" ]]; then
  case "${FAKE_DMG_SIGNATURE:-absent}" in
    absent) exit 1 ;;
    invalid|valid) exit 0 ;;
    *) echo "unexpected fake DMG signature state" >&2; exit 64 ;;
  esac
fi
if [[ "${1:-}" == "--verify" ]]; then
  target="${!#}"
  if [[ "$target" == *.dmg ]]; then
    case "${FAKE_DMG_SIGNATURE:-absent}" in
      valid) exit 0 ;;
      invalid) echo "fixture DMG signature is invalid" >&2; exit 1 ;;
      absent) echo "fixture DMG signature is absent" >&2; exit 1 ;;
    esac
  fi
  exit 0
fi
if [[ "${1:-}" == "-d" && "${2:-}" == "--entitlements" ]]; then
  cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.personal-information.calendars</key><true/>
</dict></plist>
PLIST
  exit 0
fi
echo "unexpected codesign invocation: $*" >&2
exit 64
SH

cat > "$REQUIRE_FAKE_BIN/hdiutil" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'hdiutil %s\n' "$*" >> "$FAKE_PLATFORM_CALL_LOG"
case "${1:-}" in
  verify|detach) exit 0 ;;
  attach)
    mountpoint=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-mountpoint" && $# -ge 2 ]]; then
        mountpoint="$2"
        break
      fi
      shift
    done
    [[ -n "$mountpoint" ]] || { echo "fixture attach has no mountpoint" >&2; exit 64; }
    mkdir -p "$mountpoint"
    ln -s "$FAKE_BUNDLE_SOURCE" "$mountpoint/NativeAgent.app"
    ln -s /Applications "$mountpoint/Applications"
    ;;
  *) echo "unexpected hdiutil invocation" >&2; exit 64 ;;
esac
SH

cat > "$REQUIRE_FAKE_BIN/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcrun %s\n' "$*" >> "$FAKE_PLATFORM_CALL_LOG"
case "${FAKE_NOTARIZATION:-absent}" in
  valid) exit 0 ;;
  absent) echo "fixture notarization ticket is absent" >&2; exit 1 ;;
  invalid) echo "fixture notarization ticket is invalid" >&2; exit 1 ;;
  *) echo "unexpected fake notarization state" >&2; exit 64 ;;
esac
SH

cat > "$REQUIRE_FAKE_BIN/spctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'spctl %s\n' "$*" >> "$FAKE_PLATFORM_CALL_LOG"
case "${FAKE_NOTARIZATION:-absent}" in
  valid) exit 0 ;;
  absent) echo "fixture notarization ticket is absent" >&2; exit 1 ;;
  invalid) echo "fixture notarization ticket is invalid" >&2; exit 1 ;;
  *) echo "unexpected fake notarization state" >&2; exit 64 ;;
esac
SH
chmod +x "$REQUIRE_FAKE_BIN"/*

write_require_flag_info() { # source-dirty Boolean, optional Sparkle public key
  local source_dirty="$1" sparkle_key="$2" sparkle_xml=""
  if [[ -n "$sparkle_key" ]]; then
    sparkle_xml="<key>SUPublicEDKey</key><string>$sparkle_key</string>"
  fi
  cat > "$REQUIRE_INFO" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.embwl0x.nativeagent.mac</string>
  <key>CFBundleExecutable</key><string>NativeAgentApp</string>
  <key>CFBundleShortVersionString</key><string>$REQUIRE_VERSION</string>
  <key>CFBundleVersion</key><string>$REQUIRE_VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>com.nativeagent.chat-session</string>
  </dict></array>
  $sparkle_xml
  <key>NativeAgentSourceRevision</key><string>$REQUIRE_REVISION</string>
  <key>NativeAgentSourceDirty</key><$source_dirty/>
</dict></plist>
PLIST
}

run_require_flag_verifier() { # dmg-signature state, notarization state, args...
  local dmg_signature="$1" notarization="$2"
  shift 2
  REQUIRE_RC=0
  : > "$REQUIRE_CALL_LOG"
  REQUIRE_OUTPUT="$(
    PATH="$REQUIRE_FAKE_BIN:$PATH" \
    FAKE_DMG_SIGNATURE="$dmg_signature" \
    FAKE_NOTARIZATION="$notarization" \
    FAKE_BUNDLE_SOURCE="$REQUIRE_BUNDLE" \
    FAKE_PLATFORM_CALL_LOG="$REQUIRE_CALL_LOG" \
    NATIVEAGENT_EXPECTED_MAC_BUNDLE_ID=io.github.embwl0x.nativeagent.mac \
    NATIVEAGENT_PRIVACY_DENYLIST_FILE="$REQUIRE_ROOT/no-denylist" \
    NATIVEAGENT_PRIVACY_RE='' \
    NATIVEAGENT_LOCAL_IDENTITY_RE='' \
    bash "$VERIFIER" "$@" 2>&1
  )" || REQUIRE_RC=$?
}

require_flag_passes() {
  local label="$1"
  [[ "$REQUIRE_RC" -eq 0 ]] \
    || fail "$label failed (rc $REQUIRE_RC):"$'\n'"$REQUIRE_OUTPUT"
  [[ "$REQUIRE_OUTPUT" == *"verification passed"* ]] \
    || fail "$label returned success without the verifier pass receipt:"$'\n'"$REQUIRE_OUTPUT"
}

require_flag_fails() {
  local label="$1" expected="$2"
  [[ "$REQUIRE_RC" -ne 0 ]] \
    || fail "$label unexpectedly passed:"$'\n'"$REQUIRE_OUTPUT"
  [[ "$REQUIRE_OUTPUT" == *"$expected"* ]] \
    || fail "$label failed for the wrong reason; expected '$expected':"$'\n'"$REQUIRE_OUTPUT"
  [[ "$REQUIRE_OUTPUT" != *"verification passed"* ]] \
    || fail "$label printed a false pass receipt:"$'\n'"$REQUIRE_OUTPUT"
}

# Notarization is optional without the flag, but absent/invalid trust evidence
# must fail once required. Valid stapler and Gatekeeper evidence passes.
write_require_flag_info false ''
run_require_flag_verifier absent absent --bundle "$REQUIRE_BUNDLE"
require_flag_passes "bundle without --require-notarized"
run_require_flag_verifier absent absent --bundle "$REQUIRE_BUNDLE" --require-notarized
require_flag_fails "required absent notarization" "fixture notarization ticket is absent"
run_require_flag_verifier absent invalid --bundle "$REQUIRE_BUNDLE" --require-notarized
require_flag_fails "required invalid notarization" "fixture notarization ticket is invalid"
run_require_flag_verifier absent valid --bundle "$REQUIRE_BUNDLE" --require-notarized
require_flag_passes "required valid notarization"
[[ "$(grep -c '^xcrun stapler validate ' "$REQUIRE_CALL_LOG")" -eq 1 \
   && "$(grep -c '^spctl ' "$REQUIRE_CALL_LOG")" -eq 1 ]] \
  || fail "valid bundle notarization did not execute exactly one stapler and one Gatekeeper check"

# An unsigned DMG remains a development warning without the flag. Requiring the
# signature distinguishes absent, structurally present-but-invalid, and valid.
run_require_flag_verifier absent absent --dmg "$REQUIRE_DMG"
require_flag_passes "unsigned development DMG"
[[ "$REQUIRE_OUTPUT" == *"DMG is unsigned"* ]] \
  || fail "unsigned development DMG did not emit its warning"
run_require_flag_verifier absent absent --dmg "$REQUIRE_DMG" --require-dmg-signature
require_flag_fails "required absent DMG signature" "DMG is not codesigned"
run_require_flag_verifier invalid absent --dmg "$REQUIRE_DMG" --require-dmg-signature
require_flag_fails "required invalid DMG signature" "fixture DMG signature is invalid"
run_require_flag_verifier valid absent --dmg "$REQUIRE_DMG" --require-dmg-signature
require_flag_passes "required valid DMG signature"

# Sparkle's public key is optional for a feedless development artifact. Once
# required it must exist, decode as base64, and contain exactly 32 bytes.
write_require_flag_info false ''
run_require_flag_verifier absent absent --bundle "$REQUIRE_BUNDLE" --require-sparkle-key
require_flag_fails "required absent Sparkle key" "SUPublicEDKey is empty"
write_require_flag_info false '!!!!'
run_require_flag_verifier absent absent --bundle "$REQUIRE_BUNDLE" --require-sparkle-key
require_flag_fails "required malformed Sparkle key" "SUPublicEDKey is not valid base64"
write_require_flag_info false "$(printf 'short' | base64)"
run_require_flag_verifier absent absent --bundle "$REQUIRE_BUNDLE" --require-sparkle-key
require_flag_fails "required wrong-sized Sparkle key" "SUPublicEDKey must decode to 32 bytes"
write_require_flag_info false "$REQUIRE_VALID_SPARKLE_KEY"
run_require_flag_verifier absent absent --bundle "$REQUIRE_BUNDLE" --require-sparkle-key
require_flag_passes "required valid Sparkle key"

# Dirty provenance is allowed for development verification but is an explicit
# release refusal when --require-clean-source is selected.
write_require_flag_info true "$REQUIRE_VALID_SPARKLE_KEY"
run_require_flag_verifier absent absent --bundle "$REQUIRE_BUNDLE"
require_flag_passes "dirty development bundle"
run_require_flag_verifier absent absent --bundle "$REQUIRE_BUNDLE" --require-clean-source
require_flag_fails "required clean source with dirty provenance" \
  "release artifact was built from a dirty or unknown source tree"
write_require_flag_info false "$REQUIRE_VALID_SPARKLE_KEY"
run_require_flag_verifier absent absent --bundle "$REQUIRE_BUNDLE" --require-clean-source
require_flag_passes "required clean source with clean provenance"

# The publication shape supplies all four flags together. This final run proves
# the exact valid evidence set composes, including app + DMG notarization.
run_require_flag_verifier valid valid \
  --dmg "$REQUIRE_DMG" \
  --require-notarized \
  --require-dmg-signature \
  --require-sparkle-key \
  --require-clean-source
require_flag_passes "combined production require flags"
[[ "$(grep -c '^xcrun stapler validate ' "$REQUIRE_CALL_LOG")" -eq 2 \
   && "$(grep -c '^spctl ' "$REQUIRE_CALL_LOG")" -eq 2 ]] \
  || fail "combined production flags did not validate notarization for both app and DMG"

printf '%s\n' 'release scanner integrity contract holds'
printf '%s\n' 'release bundle identity gates passed'
