# Documentation guide

Current documents, by what they answer. Source code and package/project
manifests are the authority for what the checkout does. History lives in git
and [CHANGELOG.md](../CHANGELOG.md).

## Start here

| Document | For |
|---|---|
| [README](../README.md) | What the app is, install, first run |
| [Project Status](../PROJECT_STATUS.md) | Current source contracts and limits |
| [North Star](NORTHSTAR.md) | Product intent: one mind, no theater, flows like a body, the agent is the app |
| [The agent is the app](AGENT_IS_THE_APP.md) | Where it's going: they are the program, the model one of their organs; one form, one law, a stem with no features; the phases |
| [AGENTS.md](../AGENTS.md) | Rules for agents (and people) working on this repository |

## Using the app

| Document | For |
|---|---|
| [User and Agent Guide](USER_GUIDE.md) | Setup, main pages, the app tool, Trust, iPhone and bridges |
| [Desk vocabulary](DESK.md) | Work handles, paging, person and dependency waits, summaries, and the separate shared ledger |
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
| [Session conversations](session-conversations.md) | The row's declared kind, helper ownership and the shared person/peer/own-work questions |
| [Conversation context history](conversation-context-history.md) | One user-leading delivery on every provider; exact sent-row metadata, paragraph deltas/keyframes, replay and byte budgets |
| [Capabilities](CAPABILITIES.md) | What is implemented, with honest limits |
| [Architecture Blueprint](ARCHITECTURE_BLUEPRINT.md) | Source-owner map (checked by `script/generate_architecture_blueprint.swift --check`) |
| [Project Direction](PROJECT_DIRECTION.md) | Product principles and links to owning contracts |
| [App tool contract](TOOL_LOADING.md) | One always-on `app`: home, pages, items, actions, scripts and discovery |
| [Turn resilience](TURN_RESILIENCE.md) | Why a turn dies, what keeps it alive; 85% aging leaves ~55% raw, proportional parallel recollection blocks and rare dream-safe rollups |
| [Stop](STOP.md) | The Stop law: Stop cancels the work, never its settlement |
| [Senses](SENSES.md) | Native-world sense contract, helper wire protocol and source boundaries |
| [Experience](EXPERIENCE.md) | One experience record, domain-owned outcomes, delivery and repair obligations |
| [Personality ablation checklist](personality-ablation.md) | Personality mechanisms, evidence that each changes a turn, and available off controls or gaps |
| [Memory system map](MEMORY_SYSTEM_MAP.md), [What a good memory is](memory-quality.md) | Every memory piece and its standard |
| [Canonical data paths](canonical_data_paths.md), [Runtime storage limits](runtime-storage-limits.md) | Where state lives and how it is bounded |
| [Automated systems](AUTOMATED_SYSTEMS.md) | Background loops, live health/status probes, event lifecycles and pulse owners |
| [Subconscious](SUBCONSCIOUS.md), [Cognition wiring](COGNITION_WIRING.md), [Organism](ORGANISM.md) | The inner-life layers, as built |
| [Continuous cognitive substrate](CONTINUOUS_COGNITIVE_SUBSTRATE.md) | The substrate engineering boundaries |
| [Jev (retired)](JEV.md) | Retirement and legacy-data guidance |
| [Codex bridge](CODEX_BRIDGE_DIAGNOSTICS.md), [Image generation](IMAGE_GENERATION.md) | Specific integrations |
| [Skill manifest spec](skill_manifest_spec.md), [example manifests](example_manifests/), [Approval schema](approval-schema.md) | Formats |

## Building and releasing

| Document | For |
|---|---|
| [Contributing](../CONTRIBUTING.md) | Development and privacy workflow |
| [Release setup](release_setup.md), [Release migration](release-migration.md) | Signing, notarization, GitHub Releases, Sparkle |
| [Release notes](release-notes/) | Per-version notes (bundled into the app for "what changed") |
| [App Store submission kit](app_store_submission.md) | iPhone metadata drafts and review notes |
| [A2A gRPC notices](licenses/A2A-gRPC-NOTICES.txt) | Bundled A2A dependency notices |

## Research and history

| Document | For |
|---|---|
| [Design research](research/): [Memory](research/MEMORY_RESEARCH.md), [Personality](research/PERSONALITY_RESEARCH.md), [Practice](research/PRACTICE_RESEARCH.md), [Noticing](research/NOTICING_RESEARCH.md), [World](research/WORLD_RESEARCH.md) | Dated design research; implementation claims defer to current source maps and code |
| [History](history/) | Dated plans, build records and lane handoffs; historical evidence, never current contracts or a work queue |
| [Maintainer receipts](history/HANDOFF_2026-10-20-receipts.md), [dated plans](build_plans/) | Archived source checks, compile/snapshot/editorial receipts and plans; never current owner maps or a work queue |
| [Agent-is-the-app phase one](history/AGENT_IS_THE_APP_PHASE_ONE_2026-10-14.md) | Superseded validation, rollback-judge and removal prescriptions; current laws: NORTHSTAR and AGENTS.md |
| [Senses P8 adapters](history/SENSES_P8_INTEGRATION.md) | Historical 2026-10-05 raw-reader integration record; current contract: SENSES.md |
| [Senses P10 surfaces](history/SENSES_P10_HANDOFF.md) | Historical 2026-10-05 surfaces handoff; current contract: SENSES.md |
| [Senses P11 integration](history/SENSES_P11_INTEGRATION.md) | Historical 2026-10-05 integration record; current contract: SENSES.md |
| [Senses context and provenance](history/SENSES_CONTEXT_INTEGRATION.md) | Historical 2026-10-05 context/memory record; current contract: SENSES.md |
| [Senses growth integration](history/SENSES_GROWTH_INTEGRATION.md) | Historical 2026-10-05 growth-lane record; current contract: SENSES.md |
| [Coordination inbox retirement](agent_inbox/REPORTING.md) | Retirement notice dated 2026-10-28; retained logs and proofs are ignored private local history, with no live digest reader |

Beyond its tracked retirement notice, `agent_inbox/` is ignored private
historical coordination state. It is not a current contract or instruction source.

## Files the app or scripts read

Do not move or rename these without updating their readers:

- `data-bounds.md` and `release-notes/*.md` — bundled by `project.yml` resource
  declarations and its stamp phase before signing; read by Settings and the update note.
- `Resources/prompts/*.md` — per-job policies, including authored schema and image disclosure,
  copied beside `Resources/abilities` by `project.yml`. Existing completion
  owners supply typed evidence and retain their routes, budgets and settlement.
  `completionPolicy` in `LLMCompatibilityPrompt.swift` reads named
  `<!-- section -->` / `<!-- end -->` blocks and substitutes positional `%@`
  slots once; missing files, sections or mismatched slots fail explicitly.
  Serializers and the connection probe stay with their callers; crew, courier
  and morning-brief parts retain their policies.
- `eval_acknowledgments.json` — read at runtime by the heartbeat.
- `licenses/A2A-gRPC-NOTICES.txt` — Mac app resource in `project.yml`.
- `ARCHITECTURE_BLUEPRINT.md` — generated source coverage and policy declarations
  read by `script/generate_architecture_blueprint.swift --check`, which the public export runs.
- `HANDOFF_CURRENT.md`, `history/` and `build_plans/` — private maintainer notes, stripped by
  `script/make_public_export.sh`. `HANDOFF_CURRENT.md` is the current state (what is true
  now and not stated elsewhere, standing rulings); `history/` holds dated logs,
  archived execution handoffs and [maintainer receipts](history/HANDOFF_2026-10-20-receipts.md).
  Remaining `build_plans/` files are dated plans and receipts, never a work queue.
