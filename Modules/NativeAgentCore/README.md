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

`Sources/` groups implementations by module, and `Package.swift` defines the
actual products and dependency graph. `NativeAgentEvaluation` and ChatDrive
are retired and are not products or dependencies in the current manifests.

## Runtime status

NativeAgentCore is the live Swift runtime for `NativeAgent.app`. There is no
general-purpose agent daemon or runtime-selection attachment in the app
lifecycle. The app's authenticated loopback bridge is a live adapter for local
clients; external coding CLIs and programs held by resident abilities run in
separate processes. NativeAgent's own MCP door serves other agents.

Key ownership boundaries:

- **PersistenceCore** owns atomic JSON / JSONL file IO and file-lock helpers.
- **ChatTurnRuntime**, **ProviderRouting**, **MemoryV2**, **Context**, **TrustCenter**, and
  **ToolExecution** own chat turns, model routing, recall/writeback, policy, and
  tool dispatch in process.
- **BackgroundLoops**, **TriggerScheduler**, **DreamREMCycle**, and
  **BackgroundWork** own unattended work from the Swift app. **EngineRuntime**
  owns the evaluation artifact reads and manual diagnostic support projections.
- **PersonaEngine** owns built-in skill guidance and its display inventory;
  **TrustCenter** owns capability-pack admission, saved workflow templates and the part-installation port.
- **ToolRegistry**,
  **WorkshopExecution**, **Research**, **Connectors**, and **MacControl** serve their
  runtime surfaces directly from Swift modules and the shared data root.
- **DoctorChecks** and release verification are guardrails that specifically
  check that retired runtime artifacts have not come back.

Historical comments in source may still mention old route names or retired
behavior when they pin a wire shape, file format, or regression test. Treat
those as compatibility notes only. New behavior must be implemented in Swift or
fail closed with an explicit Swift error.

## Validation runbook

From the repository root, assemble the complete change and build the
integrated target. There is no automated test suite.

```bash
swift build --jobs 4 --force-resolved-versions --skip-update
```

For app-runtime behavior changes, rebuild/install with `./script/install_app.sh`
before treating the change as shipped. iOS source changes still require an Xcode
simulator/device build.

## Recovery

Fix the failure at its owning Swift boundary and ship the corrected build.
Follow [NORTHSTAR](../../docs/NORTHSTAR.md): fix forward; no fallbacks or
rollbacks. Do not restore an external runtime or retired backend code.
