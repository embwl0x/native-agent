# Turn resilience map

How a turn keeps working, stops, and leaves evidence. One brain, many doors:
`EngineRuntime/EngineTurns.swift` holds Mac turn state through
`MacChatTurnRuntime`; `ChatTurnRuntime` owns the shared turn engine.
Source paths below are relative to `Modules/NativeAgentCore/Sources/`.

Agent's one always-on tool is `app`. `app {}` returns home, where they left
off; `page`, `item`, `find`, `action` and `script` reach its contents.
`AppToolRuntime/AppActionRegistry.swift` defines the actions and
`AppScriptRunner.swift` runs JavaScriptCore scripts. The model-facing tool
contract is in [Tool loading](TOOL_LOADING.md).

## The rule each piece follows

- Recover a failed provider call within the existing conversation, keeping
  completed tool results.
- Preserve visible partial prose when a stream fails or the person presses Stop.
- Treat a timeout or interrupted action as uncertain effects; inspect the
  receipt and current state before repeating it.
- Keep cancellation distinct from failure. Recovery does not grant permission
  to replay a whole turn.

## The pieces

### 1. One clean exit

`ChatTurnRuntime/ChatOrchestration+StreamingToolLoop.swift` continues until
the model answers with no calls or pending work. Stop interrupts; approvals,
questions and a Mac takeover wait for the person. There is no iteration or
whole-turn clock limit. Helper owners can still request a per-run token budget;
that owner's exhaustion returns the kept reply as incomplete.
Mac takeover suspends the same conversation on `MacAttentionSessionStore`'s
driver-change stream. Returning control continues from the recorded results;
task cancellation or the run-tagged Stop flag releases the wait. A waiting turn
keeps the return-control action reachable under Full Mac.

### 2. Progress and the circling question

`ToolLoopNoProgressGuard` keeps its evidence: a warning after eight identical
tool rounds, or four identical failures even when arguments change. Sixteen
identical rounds or eight identical failures raise one choice card:
“I've done the same thing N times in a row without getting further — keep going,
or change course?” The existing receipt and interaction continuation own its
persistence and resume.

### 3. Tool dispatch deadline

`ChatTurnRuntime/ChatOrchestration+ToolDispatch.swift` applies
`ToolDispatchDeadline` from `ToolLoopSupport.swift`. Folded `app` actions
use the underlying tool's name and arguments to select their deadline.
Defaults are 900 seconds for interactive work and 3,900 for unattended work;
an integer `timeout_seconds` is clamped to 30–3,600 seconds plus a 30-second
cleanup margin. Tool-specific defaults can differ.

`NATIVE_AGENT_TOOL_DISPATCH_TIMEOUT_SECONDS` overrides this policy;
nonpositive or nonfinite values disable the dispatch backstop. Expiry returns
model-visible error feedback stating that effects may already have occurred.
The deadline helper delegates to `NativeAgentCore/TurnDeadline.swift`, whose
resume-once race releases the caller without waiting for uncooperative work.
Cancellation of that work is not proof that its effects stopped or rolled back.

### 4. Provider timeouts

`ProviderRouting/ProviderStreamGuard.swift` defaults to a 90-second idle
timeout and 600-second wall timeout. Environment settings
`NATIVE_AGENT_PROVIDER_STREAM_IDLE_TIMEOUT_SEC` and
`NATIVE_AGENT_PROVIDER_STREAM_WALL_TIMEOUT_SEC` override them; values are
bounded to 0–86,400 seconds, with zero disabling that timeout. Background
calls use the same settings. Idle time is wire activity (headers, SSE
comments, events); a cut is the typed `ProviderFailure.noReply`, and every
stream failure's `Diagnostic` records whether the provider admitted the request.
Until the adapter yields the provider's first output (text, tool, reasoning),
wire keep-alives and a buffered adapter's own heartbeat hold the connection
open but are not a reply: the guard also cuts at the provider's first-output
deadline, the slowest adapter `ttftMs` of its retained calls on that model and
stream kind (`ProviderVitalsSensor`: read from the trace's `llm.call` rows at
launch, joined by each live call's `ttftMs`, nothing written). Under 100 calls
it is unmeasured and only the wall stands; buffered kinds record no `ttftMs`,
so idle and wall bound them.
The cut text says the seconds waited, what arrived, and that evidence.

`ProviderRouting/LLMClient+Real.swift` wraps streams with the configured
per-call guard and uses `withCompletionWall` for buffered calls. A guard cut
is input to recovery, never a whole-turn deadline.

### 5. In-loop provider recovery (the reconnect ladder)

`ChatTurnRuntime/ChatOrchestration+StreamingToolLoop.swift` owns the loop,
including native-tool and text-marker protocols. One `TurnObservation` owns
the model's next-round feedback for a limit, stream cut, correctness boundary,
malformed call, empty reply, announced work without a call, refusal, or full
context. It preserves kept prose and appends a user text block alongside the
round's tool results, or a standalone user message when there were no results.
`turn.observation` records the same feedback on both protocols.

Network, no-reply, overload and rate-limit failures retry with backoff until
the provider answers or the person stops: 1, 2, 4, 8, 15, then 30 seconds;
a longer provider `Retry-After` wins. A cut with no kept prose replays the
identical conversation and records an observation only in the trace. After
prose, the observation tells the provider to continue after it. No calls from
an incomplete stream dispatch; previously completed results remain.
`provider.retry` and `provider_retry` carry uncapped reconnect status.

Streaming adapters report max-token limits as `toolBoundary(.outputLimit)`;
buffered adapters carry the answer prefix in `outputLengthLimit(partial:)`.
The loop retains yielded prose, or the buffered prefix if nothing was yielded,
discards that reply's calls and continues. Retained answer text stays outside
the pre-tool commentary prefix, so every surface delivers it as answer text.
Repeated blocks/actions, invented results and prose after a call are
correctness boundaries: complete
calls before the cut run and their results carry the observation. The third
identical read in one reply is a boundary even when other reads intervene.
Line-density and inline short-unit rules and harness notices are removed.

Authentication, missing configuration/routing and unavailable-model errors
remain repair waits. Standalone `complete()` overload retries retain their
own ten-attempt bound and deadlines.

### 6. Surface ownership

Telegram invokes the shared chat engine once. Provider recovery lives inside
the same turn; no surface automatically re-runs its completed tools.
The person's explicit `/retry` and Telegram delivery retries retain their
existing meaning. Streaming surfaces keep editing the same reply after cuts.

### 7. Cancellation trace

`ChatTurnRuntime/ChatOrchestrationClient+StructuredChat.swift` records
`turn.cancelled` with a `where` field and persists the visible partial.
`EngineRuntime/EngineTurns.swift` delegates Mac Stop to `MacChatTurnRuntime`.

At dispatch, a call stopped before it starts has a skipped result; an already
started call carries `effects_unknown: true`. A late tool result cannot replace
the first terminal outcome of the dispatch race. Check the action's receipt
and current state before trying it again.

### 8. Context compaction

`ChatTurnRuntime/IntraTurnContextCompaction.swift` bounds the working
conversation: it stubs older tool-result bodies and folds earlier rounds into
working notes. It can run proactively before a provider call or reactively
after a context-overflow refusal. Reactive compaction has no attempt cap.
When nothing remains to fold, the turn finishes incomplete with its retained
prose and the existing context-full notice to the person; no provider call
follows. After a successful trim, a `contextFull` observation asks the model
to finish from what it has. The seeded prefix remains protected.
Trace `context.intraTurnCompaction` records the mode, trigger and size change;
the status notice is `context_compaction`.

Persisted history has a separate owner:
`ChatSessionWork/ChatSessionAutocompactor.swift`. It creates and verifies a
backup before replacing older rows with a recollection, retains pending cards
and recent rows, and writes durably. `ChatCompactionDistiller.swift` can improve
the mechanical recollection; a failed distillation leaves the fallback.
Compaction is bounded summarization, not lossless retention.

### 9. Process continuation

`TurnTrace/AbandonedTurnReconciler.swift` owns the small atomic checkpoint at
`chat/session_state/<session>/turn-<turnId>.json`. The shared loop writes it
before each provider iteration and before dispatch; durable tool receipts
advance its step count and peer sources in the same checkpoint write. Receipts
also retain their latched sources, which recovery consumes without weakening
saved taint when peer trust changes. It keeps identity, input, envelope and reply
route, iteration, kept prose, working notes and a possibly running step, never the
provider message array. Input attachment bytes stay in `chat/attachments/`;
their existing transcript metadata supplies the saved paths.

At launch, the reconciliation hook discovers checkpoints independently of the
legacy trace window and excludes the in-flight registry and claimed resumes.
`EngineRuntime/EngineTurnContinuation.swift` restores the original admission,
surface capabilities, peer provenance, helper ownership and delivery route.
`ChatOrchestration+Continuation.swift` re-enters the shared loop under the old
runId and turnId with `suppressUserAppend: true`. It rebuilds the current turn
from the durable user row and the same tool-receipt projection later turns use,
restores working notes and kept prose, and applies `TurnObservation.restarted`.
Saved dispatch receipts also rebuild delivery artifacts; generated-image paths
survive transcript body clipping. Mac recovery connects the existing stream
adapter and lifecycle intake under the saved identity.
An unrecorded effect is unknown, not permission to repeat it. Oversize-result
pages cannot survive the process; the observation says they are unavailable.

Terminal settlement retains a completed restart-resume checkpoint only when
it is not helper-owned and its shared completion route has a redelivery owner
(Telegram, Slack, iOS or caller-result). It atomically marks deliveryPending
before the durable terminal append, then the existing reply owner removes it
after completed delivery. Every other terminal removes its checkpoint after
the durable append. All terminals retire the live spill scope; Mac recovery
still posts chatTurnCompleted to refresh its transcript without pushed delivery.
If the answer was already saved, recovery uses it without another provider call.
Pending checkpoints with no redelivery owner retire at launch with one
turn.checkpoint_retired trace row; bridge responses and internal helper turns
leave no pending checkpoint. Scheduled helpers settle through BotRunner.
Terminal persistence awaits its own append, without draining process-wide telemetry.
An existing Desk journal stays attached to its original item; its scheduler
does not compete with checkpoint recovery. Ordinary turns acquire no Desk item.
There is no process-resume count limit or new timer.

Turns from older builds with no checkpoint keep guarded legacy reconciliation:
`turn.terminal` with `status: "abandoned"` and
`observedBy: "terminal_reconciliation"`. Their existing remote system note and
Mac outcome-unknown card say, “This reply did not finish before the app restarted.”
The hook reuses settled-boundary sweeps, throttled to once every five minutes;
those legacy scans do not bound checkpoint discovery or the running turn.

### 10. Bridge deadlines

Bridge deadlines: connection 30s; enqueue acknowledgement 30s; message wait
600s; direct tool call 300s (bridge `/tool` endpoint only); reads 60s.
`Agents/ClaudeBridgeMessageRuntime.swift` releases the message wait with
HTTP 202 `still_working` without cancelling the turn. Recover its receipt
using the original request ID (and session ID for `/agent/reply`); do not
resend merely because the response is pending.

### 11. MCP implementation pinning

`MCPDispatcher/MCPNPMIdentity.swift` leaves all recognized npm exec/npx
launches unpinned, including exact versions: version labels do not authenticate
executable bytes and dependencies. `ChatToolRuntime/SwiftToolDispatcher+MCP.swift`
refuses unresolved implementations, including under Full Mac. When pinning is
refused, configure a directly resolved executable/script and explicitly grant
consent again.

### 12. Mobile action uncertainty

The repository's `iOS/NativeAgentMobile/Sources/iCloudSyncEngine+Actions.swift`
retains signed CloudKit action envelopes before submission. Retries of an
unresolved action reuse the original signed message and transaction, including
after relaunch. Ambiguous delivery remains `outcome_unknown`. While an identical
action is unresolved, a deliberately separate action requires
`intentionalNewRequest: true`; ambiguous pending matches require the original
message identity.

## Reading a stopped turn

`TurnTrace/TurnTrace.swift` writes `turn_traces/<yyyy-MM-dd>.jsonl` under
the data root. Group events by `turnId`, then read `kind`, `ts`, `surface`
and the terminal payload together:

| Evidence | What to inspect |
|---|---|
| `provider.retry` | Attempt, delay, recovery mode and reason. |
| `context.intraTurnCompaction` | Trigger, mode and before/after size. |
| `turn.cancelled` | The `where` field and any interrupted action's effects. |
| `turn.failed` or `turn.terminal` | The recorded outcome and reason. |
| Terminal from `terminal_reconciliation` | A previous process left the turn unfinished. |
| No terminal | Check process continuity and the last recorded boundary; a missing row alone does not identify the cause. |
