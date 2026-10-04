# Documentation guide

Current documents, by what they answer. Source code and package/project
manifests are the authority for what the checkout does. History lives in git
and [CHANGELOG.md](../CHANGELOG.md).

## Start here

| Document | For |
|---|---|
| [README](../README.md) | What the app is, install, first run |
| [Project Status](../PROJECT_STATUS.md) | Current source contracts and limits |
| [North Star](NORTHSTAR.md) | Product intent: one mind, no theater, flows like a body |
| [AGENTS.md](../AGENTS.md) | Rules for agents (and people) working on this repository |

## Using the app

| Document | For |
|---|---|
| [User and Agent Guide](USER_GUIDE.md) | Setup, main pages, the app tool, Trust, iPhone and bridges |
| [Siri and notification actions](siri-notification-actions.md) | Named-agent phrases, Mac Approve/Deny/Reply actions, and installed-app checks |
| [Support](../SUPPORT.md) | Install, pairing, updates, troubleshooting |
| [Privacy](../PRIVACY.md), [Security](../SECURITY.md), [Threat model](threat-model.md) | What leaves the Mac, what is defended, what is not |
| [Data bounds](data-bounds.md) | Caps and retention (bundled in the app: **Settings → Show data limits**) |
| [Mobile companion](mobile_companion.md), [iPhone approval pairing](ios-device-pairing.md), [APNS push](apns-push.md), [iOS sharing](ios-sharing.md) | The iPhone transport, pairing, and Share extension |
| [Agent conversations](agent-communication.md), [A2A over gRPC](a2a-grpc-integration.md) ([decision report](a2a-grpc-impact.md)), [Grok Bot connection](grok-bot-connection.md) | Talking to other agents and peers |

## How it works

| Document | For |
|---|---|
| [Internal Workings](INTERNAL_WORKINGS.md) | The connected lifecycle: context, memory, action, growth, delegation |
| [Anatomy of a Turn](ANATOMY_OF_A_TURN.md) | One message from acceptance to settlement |
| [Capabilities](CAPABILITIES.md) | What is implemented, with honest limits |
| [Architecture Blueprint](ARCHITECTURE_BLUEPRINT.md) | Source-owner map (checked by `script/check_architecture_blueprint.swift`) |
| [Project Direction](PROJECT_DIRECTION.md) | Durable product and safety rules |
| [App tool contract](TOOL_LOADING.md) | One always-on `app`: home, pages, items, actions, scripts and discovery |
| [Turn resilience](TURN_RESILIENCE.md) | Why a turn dies, what keeps it alive |
| [Memory system map](MEMORY_SYSTEM_MAP.md), [What a good memory is](memory-quality.md) | Every memory piece and its standard |
| [Canonical data paths](canonical_data_paths.md), [Runtime storage limits](runtime-storage-limits.md) | Where state lives and how it is bounded |
| [Automated systems](AUTOMATED_SYSTEMS.md) | Background loops and their health probes |
| [Subconscious](SUBCONSCIOUS.md), [Cognition wiring](COGNITION_WIRING.md), [Organism](ORGANISM.md) | The inner-life layers, as built |
| [Continuous cognitive substrate](CONTINUOUS_COGNITIVE_SUBSTRATE.md), [its traceability ledger](COGNITIVE_SUBSTRATE_TRACEABILITY.md) | The substrate design and per-item status |
| [Jev (retired)](JEV.md) | Retirement and legacy-data guidance |
| [Codex bridge](CODEX_BRIDGE_DIAGNOSTICS.md), [Image generation](IMAGE_GENERATION.md), [GitHub project tracking](GITHUB_PROJECT_TRACKING.md) | Specific integrations |
| [Skill manifest spec](skill_manifest_spec.md), [example manifests](example_manifests/), [Approval schema](approval-schema.md) | Formats |

## Building and releasing

| Document | For |
|---|---|
| [Contributing](../CONTRIBUTING.md) | Development and privacy workflow |
| [Release setup](release_setup.md), [Release migration](release-migration.md) | Signing, notarization, GitHub Releases, Sparkle |
| [Release notes](release-notes/) | Per-version notes (bundled into the app for "what changed") |
| [App Store submission kit](app_store_submission.md) | iPhone metadata drafts and review notes |

## Files the app or scripts read

Do not move or rename these without updating their readers:

- `data-bounds.md` and `release-notes/*.md` — copied into the app bundle by
  `script/install_app.sh`, read by Settings and the update note.
- `eval_acknowledgments.json` — read at runtime by the heartbeat.
- `licenses/A2A-gRPC-NOTICES.txt` — a Mac app resource in `project.yml`.
- `ARCHITECTURE_BLUEPRINT.md`, `COGNITIVE_SUBSTRATE_TRACEABILITY.md` and the
  files listed in `script/check_architecture_blueprint.swift` — required by that
  check, which the public export runs.
- `HANDOFF_CURRENT.md` and `build_plans/` — private maintainer notes, stripped by
  `script/make_public_export.sh`. The newest handoff section is current; older
  sections and plans are history, not a work queue.
