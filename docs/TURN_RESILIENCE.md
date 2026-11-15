# Turn resilience map

How a turn keeps working, stops, and leaves evidence. One brain, many doors:
`EngineRuntime/EngineTurns.swift` holds Mac turn state through
`MacChatTurnRuntime`; `ChatTurnRuntime` owns the shared turn engine.
Mac views draw shared `TurnFace` values through their session-keyed face slots,
projected off main by `TurnFaceProjection`. Lifecycle state remains operational
authority. Time since movement is descriptive; it never changes phase or
expires a streaming marker. See the [face feed](designs/separate-face.md#stage-one-turn-status).
Source paths below are relative to `Modules/NativeAgentCore/Sources/`.

The agent's one door, `app`, is always on. `app {}` returns home, where they left
off; `page`, `item`, `find`, `action` and `script` reach its contents.
`AppToolRuntime/AppActions+Declarations.swift` defines the actions and
`AppScriptRunner.swift` binds scripts to the shared executor. The model-facing tool
contract is in [One door](ONE_DOOR.md).

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
- Withhold unavailable recall and name its cause in the turn's context; follow
  the [recall-unavailability law](ANATOMY_OF_A_TURN.md#recall-unavailability)
  without retrying or extending its wait.

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
fresh invocation through the gate. The card's settlement is written to the trace under the receipt id of the
call that raised it, so `trace.recent` with that receipt id, or with the card's own id, reads what was answered, by whom (the door, or the agent) and when. Ordinary conversation has no universal clock or iteration limit.
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

**No agent is ever stuck, and no call is ended by a number while it is alive.
A call is ended when the thing it waits on is seen to be dead or not
answering, exactly as Stop ends it, and the agent reads what was found dead.**
The turn goes on: the agent reads the receipt and decides what to do.
`PersistenceCore/CallBound.swift` holds the law.

Each call has a watch (`TurnDeadline` on its active-work clock), and the
watches of one outermost call and every call running inside it form one tree.
Life anywhere in the tree renews every watch in it: a call in it completing, a
part that carries itself (`{again: input}`), any event (a keep-alive included)
from a turn running under it, and each sign of life an owner reports. A
person's wait anywhere in the tree pauses it; waiting on the person is never
silence. A call running inside another holds the other's watch until it
returns or is ended, so only the innermost running call listens. Because the
tree is reached from any watch in it, work that holds an older copy of the
chain (an ability body admitted after its execution was made) still renews and
pauses the call it runs in.

What a call waits on is a `CallLife`: its owner attaches it to the call's
watch (`TurnDeadline.watching` or `attach`/`detach`), reports life with
`moved()`, and answers "is it alive?". When the innermost call has been quiet
for `quietSeconds` (60), each attached owner is asked, with `pingSeconds` (10)
to answer, and the turn's status starts saying what the call is waiting on.
Any answer of life keeps the call waiting, however long. A death or
a failure to answer, with no life, ends the call. A wait on the person keeps
it waiting and shows the turn the owner's words. When nothing attached can
answer, the call is not ended: the turn shows, as a `call.stalled` notice,
which call has been waiting and for how long with nothing able to say whether
it lives, so the person can press Stop; the question is asked again after
each quiet window. Owners that report life today:

- a child process (`OwnedProcessGroup.callLife`, attached by `ManagedProcess`
  when its `life` is set: builder commands through `runShellLikeProcess`, a
  part's `program.receive`, Codex image generation, the screenshot save, and
  `ProcessExecution.run` given the call's `life`, as Dot's helper is): alive
  while any member of its group runs,
  however quiet (`sleep 600`, a slow download); its output, read by the
  capture owner, is life as it comes; dead only when the whole group has
  exited;
- an app under automation (`AppleScriptExecution.appLife`, attached for the
  call's Apple Event or script): alive while it answers an accessibility ping,
  gone when it has quit, not answering when the ping cannot complete;
- the apps a Mac operation's Accessibility messages go to (`MacAXTargets`,
  attached in `MacControl`'s dispatch and kept until the call's watch ends, so
  a wait's observers after the dispatch returns have it too; each app is noted
  as a message to it is prepared): alive while any of those processes runs,
  however hung, so a hung app is shown as waiting and Stop ends it; dead only
  when every one has quit; with none noted yet, it cannot say;
- the holder of a file lock (`CredentialFileLock.holderLife`, attached by
  `CredentialFileLock.withLock` and `SwiftNativePersistenceCore.withFileLock`
  given the waiting call's `life`): every holder names its process in the
  lock's sidecar; alive while that other process runs; held in this process or
  unnamed, it cannot say. The async wait blocks in `flock` on a thread of its
  own, so Stop releases the caller at once and a lock it gets after the caller
  left is released;
- Chrome's extension, for every Chrome request (`ChromeControlChannel.life`):
  alive while the connection to it is open, however slow, so a hung extension
  is shown as waiting and Stop ends it; dead once the connection has closed;
- the person's keyboard hold before a key is posted (`MacInputEvents`): a wait
  on the person, shown as such;
- another agent's ACP program (`AgentACPClient.turn`, attached for the turn
  from the program's process group): alive while it runs, however quiet; each
  line it writes is life; dead once it has exited;
- a desktop contact's app under observation (`DesktopRouteObservation`): its
  `appLife` is attached while the observation lasts, and each accessibility
  event from the app is life;
- an ACP permission or connect card (`AgentACPApproval`): a wait on the person,
  shown as such;
- the agent's turn answering a helper's `agent_message`: each word and step it
  reports is life of the helper's call;
- Location Services, for a location read waiting on a fix
  (`MacLocationReader`): switched off or refused is dead, allowed is alive
  (CoreLocation answers every request with a fix or an error);
- a turn running under a call (helper runs and `bot_ask`, a part's
  `model.call` and thoughts, a desktop contact's operator turn), which carries
  the call's watch as `Turn.enclosingCall`: every provider event and every
  byte its request receives is life, and each call it makes joins the tree.
  Its open provider request answers as a request does (below), so a silent
  one is shown as still running, never ended;
- a request (`CallLife.request`; `URLSession.data(for:life:)` attaches it,
  as the image API does, and the provider transfer attaches it for a turn
  under a call): alive while its task runs, however quiet, as a running
  process is; dead once the task has completed or is being cancelled; bytes
  sent or received are life;
- a helper's run (`BotRunner.perform`): every run, scheduled or asked for, has
  its own watch, inside the asking call's when there is one, and its turn
  carries that watch. A call waiting for a busy helper
  (`BotRunQueue.claimWhenAvailable`) asks the run the helper is already doing:
  alive while that run has shown life within a quiet window or anything it
  waits on answers alive, the person's words when it waits on the person, and
  never dead (the run's own watch ends it).

A call that itself declares a time (`timeout_seconds`, or `timeout` on Mac
acts and watch frames, clamped to 30-3,600 seconds; `wait_seconds` on reply
observations) ends at that time plus a 30-second settlement allowance, on a
wall clock: the caller's own word, not the app's number. A tool's own default
inside its code (a shell's 120 seconds, a build's 600) is that tool's, and it
ends its own work; the call does not.

Four boundaries give each call its watch, and every call a turn makes crosses
one: `runSingleDispatch` for each call of a turn on the shared tool loop; a
helper's turn's own dispatch (`runStandingBot`), which does not use that loop;
the app door's re-entry (`CanonicalToolNameDispatcher`'s
`AppDoorReentry.perform`) for every nested call, which is how batch steps,
script and part actions, reads and finds, folded calls, part thoughts' calls
and every admitted primitive run; and `ToolHost.primitive` for the watch-frame
and `program.receive`/`program.close` primitives that reach their broker
without crossing the door.
The chain is stored only on `ChatToolInvocation`; `ChatTurnWork.deadlines`
and `AppActionExecution.deadlines` read and refine it, and the app execution's
invocation is a view of its held work. Receiving a nested invocation therefore
replaces the chain seen by every wait and progress callback in that operation;
the work's invocation projection never overwrites it from a second copy.
The projection also leaves `waitDeadline` unchanged: that independently supplied
absolute wait budget is never synthesized from a pausable, renewable ceiling.
Mac and fetch owners retain their own operation and transport limits.
Ability management receives the caller's whole `Parts.Invocation`, including
its ceilings, progress callback and preview state, through both action and
preflight paths. Human waits pause active-work ceilings until
the person answers or the wait ends; Stop and enclosing wall-clock limits
still apply. Missing answers cannot count as approval or completion.
Expansion's speculative delivery instead uses a wall-clock ceiling: progress
and a person's wait cannot renew or pause the bound on the original result.

An ended call takes Stop's path: its body is cancelled and the caller released
at once, even when the body ignores cancellation. A call found dead reads
`status:failed`, `reason:found_dead`, naming what was found dead; one past its
own declared time reads `status:timed_out`, `reason:ran_out_of_time`. Both
carry `execution:attempted`, `effects:unknown`, one sentence saying whether it
took effect is unknown, and a reconcile remedy; a model-facing call's receipt
also carries its invocation and call IDs and names this turn's dispatch
receipts. A nested call's receipt reaches its batch or program as that step's
failed result. The original body retains its checkpoint and records its actual
receipt through `settle`; `tool.dispatch.settled` carries that receipt with the
same IDs after actual exit. If it never returns, no settled trace is invented
and the checkpoint remains unresolved. A wait that does not answer
cancellation (a blocked `flock`, a semaphore) still holds its own body after
the caller is released.
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

### 4. Provider liveness

A provider request's stream terminal, transport completion/error, network-path
loss or explicit cancellation settles the request; elapsed
silence and historical first-output latency decide nothing. Provider vitals
retain their passive health EMAs; there is no first-output deadline interface,
sample history or startup trace replay for computing request cutoffs. `ProviderHTTP`
supplies sessions without request or resource clock limits. An unanswered
request stays waiting with Stop as its cancellation lever; `provider.waiting`
names the network path or provider response, the provider and the start time in
its trace and the turn's existing progress notices. Mac chat reduces those notices
into its working card as the turn's state, never a step; the other-door lifecycle intake consumes the same trace
descriptions for turns opened through another surface. Waiting names its start
time, reconnecting names the event and next action, and Stop remains available.
`ProviderHTTPBytes` receives headers, body chunks and task completion from one
task-specific `URLSessionDataDelegate`. Completion closes its body stream
directly; no `URLSession.AsyncBytes` iterator must rediscover that terminal.
`provider.httpRequestStarted` and `provider.httpRequestEnded` share a request id.
A system cancellation of an active request is a network failure; explicit Stop
stays cancellation.
Socket completion errors retain their original transport shape. Chat Completions
finalizes interrupted network/offline reads, preserving complete accumulated
calls in wire order and withholding incomplete argument tails. Provider verdicts
and Stop remain errors rather than permission to execute retained calls.

`NetworkSense` owns one process-wide path monitor. A new HTTP send subscribes
to its current path and waits for satisfaction or cancellation. An unobserved
path stays unknown; satisfaction proves local reachability, never provider
health. Path changes publish directly to body consumers without a quiet timer.
Each open HTTP task subscribes to those same edges; an unsatisfied path cancels
that task and closes its wait with the network cause. Subscriptions retain every
edge, including a loss followed immediately by a return.
`URLSession.waitsForConnectivity` is off: the path owner holds network waits,
while a connection that cannot be established returns its transport error
instead of becoming an unsent task held by URLSession.

Error-body diagnostics wait for EOF, read error, the declared byte cap or
cancellation. A failed read retains its partial diagnostic bytes, HTTP status
and Retry-After when observed, and original read cause; its diagnostic includes
the redacted partial body. It cannot manufacture an empty body.

The external delegation envelope and dream-preview
admission still consume `ProviderStreamGuardConfig`; those caller-owned clocks
are separate from provider transport and require removal in their owning lanes.

Anthropic-compatible message streams, including tool-free API and Kimi Code
calls, use SSE. Codex stdout supplies real progress; synthetic keep-alives
prove neither provider progress nor first output. Every Codex call uses the same
stdout producer and one strict incremental UTF-8 decoder per pipe. Split scalars
wait for their remaining bytes; invalid or unfinished scalars fail after process settlement, retaining
valid prefixes and exact undecodable suffix bytes on the encoding error. Raw
bytes are not written to diagnostics. Exit zero cannot make invalid encoding
a successful reply.
prove neither provider progress nor first output. Buffered Codex completion
collects the same stdout stream as incremental completion. A strict UTF-8 decoder
retains valid prefixes and exact undecodable suffix bytes; stdout EOF or a pipe
read failure settles the model wait without awaiting process exit or stderr.
Invalid or unfinished stdout scalars fail that wait. Raw bytes are not written
to diagnostics. The invocation retains its process and both drains until actual
exit; `codex.process.exited` records its status and capture/encoding failures
independently, including when stdout closed before exit. A late exit cannot
change the already settled reply.
Anthropic's event consumer owns frame validation, timing, text/thinking liveness,
usage and terminal receipts for both native-tool and OAuth text-marker streams;
native signed-thinking replay and tool commitment remain payload handling.
A call's input as it streams is movement the person sees, never a cut or a
deadline; [the anatomy](ANATOMY_OF_A_TURN.md#5-the-model-answers-or-requests-a-tool)
owns how it reaches the working card.

`ProviderRouting/LLMClient+Real.swift` forwards the selected adapter through its
cancellation and admission boundary. Whole-reply completion uses that same
operation and checked collector, with or without a turn token budget. Its one
reply owner releases the caller's wait at Stop while collection and forwarding
settle independently. The HTTP request observes cancellation; Codex runs to its
own exit and pipe EOF and retains its produced output, even after cancellation
has returned to a buffered or streaming caller.
The provider path performs no automatic redelivery or HTTP 401 replay.
Provider failures give the turn part the cause and remedy; they authorize no
automatic re-request. A retry chosen by the agent may be paced only by the
server's explicit `retry_after`, never by a computed backoff or an assumed
rate-limit wait.
operation and checked collector, with or without a turn token budget. Stop
leaves forwarding alive: the HTTP request observes cancellation, while Codex
runs to stdout EOF while process settlement owns its later exit. Whole-reply
settlement retains all produced output before returning cancellation.
`TurnAdmission` gives the turn one `ProviderRecovery` part; a direct turn-engine
entry creates it when no admission supplied one. The routed client's stream
boundary reads that same owner on every model round. A standalone request owns
its own allowance. Each interrupted sequence permits one reconnect, shared
across pre-output replays and partial-output continuations. A successfully
completed provider stream clears that sequence; partial rounds never renew it.
Before reply text or a complete tool call has been forwarded, the boundary
re-sends through the same adapter and admitted route. Streaming argument
fragments, liveness and presentation markers are not answers and do not prevent
reconnect; the replacement invocation starts fresh argument assembly.

After output, the turn retains prose and dispatches complete calls once; its
next request consumes the same pending recovery gate before opening a transport.
Chat Completions forwards its original interrupted-read error after yielding
the surviving calls and boundary, so finalization cannot hide a connection loss.
The owner retains the typed cause and Retry-After across the round boundary.
Headers also publish their Retry-After to that request's recovery owner, so a
mid-stream error retains a server-prescribed delay from an HTTP 200 response.
Lifecycle repair wrapping preserves both that delay and the terminal stop type.

Network failures wait for path satisfaction and any supplied Retry-After;
overloads and 5xx use Retry-After when supplied, otherwise the one reconnect has
no invented delay. A rate limit reconnects only with its explicit delay. Seconds
and HTTP-date values are not shortened by an application cap. One pending wait
owns the re-request; `provider.reconnecting` records its cause and next attempt.
Stop cancels and joins that wait. A second failure stops with its cause
and closes admission to further model requests in that turn. Retained prose and
complete calls survive that failure; a subsequent model effect receives the
terminal cause without sending. Auth, quota, malformed responses and request/
refusal errors do not admit reconnects; there is no HTTP 401 replay. Output-limit
continuations belong to their declared output budget, not connection recovery.
Direct adapter consumers receive terminal errors; the recovery owner belongs to
the routed client.

OpenAI's [streaming guide](https://developers.openai.com/api/docs/guides/streaming-responses)
specifies no heartbeat cadence. Anthropic's
[streaming contract](https://platform.claude.com/docs/en/build-with-claude/streaming#ping-events)
permits ping events without a required cadence. Neither contract supplies a
silence deadline: an open, silent stream remains waiting with Stop available.

Malformed nonempty JSON data fails Responses, Chat Completions and Anthropic
SSE decoding even before first output. Empty SSE data and protocol control
frames remain explicit; the shared framer consumes comments as keep-alives.
A malformed frame is not a network outage and does not admit a redial.
`LLMCall.allowsSilentCompletion` declares whether a clean provider terminal
without answer text or calls is a complete answer. The stem declares it for a
thought from its native opening message's `attended` object, including checkpoint
replay; other requests require output unless their caller explicitly declares
silence valid. All adapters and the stem read that same declaration. Anthropic
requires `end_turn` with every block closed, Responses requires a completed
response, Chat Completions requires `stop` and `[DONE]`, and Codex requires EOF
and successful process exit. Refusal, output limits, incomplete calls and missing
terminal evidence retain their failure or incomplete boundary. An open stream
without a terminal remains waiting with Stop available.

Without the declaration, a completed terminal with no answer text or calls,
including a clean empty CLI exit, is malformed output. It supplies no evidence
of a broken connection and does not admit a reconnect. A declared silent thought
reaches its turn program as an empty `model` event and settles through the
ordinary silence path ([turn anatomy](ANATOMY_OF_A_TURN.md#6-the-answer-settles-once)).

Quota and billing exhaustion retain `quotaExceeded(retryAfter:)`. An omitted
Retry-After is an unknown reset time, never an invented hour or a short-rate-limit
redial. Recovery directs the caller to account allowance and billing evidence.

`NATIVE_AGENT_OPENAI_LOOPBACK_ENDPOINT`, when present, must be an absolute
HTTP(S) loopback URL without credentials or a fragment. Invalid configuration
refuses both OpenAI request shapes before credentials are read or transport opens.

Provider output reaches the turn unchanged; there is no instance detector,
buffered scan or output override. Read-only app-call classification belongs to
`AppActionBinding` and uses the app executor's checked registry reader.
All cutoff diagnostics share `ProviderOutputDiagnostics.writeDiagnostic`. Preview
returns no file before directory creation, writing or pruning. Outside preview,
the request's trace-root override wins; otherwise the adapter's telemetry root
owns its output. Reason and content pass through `ContextSecretContentPolicy`
before persistence. A turnless diagnostic uses a UUID filename; retention
keeps the newest 100 text files and reports directory, metadata or deletion
failures. Existing retained files keep their names and contents.

### 5. In-loop provider recovery

`ChatTurnRuntime/ChatOrchestration+StreamingToolLoop.swift` owns the loop,
including native-tool and text-marker protocols. One `TurnObservation` owns
the model's next-round feedback for a limit, stream cut, correctness boundary,
malformed call, undeclared empty reply, refusal or full context.
No vocabulary of sentences decides that a reply is unfinished. It preserves kept prose and appends a user text block alongside the
round's tool results, or a standalone user message when there were no results.
`turn.observation` records the same feedback on both protocols.

An actual stream interruption after they
said something or called a tool is the round's `interrupted` boundary: complete
calls run, their words stay, and they continues after them. A cut where nothing
ran or nothing was sent, with no repair owed, reaches their turn part as
`provider_failure` after the pre-output reconnect described above. The shipped
turn part ends with that failure's words; that failure event requests no
further model call.

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
Provider decoders forward text deltas unchanged; repeated blocks, invented-result
headings and post-call prose do not cut the provider stream. Tool parsing and
effect admission remain with the turn and dispatcher owners.

Authentication, missing configuration/routing and unavailable-model errors
still name the needed repair; a thrown turn ends failed rather than persisting
a wait with no waiter. Standalone `complete()` overloads collect the same single
adapter invocation.

### 6. Surface ownership

Telegram invokes the shared chat engine once. Provider recovery lives inside
the same turn; no surface automatically re-runs its completed tools.
Slack journal retention reads completion-lifecycle references only when terminal
records exceed its retention cap; admission and settlement below that cap need only the journal.
An orphaned Slack generation without a saved answer settles as interrupted and
releases pending capacity. Its notice offers `/retry`, which pins the original
input and conversation to the command's own run; `/retry resend` only sends saved output.
The interrupted run keeps its identity, and a late saved answer can still be delivered.
Every advertised Slack file reaches attachment preparation, including files with
missing MIME/download metadata; any preparation failure is shown before chat admission.
Telegram speech-permission denial retains both ordinary intake and `/retry` as
`awaiting_speech_permission` and asks the Mac for authorization. A retry's resolved
input and session are durable before preparation, so approval recovery uses that same request.
Telegram's stopped turn retains and joins its settlement task without a timeout.
Stop-button polling requests that task without awaiting its result; slash commands
await confirmation in their command task after releasing polling admission.
The person's explicit `/retry` retains its meaning. A Telegram API rejection
returns to the caller without an automatic retry; a server's `retry_after`
paces later admitted sends. Streaming surfaces keep editing the same reply after cuts.
Telegram and Slack previews coalesce while the admitted send is in flight;
producer progress and send completion drive publication, without a spacing clock.
Reply producers own secret masking. Slack retains and sends their canonical reply
and fingerprint without another output check at the wire.
Slack's saved connected flag also requires its running socket owner; age alone
does not establish disconnection. Telegram progress retains its owner's phase;
elapsed time is presentation data and cannot replace that phase.

### 7. Cancellation trace

`ChatTurnRuntime/ChatTurnSettlement.swift` records
`turn.cancelled` with a `where` field and persists the visible partial.
`EngineRuntime/EngineTurns.swift` delegates Mac Stop to `MacChatTurnRuntime`.
Stop (the run's cancel flag) is the one cancel link: it cancels the turn's
work at once, wherever it waits. The Mac registers the run at admission,
before any await, so a Stop always names the live run. A door that stops listening only detaches;
the accepted turn runs on and lands in its transcript.

Dispatch interruption follows the [door receipt contract](ONE_DOOR.md).
A late tool result cannot replace the dispatch race's first terminal outcome.

### 8. Conversation tail and result pointers

The [conversation context contract](conversation-context-history.md) owns the
held conversation, stateless whole-turn half-budget jumps and oldest
result-body pointers. Quiet never ends what they holds. A conversation is held
whole until the request reaches the input budget; then the oldest whole turns
go in half-budget jumps. The input budget is min(model window minus response
allowance, 200,000 tokens). History fitting uses the input budget; refusal and
result pointers use model window minus response allowance, the physical limit.
The transcript is never replaced with generated text.
Before every resident or helper round, `context.request.fit` records measured
input, history input budget, physical input limit, output allowance and the model
window. A request that remains above the physical limit
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
An existing Desk journal stays attached to its original item; an interrupted
Desk wait whose run has a checkpoint is resumed by checkpoint recovery, never
returned (`EngineTurnContinuation.swift`). Ordinary turns acquire no Desk item.
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

### 10. Bridge ownership

Connection reads settle from request bytes, EOF, close or cancellation. Enqueue,
message, read and direct tool operations have no internal clock cutoff; their
admission, dispatch and retained receipt owners supply the actual result.
Closing a response connection cannot manufacture a terminal execution outcome.
`AgentContactTasks` owns its worker, produced output and terminal receipt. Recover its receipt
using the original request ID (and session ID for `/agent/reply`); do not
resend merely because the response is pending. An explicitly requested MCP
retrieval duration limits that caller's observation, leaving accepted work owned.

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
turn's first event row. Inspector call titles and grouping use the same checked
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
| `llm.call` | Call status and retained error detail. Missing call evidence does not prove no reconnect occurred. |
| `provider.httpRequestStarted` / `provider.httpRequestEnded` | One request id joins a send to its task completion, network loss or cancellation. |
| `provider.waiting` / `provider.reconnecting` | Working-card wait reason, time and Stop; or reconnect cause and attempt, also retained in the trace. |
| `context.tail.cut` / `context.tool_result.pointer` | Observed replay-head movement or retained result-body pointers, with measured before/after size. |
| `turn.cancelled` | The `where` field and any interrupted action's effects. |
| `turn.failed` or `turn.terminal` | The recorded outcome and reason. |
| Historical terminal from `terminal_reconciliation` | An older build recorded that a previous process left the turn unfinished; current reconciliation records recovery obligations. |
| No terminal | Check process continuity and the last recorded boundary; a missing row alone does not identify the cause. |
