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
# SCANNER INTEGRITY PRIMITIVES (2026-08-21)
# ---------------------------------------------------------------------------
# THE BUG THESE EXIST TO KILL: every secret/identity gate used to be written as
#
#     hits="$(find "$dir" -type f -print0 2>/dev/null | xargs -0 grep -IlE "$re" 2>/dev/null || true)"
#     [[ -z "$hits" ]] && echo "clean"
#
# which renders FOUR different worlds identically as a green gate:
#   1. genuinely no secrets                       (grep rc 1)
#   2. grep REJECTED the regex as invalid         (grep rc 2 — the runtime
#      denylist is assembled from local/privacy_denylist.regex, so one bad
#      line silently disables the whole scan)
#   3. the scan directory does not exist / is empty (find prints nothing)
#   4. the scanner could not read the files        (grep rc 2)
# `2>/dev/null` throws away the diagnostic and `|| true` throws away the exit
# code. `set -o pipefail` does NOT help: the `|| true` on the same line wins.
# xargs makes it worse — xargs collapses ANY utility exit in 1-125 into its own
# 123, so a clean scan and a rejected regex are indistinguishable by exit code.
#
# The contract implemented below:
#   1. VALIDATE every runtime-assembled regex before use, naming the offending
#      denylist file:line when it is rejected.
#   2. NEVER swallow scanner status. rc 0 = hits, rc 1 = clean, rc >= 2 =
#      SCANNER ERROR -> abort. Scanner stderr is left attached to the caller's
#      stderr so the diagnostic stays visible. xargs is not used at all.
#   3. ASSERT the scan had a subject — a missing or empty scan directory is an
#      abort, never a CLEAN verdict.
#   4. NEGATIVE CONTROL — before trusting a clean verdict, plant a synthetic
#      token in a throwaway tree and prove the same pipeline finds it.
#
# Calling convention for the scan helpers: matching paths on stdout (one per
# line), diagnostics on stderr, exit 0 = the scan ran and its stdout is
# authoritative (empty stdout really means clean), exit 2 = the scan did not
# run correctly and its stdout means NOTHING.

# Single source of truth for the value/filename secret shapes. release.sh and
# verify_release_artifact.sh both carried private copies of these that could
# drift apart.
RELEASE_SECRET_VALUE_RE='(sk-(proj-)?[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{20,}|[0-9]{7,12}:[A-Za-z0-9_-]{30,}|AIza[0-9A-Za-z_-]{30,}|ya29\.[0-9A-Za-z_-]{20,}|AKIA[0-9A-Z]{16}|(sk|rk)_live_[0-9A-Za-z]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,})'
# shellcheck disable=SC2034  # consumed by release.sh / verify_release_artifact.sh
RELEASE_SECRET_FILE_RE='(^|/)(\.env($|[._-])|.*\.env$|\.npmrc$|\.pypirc$|\.netrc$|id_rsa$|id_dsa$|id_ecdsa$|id_ed25519$|credentials?\.(json|ya?ml|toml|ini)$|.*credentials?\.(json|ya?ml|toml|ini)$|token(s)?\.(json|ya?ml|toml|ini)$|.*token(s)?\.(json|ya?ml|toml|ini)$|oauth.*token.*\.(json|ya?ml|toml|ini)$|client_secret(s)?\.(json|ya?ml|toml|ini)$|.*client_secret.*\.(json|ya?ml|toml|ini)$|service[-_]?account.*\.(json|ya?ml|toml|ini)$|firebase-adminsdk.*\.json$|.*\.(pem|p12|pfx|jks|keystore|key|gpg|asc)$)'

# Synthetic negative-control token. Assembled from fragments at runtime so this
# source file contains no literal vendor-shaped secret — a literal would trip
# the repo's own gitleaks pre-commit hook and every downstream secret scanner.
release_canary_token() {
  printf 'sk-%s-%s' 'ant' 'CANARYc0ffeeCANARYc0ffee0000'
}

# release_regex_is_valid <ere>
# 0 when grep accepts the pattern (rc 0/1), 1 when grep rejects it (rc >= 2).
release_regex_is_valid() {
  local re="$1"
  local rc=0
  printf '' | grep -qE -e "$re" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -le 1 ]]
}

# release_require_valid_regex <ere> <label>
# Prints grep's own rejection message so the operator sees WHY it is broken.
release_require_valid_regex() {
  local re="$1"
  local label="$2"
  if [[ -z "$re" ]]; then
    echo "ERROR: $label is empty; refusing to run a scan with no pattern." >&2
    return 1
  fi
  if release_regex_is_valid "$re"; then
    return 0
  fi
  echo "ERROR: $label is not a valid POSIX ERE — grep rejected it." >&2
  echo "       pattern (first 200 chars): $(printf '%s' "$re" | cut -c1-200)" >&2
  printf '' | grep -E -e "$re" 2>&1 >/dev/null | sed 's/^/       grep: /' >&2
  return 1
}

# release_denylist_regex_from_file <file>
# Assembles the alternation the old `grep -Ev ... | paste -sd'|'` produced, but
# validates EACH line on its own first so a rejection can name file:line, then
# validates the assembled alternation. stdout: the assembled ERE (may be empty
# when the file has only comments). rc 1 = a broken pattern; ABORT the release.
release_denylist_regex_from_file() {
  local file="$1"
  local line assembled=""
  local lineno=0
  if [[ ! -r "$file" ]]; then
    echo "ERROR: privacy denylist file is not readable: $file" >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    if [[ "$line" =~ ^[[:space:]]*(#|$) ]]; then
      continue
    fi
    if ! release_require_valid_regex "$line" "privacy denylist pattern at $file:$lineno"; then
      echo "       Fix that line; a broken denylist pattern makes the leak gate scan NOTHING." >&2
      return 1
    fi
    if [[ -n "$assembled" ]]; then
      assembled="$assembled|$line"
    else
      assembled="$line"
    fi
  done < "$file"
  if [[ -n "$assembled" ]]; then
    if ! release_require_valid_regex "$assembled" "assembled privacy denylist ERE from $file"; then
      return 1
    fi
  fi
  printf '%s' "$assembled"
  return 0
}

# release_collect_scan_files <dir> <label> [prune-path-glob...]
# Fills the RELEASE_SCAN_FILES array. rc 2 when there is no scan subject
# (directory missing, find failed, or zero files) — never a silent clean.
# NOTE: mutates a global, so callers that need the array must NOT invoke this
# inside a command substitution. The release_scan_dir_* wrappers below are the
# supported entry points and are subshell-safe.
release_collect_scan_files() {
  local dir="$1"
  local label="$2"
  shift 2
  release_collect_scan_files_of_type "$dir" "$label" f "$@"
}

# release_collect_scan_files_of_type <dir> <label> <find-type> [prune-path-glob...]
# Same contract as release_collect_scan_files, with find's -type selectable so
# the directory-shaped assertions (A1.5) get the identical status handling
# instead of their own `find ... 2>/dev/null`.
release_collect_scan_files_of_type() {
  local dir="$1"
  local label="$2"
  local find_type="$3"
  shift 3
  RELEASE_SCAN_FILES=()
  if [[ ! -d "$dir" ]]; then
    echo "ERROR: $label scan directory does not exist: $dir" >&2
    echo "       A missing scan subject is NOT a clean scan. REFUSING TO SHIP." >&2
    return 2
  fi
  local -a find_args
  find_args=("$dir")
  if [[ $# -gt 0 ]]; then
    local first=1 prune
    find_args+=('(')
    for prune in "$@"; do
      if [[ "$first" -eq 1 ]]; then first=0; else find_args+=(-o); fi
      find_args+=(-path "$prune")
    done
    find_args+=(')' -prune -o)
  fi
  find_args+=(-type "$find_type" -print0)
  local status_file f find_rc
  status_file="$(mktemp "${TMPDIR:-/tmp}/nativeagent-scan-find.XXXXXX")" || return 2
  while IFS= read -r -d '' f; do
    RELEASE_SCAN_FILES+=("$f")
  done < <(find "${find_args[@]}"; printf '%s' "$?" > "$status_file")
  find_rc="$(cat "$status_file")"
  rm -f "$status_file"
  if [[ "$find_rc" != "0" ]]; then
    echo "ERROR: $label file enumeration failed under $dir (find exit $find_rc)." >&2
    echo "       An unreadable scan subject is NOT a clean scan. REFUSING TO SHIP." >&2
    return 2
  fi
  if [[ "${#RELEASE_SCAN_FILES[@]}" -eq 0 ]]; then
    echo "ERROR: $label scan found no files under $dir." >&2
    echo "       An empty scan subject is NOT a clean scan. REFUSING TO SHIP." >&2
    return 2
  fi
  return 0
}

# release_scan_binary_files_for_regex <ere> <cs|ci> <label>
# SECOND PASS for value scans, over the files the -I text pass REFUSED TO READ.
#
# THE BUG THIS EXISTS TO KILL (2026-08-21, review round 2): `grep -I` classifies
# any file carrying NUL bytes as binary and reports NO MATCH in it — rc 1, which
# is indistinguishable from "this file is clean". A credential embedded in a
# binary plist, a compiled asset catalog, a nib, or any other binary resource is
# therefore invisible to the text pass, and the canary (a .txt file) could never
# notice, because the canary only ever exercised the text path.
#
# Classification is grep's own: `grep -Iq -e ''` matches the first line of any
# TEXT file (rc 0) and refuses a binary one (rc 1), so the two passes partition
# RELEASE_SCAN_FILES exactly, with no file read twice for matching. An empty
# file lands here too and yields an empty string table, which is harmless.
# rc >= 2 from the classifier is a real read failure and aborts like everything
# else. Same status contract as the text pass: rc 2 = the scan did NOT run.
release_scan_binary_files_for_regex() {
  local regex="$1"
  local case_mode="$2"
  local label="$3"
  local -a flags
  if [[ "$case_mode" == "ci" ]]; then flags=(-Eqi); else flags=(-Eq); fi
  local n="${#RELEASE_SCAN_FILES[@]}"
  [[ "$n" -gt 0 ]] || return 0
  local f rc hits="" failed=0 tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/nativeagent-scan-binpass.XXXXXX")" || return 2
  for f in "${RELEASE_SCAN_FILES[@]}"; do
    rc=0
    LC_ALL=C grep -Iq -e '' -- "$f" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      continue  # text file: pass 1 already read it
    fi
    if [[ "$rc" -gt 1 ]]; then
      echo "ERROR: $label binary classifier FAILED on $f — grep exited $rc." >&2
      echo "       A scanner error is NOT a clean scan. REFUSING TO SHIP." >&2
      failed=1
      continue
    fi
    if ! LC_ALL=C strings -a -- "$f" > "$tmp"; then
      echo "ERROR: $label could not read the string table of binary file $f." >&2
      echo "       An unreadable scan subject is NOT a clean scan. REFUSING TO SHIP." >&2
      failed=1
      continue
    fi
    rc=0
    LC_ALL=C grep "${flags[@]}" -e "$regex" -- "$tmp" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      hits="$hits$f"$'\n'
    elif [[ "$rc" -ne 1 ]]; then
      echo "ERROR: $label binary scanner FAILED on $f — grep exited $rc." >&2
      echo "       A scanner error is NOT a clean scan. REFUSING TO SHIP." >&2
      failed=1
    fi
  done
  rm -f "$tmp"
  [[ "$failed" -eq 0 ]] || return 2
  hits="${hits%$'\n'}"
  [[ -z "$hits" ]] || printf '%s\n' "$hits"
  return 0
}

# release_scan_files_for_regex <ere> <cs|ci> <label> [binary]
# Greps RELEASE_SCAN_FILES in bounded batches, keeping each grep's real exit
# code. No xargs (its 123 collapses clean and broken into one code) and no
# stderr redirection (the diagnostic must stay visible).
#
# A 4th argument of `binary` adds the string-table pass over binary-classified
# files (see release_scan_binary_files_for_regex). Value scans MUST pass it;
# identity/name scans deliberately do not, because the identity gate has its own
# dedicated Mach-O + raw-byte passes with a tuned minimum run length, and
# blanket string-table matching of short human names inside compiled payloads is
# exactly the false-positive source documented in the A1.1 note below.
release_scan_files_for_regex() {
  local regex="$1"
  local case_mode="$2"
  local label="$3"
  local binary_mode="${4:-}"
  local -a flags
  if [[ "$case_mode" == "ci" ]]; then flags=(-IlEi); else flags=(-IlE); fi
  local n="${#RELEASE_SCAN_FILES[@]}"
  [[ "$n" -gt 0 ]] || return 0
  local i=0 chunk=200 rc out hits="" failed=0
  local -a batch
  while [[ "$i" -lt "$n" ]]; do
    batch=("${RELEASE_SCAN_FILES[@]:$i:$chunk}")
    i=$((i + chunk))
    rc=0
    out="$(grep "${flags[@]}" -e "$regex" -- "${batch[@]}")" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      hits="$hits$out"$'\n'
    elif [[ "$rc" -ne 1 ]]; then
      echo "ERROR: $label scanner FAILED — grep exited $rc (see its diagnostic above)." >&2
      echo "       A scanner error is NOT a clean scan. REFUSING TO SHIP." >&2
      failed=1
    fi
  done
  if [[ "$binary_mode" == "binary" ]]; then
    rc=0
    out="$(release_scan_binary_files_for_regex "$regex" "$case_mode" "$label")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      failed=1
    elif [[ -n "$out" ]]; then
      hits="$hits$out"$'\n'
    fi
  fi
  [[ "$failed" -eq 0 ]] || return 2
  hits="${hits%$'\n'}"
  [[ -z "$hits" ]] || printf '%s\n' "$hits"
  return 0
}

# release_scan_dir_for_regex <dir> <label> <cs|ci> <ere> [prune-path-glob...]
# The supported entry point: validate -> assert a subject -> scan.
# stdout = matching paths; rc 0 = trustworthy result; rc 2 = ABORT.
release_scan_dir_for_regex() {
  local dir="$1"
  local label="$2"
  local case_mode="$3"
  local regex="$4"
  shift 4
  release_require_valid_regex "$regex" "$label scan pattern" || return 2
  release_collect_scan_files "$dir" "$label" "$@" || return 2
  release_scan_files_for_regex "$regex" "$case_mode" "$label" || return 2
  return 0
}

# release_scan_dir_for_secret_values <dir> <label> [prune-path-glob...]
# THE entry point for credential-VALUE scans. Identical to
# release_scan_dir_for_regex except it pins the shared secret pattern and turns
# on the binary string-table pass, so a token hidden in a binary resource is
# found instead of silently skipped by `grep -I`. Both the release leak guard
# and the artifact verifier call this; neither should hand-roll the flag.
release_scan_dir_for_secret_values() {
  local dir="$1"
  local label="$2"
  shift 2
  release_require_valid_regex "$RELEASE_SECRET_VALUE_RE" "$label scan pattern" || return 2
  release_collect_scan_files "$dir" "$label" "$@" || return 2
  release_scan_files_for_regex "$RELEASE_SECRET_VALUE_RE" cs "$label" binary || return 2
  return 0
}

# release_find_checked <label> <find-arg...>
# find with its exit status KEPT. `find ... 2>/dev/null || true` renders a
# partially-failed walk (unreadable subdirectory -> rc 1, subset of the tree
# scanned) identically to a clean one, so a leak sitting in the unreadable part
# reads as absent. stdout = find's output; rc 2 = the walk failed, ABORT.
#
# Callers must NOT pass -quit: BSD find exits 0 on -quit even after it already
# hit an error, which throws away exactly the status this function exists to
# keep. Report the first line of the full output instead.
release_find_checked() {
  local label="$1"
  shift
  local out_file rc=0
  out_file="$(mktemp "${TMPDIR:-/tmp}/nativeagent-find.XXXXXX")" || return 2
  find "$@" > "$out_file" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$out_file"
    echo "ERROR: $label file enumeration FAILED (find exit $rc; see its diagnostic above)." >&2
    echo "       A partially-scanned tree is NOT a clean scan. REFUSING TO SHIP." >&2
    return 2
  fi
  cat "$out_file"
  rm -f "$out_file"
  return 0
}

# release_scan_dir_for_filename_re <dir> <label> <ere>
# Case-insensitive filename match over the same asserted file list. Replaces
# the old `find | awk | awk || true` chain, which both swallowed status and
# stopped at the first hit.
release_scan_dir_for_filename_re() {
  local dir="$1"
  local label="$2"
  local name_re="$3"
  release_require_valid_regex "$name_re" "$label filename pattern" || return 2
  release_collect_scan_files "$dir" "$label" || return 2
  local f hits="" restore_nocasematch=0
  if shopt -q nocasematch; then restore_nocasematch=1; fi
  shopt -s nocasematch
  for f in "${RELEASE_SCAN_FILES[@]}"; do
    if [[ "$f" =~ $name_re ]]; then
      hits="$hits$f"$'\n'
    fi
  done
  [[ "$restore_nocasematch" -eq 1 ]] || shopt -u nocasematch
  hits="${hits%$'\n'}"
  [[ -z "$hits" ]] || printf '%s\n' "$hits"
  return 0
}

# release_scan_binary_for_regex <executable> <label> <cs|ci> <ere>
# `strings | grep ... | head -20 || true` had the same collapse, plus a SIGPIPE
# from head. Materialize the string table, check every exit code, then trim.
release_scan_binary_for_regex() {
  local exe="$1"
  local label="$2"
  local case_mode="$3"
  local regex="$4"
  release_require_valid_regex "$regex" "$label scan pattern" || return 2
  if [[ ! -s "$exe" ]]; then
    echo "ERROR: $label scan target is missing or empty: $exe" >&2
    echo "       A missing scan subject is NOT a clean scan. REFUSING TO SHIP." >&2
    return 2
  fi
  local tmp rc=0 out
  tmp="$(mktemp "${TMPDIR:-/tmp}/nativeagent-scan-strings.XXXXXX")" || return 2
  if ! strings "$exe" > "$tmp"; then
    rm -f "$tmp"
    echo "ERROR: $label could not read the string table of $exe." >&2
    return 2
  fi
  if [[ ! -s "$tmp" ]]; then
    # Not fatal on its own — a stubbed/stripped `strings` legitimately yields
    # nothing — but never silent: a clean verdict from an empty string table is
    # a verdict about nothing.
    echo "WARNING: $label extracted no printable strings from $exe; that scan proves nothing." >&2
  fi
  local -a flags
  if [[ "$case_mode" == "ci" ]]; then flags=(-Ei); else flags=(-E); fi
  out="$(grep "${flags[@]}" -e "$regex" -- "$tmp")" || rc=$?
  rm -f "$tmp"
  if [[ "$rc" -gt 1 ]]; then
    echo "ERROR: $label scanner FAILED — grep exited $rc (see its diagnostic above)." >&2
    return 2
  fi
  [[ "$rc" -ne 0 ]] || printf '%s\n' "$out" | head -20
  return 0
}

# The optional case-insensitive identity scan treats punctuation as a boundary,
# including underscores and possessives, but never matches inside alphanumerics.
# A1.1 deliberately retains its separate case-sensitive scans unchanged.
release_scan_binary_for_local_identity() {
  local exe="$1" label="$2" regex="$3" tmp rc=0 out string_hits
  release_require_valid_regex "$regex" "$label scan pattern" || return 2
  regex="(^|[^[:alnum:]])($regex)([^[:alnum:]]|$)"
  string_hits="$(release_scan_binary_for_regex "$exe" "$label" ci "$regex")" || return 2
  tmp="$(mktemp "${TMPDIR:-/tmp}/nativeagent-identity-runs.XXXXXX")" || return 2
  if ! LC_ALL=C tr -c '[:print:]' '\n' < "$exe" > "$tmp"; then
    rm -f "$tmp"
    echo "ERROR: $label could not extract executable byte runs." >&2
    return 2
  fi
  out="$(LC_ALL=C grep -Ei -e "$regex" -- "$tmp")" || rc=$?
  rm -f "$tmp"
  [[ "$rc" -le 1 ]] || { echo "ERROR: $label byte-run scan failed ($rc)." >&2; return 2; }
  # A short byte run with jumbled case (a lowercase letter then capitals) is
  # machine-code noise, not a name; a real literal is lowercase, Capitalized or
  # UPPERCASE, and a real path or address is longer. Keep those; drop the noise.
  if [[ "$rc" -eq 0 ]]; then
    out="$(LC_ALL=C awk 'length($0) >= 8 || $0 ~ /^[^A-Za-z]*([a-z]+|[A-Z][a-z]+|[A-Z]+)[^A-Za-z]*$/' <<<"$out")"
    [[ -n "$out" ]] || rc=1
  fi
  [[ -z "$string_hits" ]] || printf '%s\n' "$string_hits"
  [[ "$rc" -ne 0 ]] || printf '%s\n' "$out" | head -20
  return 0
}

# release_assert_scanner_canary <label>
# NEGATIVE CONTROL. Runs the real scan pipeline over a throwaway tree holding
# TWO planted synthetic tokens and two benign files:
#   - a TEXT file, in a path WITH A SPACE (which also exercises hit reporting);
#   - a BINARY file (NUL bytes around the token), which `grep -I` refuses to
#     read and reports as rc 1 "no match". Before round 2 the canary planted
#     only text, so the entire binary-resource blind spot was invisible to the
#     very control that exists to prove the pipeline has teeth.
# A pipeline that cannot find a known token cannot certify anything clean, so a
# miss on EITHER file aborts the release. Nothing is ever written inside the
# real bundle.
release_assert_scanner_canary() {
  local label="$1"
  local tmp rc=0 hits
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/nativeagent-scan-canary.XXXXXX")" || return 1
  mkdir -p "$tmp/nested dir"
  printf 'api_key = "%s"\n' "$(release_canary_token)" > "$tmp/nested dir/canary token.txt"
  printf 'BPLIST\000\001\002api_key\000%s\000\377\376trailer' "$(release_canary_token)" \
    > "$tmp/canary binary.bin"
  printf 'ordinary release text with no credentials\n' > "$tmp/benign.txt"
  printf 'BPLIST\000\001\002ordinary\000binary\000resource\000\377\376' > "$tmp/benign.bin"
  hits="$(release_scan_dir_for_secret_values "$tmp" "$label negative control")" || rc=$?
  rm -rf "$tmp"
  if [[ "$rc" -ne 0 ]]; then
    echo "ERROR: $label negative control could not run (rc $rc)." >&2
    echo "       REFUSING TO SHIP behind a scanner that does not work." >&2
    return 1
  fi
  if [[ "$hits" != *"canary token.txt"* ]]; then
    echo "ERROR: $label negative control FAILED — the secret scan pipeline did not find a planted token." >&2
    echo "       reported hits: ${hits:-<none>}" >&2
    echo "       A gate that cannot find a known secret cannot certify a bundle clean. REFUSING TO SHIP." >&2
    return 1
  fi
  if [[ "$hits" != *"canary binary.bin"* ]]; then
    echo "ERROR: $label negative control FAILED — the secret scan pipeline did not find a token" >&2
    echo "       planted in a BINARY file; binary resources are being skipped silently." >&2
    echo "       reported hits: ${hits:-<none>}" >&2
    echo "       A gate that cannot find a known secret cannot certify a bundle clean. REFUSING TO SHIP." >&2
    return 1
  fi
  if [[ "$hits" == *"benign.bin"* ]]; then
    echo "ERROR: $label negative control FAILED — the secret scan matched a benign binary file." >&2
    echo "       reported hits: $hits" >&2
    return 1
  fi
  if [[ "$hits" == *"benign.txt"* ]]; then
    echo "ERROR: $label negative control FAILED — the secret scan matched a benign file." >&2
    echo "       reported hits: $hits" >&2
    return 1
  fi
  return 0
}

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

# release_collect_identity_gate_binaries <bundle>
# Fills RELEASE_IDENTITY_BINARIES with the app-owned executables. Contents/
# Frameworks (Sparkle, third-party) is deliberately out of scope — we do not
# build it and it cannot carry our identity strings.
#
# rc 0 = the list is complete and non-empty. rc 2 = the enumeration failed or
# found nothing, which is a staging failure, NOT a clean binary. The previous
# `find ... 2>/dev/null` piped into a process substitution had no status check
# anywhere: a find that failed partway (unreadable directory) scanned whatever
# subset it managed to print and the gate passed on it.
#
# NOTE: mutates a global, so it must not be called inside a command
# substitution by a caller that needs the array.
release_collect_identity_gate_binaries() {
  local bundle="$1"
  RELEASE_IDENTITY_BINARIES=()
  local dir="$bundle/Contents/MacOS"
  if [[ ! -d "$dir" ]]; then
    echo "ERROR: A1.1 leak gate has no executable directory to scan: $dir" >&2
    echo "       A missing scan subject is NOT a clean binary. REFUSING TO SHIP." >&2
    return 2
  fi
  local status_file f find_rc
  status_file="$(mktemp "${TMPDIR:-/tmp}/nativeagent-gate-find.XXXXXX")" || return 2
  while IFS= read -r -d '' f; do
    RELEASE_IDENTITY_BINARIES+=("$f")
  done < <(find "$dir" -type f -perm -u+x -print0; printf '%s' "$?" > "$status_file")
  find_rc="$(cat "$status_file")"
  rm -f "$status_file"
  if [[ "$find_rc" != "0" ]]; then
    echo "ERROR: A1.1 leak gate could not enumerate executables under $dir (find exit $find_rc)." >&2
    echo "       A partially-scanned tree is NOT a clean binary. REFUSING TO SHIP." >&2
    return 2
  fi
  if [[ "${#RELEASE_IDENTITY_BINARIES[@]}" -eq 0 ]]; then
    echo "ERROR: A1.1 leak gate found no executable under $dir." >&2
    return 2
  fi
  return 0
}

release_identity_leak_regex() {
  local regex="${NATIVEAGENT_LOCAL_IDENTITY_RE:-}"
  local privacy_regex="${NATIVEAGENT_PRIVACY_RE:-}"
  local denylist_file="${NATIVEAGENT_PRIVACY_DENYLIST_FILE:-}"
  local file_regex=""

  if [[ -n "$denylist_file" && -r "$denylist_file" ]]; then
    # rc 1 here means a pattern in the denylist is broken. Propagating it (not
    # `|| true`) is the whole point: a scan driven by a rejected regex finds
    # nothing and looks exactly like a clean bundle.
    file_regex="$(release_denylist_regex_from_file "$denylist_file")" || return 1
  fi
  for candidate in "$privacy_regex" "$file_regex"; do
    [[ -n "$candidate" ]] || continue
    if [[ -n "$regex" ]]; then
      regex="($regex)|($candidate)"
    else
      regex="$candidate"
    fi
  done
  if [[ -n "$regex" ]]; then
    release_require_valid_regex "$regex" "assembled identity/privacy denylist" || return 1
  fi
  printf '%s' "$regex"
}

# release_personal_identity_hit_files <bundle> <regex>
#
# Search every staged file except the exact, verified MiniLM resource payload.
# A general language-model vocabulary legitimately contains ordinary person
# names, so applying a maintainer's local identity denylist to it creates false
# positives. The exemption is deliberately tied to MemoryV2's known SwiftPM
# resource bundle and to the staged large embedding model under
# Contents/Resources/embedding/ (the same kind of vocabulary; 2026-09-05, when
# the standard BERT vocabulary's token "user" tripped the guard). Similarly
# named files elsewhere remain in scope. Secret
# value/file scans still cover the full Resources tree in release.sh.
#
# rc 0 = the scan ran; stdout is authoritative (empty really means clean).
# rc 2 = the scan did NOT run correctly; stdout means nothing — abort.
release_personal_identity_hit_files() {
  local bundle="$1"
  local regex="$2"
  [[ -n "$regex" ]] || return 0

  release_scan_dir_for_regex "$bundle" "personal identity" cs "$regex" \
    '*/_CodeSignature' \
    '*/NativeAgentCore_MemoryV2.bundle/minilm_vocab.txt' \
    '*/NativeAgentCore_MemoryV2.bundle/minilm.mlpackage/*' \
    '*/Contents/Resources/embedding/vocab.txt' \
    '*/Contents/Resources/embedding/embedding.mlpackage/*'
}

# release_assert_no_identity_strings <bundle>
# Fails (returns 1) when any app-owned executable in the bundle carries a
# private instance identity string.
release_assert_no_identity_strings() {
  local bundle="$1"
  local exe fatal_hits exact_hits section_hits raw_hits identity_regex
  local section_tmp raw_tmp scan_copy scan_rc
  local failed=false

  identity_regex="$(release_identity_leak_regex)" || {
    echo "ERROR: A1.1 leak gate could not assemble a usable identity denylist." >&2
    echo "       A broken pattern scans nothing and looks clean. REFUSING TO SHIP." >&2
    return 1
  }
  if [[ -z "$identity_regex" ]]; then
    echo "ERROR: A1.1 leak gate has no maintainer identity/privacy denylist." >&2
    return 1
  fi
  release_require_valid_regex "$identity_regex" "A1.1 identity leak pattern" || return 1

  # Enumerate FIRST, with find's status checked, and assert the list is
  # non-empty before believing any per-file verdict.
  release_collect_identity_gate_binaries "$bundle" || return 1

  for exe in "${RELEASE_IDENTITY_BINARIES[@]}"; do
    # Subject assertion: a zero-byte executable is not something that can be
    # certified clean, it is something that failed to stage.
    if [[ ! -s "$exe" ]]; then
      echo "ERROR: A1.1 leak gate scan subject is empty: $exe" >&2
      failed=true
      continue
    fi
    # Mach-O string sections catch real compiled literals, including 3-byte
    # names. The raw pass additionally catches printable data outside sections,
    # but only for runs long enough not to confuse ARM64 instruction bytes for
    # human-readable identity text. See the WHY note above.
    #
    # Both passes keep grep's real exit status: rc 0 = hits, rc 1 = clean,
    # rc >= 2 = the scanner itself failed, which is NOT a clean binary.
    section_tmp="$(mktemp "${TMPDIR:-/tmp}/nativeagent-gate-sections.XXXXXX")" || return 1
    raw_tmp="$(mktemp "${TMPDIR:-/tmp}/nativeagent-gate-raw.XXXXXX")" || { rm -f "$section_tmp"; return 1; }
    scan_copy="$(mktemp "${TMPDIR:-/tmp}/nativeagent-gate-copy.XXXXXX")" || { rm -f "$section_tmp" "$raw_tmp"; return 1; }
    # strings recognizes Swift typeref sections but mistakes pointer payloads
    # inside them for text. Mask only ABI-defined numeric reference bytes in a
    # disposable scan copy. The shipped executable is never modified here.
    if ! swift "$(dirname "${BASH_SOURCE[0]}")/../macho_identity_scan_copy.swift" "$exe" > "$scan_copy"; then
      rm -f "$section_tmp" "$raw_tmp" "$scan_copy"
      echo "ERROR: A1.1 leak gate could not decode Mach-O metadata in $exe." >&2
      failed=true
      continue
    fi
    if ! strings -n 3 "$scan_copy" > "$section_tmp"; then
      rm -f "$section_tmp" "$raw_tmp" "$scan_copy"
      echo "ERROR: A1.1 leak gate could not read the string table of $exe." >&2
      failed=true
      continue
    fi
    if ! LC_ALL=C tr -c '[:print:]' '\n' < "$scan_copy" | awk 'length($0) >= 4' > "$raw_tmp"; then
      rm -f "$section_tmp" "$raw_tmp" "$scan_copy"
      echo "ERROR: A1.1 leak gate could not extract printable byte runs from $exe." >&2
      failed=true
      continue
    fi
    scan_rc=0
    section_hits="$(grep -E -e "$identity_regex" -- "$section_tmp")" || scan_rc=$?
    if [[ "$scan_rc" -gt 1 ]]; then
      rm -f "$section_tmp" "$raw_tmp" "$scan_copy"
      echo "ERROR: A1.1 leak gate section scan FAILED on $exe — grep exited $scan_rc." >&2
      failed=true
      continue
    fi
    scan_rc=0
    raw_hits="$(grep -E -e "$identity_regex" -- "$raw_tmp")" || scan_rc=$?
    rm -f "$section_tmp" "$raw_tmp" "$scan_copy"
    if [[ "$scan_rc" -gt 1 ]]; then
      echo "ERROR: A1.1 leak gate raw-byte scan FAILED on $exe — grep exited $scan_rc." >&2
      failed=true
      continue
    fi
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
  done

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

  # Both walks go through release_collect_scan_files, which keeps find's exit
  # status and refuses an empty/missing subject. The old `2>/dev/null` finds
  # here could fail partway through the bundle and the gate would pass on the
  # subset that happened to be printed.
  release_collect_scan_files_of_type "$bundle" "A1.5 bundle directory" d || return 1
  for p in "${RELEASE_SCAN_FILES[@]}"; do
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
  done

  release_collect_scan_files "$bundle" "A1.5 bundle file" || return 1
  for p in "${RELEASE_SCAN_FILES[@]}"; do
    rel="${p#"$bundle"/}"
    [[ ! "$rel" =~ $RELEASE_BUNDLE_DIR_EXEMPT_RE ]] || continue
    if [[ "$rel" =~ $RELEASE_FORBIDDEN_BUNDLE_FILE_RE ]]; then
      file_hits="$file_hits$rel"$'\n'
    fi
  done

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

# ---------------------------------------------------------------------------
# A1.0 — public-release leak guard (extracted from release.sh, 2026-08-21)
# ---------------------------------------------------------------------------
# release_assert_no_leaked_data <bundle> <product> <repo_root>
# Returns 0 when the staged bundle is genuinely clean, 1 when it leaks OR when
# any scan could not be trusted. Lives here (rather than inline in release.sh)
# so `release.sh --self-test-gates <app>` can prove the guard actually fires
# without a 20-minute build.
release_assert_no_leaked_data() {
  local BUNDLE="$1"
  local PRODUCT="$2"
  local ROOT="$3"
  local _RES_DIR _PRIVACY_DENYLIST_FILE _PERSONAL_RE _FILE_PRIVACY_RE
  local _PUBLIC_IDENTITY_RE _SECRET_VALUE_RE _SECRET_FILE_RE _EXECUTABLE
  local _raw_hits _personal_hits _identity_text_hits _secret_text_hits
  local _secret_file_hits _forbidden_runtime_hits _LOCAL_STATE_DIR_RE
  local _nested_state_hits _live_persona_hits _test_artifact_hits
  local _identity_binary_hits _secret_binary_hits _secret_binary_matches
  local _rel _f

  # PUBLIC-RELEASE LEAK GUARD: a release bundle must contain ZERO developer
  # personal data, ZERO credential-looking values, ZERO live runtime state, and
  # ZERO local-agent identity defaults in app-owned resources.
  # Scope is deliberate:
  #   - personal identifiers (handle / location / telegram id / email) fail
  #     everywhere in app-owned content. The exact verified MiniLM model payload
  #     is exempt because a general vocabulary legitimately contains ordinary
  #     person names; similarly named files elsewhere remain fully scanned.
  #   - app-owned text resources fail on common API/OAuth/JWT/private-key token
  #     shapes. This catches pasted OpenAI/Anthropic/GitHub/Slack/Telegram/
  #     Google/AWS/Stripe-style secrets without flagging code variable names.
  #   - app-owned secret-bearing file names fail even when the value inside is
  #     opaque/random and does not match a vendor-specific token regex: .env,
  #     token/credential/client-secret JSON, PEM/P12/PFX/key material, npm/pypi
  #     credential files, and SSH private keys. OAuth *code* may ship; OAuth
  #     token/cache/config files may not.
  #   - live state directories and live persona files fail. Release builds ship
  #     NO persona directory inside the bundle (see ONBOARDING-2026-05-26 above);
  #     the Swift runtime resolves persona to ~/Library/Application Support/NativeAgent/
  #     memory/ at first run and the onboarding wizard scaffolds a blank slate
  #     there.
  #   - old local-agent names fail in app-owned text resources and in the
  #     release executable's string table.
  # Runs after ALL staging, before codesign — a tampered/regressed persona
  # step aborts the release instead of shipping the developer's data.
  #
  # SCANNER-INTEGRITY CONTRACT (2026-08-21): every scan below goes through the
  # release_scan_* helpers in script/lib/release_bundle_gates.sh, which validate
  # the pattern, assert the scan had a subject, and propagate the scanner's exit
  # code instead of `2>/dev/null || true`. An empty result is only allowed to
  # mean "clean" when the scan is known to have actually run.
  _RES_DIR="$BUNDLE/Contents/Resources"
  _PRIVACY_DENYLIST_FILE="${NATIVEAGENT_PRIVACY_DENYLIST_FILE:-$ROOT/local/privacy_denylist.regex}"
  _PERSONAL_RE="${NATIVEAGENT_PRIVACY_RE:-}"
  if [[ -n "$_PERSONAL_RE" ]]; then
    release_require_valid_regex "$_PERSONAL_RE" "NATIVEAGENT_PRIVACY_RE" \
      || { echo "ERROR: refusing to run the leak guard behind a broken privacy pattern." >&2; return 1; }
  fi
  if [[ -f "$_PRIVACY_DENYLIST_FILE" ]]; then
    _FILE_PRIVACY_RE="$(release_denylist_regex_from_file "$_PRIVACY_DENYLIST_FILE")" \
      || { echo "ERROR: privacy denylist $_PRIVACY_DENYLIST_FILE is unusable — REFUSING TO SHIP." >&2; return 1; }
    if [[ -n "$_FILE_PRIVACY_RE" ]]; then
      if [[ -n "$_PERSONAL_RE" ]]; then
        _PERSONAL_RE="($_PERSONAL_RE)|($_FILE_PRIVACY_RE)"
      else
        _PERSONAL_RE="$_FILE_PRIVACY_RE"
      fi
    fi
  fi
  _PUBLIC_IDENTITY_RE="${NATIVEAGENT_LOCAL_IDENTITY_RE:-}"
  _SECRET_VALUE_RE="$RELEASE_SECRET_VALUE_RE"
  _SECRET_FILE_RE="$RELEASE_SECRET_FILE_RE"

  # NEGATIVE CONTROL (part 4). Prove the secret-scan pipeline can still find a
  # planted synthetic token — in a throwaway tree, never inside the real bundle —
  # before any of its clean verdicts are believed.
  release_assert_scanner_canary "release leak guard" \
    || { echo "ERROR: leak-guard self-test failed — REFUSING TO SHIP." >&2; return 1; }

  _raw_hits=""
  if [[ -n "$_PERSONAL_RE" ]]; then
    _raw_hits="$(release_personal_identity_hit_files "$BUNDLE" "$_PERSONAL_RE")" \
      || { echo "ERROR: personal-identity scan of $BUNDLE did not run correctly — REFUSING TO SHIP." >&2; return 1; }
  else
    echo "==> WARNING: no NATIVEAGENT_PRIVACY_RE and no usable privacy denylist —"
    echo "    the personal-identifier scan is SKIPPED for this build."
  fi
  # Preserve full paths: word-splitting on $_raw_hits used to shred any hit path
  # containing a space, so the guard reported a truncated fragment of the file it
  # was refusing to ship.
  _personal_hits=""
  while IFS= read -r _f; do
    [[ -n "$_f" ]] || continue
    _personal_hits="$_personal_hits$_f"$'\n'
  done <<< "$_raw_hits"
  _personal_hits="${_personal_hits%$'\n'}"
  _identity_text_hits=""
  if [[ -n "$_PUBLIC_IDENTITY_RE" ]]; then
    _identity_text_hits="$(
      release_scan_dir_for_regex "$_RES_DIR" "release resource identity" ci "$_PUBLIC_IDENTITY_RE" \
        '*/minilm_vocab.txt' '*/minilm.mlpackage/*' \
        '*/embedding/vocab.txt' '*/embedding/embedding.mlpackage/*'
    )" || { echo "ERROR: identity resource scan did not run correctly — REFUSING TO SHIP." >&2; return 1; }
  else
    # A silently skipped identity scan is how a leak ships as a green gate.
    # script/release_github.sh already REQUIRES this input; a direct release.sh
    # run must at minimum announce that the check did not happen.
    echo "==> WARNING: NATIVEAGENT_LOCAL_IDENTITY_RE is unset — the local-identity"
    echo "    scan of app resources AND of the release executable is SKIPPED."
    echo "    Set NATIVEAGENT_LOCAL_IDENTITY_RE (script/release_github.sh requires it)"
    echo "    before shipping anything public."
  fi
  # Binary pass included: a credential inside a binary plist / compiled asset is
  # exactly as shipped as one in a .txt, and `grep -I` never reads it.
  _secret_text_hits="$(release_scan_dir_for_secret_values "$_RES_DIR" "release resource secret value")" \
    || { echo "ERROR: secret-value resource scan did not run correctly — REFUSING TO SHIP." >&2; return 1; }
  _secret_file_hits="$(release_scan_dir_for_filename_re "$_RES_DIR" "release resource secret filename" "$_SECRET_FILE_RE")" \
    || { echo "ERROR: secret-filename resource scan did not run correctly — REFUSING TO SHIP." >&2; return 1; }
  _forbidden_runtime_hits=""
  for _rel in data .runtime workspace secrets .secrets memory memory_proposals chat_sessions self_worktrees config providers approvals pairings tokens credentials oauth keychain daemon python native_agentd.py; do
    if [[ -e "$_RES_DIR/$_rel" ]]; then
      _forbidden_runtime_hits="$_forbidden_runtime_hits$_RES_DIR/$_rel"$'\n'
    fi
  done
  _LOCAL_STATE_DIR_RE='/(activity|approvals|browser|catalog|chat_sessions|connectors|context|credentials|dreams|evolution|inbox|keychain|knowledge_graph|memory|memory_proposals|missions|nextgen|oauth|pairings|providers|scheduler|self_worktrees|tokens|traces|trust|workflow|workflows)(/|$)'
  # No `exit` after the first hit and no `|| true`: reporting every offending
  # directory is more useful than one, and stopping early sent find a SIGPIPE
  # whose nonzero status then had to be discarded — which is exactly the pattern
  # that let real scanner failures read as clean.
  # find's status is captured BEFORE the awk pipeline, so a partially-failed
  # walk cannot be masked by awk's own exit 0 (`$(find | awk)` reports awk).
  _nested_state_dirs="$(release_find_checked "nested state-directory" "$_RES_DIR" -type d -print)" \
    || { echo "ERROR: nested state-directory scan of $_RES_DIR failed — REFUSING TO SHIP." >&2; return 1; }
  _nested_state_hits="$(
    printf '%s\n' "$_nested_state_dirs" \
    | awk 'NF' \
    | awk '{ low=tolower($0); print low "\t" $0 }' \
    | awk -F '\t' -v root="$(printf '%s' "$_RES_DIR" | tr '[:upper:]' '[:lower:]')" -v re="$_LOCAL_STATE_DIR_RE" '
        index($1, root "/") == 1 {
          rel = substr($1, length(root) + 1)
          if (rel ~ re) { print $2 }
        }'
  )" || { echo "ERROR: nested state-directory scan of $_RES_DIR failed — REFUSING TO SHIP." >&2; return 1; }
  if [[ -n "$_nested_state_hits" ]]; then
    _forbidden_runtime_hits="$_forbidden_runtime_hits"$'\n'"$_nested_state_hits"
  fi
  _forbidden_runtime_hits="${_forbidden_runtime_hits%$'\n'}"
  # ONBOARDING-2026-05-26: NO persona dir should ever ship inside the bundle.
  # Any file (template or otherwise) under Contents/Resources/persona/ is a leak
  # regression: it would cause _resolve_persona_root() step 3 to resolve inside
  # the read-only signed .app, breaking first-run onboarding. The persona-pruning
  # step above removes the directory; this check fails the release if it crept
  # back in (e.g. a stale dist/ tree, a misguided cp -R, or a future packaging
  # step that re-introduces it).
  _live_persona_hits=""
  if [[ -e "$_RES_DIR/persona" ]]; then
    _live_persona_hits="$(release_find_checked "persona" "$_RES_DIR/persona" -type f -print)" \
      || { echo "ERROR: persona scan of $_RES_DIR/persona failed — REFUSING TO SHIP." >&2; return 1; }
  fi
  _test_artifact_hits="$(release_find_checked "test-artifact" "$_RES_DIR" -type f \( -name '*_tests.py' -o -name 'test_*.py' \) -print)" \
    || { echo "ERROR: test-artifact scan of $_RES_DIR failed — REFUSING TO SHIP." >&2; return 1; }
  # The staged executable is a REQUIRED scan subject at this point; "no binary to
  # scan" is a staging failure, not a clean binary.
  _EXECUTABLE="$BUNDLE/Contents/MacOS/$PRODUCT"
  if [[ ! -s "$_EXECUTABLE" ]]; then
    echo "ERROR: staged executable missing or empty: $_EXECUTABLE" >&2
    echo "       The binary leak scans have no subject. REFUSING TO SHIP." >&2
    return 1
  fi
  _identity_binary_hits=""
  if [[ -n "$_PUBLIC_IDENTITY_RE" ]]; then
    _identity_binary_hits="$(release_scan_binary_for_local_identity "$_EXECUTABLE" "release executable identity" "$_PUBLIC_IDENTITY_RE")" \
      || { echo "ERROR: identity executable scan did not run correctly — REFUSING TO SHIP." >&2; return 1; }
  fi
  _secret_binary_hits=""
  _secret_binary_matches="$(release_scan_binary_for_regex "$_EXECUTABLE" "release executable secret value" cs "$_SECRET_VALUE_RE")" \
    || { echo "ERROR: secret-value executable scan did not run correctly — REFUSING TO SHIP." >&2; return 1; }
  # Benign-literal allowlist: EXACT full-line matches only, never regex
  # loosening. Each entry is a compiled constant proven non-secret; anything
  # else — including a superstring of an entry — still refuses. Add entries
  # only with the literal's origin documented here.
  #   attention-mask-mean-or-model-pooled — MiniLM pooling-mode identifier;
  #   its "sk-mean-or-model-pooled" tail trips the sk-[A-Za-z0-9_-]{20,}
  #   alternative. Exact string-table line verified against the real staged
  #   executable 2026-08-21.
  #   pooling=attention-mask-mean-or-model-pooled — same MiniLM constant, now
  #   emitted with its log-field prefix in one string-table line. Exact line
  #   verified against the real staged executable 2026-08-25.
  if [[ -n "$_secret_binary_matches" ]]; then
    local _allow_rc=0
    _secret_binary_matches="$(grep -Fxv -e "attention-mask-mean-or-model-pooled" -e "pooling=attention-mask-mean-or-model-pooled" <<<"$_secret_binary_matches")" || _allow_rc=$?
    if [[ "$_allow_rc" -gt 1 ]]; then
      echo "ERROR: benign-literal filter FAILED — grep exited $_allow_rc. REFUSING TO SHIP." >&2
      return 1
    fi
  fi
  if [[ -n "$_secret_binary_matches" ]]; then
    _secret_binary_hits="$_EXECUTABLE"
  fi
  if [[ -n "$_personal_hits" || -n "$_identity_text_hits" || -n "$_identity_binary_hits" || -n "$_secret_text_hits" || -n "$_secret_file_hits" || -n "$_secret_binary_hits" || -n "$_forbidden_runtime_hits" || -n "$_live_persona_hits" || -n "$_test_artifact_hits" ]]; then
    echo "" >&2
    echo "ERROR: release bundle FAILED the personal-data leak guard — REFUSING TO SHIP." >&2
    if [[ -n "$_personal_hits" ]]; then
      echo "  developer personal identifiers found in:" >&2
      echo "$_personal_hits" | sed 's/^/    /' >&2
    fi
    if [[ -n "$_identity_text_hits" ]]; then
      echo "  local identity names found in app-owned text resources:" >&2
      echo "$_identity_text_hits" | sed 's/^/    /' >&2
    fi
    if [[ -n "$_identity_binary_hits" ]]; then
      echo "  local identity names found in release executable strings:" >&2
      echo "$_identity_binary_hits" | sed 's/^/    /' >&2
    fi
    if [[ -n "$_secret_text_hits" ]]; then
      echo "  credential-looking values found in app-owned text resources:" >&2
      echo "$_secret_text_hits" | sed 's/^/    /' >&2
    fi
    if [[ -n "$_secret_file_hits" ]]; then
      echo "  secret-bearing files found in app-owned resources:" >&2
      echo "$_secret_file_hits" | sed 's/^/    /' >&2
    fi
    if [[ -n "$_secret_binary_hits" ]]; then
      echo "  credential-looking values found in release executable strings:" >&2
      echo "$_secret_binary_hits" | sed 's/^/    /' >&2
    fi
    if [[ -n "$_forbidden_runtime_hits" ]]; then
      echo "  live runtime/state directories found in release resources:" >&2
      echo "$_forbidden_runtime_hits" | sed 's/^/    /' >&2
    fi
    if [[ -n "$_live_persona_hits" ]]; then
      echo "  persona files found in release bundle (Contents/Resources/persona must not ship — see ONBOARDING-2026-05-26):" >&2
      echo "$_live_persona_hits" | sed 's/^/    /' >&2
    fi
    if [[ -n "$_test_artifact_hits" ]]; then
      echo "  test artifacts found in release resources:" >&2
      echo "$_test_artifact_hits" | sed 's/^/    /' >&2
    fi
    echo "  Fix release defaults; do NOT ship until this is clean." >&2
    return 1
  fi
  echo "[release] leak guard passed — blank slate bundle: no configured personal data, credentials, OAuth/token files, live or derived ContextFlow state, or local identity defaults"
  return 0
}
