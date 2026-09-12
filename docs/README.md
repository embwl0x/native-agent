# Documentation and repository guide

Start with the question you have. NativeAgent's runtime is owned by the Mac app
in-process; the iPhone, messaging integrations, browser extension, and builder
bridges are surfaces or adapters, not separate agent brains.

## Reading paths

| I want to… | Start here | Continue with |
|---|---|---|
| Install and use the app | [User and Agent Guide](USER_GUIDE.md) | [Support](../SUPPORT.md), [Mobile Companion](mobile_companion.md) |
| Understand what is implemented | [Capabilities](CAPABILITIES.md) | [Capability Snapshot](../PROJECT_STATUS.md#capability-snapshot), [Changelog](../CHANGELOG.md) |
| Understand how the system works | [Internal Workings](INTERNAL_WORKINGS.md) | [Anatomy of a Turn](ANATOMY_OF_A_TURN.md) |
| Find the source owner for a change | [Repository layout](#repository-layout) | [Architecture Blueprint](ARCHITECTURE_BLUEPRINT.md#app-source-map) |
| Build or contribute | [Contributing](../CONTRIBUTING.md) | [Validation boundaries](#validation-boundaries), [Project Direction](PROJECT_DIRECTION.md) |
| Understand context and durable memory | [Context lifecycle](INTERNAL_WORKINGS.md#1-anatomy-of-resident-context-and-a-turn) | [Memory lifecycle](INTERNAL_WORKINGS.md#2-anatomy-of-a-memory), [State ownership](ARCHITECTURE_BLUEPRINT.md#state-ownership) |
| Find why a turn died, or what keeps it alive | [Turn resilience map](TURN_RESILIENCE.md) | [Anatomy of a Turn](ANATOMY_OF_A_TURN.md), [Instrument](INSTRUMENT.md) |
| Find any memory piece, its switch, and its regression sign | [Memory system map](MEMORY_SYSTEM_MAP.md) | [What a good memory is](memory-quality.md) |
| Know which tool schemas ride a request, and when they leave | [Tool loading contract](TOOL_LOADING.md) | [Capabilities: tools](CAPABILITIES.md#tools-and-capability-growth) |
| Understand computer control | [Mac computer control](CAPABILITIES.md#mac-computer-control) | [Chrome control](../Extensions/NativeAgentChrome/README.md), [Trust modes](USER_GUIDE.md#trust-modes-and-approvals) |
| Use specialist builders | [Builder guide](USER_GUIDE.md#codex-and-claude-code-as-specialist-builders) | [Delegation lifecycle](INTERNAL_WORKINGS.md#5-one-persistent-mind-specialist-hands) |
| Inspect cognition and organism behavior | [Organism](ORGANISM.md) | [Cognition wiring](COGNITION_WIRING.md), [Instrument](INSTRUMENT.md) |
| Understand privacy or distribution | [Security](../SECURITY.md), [Privacy](../PRIVACY.md) | [Release setup](release_setup.md), [Data bounds](data-bounds.md) |

## Which document is authoritative?

- Source code and package/project manifests describe what this checkout can
  execute. The [Architecture Blueprint](ARCHITECTURE_BLUEPRINT.md) maps those
  owners; it is not a second implementation specification.
- [Project Status](../PROJECT_STATUS.md) separates the current candidate from
  published releases and contains a compact capability table after the dated
  change narrative. The [root Changelog](../CHANGELOG.md) and version-specific
  `docs/release-notes/` record changes; [early notes](CHANGELOG.md) are retained
  separately. Candidate notes are not publication proof. A source
  change, build, test receipt, installed app, and published DMG are different
  pieces of evidence; one does not imply the others.
- [Project Direction](PROJECT_DIRECTION.md) and [North Star](NORTHSTAR.md)
  explain product intent. Roadmap language is not a claim that a feature ships.
- Maintainer checkouts also contain `docs/HANDOFF_CURRENT.md` and
  `docs/build_plans/`. Read the newest relevant handoff section and an explicitly
  current as-built map, not every historical campaign. These private planning
  documents are omitted from public exports. They are history and context, not
  an automatic work queue.
- `docs/evals/` contains coverage definitions, evidence, and frozen/generated
  evaluation records. A row is meaningful only with its scope, source revision,
  and execution receipt; simulated or isolated proof is not installed behavior.

## Repository layout

| Location | Responsibility |
|---|---|
| [`Package.swift`](../Package.swift) | Root Mac app, Chrome relay, app/relay tests, and dependencies on Core, Shared, and Sparkle. The app deployment floor is defined here. |
| [`Sources/NativeAgentApp/`](../Sources/NativeAgentApp/) | SwiftUI scenes, app lifecycle, composition, Mac effect adapters, local bridges, and UI read models. `AppChatToolDispatcher.swift` owns shared chat-body assembly; `NativeClient+*.swift` files are in-process facades, not a daemon client. |
| [`Modules/NativeAgentCore/`](../Modules/NativeAgentCore/) | Swift packages/modules for chat, providers, MemoryV2, Context, trust, tools, Desk/Workshop execution, background loops, cognition, and connectors. See the [Core guide](../Modules/NativeAgentCore/README.md). |
| [`Modules/NativeAgentShared/`](../Modules/NativeAgentShared/) | Shared Mac/iOS value models and Apple-native transport. Mac remains the canonical runtime/state owner. |
| [`iOS/NativeAgentMobile/`](../iOS/NativeAgentMobile/) | Companion SwiftUI sources, tests, Xcode project, and `project.yml` generation input. |
| [`Extensions/NativeAgentChrome/`](../Extensions/NativeAgentChrome/) | Manifest V3 extension: tab leases, structured page snapshots, and exact node actions. |
| [`Sources/NativeAgentChromeRelay/`](../Sources/NativeAgentChromeRelay/), [`Sources/NativeAgentChromeRelayCore/`](../Sources/NativeAgentChromeRelayCore/) | Swift native-messaging transport between Chrome and the app-owned Unix socket. No agent, permission, or outcome authority lives in the relay. |
| [`tests/`](../tests/) | Root app/relay tests, script/inventory/release guards, and replay fixtures. Core and Shared keep their package tests in their own `Tests/` directories; iOS keeps its own `Tests/`. |
| [`script/`](../script/) | Build/install/test/release entry points, diagnostic/evaluation tools, and bundled coding-CLI workers. Node workers are external builder adapters; they are not a replacement NativeAgent runtime. |
| [`Resources/`](../Resources/), [`distribution/`](../distribution/) | App assets and distribution/entitlement configuration. Core-owned resources, including MiniLM, stay with their package target. |
| [`docs/`](./) | This guide, current product/architecture/operations documents, and separately scoped planning/evaluation evidence. |

`persona/`, `data/`, `workspace/`, and `.runtime/` in a development checkout are
private or generated state, not additional source packages. Public/app-only
installs resolve their own local roots. [Local data and privacy](../README.md#local-data-and-privacy)
describes those locations; `NativeAgentPaths` and `NativeAgentWorkspaceRoot`
are the source authorities. Full Mac YOLO can explicitly select an existing
external project; the default workspace is not a hidden ceiling on that grant.

## Runtime boundaries at a glance

```text
Mac / detached / signed iPhone / admitted Telegram and Slack / local bridge
  -> app-owned shared chat composition
  -> Core chat + checked provider route + generation-pinned context
  -> twenty always-on tools + mounted MCP, everything else lazy + trust owners
  -> transcripts, receipts, memory projections, cognition/organism feedback

Chrome extension <-> Swift relay <-> app-owned ChromeControlRuntime
Builder CLI workers <-> authenticated loopback bridge <-> same Mac runtime
```

Native screen control, NativeAgent's visible WebKit browser, and Chrome's
tab-scoped extension are distinct effect paths. Chrome content-script actions
can operate an inactive leased tab; native screen control observes and operates
the visible desktop. Neither path promises perfect perception, game play, or
successful external effects merely because input was emitted.

Fluid Context compiles registered persona/skill sources and canonical MemoryV2
and resident-work projections into rebuildable generations. It does not crawl
the whole repository or turn every document into always-on instructions.
Cognition supplies bounded turn-time attention/posture, not another fact store.
Native swarms are bounded worker calls under their selected access profile;
Codex/Claude Code/OMP bridges are external coding conversations with explicit
continuation and delivery receipts. Neither creates a second NativeAgent mind.

## Validation boundaries

Assemble the coherent change, build the integrated target, then select the
finished-workflow validation appropriate to its scope. The commands below are
entry points, not a requirement to run every suite for every edit.

| Boundary | Entry point / evidence |
|---|---|
| Mac app build | `swift build --jobs 4 --force-resolved-versions --skip-update` |
| Core package | `swift test --package-path Modules/NativeAgentCore --no-parallel` |
| Shared package | `swift test --package-path Modules/NativeAgentShared` |
| Root Mac app and relay tests | `swift test --no-parallel` |
| iOS companion | `./script/test_ios.sh`; `--require` refuses an unavailable simulator rather than skipping. |
| Whole repository | `./script/test.sh`: script/architecture/privacy/inventory guards (including iOS release fixtures), Node bridge and Chrome extension tests, Core XCTest and serial Swift Testing shards, Shared, root Mac tests, and iOS handoff. |
| Full Mac+iOS release gate | `./script/test.sh --require-ios`; the release pipeline uses `--release-receipt PATH` to bind successful execution to one clean, unchanged source revision. |
| Chrome extension in isolation | `node --test Extensions/NativeAgentChrome/tests/*.test.js`; the canonical gate includes these suites, and relay Swift tests live in the root package. |
| Installed behavior | Canonical install followed by the relevant resident workflow; [User Mode Evaluation](USER_MODE_EVAL.md) and [Instrument](INSTRUMENT.md) describe their narrower evidence. |

The iOS runner chooses an actually available iPhone simulator and inspects the
fresh result bundle for discovered/executed tests. A simulator skip is not iOS
proof. Package tests do not establish signing, notifications on a locked phone,
real screen interaction, provider answer quality, or a fresh-machine DMG launch.
