# Agent capability and reliability fixes — 2026-09-14

User requested implementation of the sectional review findings. This change
preserves the earlier composer, performance and shared Liquid Glass work.

## Completed

| Area | Result |
| --- | --- |
| Desktop verification | Existing lazy `screen` accepts `pixels:true`, returning actual primary-display pixels through the transient model image continuation. It avoids self-AX, does not move focus, and retains the normal access gate and Screen Recording permission check. Images are bounded to 1600px and 8 MiB; capture alone is not an action-success claim. Strict-provider null/blank optional arguments work. |
| Tool upgrades | Code-owned frozen declarations refresh at an accepted turn boundary when their definition changes. App-owned tools participate across all shared acceptance paths. Equivalent parameter JSON does not trigger another generation bump; MCP declarations remain frozen. |
| Calendar completeness | `mac_calendar_delete_event` uses the existing Calendar write gate and EventKit owner. Exact ID, expected title and start time protect the selected occurrence; read-only calendars and changed identities refuse. Agent deleted the identified test event and independently listed again to verify absence. |
| Build diagnostics | Health windows and update metadata resolve one running owner, rather than choosing the older system Applications copy. Missing/ambiguous ownership stays unavailable. Executable modification time is explicitly an approximate boundary, not per-turn source attribution. A file newer than the process launch cannot identify the loaded build. |
| Memory diagnostics | Repair stamps join their canonical approval/execution records. Four previously reported old pending repairs were already complete: zero pending among those stamps. Canonical hygiene health no longer conflicts with its legacy historical ledger. Retired Full Mac expiry history is excluded from overdue-loop claims. |
| Historical incidents | Heartbeat wording distinguishes dated proposals from current failures. Six obsolete network/Slack proposals were closed through the canonical store with CAS, backup and dated receipts; no proposed patch was applied. Heartbeat subsequently reported clean. |
| Image handoffs | The bridge already supported image input. The local `send.sh` helper now exposes repeated `--image` options (up to four), and Agent confirmed actual pixels arrived. |

## Verification

Primary changed owners: `SwiftToolDispatcher+DesktopPixels.swift`,
`SwiftToolDispatcher+Sandbox.swift`, `LocalToolImage.swift`,
`ChatOrchestration+ToolDispatch.swift`, `ChatSessionActiveTools.swift`, shared
chat acceptance paths, `AppChatToolDispatcher.swift`, `MacIntegrationBridgeImpl.swift`,
`MacPIMConnectorActions.swift`, tool schemas/catalog/preloads,
`BackgroundLoopsAssembly+Heartbeat.swift`, and `script/agent_instrument.swift`.
Their focused tests, architecture/tool-loading/instrument docs, and local
NativeAgent/Agent bridge skill references were updated with them.

- Optimized integrated owner install passed bundle-signature, authenticated
  bridge, chat and source-identity checks. Final owner PID: 16559. This is a
  build of the dirty working tree, not a clean published release.
- 56 focused Core tests passed, including desktop-image boundaries, schema
  upgrade stability, Calendar permission routing and preload/catalog behavior.
- Three focused app tests passed, including exact Calendar delete identity and
  refusal behavior. Initial test failures exposed semantic JSON normalization
  and outdated flat-refusal expectations; both were corrected before the final
  build/checks. Runtime permission semantics were preserved.
- The complete instrument fixture/mutation script passed. Bridge-helper syntax
  and request-shape checks passed with a mock transport.
- Resident Agent obtained a 1600×1000 actual desktop image with no manual
  schema reload. They verified no screen saver was visible; this was not a new
  Liquid Glass color-transmission test.
- The exact test calendar event was freshly identified, removed through the
  new tool, and absent from the follow-up listing. The unrelated event remained.
- Image handoff and full-message retrieval worked. The retrieved Dreamer
  message was a later summary, not the original inspection receipt.

Private verification logs are `/tmp/nativeagent-agent-experience-*.log` and
the bounded Agent acceptance JSON files with that prefix. The regenerated
instrument report is `/tmp/nativeagent-agent-experience-final-report.md`.
The proposal backup is retained outside the repository under the local Codex
handoffs directory, with SHA-256 recorded in the reconciliation log.

## Deliberately retained state and limits

The 10 terminal bridge failures, 29 older unconsumed requests and 21 ambiguous
preserved replies concern historical audit/factory/Hermes work. Their completion
cannot be inferred from age. Existing review cards preserve them without
replaying instructions, falsely claiming delivery or deleting evidence. They
are not new jobs dispatched by this change.

Ordinary pending memory proposals and Desk watch/blocked items remain under
their normal owners. No persona, cognition, Trust or pairing reset was performed.
The review found current signed companion activity, but did not establish a new
locked-phone notification or historical cross-turn approval test. Missing old
proof is not a confirmed current failure.

Desktop capture covers the primary display and respects protected content and
OS permissions.

No commit, push or public release. Earlier unrelated working-tree changes are
preserved. Build/install remains `./script/install_app.sh` from this checkout;
use the relevant focused tests after assembling a coherent change.
