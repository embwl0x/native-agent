# Subsystem #4 - ToolRegistry

## Current Status

ToolRegistry is Swift-owned. `NativeAgent.app` reaches it through
`makeToolRegistry()`, which returns `SwiftNativeToolRegistry` from
`Modules/NativeAgentCore/Sources/ToolRegistry/ToolRegistry.swift`.

There is no live HTTP proxy, Python-backed implementation, or capture workflow
for this subsystem.

## Ownership

- Storage: `<dataRoot>/tools/registry.json`
- Implementation: `SwiftNativeToolRegistry`
- App entry points: `NativeClient+RegistryMutations.swift` and tool-dispatch
  surfaces that read the registry
- Tests: `Modules/NativeAgentCore/Tests/ToolRegistryTests/ToolRegistryTests.swift`

`SwiftNativeToolRegistry` lists tools, promotes tools, and quarantines tools
with actor serialization plus `SwiftNativePersistenceCore.withFileLock` for
cross-process file safety. Unknown registry fields round-trip through
`JSONValue` extras so older on-disk records remain readable.

## Scope

In scope:

- `listTools(filter:)`
- `getTool(id:)`
- `promote(id:)`
- `quarantine(id:reason:)`
- Preservation of unknown fields, explicit `null` fields, timestamps, signing
  metadata, and quarantine metadata
- Concurrency safety for promote/quarantine read-modify-write operations

Out of scope:

- Running arbitrary tools
- Validating or signing new manifests
- Vendoring an interpreter or external runtime into the app
- Reintroducing a network backend for registry mutations

## Validation

Use the Swift tests, not a runtime capture harness:

```bash
swift test --package-path Modules/NativeAgentCore --filter ToolRegistryTests
```

For wider confidence after registry behavior changes:

```bash
swift test --package-path Modules/NativeAgentCore
```

## Compatibility Notes

Some tests and comments may refer to historical file shapes or route names to
pin decode behavior. Treat those as schema compatibility notes only. New
ToolRegistry behavior must be implemented in Swift or fail closed with a typed
Swift error.
