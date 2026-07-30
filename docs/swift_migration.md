# NativeAgent Swift Migration - Archived Note

This file used to point at the long-running Python-to-Swift migration plan.
That migration is complete for the live runtime: `NativeAgent.app` owns the
runtime in-process, and new behavior must be implemented in Swift or fail
closed with a Swift error.

Use `docs/ARCHITECTURE_BLUEPRINT.md`, `docs/PROJECT_DIRECTION.md`, and
`PROJECT_STATUS.md` as the current architecture references.

## Historical Recap

- The migration originally moved one subsystem at a time behind a temporary
  cutover-flag control plane. That control plane has been removed.
- Current factories return Swift implementations for live runtime behavior.
- `tests/replay/` now contains archived/reference fixtures only; use Swift
  package tests for current validation.

Historical vault notes may still be useful for provenance, but they are not
instructions for current development.
