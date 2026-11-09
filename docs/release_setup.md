# NativeAgent — Release Setup Guide

Public releases use a scrubbed source checkout, a Developer ID signed and
notarized app, a DMG, and a signed Sparkle feed. The scripts are authoritative
for prerequisites and artifact checks. This guide covers setup and the
release-owner workflow; running it publishes only when the publish command is
explicitly selected.

## 1. One-time setup

Install XcodeGen before using the build scripts. Root `project.yml` and
`iOS/NativeAgentMobile/project.yml` generate the Xcode projects and copy root
`Package.resolved` into their SwiftPM workspace directories. Release builds
use `-onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates`.

Root `Package.swift` owns Sparkle's minimum version, 2.9.6, which fixes
[GHSA-3x7w-j75x-ppq5](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-3x7w-j75x-ppq5).
`script/sync_build_declarations.rb` generates the matching XcodeGen requirement.
The core manifest owns Yams (6.2.2 or newer within 6.x); Goose settings use
its node/source-mark parser while preserving the original document text.
After changing requirements, resolve packages in the root and in
`Modules/NativeAgentCore`; root `Package.resolved` supplies the generated
Xcode workspace lock copies.

Prepare these private release inputs:

| Variable | Input |
|---|---|
| `NATIVEAGENT_GITHUB_REPOSITORY` | Public `owner/repository`; authenticated `gh` access |
| `NATIVEAGENT_DEVELOPER_ID` | Developer ID Application signing identity |
| `NATIVEAGENT_TEAM_ID` | Apple team ID |
| `NATIVEAGENT_NOTARY_KEYCHAIN_PROFILE` | Stored notarytool profile |
| `NATIVEAGENT_SPARKLE_ED_PRIV_KEY` | Sparkle private-key file |
| `NATIVEAGENT_PRIVACY_DENYLIST_FILE` | Local identity/privacy regex file |
| `NATIVEAGENT_RELEASE_ENTITLEMENTS` | CloudKit-only production Mac entitlements |
| `NATIVEAGENT_PROVISIONING_PROFILE` | Matching Developer ID CloudKit profile |
| `NATIVEAGENT_PRODUCTION_CLOUDKIT_SCHEMA` | Production CloudKit schema export |
| `NATIVEAGENT_EMBEDDING_MODEL_DIR` | Complete local model directory; default `extras/embedding` |

The GitHub wrapper can infer a sole Developer ID identity and its team.
Without a notary profile, it accepts `NATIVEAGENT_APPLE_ID` and
`NATIVEAGENT_NOTARIZATION_PASSWORD`. Keep credentials and keys outside source.

Release/build configuration uses only `NATIVEAGENT_*`. `release.sh` accepts
`NATIVEAGENT_ICLOUD_BUILD=personal`, `cloudkit` or `none`; numeric encodings
and the second release environment namespace are removed.

### Local signing and product selection

`NATIVEAGENT_BUILD_CONFIG=release script/build_and_run.sh --build-only` remains
the local optimized build invocation. The default `NATIVEAGENT_SIGNING_MODE`
is `development`: one Apple Development identity (or an explicit
`NATIVEAGENT_DEVELOPMENT_SIGN_IDENTITY`), matching host profile and local
entitlements are required before compilation. Explicit `adhoc` mode disables
iCloud; a missing prerequisite or signing failure never selects it.

Both builders default to `NATIVEAGENT_PRODUCT=host`, the host app without a
widget. Select `host-with-widget` deliberately to embed it. That product
requires host and widget profiles granting their exact IDs, the same team and
shared App Group before compilation. Release widget profiles must be Developer
ID all-devices profiles; release rehearsals support the host product only.
Missing provisioning never removes a selected feature. An explicitly ad-hoc
local development product needs no Apple profiles; a distribution widget always
does.

The local installer issues one checked LaunchServices request and observes the
process for at most 30 seconds, then authenticated source/chat readiness for at
most 45 seconds. Failure retains the selected app and prior artifact, exits
nonzero and requires a forward repair; it never launches an older executable.
Retired Python installer flags and daemon cleanup are gone. Install symbol
objects live once per UUID set under `~/Library/Logs/NativeAgent-dsyms/objects/`;
revision manifests refer to those objects. The per-revision dSYM search is gone.

The running app requires complete current identity stamps: version, build, full
source revision, Boolean dirty flag, full source-content identity and matching
`Resources/VERSION_SHA`. Incomplete/unreadable stamps report unavailable through
About, introspection and the authenticated bridge; they cannot write a launch
stamp or establish exact-source proof. Command-line processes carry no
reconstructed app identity.

`script/build_inputs.txt` covers the repository-owned build inputs, including
module source descendants through `:(glob)Modules/*/Sources/**`. The content
identity reads their working bytes without changing the person's Git index;
assembly checks that identity before and after compilation.

The updater distinguishes an absent notice, a valid newer offer, known stale
display state and unreadable evidence. It clears known stale state or a fresh
Sparkle no-update/skip result; malformed bytes remain preserved with a Settings
error until a fresh observed result replaces them.

### Device sync

`release_github.sh` defaults to `NATIVEAGENT_PUBLIC_DEVICE_SYNC=cloudkit` and:

- `NATIVEAGENT_MAC_BUNDLE_ID=io.github.embwl0x.nativeagent.mac`;
- `NATIVEAGENT_BACKGROUND_TASK_PREFIX=io.github.embwl0x.nativeagent`;
- `NATIVEAGENT_ICLOUD_CONTAINER_ID=iCloud.io.github.embwl0x.nativeagent`;
- `NATIVEAGENT_MOBILE_SOURCE_KEY=mobile_app`.

Its preflight requires the production schema to contain `NAChatMessage`,
`NANotification`, `NAPairingDevice` and `NAStatus`. The release script validates
the CloudKit profile and derives signed application/team identifiers into a
temporary entitlement file. The CloudKit Mac lane rejects KVS/CloudDocuments
entitlements and retains Calendar authority.

Set `NATIVEAGENT_PUBLIC_DEVICE_SYNC=none` only for a standalone Mac artifact.
For companion distribution, check the exact Mac and iOS builds together using
the same container. Signing/schema checks alone do not prove pairing or alerts.
The notification contract is in [phone alerts](apns-push.md): ordinary alerts
use CloudKit's keyless visible subscription, while chat/status/pairing wake
silently. Direct APNS is optional, only wakes notification sync, and its private
credentials must never ship in the bundle. Coordinate this subscription/Mac
revision with TestFlight 38; build 37's local renderer would duplicate it.

### Bundled model (default)

`NATIVEAGENT_EMBEDDING_DISTRIBUTION=bundled` copies only `embedding.json`,
`embedding.mlpackage` and `vocab.txt` from the local model directory into
`Contents/Resources/embedding`. Packaging requires those resources and does not
download weights. Bundled mode removes `embedding-download.json` and publishes
no separate model or delta asset.

### Separate-download override

The supported `separate-download` override does not satisfy
[NORTHSTAR's public-release law](NORTHSTAR.md#clause-7--as-simple-as-possible-alive-means-easy-to-live-with).
It packages `NativeAgent-<version>.embedding.zip` with a SHA-256, size and
versioned HTTPS URL descriptor; packaging and publishing must use the same setting.

The release writes `NativeAgent-<version>.embedding.json` beside the DMG and
copies it to the signed bundle's `Contents/Resources/embedding-download.json`,
which `EmbeddingModelDownload` consumes. Its schema is:

```json
{
  "schema_version": 1,
  "name": "NativeAgent-<version>.embedding.zip",
  "sha256": "<64 lowercase hex characters>",
  "byte_length": 123456,
  "url": "https://github.com/<owner>/<repo>/releases/download/v<version>/NativeAgent-<version>.embedding.zip",
  "distribution": "separate-download",
  "archive_root": "embedding",
  "model": {"model": "embedding.mlpackage", "vocab": "vocab.txt", "model_id": "<id>", "dimensions": 1024}
}
```

Use the release-generated values instead of the example size and placeholders;
`model` is the original `embedding.json` object. The app verifies the archive
digest and installs its `embedding/` contents into `<dataRoot>/extras/coreml`.
The downloader checks `release.sha256` ownership independently of model manifest
and artifact usability. Missing, unreadable or malformed ownership evidence is
reported as unverified with unknown ownership and the installation is preserved;
it is never labelled a custom usable model. Downloader and Doctor give the same
remedy: preserve the whole installation under a sibling recovery name, then
choose Check / resume to install the verified release; never invent a release
marker. Only checked downloader-owned installations are eligible for replacement.
Launch requests checked memory-epoch convergence for bundled and separate-download
distributions alike, including a present model whose ownership is unverified.
A target commit always requests memory-epoch convergence;
staging cleanup failure remains a separate warning and cannot revoke the install.
An already-current target reports no installation change, including when it
arrives during a transfer; it does not release/reload the resident model.
The engine's independent launch work still requests checked epoch convergence.
Configured but unreadable/invalid descriptors leave embedding bring-up unavailable
instead of selecting bundled mode. Only genuinely absent download parts start at
zero; failed part reads retain their actual error. Release and install scripts
do not mutate the user's model cache.

To use the downloader in a development install, supply the release descriptor:

```sh
NATIVEAGENT_EMBEDDING_DISTRIBUTION=separate-download \
NATIVEAGENT_EMBEDDING_DOWNLOAD_MANIFEST=/path/to/NativeAgent-X.Y.Z.embedding.json \
  ./script/install_app.sh
```

Replace the manifest path with the actual descriptor. Bundled development
installs remain the default. Assembly finishes model resources, the optional
descriptor and documentation before the builder signs; installation verifies
and transfers that signed bundle.

Bundled development builds require a complete model in `extras/embedding` or
`NATIVEAGENT_EMBEDDING_MODEL_DIR` before compilation. A missing model is fetched;
a failed acquisition or validation stops the build. No user-data cache
substitutes for bundle resources. `fetch_embedding_model.sh` selects one
`NATIVEAGENT_EMBEDDING_MODEL_REPO` and
`NATIVEAGENT_EMBEDDING_FETCH_AUTH=anonymous` (default) or `github-cli` before
requesting bytes. It verifies that source's expected SHA-256; failure never
switches repository or authentication method. A present invalid model stays
preserved and is reported. Release packaging never downloads a model.

For delta updates in separate-download mode, retain the previous **shipped,
signed** DMG locally outside the appcast output directory. Set
`NATIVEAGENT_SPARKLE_PREVIOUS_DMG=/path/to/NativeAgent-<previous>.dmg`, or pass
`--previous-dmg /path/to/NativeAgent-<previous>.dmg` to
`script/generate_appcast.sh` with
`NATIVEAGENT_EMBEDDING_DISTRIBUTION=separate-download`. The baseline must have a
different filename from the current DMG; it is neither fetched nor uploaded.
With no baseline, or if Sparkle declines an incompatible or unhelpful patch,
only the full signed DMG update is available. An explicitly supplied missing
baseline is an error. Check the appcast manifest's `delta_count` before claiming
a delta is available. Bundled mode disables delta generation.

## 2. Sparkle key generation

Once Sparkle's tools are available from the package build, run:

```sh
./script/sparkle_keygen.sh
```

Follow its printed export command to create the private-key file and restrict
it to mode 600. The default path is
`~/.config/nativeagent/sparkle_ed_priv.key`.

`release_github.sh` derives the public key from that file.
`release.sh` checks it against `NATIVEAGENT_SPARKLE_PUBLIC_KEY` and embeds
`SUPublicEDKey`; `generate_appcast.sh` checks the signing key against the app.
Do not hardcode private keys in source or generate a replacement key for an
existing update channel without a planned key transition.

## 3. Per-release workflow

### Prepare the public source

Commit the intended `VERSION` and reviewed release changes before preparing
artifacts. From a private maintainer checkout, create the public export:

```sh
./script/make_public_export.sh /tmp/nativeagent-public-export
```

The exporter archives tracked source, removes private material, scrubs
identities, verifies resources and creates fresh single-commit history. That
directory is the reviewable source artifact; the exporter neither compiles nor
pushes. Review and explicitly publish its source commit before releasing.
The actual release executable passes the compiled identity/privacy gate in
`release.sh`; there is one compile under [AGENTS.md](../AGENTS.md).

A published-mirror checkout contains the tracked `.nativeagent-public-source`
marker. Never copy it into private source to bypass export. A nonpublishing
public `release.sh` invocation from a private tree creates the source export
and stops; `--publish-appcast` refuses private source before building. Release
from the reviewed public checkout with a matching GitHub push remote and
published HEAD. The publisher's `--preflight-source` checks that contract before
compilation.

### Preflight and publish

From the clean public checkout, with the private inputs above configured:

```sh
./script/release_github.sh --preflight
```

Preflight checks GitHub visibility, authentication, the clean source commit's
presence in the public repository, signing inputs, privacy configuration and
the selected sync prerequisites.

When publication is authorized:

```sh
./script/release_github.sh
```

The wrapper invokes `release.sh --publish-appcast`. The release script
generates the Xcode project, builds the Release app with `xcodebuild`, stages
resources, signs, notarizes, staples, builds the DMG and verifies the artifact.
The GitHub wrapper leaves the DMG wrapper unsigned; the contained app is
signed, notarized and stapled.

Production releases write an artifact-only receipt with
`canonical_gate: "script/release.sh --artifact-only"`,
`ios_required: false` and `ios_result: "not_run"`. The compatibility filename
still ends in `.test-receipt.json`; it does not claim tests ran. `--artifact-only`
is an accepted spelling for this same path, with no separate release mode.
Only after final DMG verification succeeds is the receipt atomically written
beside that DMG. Its artifact name, SHA-256 and byte length must match in both
the attestation and publisher. No completion record is minted in advance under
`.runtime/`. Build, install and check the actual release app's requested behavior.

### Verify an existing artifact

```sh
./script/verify_release_artifact.sh \
  --dmg dist/NativeAgent-X.Y.Z.dmg \
  --require-notarized --require-sparkle-key
```

Replace `X.Y.Z` before running. The verifier also accepts
`--bundle dist/NativeAgent.app`. It checks the app's signing, resources,
privacy/identity boundaries and update metadata; DMG mode mounts the image
read-only. Artifact verification does not establish installed behavior.

### Local packaging only

`./script/release.sh --dry-run` builds, stages and signs, then stops before
notarization and DMG creation. The default `NATIVEAGENT_SIGNING_MODE=developer-id`
requires `NATIVEAGENT_DEVELOPER_ID`; select `adhoc` explicitly for a host-only
rehearsal. Missing prerequisites or failed signing stop the selected mode.
Dry-run never creates a production release receipt.

`--appcast` generates a local signed feed; `--publish-appcast` publishes it.
Only the latter permits the release to claim a published update feed.

## 4. Upload and appcast

Bundled releases publish exactly four assets to `v<VERSION>`:

- `NativeAgent-<version>.dmg`;
- `appcast.xml`;
- `NativeAgent-<version>.test-receipt.json`;
- `NativeAgent-<version>.release-attestation.json`.

The attestation binds source, receipt and final DMG verification. The publisher
creates a draft and verifies uploaded asset digests/sizes before publication.
The appcast pipeline then fetches the unauthenticated feed and DMG and compares
their bytes with the local artifacts.

The wrapper derives:

- feed: `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`;
- enclosure: `https://github.com/<owner>/<repo>/releases/download/v<VERSION>/NativeAgent-<VERSION>.dmg`.

Artifacts for a publish run stay under `dist/.pending-publish/` until live
publication verification succeeds. A failed run leaves them there; do not
distribute those staged artifacts as a completed release. An exit status from
an upload command alone is insufficient.

## 5. Files reference

| File | Purpose |
|---|---|
| `VERSION` | Mac release version |
| `script/make_public_export.sh` | Scrubbed public source export |
| `script/release_github.sh` | GitHub preflight and release entry point |
| `script/release.sh` | Xcode build, signing, notarization and packaging |
| `script/dmg_builder.sh` | DMG construction |
| `script/verify_release_artifact.sh` | App/DMG verification |
| `script/generate_appcast.sh` | Sparkle feed signing and publication verification |
| `script/publish_github_release.sh` | GitHub draft, upload, verification and publication |
| `NativeAgent.cloudkit-public.entitlements` | Team-neutral public CloudKit template |
| `NativeAgent.public.entitlements` | Standalone Mac entitlements |
| `Sources/NativeAgentApp/UpdateController.swift` | Sparkle update UI |
| `script/ios_release.sh` | iOS readiness, archive and local export |

For iOS metadata and review preparation, see
[App Store submission](app_store_submission.md).
