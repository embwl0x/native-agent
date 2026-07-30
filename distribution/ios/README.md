# NativeAgent iOS distribution

This directory contains non-secret App Store distribution inputs. It does not
contain an Apple team ID, certificates, provisioning profiles, API keys, or an
App Store Connect session.

Permanent public identifiers:

- iOS app: `io.github.embwl0x.nativeagent.ios`
- shared CloudKit container: `iCloud.io.github.embwl0x.nativeagent`
- Mac companion: `io.github.embwl0x.nativeagent.mac`

Run the fail-closed readiness check from the repository root:

```bash
NATIVEAGENT_PRODUCTION_CLOUDKIT_SCHEMA=/secure/path/production.ckdb \
  ./script/ios_release.sh --preflight
```

When the preflight is green, create an archive and an IPA without uploading:

```bash
./script/ios_release.sh --archive --export
```

The export-options template uses `__NATIVEAGENT_TEAM_ID__`. The release script
replaces that marker in a temporary copy with the resolved local development
team. The committed template therefore stays reusable and identity-neutral.

The script intentionally has no upload mode. Uploading the IPA, completing
App Store Connect privacy answers, selecting the production CloudKit
container, deploying its production schema, and submitting the TestFlight/App
Store build remain explicit account-owner actions.

Metadata drafts live in `metadata/en-US`. Before submission, replace every
`REQUIRED:` value with the public website/support/privacy URLs and review
contact information. Do not put credentials or private test-account passwords
in this repository.
