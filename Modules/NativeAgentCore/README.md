# NativeAgentCore

Swift package for NativeAgent's native runtime. Every subsystem listed in the
design doc lives here as a Swift module.

Architecture doc: [`../../docs/ARCHITECTURE_BLUEPRINT.md`](../../docs/ARCHITECTURE_BLUEPRINT.md).

## Runtime ownership

NativeAgentCore is the only live runtime behind `NativeAgent.app`. Shipped
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

Subsystem #17 (HTTP server deprecation) is a removal, not a new module.

## Runtime status

NativeAgentCore is the live Swift runtime for `NativeAgent.app`. There is no
runtime HTTP server, process-owned daemon, fallback backend, or runtime-selection
attachment in the app lifecycle.

Key ownership boundaries:

- **PersistenceCore** owns atomic JSON / JSONL file IO and file-lock helpers.
- **ChatOrchestration**, **ProviderRouting**, **MemoryV2**, **TrustCenter**, and
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

Run the narrowest package check for the changed module, then broaden when the
change crosses module or app boundaries:

```bash
cd ~/Projects/NativeAgent

# Shared model changes
swift build --package-path Modules/NativeAgentShared

# Core runtime changes
swift test --package-path Modules/NativeAgentCore --filter <Subsystem>Tests
swift test --package-path Modules/NativeAgentCore

# Mac app changes
swift build

# Full repo sweep when the surface is broad
./script/test.sh
```

For app-runtime behavior changes, rebuild/install with `./script/install_app.sh`
before treating the change as shipped. iOS source changes still require an Xcode
simulator/device build.

## Rollback

Rollback is now normal Swift rollback: revert the bad change or ship a follow-up
build that gates the feature off in Swift. Do not start an external runtime or
restore retired backend code to recover behavior.
