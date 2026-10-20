# Turn resilience map

> One structure (docs/NORTHSTAR.md, first law): this doc is part of one whole. A change here is molded into every doc that states the same thing, in the same commit, with what comes out named; a contradiction is a defect.

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
the model answers with no calls or pending work. Stop interrupts; a Mac
takeover waits for the person. A result waiting on an approval or a question
reaches their part like any other, with the card it waits on: they says what they
says and the turn ends waiting, the card still gating the effect and its
answer resuming the request. The card is the effect's one execution claim:
while it is undecided, the same call (tool and arguments) proposed again runs
nothing and gets the card's waiting receipt; after the decision, one
re-proposal gets the card's receipt, and an identical call after that is a
fresh invocation through the gate. There is no iteration or
whole-turn clock limit. Helper owners can still request a per-run token budget;
when it is spent their part reads a `provider_failure` receipt naming the cap and
its control, and ends the turn, incomplete, on what was written.
Mac takeover suspends the same conversation on `MacAttentionSessionStore`'s
driver-change stream. Returning control continues from the recorded results;
task cancellation or the run-tagged Stop flag releases the wait. A waiting turn
keeps the return-control action reachable under Full Mac.

### 2. Progress and the circling question

`ToolLoopNoProgressGuard` keeps its evidence and hands it to them: from eight
identical tool rounds, or four identical failures even when arguments change,
every round of the streak carries a note with the count. It never stops or
suspends the turn; whether to go on is theirs.

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
Until anything arrives on the wire (headers, comments, events), the guard
also cuts at the provider's first-output deadline: a connection that never
opened or hung before headers. A live wire is a provider thinking, bounded by
idle and wall. The deadline is the slowest adapter `ttftMs` of its retained
calls on that model and stream kind (`ProviderVitalsSensor`: read from the trace's `llm.call` rows at
launch, joined by each live call's `ttftMs`, nothing written). Under 100 calls
it is unmeasured and only the wall stands; buffered kinds record no `ttftMs`,
so idle and wall bound them.
The cut text says the seconds waited, what arrived, and that evidence.

`ProviderRouting/LLMClient+Real.swift` wraps streams with the configured
per-call guard and uses `withCompletionWall` for buffered calls. A guard cut
is input to recovery, never a whole-turn deadline: their turn part asks again
once when nothing ran and no repair is owed, and says the failure if the same
cut follows.

### 5. In-loop provider recovery

`ChatTurnRuntime/ChatOrchestration+StreamingToolLoop.swift` owns the loop,
including native-tool and text-marker protocols. One `TurnObservation` owns
the model's next-round feedback for a limit, stream cut, correctness boundary,
malformed call, empty reply, refusal, unwritten working notes, or full context.
No vocabulary of sentences decides that a reply is unfinished. It preserves kept prose and appends a user text block alongside the
round's tool results, or a standalone user message when there were no results.
`turn.observation` records the same feedback on both protocols.

The learned first-output deadline bounds only a wire with nothing on it; a
live wire is bounded by idle silence and the wall. A recoverable cut after they
said something or called a tool is the round's `interrupted` boundary: complete
calls run, their words stay, and they continues after them. A cut where nothing
ran or nothing was sent, with no repair owed, is their turn part's next input
once (the stem's `provider_failure` notice is the nudge); the same cut again
becomes their words to the person.

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
Stop (the run's cancel flag) is the one cancel link: it cancels the turn's
work at once, wherever it waits. The Mac registers the run at admission,
before any await, so a Stop always names the live run. A door that stops listening only detaches;
the accepted turn runs on and lands in its transcript.

At dispatch, a call stopped before it starts has a skipped result; an already
started call carries `effects_unknown: true`. A late tool result cannot replace
the first terminal outcome of the dispatch race. Check the action's receipt
and current state before trying it again.

### 8. Context compaction

`ChatTurnRuntime/IntraTurnContextCompaction.swift` bounds the working
conversation: it stubs older tool-result bodies and folds earlier rounds into
working notes. It can run proactively before a provider call or reactively
after a context-overflow refusal. Reactive compaction has no attempt cap.
When nothing remains to fold, the refusal is their turn part's
`provider_failure` input like any other. After a successful trim, a
`contextFull` observation asks the model to finish from what it has. Working
notes that cannot be written leave their span as it was and nothing else is
trimmed in their place; the receipt (a route that is wrong owes its repair
through `ProviderFailure`) is their input: a note in the conversation, or, when
an overflow has nothing else to trim, their part's `provider_failure`. The seeded prefix remains
protected.
Trace `context.intraTurnCompaction` records the mode, trigger and size change;
the status notice is `context_compaction`.

Persisted history has a separate owner:
`ChatSessionWork/ChatSessionAutocompactor.swift`. It creates and verifies a
backup before replacing older rows with a recollection, retains pending cards
and recent rows, and writes durably. `ChatCompactionDistiller.swift` writes the
recollection; one that fails leaves its summary pending, unrendered, with the
original turns in the backup and its repair owed. A turn
whose pre-turn compaction did not finish answers from the history that is
there, and its message carries the failure and its repair call.
Compaction is bounded summarization, not lossless retention.

### 9. Process continuation

`TurnTrace/AbandonedTurnReconciler.swift` owns the small atomic checkpoint at
`chat/session_state/<session>/turn-<turnId>.json` (a worker, which has no
conversation, owns `chat/session_state/worker-<runId>/` and removes it when it
ends). Acceptance writes it before
any context is built; the shared loop writes it again before each provider
iteration and before dispatch, its part log carrying their final words for a
resume to settle with; durable tool receipts
advance its step count and the turn's steering peers in the same checkpoint
write. Receipts retain the sources their results labelled (provenance); a
steered turn's checkpoint keeps its steering peers and the person's answer, so
a resume continues under the same one card, never a second. It keeps identity, input, envelope and reply
route, iteration, kept prose, working notes and a possibly running step, never the
provider message array. Input attachment bytes stay in `chat/attachments/`;
their existing transcript metadata supplies the saved paths.

At launch, the reconciliation hook discovers checkpoints independently of the
legacy trace window and excludes the in-flight registry and claimed resumes.
An unreadable trace day or checkpoint owes its own repair; every readable
checkpoint still resumes.
`EngineRuntime/EngineTurnContinuation.swift` restores the original admission,
surface capabilities, peer provenance, helper ownership and delivery route.
`ChatOrchestration+Continuation.swift` re-enters the shared loop under the old
runId and turnId with `suppressUserAppend: true`. It rebuilds the current turn
from the durable user row and the same tool-receipt projection later turns use,
restores working notes and kept prose, and applies `TurnObservation.restarted`.
Saved dispatch receipts also rebuild delivery artifacts; generated-image paths
survive transcript body clipping. Mac recovery connects the existing stream
adapter and lifecycle intake under the saved identity.
An unrecorded effect is unknown, not permission to repeat it; the restart
observation names each call their part's log shows started without a receipt
(tool and redacted arguments), and an attached Desk journal admits the same
call proposed again (tool and argument digest) as that unresolved step, so its
receipt settles it instead of a fresh step beside it. Oversize-result
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
