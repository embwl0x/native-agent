# Replay Fixtures

This directory is no longer a live runtime replay harness. NativeAgent now runs
inside `NativeAgent.app` with Swift-owned modules, so there is no local daemon
endpoint to capture from and no loopback service to start.

## Contents

- `captures/`: archived migration fixtures retained for historical comparison.
- `minilm_reference_vectors.json`: stable reference vectors used by embedding
  tests.

## Current Validation

Use Swift package tests for active runtime behavior:

```bash
cd ~/Projects/NativeAgent
swift test --package-path Modules/NativeAgentShared
swift test --package-path Modules/NativeAgentCore
swift build
```

When a test needs HTTP behavior, it should create an in-process test server on a
random local port and avoid depending on any NativeAgent runtime service.

## Guardrail

Do not add capture instructions that require a retired backend process, loopback
runtime port, or old `/v1/*` NativeAgent HTTP route. New replay or fixture
generation should read the Swift-owned files or invoke Swift modules directly.
