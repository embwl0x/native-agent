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
explain intent; the [project status](PROJECT_STATUS.md#where-things-stand)
records implementation boundaries. Maintainer checkouts also retain dated
plans and receipts under `docs/build_plans/` and archived execution handoffs
under `docs/history/`; these are history, not current owner maps or work
queues. Public exports omit both directories.

Code and Git are authoritative when an old plan is stale. Update the active
docs when changing ownership, state roots, policy, or a cross-surface contract.

## Engineering rules

- NativeAgent runtime behavior must stay Swift-native and app-owned. Do not add
  a Python backend, launchd agent runtime, or LAN HTTP fallback.
- MemoryV2 is the fact source of truth. Fluid Context is rebuildable
  circulation; cognition and organism state are bounded advisory layers.
- Core `BackgroundLoopLifetimes` owns loop lifecycle and single-flight state.
- Tools and skill bodies remain lazy. Do not add broad catalogs or memory dumps
  to every prompt.
- Fix shared boundaries and audit Mac, detached chat, iOS, Telegram, Slack,
  local bridges, and Workshop where the contract is shared.
- TrustCenter, approvals, Full Mac, connector proof, signed mobile actions, and
  external-send confirmation remain authoritative.
- Follow [AGENTS.md](AGENTS.md): build, install, and check the requested behavior
  in the working app. Do not create or run separate automated tests, test-only
  builds, harnesses, simulations, or stress/load campaigns.
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

## Build

A contributor building NativeAgent for their own use may build locally;
implementation lanes follow [AGENTS.md](AGENTS.md#how-we-work) and run no builds
of their own. The lead builds and installs the coherent phase once, then checks
the requested behavior in the installed app with a small, bounded check.
The repository has no automated test suite.
Documentation-only changes need a direct readback of the changed text, not an
app build or test run.

The canonical Mac build/install path, including both Codex environment actions,
is `script/install_app.sh`: `build_and_run.sh --build-only` assembles and signs
the finished bundle; the installer verifies and transfers it, launches and
checks authenticated readiness against the stamped source content identity,
including dirty edits. Builders capture it after generation and before compilation.
Codex shells use this installed-app path because the builder refuses GUI launch:

```bash
./script/install_app.sh
```

The promotion gauntlet runs static checks and verifies the running app's signature
and exact installed-source readiness. Compilation and source assembly belong to
the canonical build/install path. Optional contributor-local checks:

```bash
# Static checks; --live also checks the already-installed runtime's exact identity.
./script/smoke_all.sh
./script/smoke_all.sh --live
```

For a contributor's iOS build, use an actually installed simulator and verify
signing-sensitive behavior on a properly entitled device when needed.

## Pull requests

- Keep commits focused and use a GitHub-safe noreply author identity.
- Explain the invariant fixed, sibling paths audited, and how it was proven.
- Include screenshots for visible Mac/iOS changes.
- Call out migrations, compatibility wire IDs, or state-root changes.
- Do not claim a connector, release, or live integration works without the
  corresponding proof.

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

The compatibility-named `test-receipt.json` records artifact-only release
evidence; it does not attest automated tests or installed-app behavior.
