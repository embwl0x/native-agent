import Foundation
import os
import CryptoKit
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// WAVE 21 (2026-06-01) — SUBSYSTEM #21: SwiftNativeWorkshopRunner.
//
// PURPOSE
//   Port the deterministic skeleton of the retired daemon::MissionRunner so
//   SwiftNativeTriggerScheduler.fireMissionTrigger can go FLIPPABLE-NATIVE.
//   Wave 12 (the trigger-scheduler fire_now port) initially tried a native
//   execution enqueue but landed empty-plan executions because it skipped
//   _plan_mission entirely. This wave closes the hole.
//
// WHAT IS NATIVE
//   - planWorkshopExecution(spec:)
//     - Builds the planner prompt byte-for-byte against the Python source
//       at the retired daemon (header text, tools_summary line
//       format, Rules block, JSON return-shape example).
//     - Parses the codex JSON response with the same markdown-fence strip,
//       same per-step validation (tool allow-list with chat.synthesize
//       fallback, autonomy_hint clamp to {auto, needs_approval}, ≤8 steps).
//     - Falls back to the deterministic 2-step stub when the LLM throws,
//       returns invalid JSON, returns 0 valid steps, or when autonomy is
//       disabled. The stub IS byte-for-byte identical to the Python source
//       at L1583-L1598 — verified by the fixture tests.
//   - submit(spec:)
//     - Writes timeline.jsonl FIRST (the "enqueued" event) and THEN
//       mission.json. The Python side writes mission.json first (in
//       TaskQueue.enqueue at L353), but a partial-crash between those two
//       writes would land a mission.json with no enqueued event in the
//       timeline. Wave-12 gpt-5.5 finding #4 explicitly flagged this
//       inversion as a state-lifecycle leak. Wave 21 fixes it on the Swift
//       side and the daemon side together.
//   - Persistence layout: <root>/workshop/executions/<id>/{mission.json,
//     timeline.jsonl, receipts/} mirroring the retired daemon + L625.
//   - Cross-process flock via PersistenceCore.withFileLock on the
//     mission.json target so the daemon's _write_json (already
//     file_lock-wrapped per wave-4) and Swift can't tear each other.
//
// WHAT IS NATIVE (wave 23 update)
//   - The LLM call. SwiftNativeWorkshopRunner injects a `WorkshopPlannerLLM`
//     protocol; the production `SwiftNativeWorkshopPlannerLLM` (wired by
//     `makeWorkshopRunner` factory) calls the in-app `SwiftNativeLLMClient`
//     which dispatches through the selected provider adapter. One checked
//     routing snapshot admits the complete 'executions'
//     provider/model/effort/tier tuple and task-local admission prevents a
//     valid preference change from splicing generations mid-call. Falls back to the
//     deterministic stub on LLM throw or timeout, matching Python's
//     broad-except path at the retired daemon.
//
// WHAT IS NATIVE (2026-06-10 executor port)
//   - The step executor loop: WorkshopExecutorLoop (WorkshopExecution+Executor.swift)
//     drains queued executions (claim under flock, started/step_completed/
//     terminal timeline events, receipts, approval staging + resume).
//     start(missionId:) on THIS protocol still throws .unavailable — the
//     executor actor owns execution because it carries the injected
//     LLM/tool/approval closures (see WorkshopExecution+Executor.swift header).
//
// WHAT IS NOT EXECUTED YET
//   - The live connector registry for planner tool summaries. The planner
//     still accepts `availableTools(surface:)` injection; native callers can
//     provide a Swift registry when available.
//
// SECURITY / CORRECTNESS NOTES
//   - The stub fallback is the ABSOLUTE FLOOR. Any planner exception,
//     any non-JSON LLM response, any 0-valid-step parse, any
//     autonomy-disabled state → 2-step stub. We never enqueue an empty
//     `plan: []` execution (the wave-12 regression).
//   - Provider dispatch uses one checked executions routing snapshot. The
//     selected provider adapter owns authentication (OAuth or API key); model
//     prefixes do not choose the provider. Unavailable routing fails planning
//     without borrowing another provider's credentials.
//   - CANCELLATION (wave 23). `runCodex` and `_planWorkshopExecutionWithReason`
//     propagate `CancellationError` distinctly from `WorkshopExecutionError`. A
//     cancelled `submit()` MUST NOT write `mission.json` or fire the
//     detached auto-start — without the explicit propagation the broad
//     `catch { ... plannerFailure }` would erase the cancellation and
//     silently land a stub execution.
//   - title/objective truncation matches Python: title[:160],
//     objective[:2000].
//   - execution.id is a v4 UUID lowercased to match Python's str(uuid.uuid4()).
//   - created_at / updated_at / event ts are ISO-8601 with timezone offset,
//     using the same DateFormatter shape as MCPDispatcher.isoTimestamp.
//   - asdict(execution) shape parity: every field on the Python @dataclass
//     Execution appears in the JSON with the same key name (all 15 fields).
//     Key order is NOT preserved — JSONValue serialization sorts keys
//     alphabetically — so the shape matches but the literal byte order
//     differs from Python's asdict() output. See `WorkshopExecutionRecord.toJSON()`.
