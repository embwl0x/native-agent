#!/usr/bin/env bash
# release_bundle_gates.sh — post-build, pre-signature assertions on a staged
# NativeAgent .app bundle. Sourced by script/release.sh; every function here is
# side-effect free (it reads the bundle and reports) so the gates can be run
# standalone against any existing .app:
#
#   ./script/release.sh --self-test-gates dist/NativeAgent.app
#
# A1.1 (leak gate) and A1.5 (bundle assertion) of
# docs/build_plans/prerelease-upgrade-campaign.md live here.

# ---------------------------------------------------------------------------
# A1.1 — compiled-binary identity leak gate
# ---------------------------------------------------------------------------
# The pre-existing text/binary identity guard in release.sh keys off
# NATIVEAGENT_LOCAL_IDENTITY_RE, which defaults to EMPTY — so on a machine that
# never exported that variable the "local identity names found in release
# executable strings" check silently scanned for nothing. This gate is
# unconditional and hard-coded: the two private instance identities may never
# appear in a shipped executable, no configuration required.
RELEASE_IDENTITY_LEAK_RE_CI='claude|agent'
# Canonical casings a real source reference can produce (types, wire values,
# routes, log tags, SCREAMING_CASE constants).
RELEASE_IDENTITY_LEAK_RE_EXACT='Claude|CLAUDE|claude|Agent|AGENT|agent'

# ALLOWLIST (investigated 2026-08-02, A1.1):
# Measured against the unscrubbed dev binary
# (dist/NativeAgent.app/Contents/MacOS/NativeAgentApp, 128MB):
#   case-insensitive /claude|agent/  -> 784 matching runs
#   canonical casings (above)         -> 780 matching runs
#   difference                        ->   4, all Swift mangled-symbol /
#                                          reflection-metadata noise: dense
#                                          mixed-case letter runs that happen to
#                                          contain the target letters in an order
#                                          the case-insensitive scan matches, but
#                                          in no casing any human or code
#                                          generator writes. (No example string
#                                          is embedded here on purpose — a
#                                          literal one would itself trip this
#                                          gate, and this file ships public.)
# There is NO legitimate product string containing these names, so the allowlist
# is a RULE, not a literal list: a run that matches case-insensitively but
# contains none of the canonical casings is mangler noise and is reported as a
# warning. Anything in a canonical casing fails the release, unconditionally.
#
# WHY A BYTE SCAN AND NOT `strings`: macOS `strings` (cctools) parses the Mach-O
# and only walks loadable sections — even with -a. Verified 2026-08-02 with a
# fixture whose identity strings were appended outside any section: `strings`
# and `strings -a` both returned ZERO, the byte scan found them. `strings` also
# needs a 4-char printable run, so it reported only 68 of the 780 real hits in
# the dev binary. The gate therefore decides on a section-agnostic byte scan
# (tr splits on every non-printable byte) and uses `strings` only to render
# human-readable evidence.

release_identity_gate_binaries() {
  # Executables owned by this app. Contents/Frameworks (Sparkle, third-party)
  # is deliberately out of scope — we do not build it and it cannot carry our
  # identity strings.
  local bundle="$1"
  find "$bundle/Contents/MacOS" -type f -perm -u+x -print0 2>/dev/null
}

# release_assert_no_identity_strings <bundle>
# Fails (returns 1) when any app-owned executable in the bundle carries a
# private instance identity string.
release_assert_no_identity_strings() {
  local bundle="$1"
  local exe fatal_hits noise_hits ci_hits exact_hits
  local any_binary=false
  local failed=false

  while IFS= read -r -d '' exe; do
    any_binary=true
    # Section-agnostic: every maximal run of printable bytes, not just the
    # sections `strings` chooses to walk. See the WHY note above.
    ci_hits="$(LC_ALL=C tr -c '[:print:]' '\n' < "$exe" 2>/dev/null | grep -Ei "$RELEASE_IDENTITY_LEAK_RE_CI" || true)"
    [[ -n "$ci_hits" ]] || continue
    exact_hits="$(printf '%s\n' "$ci_hits" | grep -E "$RELEASE_IDENTITY_LEAK_RE_EXACT" || true)"
    noise_hits="$(printf '%s\n' "$ci_hits" | grep -Ev "$RELEASE_IDENTITY_LEAK_RE_EXACT" || true)"
    if [[ -n "$noise_hits" ]]; then
      echo "[leak-gate] note: $(printf '%s\n' "$noise_hits" | wc -l | tr -d ' ') mangled-symbol near-match(es) in $(basename "$exe") — allowlisted (no canonical casing)." >&2
    fi
    if [[ -n "$exact_hits" ]]; then
      failed=true
      # Prefer readable `strings` output for the evidence sample; fall back to
      # the raw runs when the leak lives where strings will not look.
      fatal_hits="$(strings "$exe" 2>/dev/null | grep -E "$RELEASE_IDENTITY_LEAK_RE_EXACT" | sort -u || true)"
      [[ -n "$fatal_hits" ]] || fatal_hits="$(printf '%s\n' "$exact_hits" | sort -u)"
      echo "" >&2
      echo "ERROR: A1.1 leak gate — private instance identity compiled into $exe" >&2
      echo "       $(printf '%s\n' "$exact_hits" | wc -l | tr -d ' ') matching byte run(s); first 20 distinct readable:" >&2
      printf '%s\n' "$fatal_hits" | head -20 | cut -c1-160 | sed 's/^/    /' >&2
      echo "       A public DMG must be built from the scrubbed export" >&2
      echo "       (script/make_public_export.sh). REFUSING TO SHIP." >&2
    fi
  done < <(release_identity_gate_binaries "$bundle")

  if [[ "$any_binary" != "true" ]]; then
    echo "ERROR: A1.1 leak gate found no executable under $bundle/Contents/MacOS." >&2
    return 1
  fi
  [[ "$failed" == "false" ]] || return 1
  echo "[leak-gate] passed — no private instance identity strings in the compiled binary."
  return 0
}

# ---------------------------------------------------------------------------
# A1.5 — user-store / runtime-state bundle assertion
# ---------------------------------------------------------------------------
# The .app is read-only signed code. Any live store shipped inside it either
# leaks the developer's machine state to every downloader (trust/policy.json
# grants, providers/surfaces.json wiring) or gets resolved as the runtime data
# root on a public install, which both breaks first run and violates codesign.

# Directory basenames that only ever exist as user data roots.
RELEASE_FORBIDDEN_BUNDLE_DIRS=(
  data .runtime workspace secrets .secrets
  trust providers approvals pairings tokens credentials oauth keychain
  memory memory_proposals chat_sessions self_worktrees
  activity browser catalog connectors context dreams evolution inbox
  knowledge_graph missions nextgen scheduler traces workflow workflows
  persona
)

# Exact user-store file names, plus store suffixes, checked anywhere in the
# bundle (not just Contents/Resources).
RELEASE_FORBIDDEN_BUNDLE_FILE_RE='(^|/)(policy\.json|surfaces\.json|trust\.json|autonomy\.json|approvals\.json|pairings\.json|tokens\.json|credentials\.json|oplog(\.[A-Za-z0-9]+)?|SOUL\.md|VOICE\.md|GROWTH\.md|USER\.md)$|\.(sqlite3?|db|db-wal|db-shm|sqlite-wal|sqlite-shm|jsonl)$|\.bak$'

# CoreML .mlpackage carries a REQUIRED payload directory literally named "Data"
# (Data/com.apple.CoreML/{model.mlmodel,weights/weight.bin}). It is a build
# resource, not user state, and dropping it ships a hollow model — so it is the
# one documented exemption from the case-insensitive `data` directory rule.
RELEASE_BUNDLE_DIR_EXEMPT_RE='\.mlpackage/Data(/|$)'

# release_assert_no_user_state_in_bundle <bundle>
release_assert_no_user_state_in_bundle() {
  local bundle="$1"
  local dir_hits="" file_hits="" p rel low name forbidden

  while IFS= read -r -d '' p; do
    rel="${p#"$bundle"/}"
    [[ ! "$rel" =~ $RELEASE_BUNDLE_DIR_EXEMPT_RE ]] || continue
    name="$(basename "$p")"
    low="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    for forbidden in "${RELEASE_FORBIDDEN_BUNDLE_DIRS[@]}"; do
      if [[ "$low" == "$forbidden" ]]; then
        dir_hits="$dir_hits$rel"$'\n'
        break
      fi
    done
  done < <(find "$bundle" -type d -print0 2>/dev/null)

  while IFS= read -r -d '' p; do
    rel="${p#"$bundle"/}"
    [[ ! "$rel" =~ $RELEASE_BUNDLE_DIR_EXEMPT_RE ]] || continue
    if [[ "$rel" =~ $RELEASE_FORBIDDEN_BUNDLE_FILE_RE ]]; then
      file_hits="$file_hits$rel"$'\n'
    fi
  done < <(find "$bundle" -type f -print0 2>/dev/null)

  dir_hits="${dir_hits%$'\n'}"
  file_hits="${file_hits%$'\n'}"

  if [[ -n "$dir_hits" || -n "$file_hits" ]]; then
    echo "" >&2
    echo "ERROR: A1.5 bundle assertion — user/runtime state staged inside the .app." >&2
    if [[ -n "$dir_hits" ]]; then
      echo "  state directories:" >&2
      printf '%s\n' "$dir_hits" | sed 's/^/    /' >&2
    fi
    if [[ -n "$file_hits" ]]; then
      echo "  user-store files:" >&2
      printf '%s\n' "$file_hits" | sed 's/^/    /' >&2
    fi
    echo "  The app resolves its data root to ~/Library/Application Support/NativeAgent/" >&2
    echo "  at runtime; nothing writable belongs in the signed bundle. REFUSING TO SHIP." >&2
    return 1
  fi
  echo "[bundle-assert] passed — no data/, trust/policy.json, providers/surfaces.json, or user stores in the bundle."
  return 0
}
