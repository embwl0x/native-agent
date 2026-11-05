# Turn resilience map

How a turn keeps working, stops, and leaves evidence. One brain, many doors:
`EngineRuntime/EngineTurns.swift` holds Mac turn state through
`MacChatTurnRuntime`; `ChatTurnRuntime` owns the shared turn engine.
Source paths below are relative to `Modules/NativeAgentCore/Sources/`.

The agent's one always-on tool is `app`. `app {}` returns home, where they left
off; `page`, `item`, `find`, `action` and `script` reach its contents.
`AppToolRuntime/AppActions+Declarations.swift` defines the actions and
`AppScriptRunner.swift` binds scripts to the shared executor. The model-facing tool
contract is in [Tool loading](TOOL_LOADING.md).

## The rule each piece follows

- Recover a failed provider call within the existing conversation, keeping
  completed tool results.
- Preserve visible partial prose when a stream fails or the person presses Stop.
- Follow [Stop](STOP.md): cancel the effect, then join its one `settle` to save
  produced output, write its terminal and release its registrations. The outer
  rescue catch, nested terminal writers and partial-writer dedup scan are gone.
  Save errors are reported; terminal and registration settlement still run.
- Treat a timeout or interrupted action as uncertain effects; inspect the
  receipt and current state before repeating it.
- Keep cancellation distinct from failure. Recovery does not grant permission
  to replay a whole turn.

## The pieces

### 1. One clean exit

The turn part's `reply.end` ends conversational work, including incomplete
provider-failure outcomes. Stop interrupts; Mac takeover returns a refusal.
An approval or question reaches their part with its card; their reply can end
waiting while the card gates the effect and its answer resumes the request.
The card is the effect's one execution claim:
while it is undecided, the same call (tool and arguments) proposed again runs
nothing and gets the card's waiting receipt; after the decision, one
re-proposal gets the card's receipt, and an identical call after that is a
fresh invocation through the gate. Ordinary conversation has no universal clock or iteration limit.
Each dispatch batch lazily reads claimed cards once, retaining the records or the read failure.
Callers may bound helper work with output budgets and active-work deadlines; a spent output budget returns `provider_failure`, naming the cap and its control, and ends the turn incomplete.
Mac takeover reaches their next model round as the recorded tool refusal. The
loop never parks for handback: they decides whether to wait, answer or stop.
Under Full Mac their next action can reacquire control; otherwise the person's
composer handoff grants control. Shotgun Resume grants control and sends
“Mac control has returned; continue from the recorded results” through the
ordinary session Send path, including after the refused turn has ended.
Stop still cancels the driving turn and releases held input.

### 2. Progress

Tool results reach their unchanged by repetition coaching.
Whether to continue from the results is theirs.

### 3. Tool dispatch deadline

Mac acts and screen reads additionally carry one absolute `TaskWaitDeadline`
from their entry, before the serial act queue. Native dispatch and watch hands
also establish it when called directly. Nested dispatches,
post-act looks and `Task {}` inherit it without renewing it. The existing Mac
action budgets select it (30 seconds for act; an explicit `timeout` is clamped
to 1–120 seconds). `ScopedWaiter.park` expires only its own parker;
`ContinuationOnce.wait(cancellingWith:onCancel:)` uses the owner's typed cancellation result.
Shotgun's fade parks directly, and ScreenCaptureKit callbacks use that same
deadline-aware wait. A callback that never comes cannot hold the tool result.
The bounded response requests cancellation without joining an unresponsive producer;
it says timed out, earlier effects may have landed, and completion is unverified.
The response signal and retained body result are separate. A missing result is
`outcome_unknown`, never cancellation acknowledgement, with no terminal timestamp
until actual exit. The original body settles once through detached `settle`,
which does not inherit the work deadline. It publishes the real terminal evidence
and retains produced output, including when lifecycle settlement itself fails.
The registry keeps its newest 32 settled results in process for matching-operation
retrieval; older/restarted lifecycle-only receipts say `result_available:false`.
No result retrieval re-executes the action; a body that never returns remains
owned and uncertain while the reporting caller stays bounded. The payload-free
lifecycle and startup recovery remain the durable evidence owner.

`ChatTurnRuntime/ChatOrchestration+ToolDispatch.swift` applies
`ToolDispatchDeadline` from `ToolLoopSupport.swift`. Folded `app` actions
use the underlying tool's name and arguments to select their deadline.
Defaults are 900 seconds for interactive work and 3,900 for unattended work;
an integer `timeout_seconds` is clamped to 30–3,600 seconds plus a 30-second
cleanup margin. Tool-specific defaults can differ. The deadline bounds time without
progress: a part that carries itself (`{again: input}`) renews it with every run.
The chain is stored only on `ChatToolInvocation`; `ChatTurnWork.deadlines`
and `AppActionExecution.deadlines` read and refine it, and the app execution's
invocation is a view of its held work. Receiving a nested invocation therefore
replaces the chain seen by every wait and progress callback in that operation;
the work's invocation projection never overwrites it from a second copy.
The projection also leaves `waitDeadline` unchanged: that independently supplied
absolute wait budget is never synthesized from a pausable, renewable ceiling.
The live `TurnDeadline` owns enclosing expiry and cancellation; Mac and fetch
owners retain their own operation and transport limits.
Ability management receives the caller's whole `Parts.Invocation`, including
its ceilings, progress callback and preview state, through both action and
preflight paths. Missing ceilings mean no enclosing bound, never a new timeout
or a verdict about completion. Human waits pause active-work ceilings until
the person answers or the wait ends; Stop and enclosing wall-clock limits
still apply. Missing answers cannot count as approval or completion.
Expansion's speculative delivery instead uses a wall-clock ceiling: progress
and a person's wait cannot renew or pause the bound on the original result.

`NATIVE_AGENT_TOOL_DISPATCH_TIMEOUT_SECONDS` overrides this policy;
nonpositive or nonfinite values disable the dispatch backstop. Expiry returns
model-visible error feedback stating that effects may already have occurred.
The deadline helper delegates to `NativeAgentCore/TurnDeadline.swift`, whose
resume-once race bounds the wait without cancelling or joining the original
tool at expiry. The feedback is `status:timeout`, `effects:unknown`,
`reason:tool_dispatch_wait_expired`, with the invocation and call IDs. The
original body retains its checkpoint and records its actual receipt through
`settle`; `tool.dispatch.settled` carries that receipt with the same IDs after
actual exit, including a late return or journal-settlement failure. If it never
returns, no settled trace is invented and the checkpoint remains unresolved.
The response-only ceiling does not constrain downstream work through
`secondsLeft`. Stop requests cancellation while the original body still owns
its settlement, as required by [Stop's dispatch lifetime law](STOP.md).
Its resolved state carries the value directly, including cancellation before
the waiter arrives; nested human waits keep tokens rather than an integer
counter. The helper refuses nonfinite, negative or unrepresentable seconds
before constructing a duration.
Cancellation of that work is not proof that its effects stopped or rolled back.

Tool execution uses exactly the admitted transport grammar: native routes use
structured call events; the text-marker route uses its offered markers;
text-only routes execute no calls. JSON call objects in reply text (including
the retired `function_call` form) and malformed-marker salvage are not
executable. Duplicate invoke parameter names and any non-whitespace content
outside its parameter elements refuse the round before building arguments.
The existing malformed-call observation supplies the model's correction path.
Marker catalog layout requires coherent system segments. Missing provider
identity/capability fails checked admission instead of selecting a grammar.
Resident and helper model calls use the same offered-descriptor refusal before
the canonical dispatch/policy chain; internal app re-entry keeps its own gate.

The resident loop refuses a part's out-of-round call index before dispatch.
A restored negative commentary length contributes no commentary, and a helper
round with missing tool results is refused before formatting its feedback.

### 4. Provider timeouts

`ProviderRouting/ProviderStreamGuard.swift` defaults to a 90-second idle
timeout and 600-second wall timeout. Environment settings
`NATIVE_AGENT_PROVIDER_STREAM_IDLE_TIMEOUT_SEC` and
`NATIVE_AGENT_PROVIDER_STREAM_WALL_TIMEOUT_SEC` override them; values are
required to be finite in 0–86,400 seconds, with zero disabling that timeout.
Only an absent override uses the default. An empty, malformed, negative,
nonfinite or out-of-range override refuses execution before transport; only
the `_SEC` names are supported. Background
calls use the same settings. Idle time is wire activity (headers, SSE
comments, events); a cut is the typed `ProviderFailure.noReply`, and every
stream failure's `Diagnostic` records whether the provider admitted the request.
An HTTP request awaiting its response head uses the same idle, wall and
learned first-output bounds as the answer. There is no separate fixed
response-head timer: a provider can withhold headers during prefill or thought,
so cutting that wire early can repeatedly restart real work. Before any wire
activity, the learned first-output deadline applies: the slowest retained adapter `ttftMs` on that model and
stream kind (`ProviderVitalsSensor`, from trace `llm.call` rows at launch and
live calls). Under 100 calls it is unmeasured. Whole-reply callers collect
the same incremental stream and retain its first-output measurement.
A live wire is bounded by idle and wall; between attempts only the wall and
the shared offline deadline run. One process-wide `NetworkSense` replaces
private provider, iCloud and Dot path monitors. Online, dial admission reads
its Bool. Offline, a dial waits at most 30 seconds for the path to return,
then fails typed `ProviderFailure.offline`. Offline describes the connection,
not whether anything ran: its diagnostic retains the current dial's send,
response-admission and event evidence; the turn owns work progress. Without
that work evidence the report says outcome unknown.
The guard also observes path loss during an in-flight stream, so an already
running wake ends typed after 30 seconds offline instead of waiting for its
wall to be cancelled. The delegation tick budget derives from this guard's
configured wall plus 60 seconds (normally 660 seconds).
The cut text says the seconds waited, what arrived, and that evidence.
The request's progress writer wakes deadline evaluation, registered before the
state read; no interval samples it. Termination closes activity admission and
cancels the request's forwarding and deadline tasks. The owner retains their
handles through actual exit without joining a noncooperative producer.
Wall-off streams retain transport-driven completion while online; the deadline
worker parks on events with no timer until a network loss needs its offline bound.
Error-body diagnostics use their byte writer's wake with the same idle threshold
and absolute cap, return partial bytes on read timeout, and preserve user cancellation.

Anthropic-compatible message streams, including tool-free API and Kimi Code
calls, use SSE. Codex stdout supplies real progress; synthetic keep-alives
prove neither provider progress nor first output. Both Codex runners use one
strict incremental UTF-8 decoder per pipe. Split scalars wait for their remaining
bytes; invalid or unfinished scalars fail after process settlement, retaining
valid prefixes and exact undecodable suffix bytes on the encoding error. Raw
bytes are not written to diagnostics. Exit zero cannot make invalid encoding
a successful reply.
Anthropic's event consumer owns frame validation, timing, text/thinking liveness,
usage and terminal receipts for both native-tool and OAuth text-marker streams;
native signed-thinking replay and tool commitment remain payload handling.
A call's input as it streams is movement the person sees, never a cut or a
deadline; [the anatomy](ANATOMY_OF_A_TURN.md#5-the-model-answers-or-requests-a-tool)
owns how it reaches the working card.

`ProviderRouting/LLMClient+Real.swift` wraps streams with the configured
per-call guard. Its whole-reply completion uses that same guarded operation
and checked collector, with or without a turn token budget. There is no
independent buffered HTTP completion or completion-wall timer. A guard cut
is input to recovery, never a whole-turn deadline. Before any answer arrives,
sent HTTP calls can redial for lost wires, overload or retryable rate limits,
up to ten total attempts within the call's wall. Separately, their turn part asks
again once only when `retry_now` permits it, the wire has not redialed, nothing
ran or was sent, and no repair is owed. Otherwise it says the failure.

Malformed nonempty JSON data fails Responses, Chat Completions and Anthropic
SSE decoding even before first output. Empty SSE data and protocol control
frames remain explicit; the shared framer consumes comments as keep-alives.
A malformed frame is not a network outage and does not admit a redial.

Quota and billing exhaustion retain `quotaExceeded(retryAfter:)`. An omitted
Retry-After is an unknown reset time, never an invented hour or a short-rate-limit
redial. Recovery directs the caller to account allowance and billing evidence.

`NATIVE_AGENT_OPENAI_LOOPBACK_ENDPOINT`, when present, must be an absolute
HTTP(S) loopback URL without credentials or a fragment. Invalid configuration
refuses both OpenAI request shapes before credentials are read or transport opens.

All cutoff diagnostics share `RunawayOutputDetector.writeDiagnostic`. Preview
returns no file before directory creation, writing or pruning. Outside preview,
the request's trace-root override wins; otherwise the adapter's telemetry root
owns its output. Reason and content pass through `ContextSecretContentPolicy`
before persistence. Existing retained files are not rewritten by this change.

### 5. In-loop provider recovery

`ChatTurnRuntime/ChatOrchestration+StreamingToolLoop.swift` owns the loop,
including native-tool and text-marker protocols. One `TurnObservation` owns
the model's next-round feedback for a limit, stream cut, correctness boundary,
malformed call, empty reply, refusal or full context.
No vocabulary of sentences decides that a reply is unfinished. It preserves kept prose and appends a user text block alongside the
round's tool results, or a standalone user message when there were no results.
`turn.observation` records the same feedback on both protocols.

The learned first-output deadline bounds only a wire with nothing on it; a
live wire is bounded by idle silence and the wall. A recoverable cut after they
said something or called a tool is the round's `interrupted` boundary: complete
calls run, their words stay, and they continues after them. A cut where nothing
ran or nothing was sent, with no repair owed, reaches their turn part as
`provider_failure`; only `retry_now` with no wire redial permits one more
model call. Otherwise the failure becomes their words to the person.

Streaming adapters report max-token limits as `toolBoundary(.outputLimit)`.
Whole-reply collection returns a complete reply or rethrows the original error
unchanged. Partial text travels beside the error through the caller's
`LLMCallContext.partialReply` sink and the shared trace recorder, never through
an Error wrapper. Cancellation stays `CancellationError`; provider diagnostics
keep their type and remedy. Incomplete text is never admitted as successful input.
The `llm.reply.partial` receipt retains credential-redacted output under the
trace owner's payload bounds and the selected data root, including after Stop;
explicit preview generation emits no receipt.
An output-limit partial withholds that reply's calls and carries
`outputLengthLimit(partial:)`; repair and classification still read that original error. The loop retains yielded
prose, or that prefix if nothing was yielded,
discards that reply's calls and continues. Retained answer text stays outside
the pre-tool commentary prefix, so every surface delivers it as answer text.
Repeated blocks/actions, invented results and prose after a call are
correctness boundaries: complete
calls before the cut run and their results carry the observation. The third
identical read in one reply is a boundary even when other reads intervene.

Authentication, missing configuration/routing and unavailable-model errors
still name the needed repair; a thrown turn ends failed rather than persisting
a wait with no waiter. Standalone `complete()` overload retries retain their
own ten-attempt bound and deadlines.

### 6. Surface ownership

Telegram invokes the shared chat engine once. Provider recovery lives inside
the same turn; no surface automatically re-runs its completed tools.
The person's explicit `/retry` and Telegram delivery retries retain their
existing meaning. Streaming surfaces keep editing the same reply after cuts.

### 7. Cancellation trace

`ChatTurnRuntime/ChatTurnSettlement.swift` records
`turn.cancelled` with a `where` field and persists the visible partial.
`EngineRuntime/EngineTurns.swift` delegates Mac Stop to `MacChatTurnRuntime`.
Stop (the run's cancel flag) is the one cancel link: it cancels the turn's
work at once, wherever it waits. The Mac registers the run at admission,
before any await, so a Stop always names the live run. A door that stops listening only detaches;
the accepted turn runs on and lands in its transcript.

Dispatch interruption follows the [tool receipt contract](TOOL_LOADING.md).
A late tool result cannot replace the dispatch race's first terminal outcome.

### 8. Conversation tail and result pointers

The [conversation context contract](conversation-context-history.md) owns the
verbatim tail, model-default window, stateless whole-turn half-budget jumps and oldest
result-body pointers. The transcript is never replaced with generated text.
Before every resident or helper round, `context.request.fit` records measured
input, output allowance and the model window. A request that remains too large
is refused as `context_window_exceeded`; a provider's later overflow refusal
reports its cause without an alternate summary pass.

### 9. Process continuation

`TurnTrace/AbandonedTurnReconciler.swift` owns the small durably committed checkpoint at
`chat/session_state/<session>/turn-<turnId>.json` (a worker, which has no
conversation, owns `chat/session_state/worker-<runId>/` and removes it when it
ends). Writes flush the encoded bytes and parent directory through PersistenceCore's
durable atomic writer before returning. Acceptance writes it before
any context is built; the shared loop saves its part log at effect boundaries,
including their final words for a resume to settle with. `runningStep` is a
1-or-nil sentinel for in-flight calls, never a step index or iteration count;
durable receipts update that presence and the turn's steering peers together.
Receipts retain their results' labelled sources (provenance); a checkpoint
keeps steering peers and the person's answer so a resume uses the same card.
It keeps identity, input, envelope, reply route, kept prose and replay evidence, never the
provider message array. Input attachment bytes stay in `chat/attachments/`;
their existing transcript metadata supplies the saved paths.

The reconciliation hook discovers checkpoints independently of the legacy
trace date window and excludes the in-flight registry and claimed resumes.
Its cursor and trace-directory inventory are checked. Only a confirmed missing
cursor bootstraps from the trace inventory; failed reads do not choose another
scan scope. A failed cursor save stays a failed recovery pass with its window
pending.
An unreadable checkpoint does not prevent discovery of readable siblings.
Resume admission also requires the checkpoint's necessary terminal evidence
to have clean trace coverage; an unreadable required day or checkpoint owes
repair rather than admitting that resume.
`EngineRuntime/EngineTurnContinuation.swift` restores the original admission,
surface capabilities, peer provenance, helper ownership and delivery route.
File-write verification rejects negative saved byte counts and checks read
arithmetic before dispatch; malformed saved sizes cannot abort recovery.
It hashes authorized file-read windows incrementally under one file version,
including raw binary bytes where supported. The read owner's window cap is
not a file-size cap. Incomplete, changed or refused observations are named
separately from a witnessed byte-count or digest mismatch.
`ChatOrchestration+Continuation.swift` re-enters the shared loop under the old
runId and turnId with `suppressUserAppend: true`. It rebuilds the current turn
from the durable user row and the same tool-receipt projection later turns use,
restores kept prose, and applies `TurnObservation.restarted`.
Saved dispatch receipts also rebuild delivery artifacts; generated-image paths
survive transcript body clipping. Mac recovery connects the existing stream
adapter and lifecycle intake under the saved identity. Once that turn settles,
its reservation is released and the next arrival in line is admitted.
An unrecorded effect is unknown, not permission to repeat it; the restart
observation names each call their part's log shows started without a receipt
(tool and redacted arguments), and an attached Desk journal admits the same
call proposed again (tool and argument digest) as that unresolved step, so its
receipt settles it instead of a fresh step beside it. Oversize-result
pages cannot survive the process; the observation says they are unavailable.

Terminal settlement retains a checkpoint when status is completed or waiting
and `hasRedeliveryOwner` holds: no stopped reason or helper owner, and a
Telegram, Slack or iOS reply route. It durably marks `deliveryPending` before
the terminal append; the reply owner removes it after delivery settlement.
Other terminals remove their checkpoint after the durable append. All retire the live spill scope; Mac recovery
still posts chatTurnCompleted to refresh its transcript without pushed delivery.
If the answer was already saved, recovery uses it without another provider call.
Reply owners and the continuation sweep start independently of senses
registration. A resumed turn that reads a sense waits at that read's owner,
with the [bounded readiness and repair law](SENSES.md); an unavailable sense
does not prevent saved answers on other routes from being delivered.
Pending checkpoints with no redelivery owner retire at launch with one
turn.checkpoint_retired trace row; bridge responses and internal helper turns
leave no pending checkpoint. Scheduled helpers settle through BotRunner.
Terminal persistence awaits its own append, without draining process-wide telemetry.
After a requested resume returns, `turn.reconcile` flushes only that turn's
prior write failures and outstanding accepted trace entries captured at the
flush marker. Later traffic
cannot extend the marker. The wait is cancellable and has a five-second deadline;
timeout, or a prior or captured queue refusal/append failure, leaves
recovery unconfirmed and owed. A flush is ordering evidence, never a claim that lossy telemetry is
complete: checkpoint retirement and clean persisted completed/waiting terminal
confirmation still decide success. The old global-idle drain is removed from
this repair path; the deadline does not limit the resumed work itself.

Automatic session retention reads the conversation anchor through a checked
boundary before planning any archive. Only a missing anchor means no anchor;
unreadable bytes/JSON or an invalid session id hold retention with the source
fault surfaced by its existing failure logger. A checked session row may still
establish that an old pin is not the person's direct conversation. Failed
publication cannot replace damaged anchor bytes. Display-only anchor reads log
unavailability and omit the pin; that omission never decides retention.

Turn cards render an invalid or unrepresentable elapsed interval as
“Duration unavailable”; a finite saved date alone does not establish a
representable duration.

The composer's context receipt requires complete trace-read coverage for
today and yesterday before identifying the latest accepted turn or claiming
there is none. A truncated window, malformed rows or an unfinished final row
produces an unavailable receipt with that coverage gap, never an older receipt
presented as the latest turn.

Live terminal deduplication matches decoded rows by turn and status; unrelated
malformed or torn rows do not prevent the known terminal from landing. The
canonical JSONL writer closes a torn tail before appending the new row. Recovery
still requires clean trace coverage before concluding that a turn is settled.
An existing Desk journal stays attached to its original item; its scheduler
does not compete with checkpoint recovery. Ordinary turns acquire no Desk item.
There is no process-resume count limit or new timer.

Resuming a current checkpoint requires the tool receipt's recorded `ranCall`
identity. Saved names, arguments and image metadata do not invent that binding.
Tool receipt/input encoders and working-note renderers report invalid values;
they do not replace an unencodable result with null, an empty string or zero
bytes. The offered provider catalog admits every model call before execution;
an unoffered name cannot execute through a retired-name exception.

For an accepted turn with no checkpoint or confirmed terminal, guarded legacy
reconciliation records an experience-backed recovery obligation with the stable
identity `turn-recovery:<turnId>`. Restore its checkpoint from retained evidence
before resuming; do not repeat uncertain effects. The current writer does not
emit an abandoned terminal or append a remote restart note.

Retained historical evidence can include `turn.terminal` with
`status: "abandoned"` and `observedBy: "terminal_reconciliation"`, plus the old
remote system note or Mac outcome-unknown card saying, “This reply did not finish
before the app restarted.” Reader compatibility with those rows does not make
them a current reconciliation output.

Launch and eligible settled-boundary sweeps use the same reconciliation hook.
Its five-minute gate applies before the shared sweep, including checkpoint
discovery. The legacy trace date window does not bound checkpoint discovery,
and this sweep cadence imposes no clock limit on a running turn.

### 10. Bridge deadlines

Bridge deadlines: connection 30s; enqueue acknowledgement 30s; message wait
600s; direct tool call 300s (bridge `/tool` endpoint only); reads 60s.
Direct tool ingress passes the 300-second active-work chain to its
operation-aware dispatcher, so nested human waits and part progress act on
that same ceiling rather than an empty chain.
`Agents/ClaudeBridgeMessageRuntime.swift` releases either enqueue or message wait
with HTTP 202 `still_working`, retaining `task_id` without cancelling admission
or execution. A late durable enqueue continues under that same task/run identity.
`AgentContactTasks` owns its worker, produced output and terminal receipt. Recover its receipt
using the original request ID (and session ID for `/agent/reply`); do not
resend merely because the response is pending.

### 11. Mobile action uncertainty

The repository's `iOS/NativeAgentMobile/Sources/iCloudSyncEngine+Transactions.swift`
retains signed CloudKit action envelopes before submission. Retries of an
unresolved action reuse the original signed message and transaction, including
after relaunch. Ambiguous delivery remains `outcome_unknown`. While an identical
action is unresolved, a deliberately separate action requires
`intentionalNewRequest: true`; ambiguous pending matches require the original
message identity.

## Reading a stopped turn

`TurnTrace/TurnTracePersistLane.swift` writes a turn's events as details in the
record (`experiences/experiences.sqlite`, table `detail`, subject = the turn id).
Read a turn's details by its id, then read `kind`, `ts`, `surface` and the
terminal payload together. The record forgets details after two weeks
([Storage](EXPERIENCE.md#storage)); there is no separate trace retention.

Trace token and duration measurements accept nonnegative integers and use
checked accumulation. Invalid or unrepresentable totals report damaged evidence;
Inspector leaves the total unavailable and shows the measurement error in the
turn's first row. Inspector call titles and grouping use the same checked
`inputTokens`/`outputTokens` reader; each absent count is shown as `unavailable`,
never zero. A damaged count also marks its call row failed with its measurement
error. Statistics fail explicitly rather than returning wrapped totals.

Usage totals read the same evidence as model-call statistics: the record's
`llm.call` details, turn-bound and standalone, as recorded. The reader neither
infers duplicate identities from timestamps nor merges fields between details.
Unreadable details or a read that reached its bound return `incomplete` with the
recorded totals.
Model-call statistics derive heavy-turn titles and dispatch descriptions from
that first week's snapshot, including `work.identified`, without rereading days.

Recovery's trace flush captures this turn's outstanding accepted queue entries
and any earlier write failure retained by that bus. Queue rejection and failed
appends keep the turn's first failure for the bus's lifetime, even after the
ticket finishes or a flush reports it; later successful writes cannot replace
lost evidence. The five-second deadline and cancellation end only the wait.
Later traffic cannot extend the captured boundary, and a successful flush still
requires checkpoint and terminal confirmation. Direct durable terminal writes
propagate their own errors to their caller.

| Evidence | What to inspect |
|---|---|
| `llm.call` | Call status and retained error detail. Exhausted wire recovery includes the aggregate diagnostic's tries and elapsed time; no per-attempt delay history is emitted. Missing call evidence does not prove no retry occurred. |
| `context.tail.cut` / `context.tool_result.pointer` | Whole-turn cut or retained result-body pointers, with measured before/after size. |
| `turn.cancelled` | The `where` field and any interrupted action's effects. |
| `turn.failed` or `turn.terminal` | The recorded outcome and reason. |
| Historical terminal from `terminal_reconciliation` | An older build recorded that a previous process left the turn unfinished; current reconciliation records recovery obligations. |
| No terminal | Check process continuity and the last recorded boundary; a missing row alone does not identify the cause. |
