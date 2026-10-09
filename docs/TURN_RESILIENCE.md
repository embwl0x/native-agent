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

### 1. Whole-turn budget (progress-aware)

`ChatTurnRuntime/ToolLoopSupport.swift` owns `WholeTurnWallClockBudget`.
Default windows are 600 seconds for interactive and Telegram turns, and
3,900 seconds for unattended surfaces. Successful tool results renew the
window, up to six hours from the start. Waiting on a person, calls that never
ran, and streamed prose do not renew it.

This is a checkpoint between provider attempts, not an interrupt of a running
action. Exhaustion ends through the loop's terminal path, retaining accumulated
prose and dispatch records. The shared loop checks the budget again after
compaction and before another provider attempt.

### 2. Iteration cap

`ToolLoopBudget`, in the same file, defaults to 60 iterations for ordinary
chat, 90 for mobile, 180 for Telegram and Codex/Claude bridges, and 80 for
autonomy/background, swarm and Workshop surfaces. Explicit limits are clamped
to 1–240.

`ToolLoopNoProgressGuard` warns after eight identical tool rounds and stops
after sixteen. A repeated identical failure has a separate warning at four
rounds and stop at eight, even if the arguments change.

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

`ProviderRouting/LLMClient+Real.swift` wraps streams with the guard and uses
`withCompletionWall` for buffered calls. `ProviderRecoveryPolicy.callWallSeconds`
reduces the call wall using the turn's remaining time, reserving 60 seconds
for recovery with a 60-second floor, never exceeding the configured wall.
The loop separately refuses to start an attempt after the turn budget is spent.

### 5. In-loop provider recovery (the reconnect ladder)

`ChatTurnRuntime/ChatOrchestration+StreamingToolLoop.swift` owns the loop,
including native-tool and text-marker protocols and callers that do not render
live prose. `ProviderRouting/ProviderRecoveryPolicy.swift` classifies failures;
its `ChatTurnRuntime` extension supplies turn-error replay restrictions.

Network failures and rate limits can retry in place: up to ten attempts per
call and twenty recoveries per turn. Once the provider admitted a request (a
2xx response body began), a cut where it never said no (idle or wall,
connection loss, truncation) is not re-issued before visible prose: the turn
ends (a guard cut reads "No reply from <provider> in N s (M events)") and the
person can say continue. An explicit provider error event (overloaded, rate
limit) said it did not generate and is retried as before. Backoff is 1, 2, 4, 8, 15, then 30 seconds;
a longer provider `Retry-After` wins. The loop refuses a wait that would consume
the remaining budget. Provider overload has a separate pre-output ladder in
`LLMClient+Real.swift`; exhaustion there vetoes outer retries.

When no prose was rendered, recovery reissues the request. After visible
prose, it keeps that prefix and asks the provider to continue from it.
Undispatched calls from the failed attempt are discarded in either case;
completed tool results stay in the conversation. Cancellation is checked
before and after the recovery wait.

Output-length exhaustion keeps the partial answer and ends the turn without
automatic continuation. Context overflow uses compaction below. Recovery emits
`provider.retry` trace events and `provider_retry` status notices.

### 6. Surface retry boundary

Telegram's `TelegramBot/TelegramPollLoop+ChatProgress.swift` delegates
whole-turn retry eligibility to `ProviderRecoveryPolicy.permitsWholeTurnRetry`.
`ProviderErrorAfterToolEffects` vetoes replay after completed dispatch work,
including reads; cancelled calls with unknown effects also count. Visible
partial answers veto whole-turn replay through `TurnEngineError`.

These restrictions differ from retrying a provider request inside the loop:
starting the turn over could repeat actions and reset its recovery allowance.

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
after a context-overflow refusal. Reactive recovery is limited to two passes
per call and shares the twenty-recovery turn budget; for visible streaming,
it requires that the failed attempt emitted neither prose nor calls.
Trace `context.intraTurnCompaction` records the mode, trigger and size change;
the status notice is `context_compaction`.

Persisted history has a separate owner:
`ChatSessionWork/ChatSessionAutocompactor.swift`. It creates and verifies a
backup before replacing older rows with a recollection, retains pending cards
and recent rows, and writes durably. `ChatCompactionDistiller.swift` can improve
the mechanical recollection; a failed distillation leaves the fallback.
Compaction is bounded summarization, not lossless retention.

### 9. Abandoned-turn reconciliation

`TurnTrace/AbandonedTurnReconciler.swift` finds accepted turns with no
`turn.terminal`, `turn.cancelled` or `turn.failed` event. Only turns accepted
before the current process epoch qualify; there is no six-hour minimum age.

Before appending, it locks and rereads the target and neighboring trace-day
files. An existing terminal prevents the abandoned verdict; unreadable scan
files abort the sweep, and unreadable neighboring files prevent the append.
The result is `turn.terminal` with `status: "abandoned"` and
`observedBy: "terminal_reconciliation"`, not a claim of successful completion.

`TurnTrace/AbandonedTurnReconciliationHook.swift` runs a sweep at launch and
after completed turns, at most once every five minutes and one at a time,
after draining the trace bus. It does not replay the interrupted work.

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
