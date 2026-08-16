# NativeAgent — Release Setup Guide

<!-- RELEASE-2026-05-06: Sprint 4 Task 4.1-4.4 documentation -->

## Overview

NativeAgent uses Developer ID signing, notarization, Sparkle for auto-updates,
and a hand-rolled DMG builder. Official artifacts always start from a verified
one-commit public source snapshot, never directly from the private maintainer
working tree. The private tree creates that snapshot with
`script/make_public_export.sh`; the published mirror already is that scrubbed
snapshot and intentionally omits the private exporter. This document covers
the one-time setup and per-release workflow.

---

## 1. One-time setup

### Apple Developer account and certificate

1. Enroll at [developer.apple.com](https://developer.apple.com) — $99/yr individual or organization.
2. In Xcode → Settings → Accounts: add your Apple ID, then "Manage Certificates" → (+) → **Developer ID Application**.
3. Export the cert to your login keychain so `codesign` can find it:
   ```
   security find-identity -v -p codesign | grep "Developer ID Application"
   ```
   You should see a line like:
   ```
   1) ABCDEF1234  "Developer ID Application: Example Developer (XXXXXXXXXX)"
   ```
4. Set the env var:
   ```bash
   export NATIVEAGENT_DEVELOPER_ID="Developer ID Application: Example Developer (XXXXXXXXXX)"
   export NATIVEAGENT_TEAM_ID="XXXXXXXXXX"   # 10-char Team ID from developer.apple.com/account
   ```

### Apple ID app-specific password (for notarization)

1. Go to [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords.
2. Generate a new password, label it "NativeAgent notarytool".
3. Set the env var:
   ```bash
   export NATIVEAGENT_APPLE_ID="you@example.com"
   export NATIVEAGENT_NOTARIZATION_PASSWORD="xxxx-xxxx-xxxx-xxxx"
   ```
   Alternatively store in keychain and reference as `@keychain:NativeAgent-notarytool`.

### Store secrets in your shell profile (or `.env`)

Add to `~/.zshrc` (or use a `.env` file + `direnv`):

```bash
export NATIVEAGENT_DEVELOPER_ID="Developer ID Application: Example Developer (XXXXXXXXXX)"
export NATIVEAGENT_TEAM_ID="XXXXXXXXXX"
export NATIVEAGENT_APPLE_ID="you@example.com"
export NATIVEAGENT_NOTARIZATION_PASSWORD="xxxx-xxxx-xxxx-xxxx"
export NATIVEAGENT_SPARKLE_ED_PRIV_KEY="$HOME/.config/nativeagent/sparkle_ed_priv.key"
export NATIVEAGENT_SPARKLE_PUBLIC_KEY="base64-32-byte-public-key-from-sparkle_keygen"
# The GitHub wrapper derives feed/download/release URLs from this plus VERSION.
export NATIVEAGENT_GITHUB_REPOSITORY="embwl0x/native-agent"
```

**Never commit these values to git.** The `VERSION` file and scripts are safe to commit; secrets are not.

`script/release.sh` also accepts the `NATIVE_AGENT_*` aliases for these signing variables, but it normalizes them internally to the `NATIVEAGENT_*` names shown here.

---

## 2. Sparkle key generation

Run once before your first release:

```bash
# Build Sparkle first (so generate_keys is available)
swift build --package-path /path/to/NativeAgent

# Generate keys
./script/sparkle_keygen.sh
```

The script:
- Writes the **private key** to `~/.config/nativeagent/sparkle_ed_priv.key`
- Prints the **public key** to stdout

The private key path should match `NATIVEAGENT_SPARKLE_ED_PRIV_KEY`.
`release.sh` derives/checks the public half and writes `SUPublicEDKey` into the
staged release bundle. Do not paste a private key or a fixed key into source.

---

## 3. Per-release workflow

### Create the scrubbed public source tree (private maintainer checkout only)

From the private repo at the exact reviewed commit:

```bash
./script/make_public_export.sh /tmp/nativeagent-public-export
cd /tmp/nativeagent-public-export
```

The exporter creates fresh single-commit history, scrubs private identities, excludes local/runtime state, verifies the exact Git-owned MiniLM resources, rejects derived ContextFlow state, and builds the exported source. The model payload must already be tracked in the source commit; export never repairs it from machine-local state. Review and release from that output. It does not push a public repository.

If this is a clone of the published `embwl0x/native-agent` mirror, this step is
already complete. Verify that `.nativeagent-public-source` is tracked by the
current clean commit and begin with the release preflight below.

The export also commits `.nativeagent-public-source`. Every public release
mode refuses to run unless that exact marker is a regular file tracked by the
release commit. Do not create or copy the marker into the private checkout:
the guard exists to prevent a signed public DMG from accidentally retaining
private instance names such as a locally customized Claude Code identity.

### Bump the version

Edit `VERSION` (single source of truth):

```bash
echo "0.3.0" > VERSION
```

### Run the GitHub release preflight

The exact source commit must already exist in the public repository. Installed
applications have no GitHub credentials, so a private repository cannot serve
their update feed.

```bash
NATIVEAGENT_GITHUB_REPOSITORY=embwl0x/native-agent \
NATIVEAGENT_NOTARY_KEYCHAIN_PROFILE=NativeAgent-notary \
NATIVEAGENT_PUBLIC_DEVICE_SYNC=cloudkit \
NATIVEAGENT_MAC_BUNDLE_ID=io.github.embwl0x.nativeagent.mac \
NATIVEAGENT_BACKGROUND_TASK_PREFIX=io.github.embwl0x.nativeagent \
NATIVEAGENT_ICLOUD_CONTAINER_ID=iCloud.io.github.embwl0x.nativeagent \
NATIVEAGENT_RELEASE_ENTITLEMENTS=/secure/path/NativeAgent.cloudkit.public.entitlements \
NATIVEAGENT_PROVISIONING_PROFILE=/secure/path/NativeAgent.DeveloperID.CloudKit.provisionprofile \
NATIVEAGENT_PRODUCTION_CLOUDKIT_SCHEMA=/secure/path/production.ckdb \
NATIVEAGENT_PRIVACY_DENYLIST_FILE=/secure/path/privacy_denylist.regex \
./script/release_github.sh --preflight
```

### Publish the notarized release and update feed

```bash
NATIVEAGENT_GITHUB_REPOSITORY=embwl0x/native-agent \
NATIVEAGENT_NOTARY_KEYCHAIN_PROFILE=NativeAgent-notary \
NATIVEAGENT_PUBLIC_DEVICE_SYNC=cloudkit \
NATIVEAGENT_MAC_BUNDLE_ID=io.github.embwl0x.nativeagent.mac \
NATIVEAGENT_BACKGROUND_TASK_PREFIX=io.github.embwl0x.nativeagent \
NATIVEAGENT_ICLOUD_CONTAINER_ID=iCloud.io.github.embwl0x.nativeagent \
NATIVEAGENT_RELEASE_ENTITLEMENTS=/secure/path/NativeAgent.cloudkit.public.entitlements \
NATIVEAGENT_PROVISIONING_PROFILE=/secure/path/NativeAgent.DeveloperID.CloudKit.provisionprofile \
NATIVEAGENT_PRODUCTION_CLOUDKIT_SCHEMA=/secure/path/production.ckdb \
NATIVEAGENT_PRIVACY_DENYLIST_FILE=/secure/path/privacy_denylist.regex \
./script/release_github.sh
```

The wrapper defaults to the production CloudKit-only public lane. It embeds
the matching Developer ID provisioning profile, rejects KVS/CloudDocuments
entitlements on the Mac, retains Calendar authority, requires real identifiers,
derives the signed application/team identifiers from the validated profile
into a temporary signing plist, and proves those signed values plus the
stapled app inside the intentionally unsigned DMG. The checked-in entitlement
template therefore remains team-neutral; do not hardcode a contributor's Team
ID into it. Set
`NATIVEAGENT_PUBLIC_DEVICE_SYNC=none` only for an explicitly standalone Mac
release; that artifact cannot be advertised as iPhone-compatible.

The privacy denylist is a maintainer-local, ignored file with one extended
regular expression per line for private instance names and personal identifiers.
Preflight requires it (or an explicit privacy/identity regex), and the same
input is applied to resources and section-independent executable byte runs.

Before advertising public Mac/iPhone continuity:

1. Register the permanent public identifiers
   `io.github.embwl0x.nativeagent.mac`,
   `io.github.embwl0x.nativeagent.ios`, and
   `iCloud.io.github.embwl0x.nativeagent` before creating App Store records or
   production CloudKit history.
2. Sign the App Store iOS bundle under the same Apple team and container, with
   production push and CloudKit entitlements.
3. Promote `distribution/cloudkit/NativeAgent.ckdb` to production in CloudKit
   Console and re-export it to prove all required record types.
4. Verify the exact notarized website DMG against a TestFlight/App Store build
   on a fresh ordinary Apple Account: pairing, notification consent, background
   silent-push drain, local lock-screen projection, delivery acknowledgement,
   restart/reinstall, offline recovery, Focus, and force-quit behavior.

Direct Mac-to-APNS remains an optional developer/self-hosted lane because its
provider signing key must not ship in a public artifact. The public companion
path should use the existing signed CloudKit record, silent-push drain, and
iPhone-local notification projection.

This will:
1. Read version from `VERSION`
2. Validate all required env vars
3. `swift build -c release`
4. Stage `dist/NativeAgent.app` with Info.plist (version, Sparkle feed URL, usage strings)
5. Codesign with hardened runtime and `NativeAgent.entitlements`
6. Create zip for notarization
7. Submit to Apple notarytool and wait
8. Staple the notarization ticket
9. Verify with `spctl` and `stapler`
10. Call `script/dmg_builder.sh` → produces `dist/NativeAgent-X.Y.Z.dmg`
11. Run `script/verify_release_artifact.sh` against the final DMG with signing, notarization, and Sparkle-key requirements

### Dry-run (no Apple creds needed)

```bash
./script/release.sh --dry-run
```

Builds, stages, and signs ad-hoc. Useful for local testing before you have a
Developer ID cert. Hardened-runtime ad-hoc signatures have no Team ID, so the
shared ad-hoc entitlement contract disables library validation to let the
bundled Sparkle framework load. This is a development/dry-run compatibility
rule, not a substitute for Developer ID signing or notarization. Static bundle
verification does not replace one clean-VM launch of the exact DMG.

All Mac signing profiles must also retain
`com.apple.security.personal-information.calendars`. On current macOS releases,
a hardened-runtime app without that entitlement is denied before the Calendar
consent sheet and never appears under Privacy & Security → Calendars. The
release guard checks the source profiles, and artifact verification confirms
the entitlement survived codesigning in the app users actually install.

### Verify an already-built DMG

```bash
./script/verify_release_artifact.sh --dmg dist/NativeAgent-X.Y.Z.dmg
```

To run the same bundle-level blank-slate checks before building a DMG:

```bash
./script/verify_release_artifact.sh --bundle dist/NativeAgent.app
```

For the current public distribution path, the app inside the DMG is signed, notarized, and stapled while the DMG wrapper remains unsigned for cross-macOS mount compatibility. Verify the app notarization and Sparkle key without requiring a DMG signature:

```bash
./script/verify_release_artifact.sh \
  --dmg dist/NativeAgent-X.Y.Z.dmg \
  --require-notarized \
  --require-sparkle-key
```

The verifier mounts the DMG read-only and checks the artifact users actually drag-install: bundle shape, readable permissions, `/Applications` symlink, app signing, retired interpreter imports, blank-slate resources, no bundled persona directory, no `REPO_PATH`, no runtime state directories even when nested under another resource folder, no derived ContextFlow database/receipts/registrations/arena snapshots/diagnostics (including SQLite sidecars), no credential/token files, and the public first-run quarantine marker. `make_public_export.sh` runs the same ContextFlow-state assertion against the scrubbed source tree before creating its single public commit.

### Sign the update for Sparkle appcast

After the DMG is built:

```bash
# Using Sparkle's sign_update tool (built alongside the package):
.build/checkouts/Sparkle/bin/sign_update \
  dist/NativeAgent-0.3.0.dmg \
  --ed-key-file "$NATIVEAGENT_SPARKLE_ED_PRIV_KEY"
```

This prints the `sparkle:edSignature` and `length` values you need for `appcast.xml`.

---

## 4. Upload and appcast

### Where to host

**Recommended: GitHub Releases**

`script/release_github.sh` publishes both assets to `v<VERSION>`:

- stable feed:
  `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`
- exact enclosure:
  `https://github.com/<owner>/<repo>/releases/download/v<VERSION>/NativeAgent-<VERSION>.dmg`

The publisher refuses a private repository. It creates a draft, uploads and
reads back both assets, then publishes only when they are byte-identical. The
existing appcast pipeline separately fetches the public unauthenticated URLs
before promoting locally shippable artifacts.

### The update-honesty contract (A2.1, 2026-07-24)

`SUFeedURL` is written into the app **only** by `--publish-appcast`, together
with `NativeAgentUpdateFeedPublished=true`. The app's `UpdateController` requires
that flag before it will start Sparkle or offer a real update check.

| release.sh invocation | app's `SUFeedURL` | "Check for Updates…" |
|---|---|---|
| (none) / `--dry-run`  | absent  | reads "About Software Updates…", shows an honest explanation |
| `--appcast`           | absent  | same — this mode only *rehearses* the signing pipeline |
| `--publish-appcast`   | set     | real Sparkle check against the feed just published |

This exists because every release before 2026-07-24 stamped a required feed URL
that had never been published, so the menu item invoked a check that 404'd.
`script/verify_release_artifact.sh` now fails any artifact that advertises a feed
it did not publish, or that leaves `SUEnableAutomaticChecks` on with no feed.

### Generating the feed

`script/generate_appcast.sh` wraps Sparkle's own `generate_appcast`/`sign_update`.
It refuses to emit a feed that is unsigned, placeholder-signed, version-mismatched,
or pointed at the wrong download URL. In particular Sparkle only *warns* and emits
an **unsigned** enclosure when the signing key does not match the app's
`SUPublicEDKey` — this script treats that warning as fatal.

If `NATIVEAGENT_SPARKLE_ED_PRIV_KEY` is unset it fails with the exact remediation
(`script/sparkle_keygen.sh`, then `generate_keys -x`) rather than emitting anything.

### Round 2 hardening (2026-07-24, independent review)

Three ways the pipeline above could still ship a lying artifact, and what now
stops each:

1. **A failed publish used to leave a shippable DMG behind.** The app must be
   stamped "feed published" *before* the feed can exist, because the enclosure
   signature has to cover the final notarized bytes. So a `--publish-appcast` run
   **stages, signs, notarizes, staples and DMG-builds entirely inside
   `dist/.pending-publish/`** — the ship-ready names `dist/NativeAgent.app`,
   `dist/NativeAgent.app.zip` and `dist/NativeAgent-<v>.dmg` never exist until
   `release_quarantine_promote` runs, and that runs only after publication has
   been verified live. (Quarantining at the *end* of the run was not enough: the
   window from staging through notarization is minutes long, and an abort inside
   it left a signed, feed-claiming bundle under its shippable name.) Quarantine is
   the resting state and promotion the only exit, so a `set -e` abort, a Ctrl-C,
   and a hard crash mid-notarization all leave the same safe state — no cleanup
   code has to run. Only artifacts the *current* run registered are promoted, so a
   later successful release cannot drag a previous failed run's unpublished
   artifacts into `dist/` with it. If you find `dist/.pending-publish/`, that
   release failed: fix the publish problem and re-run. Never upload anything from
   that directory. Two related leaks are closed alongside it: `dmg_builder.sh`
   removes its fully-populated temp image on *every* exit path (a failed
   `hdiutil convert` used to leave a mountable `dist/NativeAgent-tmp.dmg`), and
   `generate_appcast.sh` removes the DMG it stages for Sparkle when the feed is
   rejected.
2. **An exit code is not existence.** `NATIVEAGENT_APPCAST_PUBLISH_CMD=true`
   exits 0 and uploads nothing; a DMG-only upload also exits 0. After the publish
   command returns, `generate_appcast.sh` fetches `NATIVEAGENT_APPCAST_URL` and
   compares its sha256 against the feed it just signed, then confirms
   `NATIVEAGENT_DMG_DOWNLOAD_URL` resolves with exactly the length in the
   enclosure. Bounded retries (`NATIVEAGENT_APPCAST_VERIFY_ATTEMPTS`, default 6,
   `_DELAY` 5s) cover host propagation; running out of attempts, or having no
   `curl` at all, FAILS the release. Nothing prints "Published" unverified, and a
   feed whose publication could not be verified gets a
   `.PUBLISH-FAILED-DO-NOT-UPLOAD.txt` note dropped beside it so nobody
   hand-uploads it later.
3. **Wrong signing key, detected by arithmetic instead of prose.** The old guard
   grepped Sparkle's "does not match key" warning. `script/sparkle_ed_public_key.swift`
   now derives the public half of the signing key (Swift + CryptoKit)
   and requires it to equal the bundle's `SUPublicEDKey`; `release.sh` runs the
   same check against `NATIVEAGENT_SPARKLE_PUBLIC_KEY` in the first seconds, long
   before the build. The warning-text guard is kept as belt-and-braces. Both
   Sparkle secret formats are handled the way Sparkle itself handles them
   (`common_cli/Secret.swift`): a 32-byte seed is derived from, while the legacy
   96-byte secret already *contains* its public key in bytes 64..96 and is read
   verbatim — re-deriving from its first 32 bytes would hash an already-hashed key
   and report a good key pair as mismatched.

Related: `verify_release_artifact.sh` asserts plist value **types**, not printed
text. `<string>true</string>` used to satisfy `NativeAgentUpdateFeedPublished`
while Swift's `info[…] as? Bool` read nil — a verified artifact with a dead
updater. Booleans must be real `<true/>`/`<false/>` and `SUFeedURL` a real
`<string>`.

All of this is covered by `tests/scripts/sparkle_publish_ordering_test.sh`, which
runs the real publish path offline against a stub release host.

### appcast.xml format

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>NativeAgent Changelog</title>
    <link>https://example.com/nativeagent/appcast.xml</link>
    <item>
      <title>Version 0.3.0</title>
      <pubDate>Wed, 06 May 2026 12:00:00 +0000</pubDate>
      <sparkle:version>0.3.0</sparkle:version>
      <sparkle:shortVersionString>0.3.0</sparkle:shortVersionString>
      <enclosure
        url="https://example.com/nativeagent/releases/v0.3.0/NativeAgent-0.3.0.dmg"
        sparkle:edSignature="BASE64_SIGNATURE_FROM_SIGN_UPDATE"
        length="BYTE_LENGTH_OF_DMG"
        type="application/octet-stream"
      />
    </item>
  </channel>
</rss>
```

### Per-release steps (summary)

1. Commit the intended version in private `VERSION`.
2. From the private maintainer checkout, run `make_public_export.sh` and inspect
   the fresh export. A published-mirror clone skips this already-completed step.
3. Publish the reviewed public-source commit and make the repository public.
4. In the export, run `./script/release_github.sh --preflight`.
5. Run `./script/release_github.sh`; it performs build, signing, notarization,
   appcast signing, draft upload/readback, publication, and public URL proof.
6. Test the exact promoted DMG on a fresh supported arm64 macOS 14+ VM.

Users with NativeAgent installed will see an update prompt automatically on next check.

---

## 5. Files reference

| File | Purpose |
|------|---------|
| `VERSION` | Single version source of truth |
| `script/make_public_export.sh` | Canonical scrubbed, fresh-history public source export |
| `NativeAgent.entitlements` | Hardened runtime entitlements for notarization |
| `NativeAgent.public.entitlements` | No-iCloud public direct-download entitlements |
| `script/release.sh` | Full production release: build → sign → notarize → staple → DMG |
| `script/dmg_builder.sh` | hdiutil-based DMG with Applications symlink |
| `script/verify_release_artifact.sh` | Mounted-DMG release gate for signing, permissions, blank-slate resources (including derived ContextFlow state), retired interpreter artifacts, and notarization checks |
| `script/sparkle_keygen.sh` | EdDSA key generation for Sparkle update signing |
| `Sources/NativeAgentApp/UpdateController.swift` | Sparkle SPUStandardUpdaterController SwiftUI wrapper |
| `script/release_github.sh` | One-command GitHub release preflight and production release entry point |
| `script/publish_github_release.sh` | Draft/upload/readback/publish adapter for GitHub Releases |
| `script/build_and_run.sh` | Dev workflow only — ad-hoc sign, no notarization |
| `script/install_launch_agent.sh` | Legacy cleanup shim; delegates to app-owned install flow |
