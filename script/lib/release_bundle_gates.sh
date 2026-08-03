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
# The compiled-binary gate consumes maintainer-local patterns instead of
# embedding private identities in public source. GitHub release preflight
# requires NATIVEAGENT_LOCAL_IDENTITY_RE, NATIVEAGENT_PRIVACY_RE, or a readable
# NATIVEAGENT_PRIVACY_DENYLIST_FILE, and the same input drives resource checks.
#
# WHY BOTH A MACH-O STRING SCAN AND A BYTE SCAN: macOS `strings` understands
# Mach-O sections, which keeps arbitrary instruction/model bytes from becoming
# false identity matches. `-n 3` is required for short maintainer names. It does
# not inspect bytes appended outside a loadable section, however, so a second
# section-agnostic scan covers printable runs of four or more bytes. Three-byte
# raw runs are deliberately excluded: ARM64 instructions and opaque payloads
# routinely contain coincidental triplets (the 0.3.4 public build contained
# three such `User`/`user` byte sequences while carrying no corresponding string
# literal). Source/resource identity gates cover three-character text outside
# the executable, while real compiled string literals remain visible to the
# Mach-O-aware scan.

release_identity_gate_binaries() {
  # Executables owned by this app. Contents/Frameworks (Sparkle, third-party)
  # is deliberately out of scope — we do not build it and it cannot carry our
  # identity strings.
  local bundle="$1"
  find "$bundle/Contents/MacOS" -type f -perm -u+x -print0 2>/dev/null
}

release_identity_leak_regex() {
  local regex="${NATIVEAGENT_LOCAL_IDENTITY_RE:-}"
  local privacy_regex="${NATIVEAGENT_PRIVACY_RE:-}"
  local denylist_file="${NATIVEAGENT_PRIVACY_DENYLIST_FILE:-}"
  local file_regex=""

  if [[ -n "$denylist_file" && -r "$denylist_file" ]]; then
    file_regex="$(grep -Ev '^[[:space:]]*(#|$)' "$denylist_file" | paste -sd'|' - || true)"
  fi
  for candidate in "$privacy_regex" "$file_regex"; do
    [[ -n "$candidate" ]] || continue
    if [[ -n "$regex" ]]; then
      regex="($regex)|($candidate)"
    else
      regex="$candidate"
    fi
  done
  printf '%s' "$regex"
}

# release_personal_identity_hit_files <bundle> <regex>
#
# Search every staged file except the exact, verified MiniLM resource payload.
# A general language-model vocabulary legitimately contains ordinary person
# names, so applying a maintainer's local identity denylist to it creates false
# positives. The exemption is deliberately tied to MemoryV2's known SwiftPM
# resource bundle; similarly named files elsewhere remain in scope. Secret
# value/file scans still cover the full Resources tree in release.sh.
release_personal_identity_hit_files() {
  local bundle="$1"
  local regex="$2"
  [[ -n "$regex" ]] || return 0

  find "$bundle" \
    \( -path '*/_CodeSignature' \
       -o -path '*/NativeAgentCore_MemoryV2.bundle/minilm_vocab.txt' \
       -o -path '*/NativeAgentCore_MemoryV2.bundle/minilm.mlpackage/*' \) -prune -o \
    -type f -print0 2>/dev/null \
  | xargs -0 grep -IlE "$regex" 2>/dev/null \
  || true
}

# release_assert_no_identity_strings <bundle>
# Fails (returns 1) when any app-owned executable in the bundle carries a
# private instance identity string.
release_assert_no_identity_strings() {
  local bundle="$1"
  local exe fatal_hits exact_hits section_hits raw_hits identity_regex
  local any_binary=false
  local failed=false

  identity_regex="$(release_identity_leak_regex)"
  if [[ -z "$identity_regex" ]]; then
    echo "ERROR: A1.1 leak gate has no maintainer identity/privacy denylist." >&2
    return 1
  fi

  while IFS= read -r -d '' exe; do
    any_binary=true
    # Mach-O string sections catch real compiled literals, including 3-byte
    # names. The raw pass additionally catches printable data outside sections,
    # but only for runs long enough not to confuse ARM64 instruction bytes for
    # human-readable identity text. See the WHY note above.
    section_hits="$(strings -n 3 "$exe" 2>/dev/null | grep -E "$identity_regex" || true)"
    raw_hits="$(LC_ALL=C tr -c '[:print:]' '\n' < "$exe" 2>/dev/null \
      | awk 'length($0) >= 4' \
      | grep -E "$identity_regex" || true)"
    exact_hits="$(printf '%s\n%s\n' "$section_hits" "$raw_hits" | sed '/^$/d')"
    if [[ -n "$exact_hits" ]]; then
      failed=true
      # Prefer readable `strings` output for the evidence sample; fall back to
      # the raw runs when the leak lives where strings will not look.
      fatal_hits="$(printf '%s\n' "$section_hits" | sort -u || true)"
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
