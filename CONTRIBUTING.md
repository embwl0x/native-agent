# Contributing to NativeAgent

NativeAgent is an advanced single-operator Swift project. Contributions should
preserve its central invariants: one Mac-owned runtime, one canonical memory,
lazy context and tools, shared surface policy, and fail-closed trust boundaries.

## Setup

```bash
git clone https://github.com/embwl0x/native-agent.git
cd native-agent

# Hooks are not cloned. Install the staged privacy/secret guard once.
bash script/hooks/install.sh

# Builds, signs with available local configuration, installs, and launches.
./script/install_app.sh
```

The installer initializes blank-slate local persona, data, and workspace roots
when necessary. Personal persona files, runtime state, credentials, generated
artifacts, and local signing material are intentionally ignored.

## Read before changing architecture

Start with the [Documentation and Repository Guide](docs/README.md), then read
the relevant owner section in the [Architecture Blueprint](docs/ARCHITECTURE_BLUEPRINT.md).
[North Star](docs/NORTHSTAR.md) and [Project Direction](docs/PROJECT_DIRECTION.md)
explain intent; the [capability snapshot](PROJECT_STATUS.md#capability-snapshot)
records implementation boundaries. Maintainer checkouts additionally have
task-specific as-built maps under `docs/build_plans/`; public exports omit
private plans and handoffs.

Code and Git are authoritative when an old plan is stale. Update the active
docs when changing ownership, state roots, policy, or a cross-surface contract.

## Engineering rules

- NativeAgent runtime behavior must stay Swift-native and app-owned. Do not add
  a Python backend, launchd agent runtime, or LAN HTTP fallback.
- MemoryV2 is the fact source of truth. Fluid Context is rebuildable
  circulation; cognition and organism state are bounded advisory layers.
- Core `BackgroundLoopsManager` owns loop lifecycle and single-flight state.
- Tools and skill bodies remain lazy. Do not add broad catalogs or memory dumps
  to every prompt.
- Fix shared boundaries and audit Mac, detached chat, iOS, Telegram, Slack,
  local bridges, and Workshop where the contract is shared.
- TrustCenter, approvals, Full Mac, connector proof, signed mobile actions, and
  external-send confirmation remain authoritative.
- Add focused tests at persistence, identity, authorization, routing, and
  lifecycle boundaries.
- Preserve unrelated work in a dirty tree.

## Privacy and secret guard

Install [gitleaks](https://github.com/gitleaks/gitleaks), then arm the hook:

```bash
brew install gitleaks
bash script/hooks/install.sh
```

Before publication, run the repository's complete tracked-tree guard and the
upstream scanner:

```bash
./script/check_tracked_privacy.sh
gitleaks detect --source . --redact
```

The staged hook rejects common credentials and owner metadata such as local
home paths, usernames, email addresses, private bundle IDs, and machine names.
Do not use `--no-verify` unless the finding is understood and independently
checked.

## Build and tests

Assemble the coherent change, build the integrated target, then run one
proportionate validation of the finished workflow. The
[validation map](docs/README.md#validation-boundaries) explains the different
gates; these commands are alternatives selected by scope, not a sequence of
per-file checks.

```bash
swift build --jobs 4 --force-resolved-versions --skip-update

# Select the relevant finished-workflow/package check.
swift test --filter '<suite-or-test>'
swift test --package-path Modules/NativeAgentCore --no-parallel
swift test --package-path Modules/NativeAgentShared

# Canonical whole-repository gate before publication.
./script/test.sh
./script/test.sh --require-ios

# Optional installed-runtime sweeps.
./script/smoke_all.sh
./script/smoke_all.sh --live
```

For iOS changes, build or test against an actually installed simulator and
verify signing-sensitive behavior on a properly entitled device when needed.
The canonical gate covers script/inventory/iOS-release guards, Node builder and
Chrome extension tests, Core
XCTest and Swift Testing shards, Shared, the root Mac package, and an iOS test
handoff. An ordinary unavailable-simulator skip is not iOS proof; release
receipts require that lane. Chrome extension tests also have a focused
[entry point](Extensions/NativeAgentChrome/README.md).

For Mac runtime or UI changes, install canonically with
`./script/install_app.sh`. Do not execute the repository `dist` GUI executable
directly from a sandboxed agent shell; that can trigger a delayed AppKit crash
dialog even when the installed app is healthy.

## Pull requests

- Keep commits focused and use a GitHub-safe noreply author identity.
- Explain the invariant fixed, sibling paths audited, and tests run.
- Include screenshots for visible Mac/iOS changes.
- Call out migrations, compatibility wire IDs, or state-root changes.
- Do not claim a connector, release, or live integration works without the
  corresponding proof.
- Leave `./script/test.sh` green.

## Distribution

The public flow is intentionally stricter than a personal install:

```text
make_public_export.sh
  -> scrubbed one-commit source tree
  -> release.sh
  -> signed/notarized app and DMG
  -> verify_release_artifact.sh
```

See [docs/release_setup.md](docs/release_setup.md). Never publish `data/`,
`.runtime/`, `workspace/`, private persona files, OAuth tokens, Apple signing
material, generated context databases, or local receipts.
