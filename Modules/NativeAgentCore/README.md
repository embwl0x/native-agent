# NativeAgentCore

Swift package for NativeAgent's core runtime owners. Mac UI, app composition,
and platform effect adapters live in `Sources/NativeAgentApp` at the repository
root; shared transport and the iOS app are separate packages/targets.

Architecture doc: [`../../docs/ARCHITECTURE_BLUEPRINT.md`](../../docs/ARCHITECTURE_BLUEPRINT.md).

## Runtime ownership

NativeAgentCore runs inside `NativeAgent.app`, alongside app-owned composition
and platform adapters. Shipped
subsystems are unconditionally Swift-native; unsupported edges fail closed with
an explicit Swift error rather than selecting another process or backend.

The retired migration control plane (`SubsystemFlag`, `RuntimeSnapshot`, and
`MutableRuntime`) must not be reintroduced. Product capabilities may still have
real trust, onboarding, or user-preference gates, but those gates belong to their
canonical subsystem owners and never choose between runtimes.

## Modules

Core package products include persistence, approvals, tool discovery and
execution, persona, doctor checks, chat orchestration, memory, dreams/REM,
self-improvement, trust, provider routing, background cognition, connectors,
Workshop, workflows, and the cognition/organism runtime.

`Sources/` groups implementations by module, `Tests/` groups their test targets,
and `Package.swift` defines the actual products and dependency graph. In
particular, `NativeAgentEvaluation` is evaluation support linked by ChatDrive
and tests, not a second production cognition owner or a Mac app dependency.

## Runtime status

NativeAgentCore is the live Swift runtime for `NativeAgent.app`. There is no
general-purpose agent daemon or runtime-selection attachment in the app
lifecycle. The app's authenticated loopback bridge is a live adapter for local
clients, not a fallback runtime; external coding CLI/MCP child processes remain
distinct from the Mac-owned agent.

Key ownership boundaries:

- **PersistenceCore** owns atomic JSON / JSONL file IO and file-lock helpers.
- **ChatOrchestration**, **ProviderRouting**, **MemoryV2**, **Context**, **TrustCenter**, and
  **ToolExecution** own chat turns, model routing, recall/writeback, policy, and
  tool dispatch in process.
- **BackgroundLoops**, **TriggerScheduler**, **DreamREMCycle**, and
  **SelfImprovement** own unattended work from the Swift app.
- **MCPDispatcher**, **ToolRegistry**, **Skills**, **WorkflowOrchestration**,
  **WorkshopExecution**, **Research**, **Connectors**, and **MacControl** serve their
  runtime surfaces directly from Swift modules and the shared data root.
- **DoctorChecks** and release verification are guardrails that specifically
  check that retired runtime artifacts have not come back.

Historical comments in source may still mention old route names or retired
behavior when they pin a wire shape, file format, or regression test. Treat
those as compatibility notes only. New behavior must be implemented in Swift or
fail closed with an explicit Swift error.

## Validation runbook

From the repository root, assemble the complete change, build the integrated
target, then choose the relevant final check. The
[repository validation map](../../docs/README.md#validation-boundaries)
describes the canonical gate, including Core XCTest/Swift Testing, Shared, Mac,
script/bridge guards, and iOS. A Core-only test is not full-system proof.

```bash
# Integrated Mac build
swift build --jobs 4 --force-resolved-versions --skip-update

# Core runtime changes
swift test --package-path Modules/NativeAgentCore --no-parallel

# Shared models or root Mac/relay tests
swift test --package-path Modules/NativeAgentShared
swift test --no-parallel

# Full repo sweep when the surface is broad
./script/test.sh
# Require the iOS lane; an ordinary simulator skip is not proof.
./script/test.sh --require-ios
```

For app-runtime behavior changes, rebuild/install with `./script/install_app.sh`
before treating the change as shipped. iOS source changes still require an Xcode
simulator/device build.

## Rollback

Rollback is now normal Swift rollback: revert the bad change or ship a follow-up
build that gates the feature off in Swift. Do not start an external runtime or
restore retired backend code to recover behavior.
