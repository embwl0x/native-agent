#!/usr/bin/env bash
# Publish an appcast and prove the advertised feed and enclosure are actually
# live. Kept outside generate_appcast.sh so the no-op-publisher boundary can be
# exercised without requiring Sparkle's generator to be installed.

# shellcheck disable=SC2034
NATIVEAGENT_APPCAST_PUBLISH_VERIFY_LIB_LOADED=1

# Result fields are deliberately data, not success prose: callers decide how
# to quarantine/report a failed publication.
NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REASON=""
NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REMOTE_APPCAST_SHA=""
NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REMOTE_DMG_LEN=""
NATIVEAGENT_APPCAST_PUBLISH_VERIFY_ATTEMPTS=""

# $1 publish command; $2 appcast; $3 dmg; $4 appcast URL; $5 enclosure URL;
# $6 version; $7 rehearsal marker; $8 expected enclosure length; $9 scratch dir
nativeagent_publish_appcast_and_verify() {
  local publish_cmd="$1" appcast_xml="$2" dmg_path="$3" appcast_url="$4"
  local download_url="$5" version="$6" rehearsal="$7" enclosure_len="$8" scratch_dir="$9"

  NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REASON=""
  NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REMOTE_APPCAST_SHA=""
  NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REMOTE_DMG_LEN=""
  NATIVEAGENT_APPCAST_PUBLISH_VERIFY_ATTEMPTS=""

  if ! NATIVEAGENT_PUBLISH_APPCAST="$appcast_xml" \
      NATIVEAGENT_PUBLISH_DMG="$dmg_path" \
      NATIVEAGENT_PUBLISH_TEST_RECEIPT="${NATIVEAGENT_PUBLISH_TEST_RECEIPT:-}" \
      NATIVEAGENT_PUBLISH_ATTESTATION="${NATIVEAGENT_PUBLISH_ATTESTATION:-}" \
      NATIVEAGENT_PUBLISH_APPCAST_URL="$appcast_url" \
      NATIVEAGENT_PUBLISH_VERSION="$version" \
      NATIVEAGENT_APPCAST_REHEARSAL="$rehearsal" \
      bash -c "$publish_cmd"; then
    NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REASON="publish command failed; the feed was NOT published."
    return 3
  fi

  nativeagent_verify_published_appcast \
    "$appcast_xml" "$dmg_path" "$appcast_url" "$download_url" "$enclosure_len" "$scratch_dir"
}

# $1 local appcast; $2 local dmg; $3 appcast URL; $4 enclosure URL;
# $5 expected enclosure length; $6 scratch dir
nativeagent_verify_published_appcast() {
  local appcast_xml="$1" dmg_path="$2" appcast_url="$3" download_url="$4"
  local enclosure_len="$5" scratch_dir="$6"
  local curl_bin verify_attempts verify_delay local_appcast_sha local_dmg_sha
  local remote_appcast_sha="" remote_dmg_len="" remote_dmg_sha="" verify_note=""
  local attempt=1

  NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REASON=""
  NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REMOTE_APPCAST_SHA=""
  NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REMOTE_DMG_LEN=""
  NATIVEAGENT_APPCAST_PUBLISH_VERIFY_ATTEMPTS=""

  curl_bin="$(command -v curl || true)"
  if [[ -z "$curl_bin" ]]; then
    NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REASON="curl is not available, so the publish cannot be VERIFIED. Refusing to claim a feed is live on the strength of an exit code alone. Install curl (or publish from a host that has it) and re-run."
    return 2
  fi

  verify_attempts="${NATIVEAGENT_APPCAST_VERIFY_ATTEMPTS:-6}"
  verify_delay="${NATIVEAGENT_APPCAST_VERIFY_DELAY:-5}"
  if [[ ! "$verify_attempts" =~ ^[0-9]+$ || "$verify_attempts" -lt 1 ]]; then
    NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REASON="NATIVEAGENT_APPCAST_VERIFY_ATTEMPTS must be a positive integer, got '$verify_attempts'"
    return 2
  fi
  if [[ ! "$verify_delay" =~ ^[0-9]+$ ]]; then
    NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REASON="NATIVEAGENT_APPCAST_VERIFY_DELAY must be a non-negative integer, got '$verify_delay'"
    return 2
  fi

  local_appcast_sha="$(shasum -a 256 "$appcast_xml" | awk '{print $1}')"
  local_dmg_sha="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
  mkdir -p "$scratch_dir" || {
    NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REASON="could not create publish-verification scratch directory: $scratch_dir"
    return 2
  }

  echo ""
  echo "==> Verifying the published feed is actually LIVE (exit 0 proves nothing)"

  while [[ $attempt -le $verify_attempts ]]; do
    verify_note=""
    if ! "$curl_bin" -fsSL --max-time 120 -o "$scratch_dir/appcast.remote.xml" "$appcast_url" 2>"$scratch_dir/appcast.err"; then
      verify_note="could not fetch $appcast_url: $(tr -d '\n' < "$scratch_dir/appcast.err")"
    else
      remote_appcast_sha="$(shasum -a 256 "$scratch_dir/appcast.remote.xml" | awk '{print $1}')"
      if [[ "$remote_appcast_sha" != "$local_appcast_sha" ]]; then
        verify_note="the appcast served at $appcast_url is NOT the feed just generated (remote sha256 $remote_appcast_sha != local $local_appcast_sha)"
      else
        remote_dmg_len=""
        if "$curl_bin" -fsSLI --max-time 120 "$download_url" >"$scratch_dir/dmg.head" 2>"$scratch_dir/dmg.err"; then
          remote_dmg_len="$(
            tr -d '\r' < "$scratch_dir/dmg.head" | tr '[:upper:]' '[:lower:]' \
              | awk -F'[:[:space:]]+' '/^content-length:/ { v=$2 } END{ if (v ~ /^[0-9]+$/) print v }'
          )"
        fi
        if [[ -z "$remote_dmg_len" ]] && \
            "$curl_bin" -fsSL --max-time 600 -r 0-0 -D "$scratch_dir/dmg.head2" -o /dev/null "$download_url" 2>>"$scratch_dir/dmg.err"; then
          remote_dmg_len="$(
            tr -d '\r' < "$scratch_dir/dmg.head2" | tr '[:upper:]' '[:lower:]' \
              | awk -F'[:[:space:]]+' '
                  /^content-range:/ { n=split($0, p, "/"); if (n>1 && p[n] ~ /^[0-9]+$/) range=p[n] }
                  /^content-length:/ { if ($2 ~ /^[0-9]+$/) len=$2 }
                  END { if (range != "") print range; else if (len != "") print len }'
          )"
        fi
        if [[ -z "$remote_dmg_len" ]]; then
          verify_note="the DMG at $download_url did not resolve to a readable size: $(tr -d '\n' < "$scratch_dir/dmg.err")"
        elif [[ "$remote_dmg_len" != "$enclosure_len" ]]; then
          verify_note="the DMG served at $download_url is $remote_dmg_len bytes but the feed advertises $enclosure_len — the enclosure signature covers different bytes"
        elif ! "$curl_bin" -fsSL --max-time 900 -o "$scratch_dir/dmg.served" "$download_url" 2>>"$scratch_dir/dmg.err"; then
          verify_note="the DMG at $download_url passed the size check but could not be fetched for byte verification: $(tr -d '\n' < "$scratch_dir/dmg.err")"
        else
          remote_dmg_sha="$(shasum -a 256 "$scratch_dir/dmg.served" | awk '{print $1}')"
          rm -f "$scratch_dir/dmg.served"
          if [[ "$remote_dmg_sha" != "$local_dmg_sha" ]]; then
            verify_note="the DMG served at $download_url has sha256 $remote_dmg_sha but the published artifact is $local_dmg_sha — same length, DIFFERENT bytes (stale CDN or wrong upload)"
          else
            NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REMOTE_APPCAST_SHA="$remote_appcast_sha"
            NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REMOTE_DMG_LEN="$remote_dmg_len"
            NATIVEAGENT_APPCAST_PUBLISH_VERIFY_ATTEMPTS="$attempt"
            return 0
          fi
        fi
      fi
    fi
    if [[ $attempt -lt $verify_attempts ]]; then
      echo "    attempt $attempt/$verify_attempts not yet verified ($verify_note)" >&2
      echo "    retrying in ${verify_delay}s (host propagation)..." >&2
      sleep "$verify_delay"
    fi
    attempt=$((attempt + 1))
  done

  NATIVEAGENT_APPCAST_PUBLISH_VERIFY_REASON="$verify_note"
  NATIVEAGENT_APPCAST_PUBLISH_VERIFY_ATTEMPTS="$verify_attempts"
  return 1
}
