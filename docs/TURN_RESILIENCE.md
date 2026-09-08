# Turn resilience map

2026-09-08: Source-free `bot_ask` receives the dispatcher's app-assembled provider
lifecycle observer, preserving provider vitals coverage through the existing
admission and deadline path.

2026-09-07: CloudKit inner action authentication precedes all ID-owned state;
failure retains only a digest-keyed envelope quarantine, with failed quarantine
or unavailable pairing authority left retryable. Telegram `/new` rolls back its
new index row under the index lock if the conversation-map update throws.
2026-09-07: iOS clarity closeout replaces Send with Stop during generation.
Approval cards gate decisions on pairing and current transport/network state;
unconfirmed outcomes no longer claim that the Mac received or executed a decision.
Offline decisions have no new automatic retry promise. The existing signed
action transport retains uncertain CloudKit transactions for checking/retry;
definite send failures may be retired. No transport, queue or receipt owner changed.
Evidence: `ios-shots/f1g/README.md`.

2026-09-07: iOS composer exposes a labeled 44pt-minimum Stop through the existing
run-scoped `ChatStore.stop(client:)` → `MacBridgeClient.cancelChat` path. The
store retains its visible cancellation-confirmation failure; DEBUG samples do
not send stop requests. No cancellation protocol or receipt semantics changed.

2026-09-07: iOS chat layout uses the existing scroll scheduler with a measured
composer safe-area inset; keyboard and native tab exclusion are not added twice.
Configuration moved into a sheet without changing selection transactions.
DEBUG streaming is a view-only in-flight sample, not an execution or receipt.
2026-09-07: Telegram session-map reads and mutations share a checked decoder
under the existing map lock. Invalid or unreadable storage throws a recoverable
session-storage error without rewriting bindings or selecting legacy context.
Missing storage alone bootstraps; locked mint-or-adopt still preserves concurrent
bindings and persona-only topic entries.
2026-09-07: iOS secondary-screen token propagation changes reading surfaces,
layout and copy only. Existing snapshot refresh, action receipts, cancellation
and retry owners remain unchanged; DEBUG design rows are view-only projections.

2026-09-07: CloudKit client-date fallback reads never stop at a server-date
watermark. Completed pages and their continuation survive bounded pull retries
in memory; only a complete scan reaches delivery. Individual record read errors
fail the page, preserving the receive watermark and prior page checkpoint.
Rejected continuations restart the scan; process restart safely rescans too.

2026-09-07: iOS terminal replies retire their retained send handoffs and win
over both late transport success and error. Pairing refresh reverifies the
original reply; unsigned hints and failed reply signatures never authorize
another execution identity. Pending arguments/session/placeholder and existing
reply polling, transcript backstop, and observation-only Retry remain intact.
Unverifiable CloudKit replies remain unacknowledged and Drive files unarchived
until verification succeeds; failure may hold the CloudKit receive cursor.
2026-09-07: Mac CloudKit receive admits authenticated, run-scoped `cancelChat`
actions before same-batch chats and through a separate single-flight drain
while the ordinary handler awaits a stream. The existing fallback timer stays
armed during silent streams. Both paths share message claims; only the serial
drain advances its cursor, and it halts while cancellation claims are unsettled.
The existing MacSync action ledger/response and active-run registry remain the
cancellation owners; the original chat task still owns its terminal reply and
receipt. Failed cancellation delivery releases its claim for retry.
2026-09-07: MemoryV2 retains candidate embeddings after corpus-drift refusal
for the existing two launch retries, keyed by provider epoch, row kind/ID and
content hash. Every attempt re-snapshots; removed rows leave the candidate set,
and atomic whole-corpus validation still precedes activation. Success, other
failures and the third refusal release retained candidates. No retry or timer
was added. Warm recall reuses lexical statistics and decoded vectors across its
own usage writes while refreshing counters and checking external data versions.
2026-09-07: ChatOrchestration's lazy bots tools use the canonical definition
and shelf stores. Shelf response construction completes before exact returned
IDs are acknowledged for reader `agent`; failed reads and filtered/lookahead
entries never advance that reader. Query-bound page tokens remain separate
from sparse acknowledgements. No tool-owned timer or retry loop is added.
`bot_run_once` calls the app-injected `standingBotRunEnqueue` adapter, whose
contract is local durable enqueue only. The dispatcher returns the accepted
request ID without waiting for completion; a missing or failing adapter never
claims a run was queued. Production `makeNativeAgentAppToolDispatchClient` binds
it to `BotRunQueue`: queued requests survive restart, but are consumed before
spend so interrupted work never replays. Paused, queued/running, and insufficient
input-budget requests are rejected. The scheduler drains this queue through the
same bounded runner as scheduled work, preserving the request UUID as book ID.
Definition changes and enqueue writes invalidate the existing deadline owner
immediately; no new timer is added. A manual run satisfies a coincident due slot.
| Owner | Budget and terminal behavior |
|---|---|
| StandingBots `BotRunner` / `BotRunnerDeadline` | Scheduled and queued checks reload autonomy and canonical Security Center admission (including kill switch and hard stops) before fetching and before provider dispatch; denied/unavailable policy records a failed book. Initial and redirect HTTP destinations must resolve only to public unicast addresses. Definitions cap runs at 32,000 tokens/120 seconds; `BotRunQueue` atomically reserves a fleet-wide 256,000-token UTC-day allowance, preserved across restart/corruption. Conservative input admission and provider wire output ceiling stop token spend. A monotonic deadline cancels HTTP/provider work and drops non-cooperative late output; only the parent appends one terminal book. Failed checks preserve last-good context and never notify or write memory. `BotRunnerScheduler` reserves before work for crash safety, then schedules from completion with a 15-minute minimum interval/cron gap. Existing BackgroundLoopsManager owns wakes and single-flight lifecycle. |
`BotRunnerHTTP` pins each admitted numeric address in NWConnection and verifies
fresh Trust Center admission immediately before every hop's exchange. Both
Anthropic OAuth completion paths also recheck the optional bot admission hook
after token refresh and before the retry; nil preserves ordinary chat behavior.
Whole-run and source-free `bot_ask` deadlines include admission and storage and retain the cross-process per-bot flock
until terminal storage settles. Indexed entry writes replace full-history append
scans and daily rewrites; provisional partial receipts finalize only after shelf
and continuity IO, with actual elapsed duration and failed/partial overruns.
The kernel releases claims on process exit. Cron mutations use scheduler parsing;
legacy bad schedules receive one failed receipt per revision without starving
other bots. Final receipt persistence necessarily follows its duration sample.

`BotRunnerHTTP` also verifies
the connected peer before sending and while reading. Original-host TLS SNI/trust
and Host survive pinning; redirects re-enter admission with a 20-hop ceiling.
The existing `BotRunnerDeadline` owns a 30-second whole-fetch deadline and cancels
the connection, while HTTP/1.1 parsing caps decoded bodies at 256 KiB.

2026-09-07: `codex_wake_rpc.js` rejects invalid control headers before waiting
for payload, accepts registered Close statuses 1012–1014, and latches closing
across data events. `TelegramApprovalFiler` reserves request identity before
inbox creation; duplicates await the same prompt success or failure and failed
delivery remains retryable. No timer or retry policy changed.
2026-09-07: Telegram manual compaction generates the entire replacement
recollection before rewriting under the transcript lock. Summary failures refuse
without changing transcript bytes; checked reads and mandatory backups remain.
Telegram status reads checked pending approvals scoped to chat and topic even
after the work card completes; an unreadable inbox reports unavailable. Picker
changes are labeled next-turn selections, never attributed to a running turn.

2026-09-07: standalone embedding downloads run independently of turns. MiniLM
(or the current installed model) serves until the download passes its SHA-256
gate. Network errors and cancellation leave resumable ranges and visible status
in Memory/Diagnostics. Verified installation uses the existing provider release
and corpus epoch reconciliation path; download progress adds no polling timer.
The bundled release descriptor supplies the URL, byte length and digest;
descriptor-free dev builds return quietly before creating a network session.

A turn that is working must never die. A turn that is stuck must be unstuck at the
stuck step, keep its work, and continue. The user should only ever see a failure
after every recovery is spent. User, 2026-09-05: "Their turn shouldn't be dying on them
while they are working."

This is the map of every clock, guard, and recovery in a turn, where each lives,
how to see it working, and what it looks like when it regresses. Read
[Anatomy of a Turn](ANATOMY_OF_A_TURN.md) first for the turn itself.

Fresh-install memory uses Fast (`performance`) mode in
`MemoryV2+EmbeddingRuntime.swift`: the embedding model loads on demand and has
no idle-unload deadline. Explicit Balanced/Low selections retain their existing
idle timers; manual release and embedding failure handling are unchanged.

## The rule each piece follows

Launch index reconciliation selects orphan and stale candidates under the
`sessions.json` lock, then reads transcripts after releasing it. Transcript
lock admission is a single nonblocking attempt with sidecar inode validation;
contention counts as deferred work for a later launch. Insertion rechecks that
the orphan still lacks an index row; stale repair rechecks the selected row's
timestamp and reconciliation stamp. Byte limits are charged under transcript
locks, without holding up unrelated index writers.

Mac session selection keeps its transactional load and turn-lifecycle checks.
`AppModel` shares a bounded converted disk-transcript cache through its
`NativeClient` values. Checked file identity permits reuse of unchanged
transcripts; changed or uncertain identity reloads through the existing history
reader. Optimistic rows and synthetic notices remain UI-owned, and context
receipts refresh independently.

| Storage boundary | Recovery and turn effect |
|---|---|
| `StandingBots/BotDefinitionStore.swift`, `StandingBots/ShelfStore.swift` | Store APIs used by ChatOrchestration's bots tools; no store-owned scheduler, timer, retry loop or turn/context injection. PersistenceCore's shared file lock and durable atomic rename serialize mutations. Corrupt JSON/JSONL throws and stays byte-preserved. Append-sequence page cursors include only returned rows; explicit sparse per-reader acknowledgements preserve unseen holes and survive restart independently of UI state. |
| `ChatOrchestration/SwiftToolDispatcher+StandingBotsToolLoop.swift` | Typed tool sources reuse the structured engine with a fresh prebuilt context, no memory promoter, four provider rounds and 16 tool calls. Each provider input and hard wire output allowance is reserved from the single run budget, including repeated history/schema bytes. Each call reloads admission, validates the catalog's capabilities for actual arguments, and traverses ordinary chat gates. A denied call latches failure even if the shared loop catches its error; the parent BotRunner alone appends “could not check: not permitted”. Tool evidence is capped, untrusted and shelf-only; missing/truncated coverage cannot become a successful complete check. The existing parent deadline cancels the whole loop and drops late output. |
| `StandingBots/BotContinuityStore.swift`, `ChatOrchestration/SwiftToolDispatcher+StandingBotsContinuity.swift` | Per-bot working notes cap at 12,000 UTF-8 bytes, compacted by the existing in-flight mechanical helper with no extra provider spend. Eight current named reports maximum, 32,000 bytes each, with immutable linked versions and one bounded atomic current manifest. Shelf append precedes continuity publication; a failed publication surfaces an error, preserves previous context, and may leave an unreferenced revision. Only the parent publishes completed nonfailed material; cancelled/late candidates cannot write. Source-free `bot_ask` shares the run claim, live autonomy admission, conservative daily reservation, per-call wire ceiling and BotRunnerDeadline, and writes only spend. Version-pinned character pages avoid mixing revisions during concurrent updates. No memory, chat, notification, automatic context injection or acknowledgement is introduced. OpenAI structured bot calls now enforce the task-local max_completion_tokens ceiling, with no ordinary-chat change. |

`TriggerScheduler.swift` retains trigger configuration and fire orchestration;
its fire path calls the advisory `surface` check in `ProactiveInboxStore.swift`.
That actor owns only the read-only active-duplicate projection over the canonical
notifications inbox and retains only its root; its historical `persistence:`
initializer parameter remains accepted and intentionally unused.
App `TriggerNotifierBinding.swift` calls the same static matcher under the inbox
lock before append and retains push handling. The extraction adds no write,
lock, cache, notification, canonical memory or turn-recovery owner and does not
make the early advisory check atomic with delivery.

`iCloudBridge.swift` retains transport/setup, live draining and send/receive
lifecycle. Its instance receipt forwarder, action send and inbound processing,
plus `MacSyncEngine+Inbox.swift` and `MacSyncActionRouter.swift`, call the existing
static receipt members now implemented in `iCloudBridge+DeliveryReceipts.swift`.
That extension owns durable projection over the supplied data root, sharing the
existing locked upsert, tolerant loader/quarantine and atomic writer. Successful
saves return true; a damaged store that cannot be quarantined throws before
rewrite, with the existing append error swallowing and confirmation Bool contract.
The router retains signed notification-action validation/handling and Shared
retains wire/HMAC contracts. Receipt status still states only the observed
boundary; the split adds no canonical memory, retry or peer-presence owner.

The public SystemOps router-plan client uses module-internal classification and
candidate scoring helpers. Context's canonical context/capability selector remains
a separate owner; this helper boundary changes no turn-context or recovery path.
Next-action prose is private to the router-plan file, timestamp forwarding is
module-internal, and CommandPalette search calls its internal keyword tokenizer.
Public router and search entrypoints retain the same behavior and recovery owners.

Native setup readiness uses AppModel's existing health, authentication and
configuration projections. The retired setup-question ledger has no placeholder
model, client or refresh task and introduces no onboarding or recovery owner.

Tool promotion's timestamp wrapper delegates to TrustCenter's manifest signer,
which owns the rounded optional-microsecond UTC format. Promotion still owns
staging, validation and receipts; TrustCenter owns signatures and keys. This
shared formatting path changes no clock sampling, receipt ordering or recovery.

PersonaCompiler's compiled-packet canonical/pretty encoders and TrustCenter's
manifest signer append string values and keys through PersistenceCore's
package-scoped `JSONValue.encodeString(_:into:)`. JSONValue owns only the
ASCII-compatible scalar escaping; packet construction, tree layout and
fingerprints stay with PersonaCompiler, and manifest policy, signatures and
signing-key authority stay with the signer. This stateless shared emitter adds
no persona, trust, memory or turn-recovery authority.

Workflow registry defaults, merge and create normalization are module-internal
helpers called by the public `WorkflowOrchestration` registry client. They add no
execution or retry owner: the workflow run engine remains retired, and
`WorkshopExecution` retains execution authority.

| Rule | Mechanism |
|---|---|
| Deadlines watch progress, not the wall | whole-turn budget slides on every productive round |
| A stuck step is cut, not the turn | per-tool dispatch deadline; per-call provider wall timeout |
| A cut step becomes recoverable feedback | tool timeout is returned to the model as a tool error; provider failure is retried in place |
| Nothing already done is redone | retries reuse the same conversation with tool results attached; tool effects never replay |
| What the user saw stays | mid-stream drops continue from the visible partial |
| The user can see it happening | `provider.retry` trace rows and a reconnect status line on every chat surface |
| A stop is always a stop | `CancellationError` is never retried, never wrapped |

Chat Completions streaming tool batches are validated in full before any call
is yielded. A missing name or invalid/non-object argument JSON rejects the
entire batch; empty arguments still mean an empty object. The structured turn
loop also rejects invalid object input from any streaming adapter, preserving
visible partial prose through its interrupted-turn path and dispatching none
of that response's buffered calls.

## The pieces

The fused-screen family leaves capture/render protocols, snapshot contracts,
geometry/building, staleness and prose/result redaction in `MacScreenView.swift`.
`MacScreenViewCapture.swift` owns display selection and the production capture
backend; `MacScreenViewRenderer.swift` owns annotated-image rendering and PNG
encoding. Each backend keeps its platform fallback and unchanged default factory,
used by `MacControl+Client.swift` to supply the builder's injectable seams.
`MacScreenViewStore` remains the staleness owner; `MacAccessibilityReader` remains
the only AX walker, and the client retains gates, actions and cancellation.
The split creates no input authority, perception state store or turn-retry owner.

### Source ownership after the splits (2026-09-07)

Core `LLMClient.swift` and ProviderRouting's `LLMClient+Real.swift`,
`LLMClient+AnthropicAdapter.swift`, and `LLMClient+OpenAIAdapter.swift` delegate
only compatibility content serialization to NativeAgentCore's stateless
`LLMCompatibilityPrompt.swift`. Callers retain their distinct role prefixes,
structured-path admission, unsupported-image notes/tracing and completion
dispatch. No turn-loop policy, context state or retry owner moves.

`NativeOAuthFlow+SessionRunner.swift` owns ASWebAuthenticationSession setup,
callback fallback/completion and release, and the pure shared callback validator
(provider error, absent or empty code, then exact state comparison).
`NativeOAuthFlow.swift` and `+Connectors.swift` call `validateCallback` and retain
failure results, token exchange, sign-in-attempt ownership and credential
destinations; connector loopback and OpenAI/xAI-specific transports retain their
existing owners. Sharing `validateCallback` adds no new state or authority.

Reviewed at `13006f73`. Core chat files below are under `Sources/ChatOrchestration/`.
The split does not unify the different retry policies.

`ChatFullMacYoloAdmission.swift` assembles fresh full-Mac authority queries for
NativeClient and SwiftToolDispatcher in the calling task. Their wrappers retain
call timing and distinct audit sources; TaskLocal provenance and raw surface
reach TrustCenter unchanged. TrustCenter alone evaluates authority, with no new
grant, authority cache, remote trust rule or turn/recovery owner.

`NativeAgentCore/NativeTimestampFormat.flooredOptionalMicrosecondUTCOffset` owns
the exact floored optional-microsecond wire formatting used by Context feedback
and Mac Control audit. The existing public Context `isoTimestamp` and private
Mac Control `iso8601` wrappers delegate formatting only; Context retains feedback
state and Mac Control retains audit and permissions. The signer/promotion
formatter remains a separate rounded contract. Neither shared formatting contract
owns time sampling, persistence, memory, or recovery.

Shared `NativeAgentShared/InboxWireModels.swift` owns immutable inbox group/action
wire values and scalar group-membership presentation. Mac `InboxView.swift` and
mobile `InboxModels.swift` alias those values and project their local item ID/title
into the shared matching rule (self-exclusion, membership, then trimmed group title
fallback). Parent item records and action visibility/dispatch stay platform-owned;
NotificationInbox/Desk retain durable lifecycle and action authority. The shared
leaves own no delivery, retry, store, or mutable UI state, and permission
constructors remain separate.

`WorkshopExecution/WorkshopExecutorContracts.swift` holds public injected
approval, LLM, tool-dispatch and terminal-sink signatures and the step receipt
value. App `BackgroundLoopsAssembly+WorkshopExecution.swift` supplies the adapters.
`WorkshopExecutorLoop` in `WorkshopExecution+Executor.swift` retains execution
state, queue claims, step execution, cancellation, approval resumption and terminal
settlement; no deadline or recovery path moves into the contract file.

Mac session rows in `ChatView.swift` and `ChatView+ShellColumn.swift` call the
stateless builder in `ChatView+DetachedSessionMenu.swift` for common detached-window
menu presentation, retaining their own pin/unpin, rename availability and dividers.
The builder queries and calls `DetachedChatWindowController`, which retains window
identity and lifecycle; opening still uses nil origin. No transcript, draft, turn,
permission or memory ownership moves.

On the Mac composer, `ChatView.swift` owns draft and popover visibility state
and supplies selection/dismissal callbacks to `SlashCommandMenu` in
`ChatSlashCommandMenu.swift`. The menu reads `ChatSlashCommandRegistry` for
command metadata/visibility and presents supplied dynamic tools; it does not
execute tools or own turn admission/recovery. `ChatMessageListView.swift`
retains transcript/group composition, Markdown facades, bubbles, grouping and
transcript admission, delegating inline approvals directly to `InlineApprovalCard`
in `ChatInlineApprovalCard.swift`. That file also owns the pure
`InlineApprovalPresentation` projection and the card's local busy/error/resolution/
draft state, with classic and shell render paths. Resolution awaits AppModel,
then updates local state and calls `loadHealthCard`; AppModel/NativeClient and
ApprovalInbox retain mutation/execution authority. `MacChatTurnCard` and
`MacChatTurnApproval` remain existing consumers of canonical approval state.
The Markdown and rich-content facades use separate `ChatContentCache` instances
for bounded process-local FIFO storage. Facades retain parsing/admission and
sanitation outside the storage lock; no transcript persistence, execution,
memory or recovery state moves.

At turn entry, `ChatOrchestrationClient+StructuredChat.swift`,
`+TextCompatibility.swift` and `+EphemeralToolTurn.swift` call
`+Attachments.swift`'s `turnAttachmentInput` for fresh multimodal admission
and bounded provider input. That extension keeps image conversion, document
preparation, classifiers and skip notes together, reading the existing Trust
policy within the per-turn path. Its document budget is local to the turn:
40,000 characters per document and 120,000 total, consumed in attachment order,
with budget admission before decoding/extraction. It introduces no attachment
store or policy authority. `+MessagePersistence.swift` retains durable
transcript writes, regeneration, session indexes and observations.

| Lane | State owner and call path |
| --- | --- |
| Whole-turn budget and iteration cap (1–2) | `ToolLoopSupport.swift` defines wall/iteration/no-progress/exhaustion policy. `ChatOrchestration+ToolLoop.swift`, `ChatOrchestration+StreamingToolLoop.swift` and `ChatOrchestrationClient+TextCompatibility.swift` hold turn-local counters/conversations. Successful dispatch rounds renew the shared policy; approval requests do not. |
| Tool deadline (3) | `ChatOrchestration+ToolDispatch.swift`: prepared calls → `ParallelToolDispatch.plan` → `runIterationDispatchGroups` → `runSingleDispatch` → gated `ToolDispatchClient`. `ParallelToolDispatch.swift` owns safe-set/group planning and bounds. The runner restores slot order and distinguishes unstarted cancellation from interrupted effects. |
| Provider timeouts/recovery (4–5) | ProviderRouting `ProviderStreamGuard.swift`, `LLMClient+Real.swift` and `ProviderRecoveryPolicy.swift` own transport walls/classification; ChatOrchestration's `ProviderRecoveryPolicy.swift` unwraps turn failures. Structured loops own reconnect state/partials. `ToolLoopSupport.swift` owns the post-effect retry marker; `TurnEngineContracts.swift` carries interruption/result contracts. |
| Compatibility entry/replay (5–6) | `ChatOrchestrationClient+TextCompatibilityEntry.swift` selects the lane and joins the producer before returning a saved response, including regeneration. `+TextCompatibility.swift` owns replay, retry/nudge accounting, cancellation exits, conversation mutations, visible accumulation and dispatch records, calling the shared lower dispatch runner. `+TextCompatibilityProtocol.swift` normalizes calls and buffers marker-aware prose using `ToolCallParser.swift`; `+TextCompatibilityFeedback.swift` renders recovery feedback without owning retry decisions. The loop awaits `+TextCompatibilityCompletion.swift` for the assistant receipt, terminal trace and promotion observation before finishing; the existing `+ToolReceipts.swift` drains tool rows in the writer task created and joined by the loop. Canonical regenerate replacement remains in `+MessagePersistence.swift`. Length-limited output takes the incomplete-result path. |
| Telegram recovery (6) | `TelegramPollLoop+ChatProgress.swift` owns surface replay classification. `TelegramUpdateInbox.swift` owns durable claims, queue acknowledgement and recovery; `TelegramPollLoop.swift` orders ingress and delegates HTTP/chunk/send mechanics to `TelegramPollLoop+Transport.swift`. `TelegramPollLoop+Approvals.swift` retains approval replay. |
| Slack recovery (6) | App `SlackSocketModeLoop.swift` coordinates socket lifecycle, teardown and turns and owns the short-lived session floor; its session completion and teardown paths call pure session outcome/disconnect classification members in `SlackSocketModeLoop+SessionClassification.swift`, which owns no state. `SlackTurnContracts.swift` supplies payload/reply values and plain/progress handler signatures shared by the loop, chat-surface assembly, session mapping and durable journal, with execution owned by canonical `ChatOrchestration`. `SlackSocketModeSupport.swift` holds socket/cache/handler helpers and `SlackSocketModeConfig.swift` decodes ingress policy. `SlackSessionStore.swift` and `SlackInboundDeliveryJournal.swift` retain durable session and delivery/recovery truth; the contracts introduce no transport, session or progress owner. |
| Bridge lanes (7) | App `ClaudeBridge.swift` owns authenticated message/tool admission and response latches. All three chat calls await a shared notice sink publishing bounded, redacted `message_notice` events before terminal events on `/claude/events`. `requestId` correlates early notices with terminal session/run IDs; enqueue notices already carry canonical IDs. Notices do not grant approvals or prove completion. `ClaudeBridge+StateProjection.swift` owns state reads/deadline; `+StandingViews.swift` delegates decisions to `CognitionProposalActions`. Core `SwiftToolDispatcher+OMPBridgeTools.swift` owns OMP message/wake submission; the agent-bridge family retains shared inbox/conversation helpers. |
| Wake workers (7–8) | `script/codex_thread_wakeup.js` and `claude_thread_wakeup.js` retain command dispatch, configuration, durable paths and orchestration. Both assemble lane-specific factories from `wake_queue_admission.js` (pending/topic admission and locks), `wake_turn_observation.js` (Codex rollout/event/liveness evidence and per-worker rollout cache; Claude child/transcript/exit observation), `wake_reply_delivery.js` (formatting, POST classification, Codex saved-job disposition and Claude session-store confirmation), and `wake_recovery.js` (existing-job/stale-owner reconciliation using those families and entrypoint receipt/inbox/dispatch callbacks). Existing job/queue/session stores remain authoritative; factories introduce no durable state owner. `readStdin` and `pidAlive` remain lane-local; recovery receives the PID callback explicitly. OMP retains its existing worker. `wake_worker_common.js` supplies synchronized append/claim, process identity/tree, event-wait and completion HTTP mechanics with explicit lane delivery policy. `codex_turn_result.js` projects terminal evidence without starting work. Codex also assembles `codex_wake_prompt.js` once for admitted single/batch handoff text and paired-review instructions through an explicit checkout-validator callback. Before prompt assembly, the worker creates `codex_wake_execution_policy.js` with worker-supplied settings and the execution-profile constant. It projects admitted Codex entries/config into brain controls, a checked common checkout and execution-policy values; checkout filesystem validation and bounded Git writable-root discovery stay fresh per call, and prompt rendering delegates to that validator. The factories add no durable state. The entrypoint retains admission, thread/turn RPC invocation, orchestration, daemon recovery and durable paths; permissions and watcher notification-only authority do not change. The worker assembles `codex_wake_request_params.js` after the execution-policy and prompt factories to assemble thread/turn wire parameters and client user-message IDs using worker-supplied settings, brain controls, execution-policy and prompt callbacks. Fresh-thread, turn-admission and durable reply-job paths consume its three functions through retained local bindings; fresh/turn exports remain unchanged. Calls independently generate fallback identities and read execution-policy/checkout evidence without caching. The worker retains RPC invocation, durable admission, lifecycle and configuration; the execution-policy helper remains checkout/policy authority, prompt helper remains text renderer, and lane identity remains lock-name projection. The helper ships beside the worker in app-only installs and adds no durable state. The worker passes its resolved socket path to `codex_wake_rpc.js`, which owns each socket session's framing, initialization, request correlation, listeners, deadlines and unattended client-request refusals. The worker calls `connectRpcOnce`, re-exports the unattended-reply helper, and retains daemon lifecycle, reconnect policy, admission/orchestration and durable paths; the RPC factory adds no retry policy or durable owner. The worker imports five pure thread/error projections from `codex_wake_thread_state.js`, including unhealthy-status classification and turn-ID exclusion. That ordinary module owns no IO or durable state and ships beside the worker in app-only installs. `readThreadState` and other RPC reads, admission and retries remain in the worker; transport remains in `codex_wake_rpc.js` and rollout/event evidence in `wake_turn_observation.js`. The worker also assembles `codex_wake_heartbeat.js` once through worker-supplied configuration, resolved heartbeat path and IO. Its `createDrainerHeartbeat` entrypoint owns each Codex drainer heartbeat instance's admission/receipt/timer lifecycle, serialized writes and stop/drain; `drainPending` retains drain orchestration and the worker owns durable paths. The existing heartbeat JSONL and lock remain the evidence, with no new store. The worker assembles `codex_wake_daemon_probe.js` with its resolved socket path and existing process-start identity callback. Construction performs no IO; the six probes observe daemon version/PID/start/cwd-inode evidence and project mismatches afresh per call. The entrypoint consumes them for recovery and reply identity, passes the PID probe to recovery, and preserves its exports. All healing decisions, restart/kill/socket cleanup, reconnect, jobs and durable paths remain in the entrypoint. The helper ships beside the worker in app-only installs, adding no daemon, watcher, state store or permission boundary. The worker assembles `codex_wake_inbox_projection.js` with its bridge directory, per-call inbox lock-path reader, clock and deferred queue-admission lock callback. The helper owns locked projection of already-decided delivery outcomes into existing inbox rows: queue admission consumes terminal marking, worker delivery consumes consumed marking, and recovery consumes both plus the message-ID helper. Terminal marking does not mark rows read or consumed. The worker retains configuration, durable path selection, wiring and its existing exports; queue admission and recovery retain decisions, while `wake_reply_delivery.js` retains transport and receipt interpretation. The helper ships beside the worker in app-only installs and adds no journal, retry owner or replay permission. The worker assembles `codex_wake_lane_identity.js` once with its resolved lane root and mode constants, preserving its four bindings and exports. The pure helper owns thread normalization, lane identity and hashed lock naming; worker dispatch and queue admission consume normalization, queue admission retains lock/capacity admission and queue mutation, and recovery consumes lane key/path projections while retaining recovery decisions. Configuration, path roots and wiring remain in the worker; remote-state/error projections remain in `codex_wake_thread_state.js` and locked receipt projection in `codex_wake_inbox_projection.js`. The lane helper ships beside the worker in app-only installs, performs no IO and adds no durable store, retry owner or replay authority. Claude prompt rendering remains lane-local. |
| Cancellation (8) | Surface/client task ownership reaches provider guards and shared dispatch. Mac `MacControl+Client.swift` owns operation cancellation/settlement; `+Perception.swift` checks targeting/cancellation during document reads. `MacActReceiptRendering.swift` and Four Verbs target resolution grant no cancellation or input authority. |
| Context compaction (9) | `IntraTurnContextCompaction` owns transient-context compaction and its deadline helper for the non-streaming and streaming structured tool loops; the Anthropic-shaped text-compatibility loop retains its own retry policy and has no in-turn compaction. `ChatOrchestration+SessionHistory.swift` loads history and `SessionHistoryPromptRenderer.swift` budgets its projection; the renderer does not persist compaction. |

Four Verbs shares immutable dependencies from `MacFourVerbs.swift`.
`+Act.swift` owns bounded repeats and burst attention, calling
`+PhysicalActions.swift` for gestures and cross-app drag anchoring.
Both use `+Observation.swift` for call-local sightings, bounded wake recovery,
motion resampling and post-action evidence. `+Wait.swift` owns observer
subscriptions, cancellation checks and signal/deadline pacing through the
injected clock; it reacquires through Observation. Navigation also uses that
sighting path. `+ScreenPresentation.swift` only formats/scopes existing values;
it owns neither observation nor verification. No split introduces another
operation store, screen cache or retry policy.

`MacControl+Client.swift` retains operation deadlines, cancellation and terminal
settlement. Its admitted dispatch calls `+DirectInput.swift` for direct input
and marked-target checks, or `+HandAndWake.swift` for hand/nudge/wake handling.
Those extensions retain effect-time checks and balanced input cleanup, with
the original click drag-step delay and hand/wake settle waits beside the
handlers they pace. They share the actor's event sink, session source and
attention state; `+ClosedLoopAction.swift` retains the `handleAct`/`performAct`
pair and its observed verification.

`MacAccessibilityActuator.swift` retains AX/input execution, capability minting,
nonce state, TaskLocal authority, approval binding digest and the in-memory secret
replay vault. `MacInjectionRedaction.swift` owns the stateless request/result
secret projection and approved-replay rehydration helpers within MacControl;
result scrubbing calls the argument redactor and `MacInjectionToolNames`.
Existing persistence/emission callers still redact independently. This file
boundary adds no mint or persistence owner and changes no replay recovery policy.

Reader and actuator call `MacAXWindowIdentityRead.swift` only for synchronous
role/subrole/title/frame projection, after minting their own handles. Each keeps
its execution lane, process checks and window/index selection; the actuator
keeps focus verification, and `MacAXWindowInventory` keeps ordered union/dedup.
The helper owns no state, permission or screen cache and moves no turn or memory
authority.

Discovery is separate: `MCPToolCatalogWarmer.swift` owns a detached warm slot,
rearm clock and signature ledger; MCP dispatcher/pool owners retain cache
publication, consent, cancellation and child generations. The warmer's timeout
cannot certify a non-cooperative server stopped. Catalog cancellation below
belongs to the discovery fetch owner.

The package-only `NativeAgentCore/ProviderFamilyIdentity.swift` only projects
family strings through existing routing and Telegram menu wrappers, never
choosing a transport. Checked routing and
adapter identity stay in ProviderRouting; menu matching/rendering stay in Telegram,
and catalog/command transport aliases remain distinct. No retry or memory owner moves.

`OAuthProductionSession.swift` constructs fresh HTTP sessions from raw timeout
strings for the Anthropic/OpenAI wrappers; those adapters retain environment-key
selection, separate cached production sessions and transport/auth lifecycle.

Credential recovery remains with adapters: `ProviderRoutingContracts.swift`
defines the checked snapshot, `ProviderRouting.swift` reconciles it, and
`LLMClient+OpenAIOAuthCredentials.swift` supplies path/JWT/saved-token helpers
to `LLMClient+OpenAIOAuthDirectAdapter.swift`, which still refreshes and executes
requests. Anthropic, OpenAI and xAI OAuth adapters delegate queue lookup to
`OAuthRefreshQueueRegistry.swift`, each retaining a separate static registry
with strong process-lifetime queues keyed by standardized credential path.
The registry owns only synchronous locked lookup/create; `AsyncSerialQueue`
in the OpenAI adapter file still owns serialization and cancellation forwarding.
Token rereads, single-use refresh sequencing and credential writes stay with
the adapters, without changing routing, auth authority or recovery policy.
App connector credentials and common revoke/connect live in
`NativeOAuthFlow+ConnectorCredentials.swift` and `Connectors+Auth.swift`; they
are not alternate provider retry ladders.

`NativeAgentShared/ProviderCatalogWireModels.swift` owns the catalog leaf wire
records `ProviderModelInfo` and `ProviderTestResult`; local aliases in Mac
`Models/ConfigProviderDoctorModels.swift` and iOS `Models.swift` expose them to
surface consumers. Their fields, construction defaults and synthesized Codable
behavior are shared; `ProviderInfo` stays platform-specific. Routing, auth and
verification retain their existing owners, with no recovery state or retry policy
moving. These records are separate from auth coercion and permission decoding.

`NativeAgentShared/ProviderAuthStatus.swift` owns the five mutable fields,
required five-argument construction and keyed encoding, omitting nil metadata
and timestamps. Mac `Models/ConfigProviderDoctorModels.swift` and iOS `Models.swift`
expose local aliases; `ProviderInfo` stays platform-owned. The shared value calls
`NativeAgentShared/ProviderAuthStatusWireSnapshot.swift` for snapshot compatibility
and lossy metadata-to-string projection through its private recursive coercer. Null metadata
values drop, arrays comma-join projected values, objects expose sorted keys and
non-object metadata remains nil. Provider stores/adapters still own credentials,
refresh and routing; no retry or memory ownership changes.

`NativeAgentShared/MacControlPolicyWireSnapshot.swift` owns only Mac Control
snapshot decoding compatibility: Mac `MacControlPermissionsView.swift` and iOS
`Models.swift` delegate their local policy decoders and copy the twelve fields.
Missing/null fields retain the existing fallbacks; malformed present types
still throw. Platform models retain state, encoding and distinct direct-construction
defaults (five approval categories on Mac, an empty list on iOS). TrustCenter
remains policy authority; no recovery store or permission authority moves.

For memory/KG/substrate restore, proposal recurrence and consolidation lanes,
see the [memory map's new owners](MEMORY_SYSTEM_MAP.md#ownership-after-the-september-splits).
Organism continuity decoding uses `OrganismPersistentState`; prediction types
are in `OrganismPredictionModels.swift`, transitions in `OrganismPrediction.swift`
and horizon refresh in `OrganismPrediction+Horizon.swift`. They share the kernel
ledger; no split introduced another recovery store.

### GitHub check-run page stability (2026-09-06)

Check classification requires two consecutive complete scans with matching
ID-sorted rows, not just equal counts and unique IDs. A changed observation
gets one refetch (three scans maximum); continued drift or incompleteness fails
visibly. This detects same-count replacement across pages, although GitHub's
paginated endpoint cannot provide a transactional snapshot.

### Phone pending-action retry identity (2026-09-06)

CloudKit sends first recover an exact retained message identity, or a unique
pending envelope with the same client, action and payload. This applies to all
action entry points, including ordinary retries and relaunches: provisional
IDs from `InboxAction.make` never replace the retained timestamp, signature,
message or transaction. Ambiguous pending matches fail closed. A caller must
explicitly set `intentionalNewRequest` to send a separate identical action while
one is unresolved. Once a verified response retires the pending envelope, an
ordinary new action receives fresh identity as before.

### MCP server removal during spawn (2026-09-06)

Removing a server cancels and removes its in-flight spawn task before any await.
A child may publish only while its spawn generation still owns that server;
removing and re-adding the same specification cannot adopt the old child.

### Pending phone action collisions (2026-09-06)

A retained message ID cannot be reused with a different transaction, client,
action, or payload. The send fails before writing or dispatching, preserving
the original signed envelope for recovery.

### Proposal recurrence evidence (2026-09-06)

A saved string counter that cannot be parsed as Int64, or a counter with an
invalid JSON type, aborts the proposal merge and logs the refusal. It is never
treated as missing evidence or reset to one; the saved proposal is preserved.

### MCP catalog and response bounds (2026-09-06)

Discovery rejects catalogs exceeding 10,000 items, 32 MiB of serialized pages,
or 1,000 pages without publishing a partial catalog. Each HTTP response is
limited to 8 MiB while reading, including SSE frames, comments, error bodies,
and notification drains. Limit errors name the server and method; the HTTP
task is cancelled when parsing exits.

### MCP discovery cancellation (2026-09-06)

Cancelling a catalog waiter cancels its shared refill and initialization task.
Pagination observes that cancellation before another page, and cancelled values
cannot publish to the live cache. Other waiters sharing the fetch also receive
the cancellation and can retry discovery; Stop does not leave a hidden refill.

### Telegram command shutdown generation (2026-09-06)

Command admission captures the coordinator's shutdown generation and checks it
again when registering its task. A command accepted before shutdown cannot
register after the drain completes and the replacement lifecycle starts.

### CloudKit retained-message replay (2026-09-06)

New chat records serialize sorted JSON keys. Conflict reconciliation canonicalizes
both complete JSON objects, including legacy records, before comparing them and
requires equal direction. Signatures, unknown fields, and array order remain part
of the proof; malformed payloads cannot prove a replay.

### Chrome lease recovery removal (2026-09-06)

Normal release and expiry persist a non-actionable `releasing` lease, including
the close choice and reason, before cleanup. Restoration resumes pending cleanup
even before the original expiry. Removal failure retains ownership and a retry
alarm; ownership is retired only after cleanup, then the alarm is cleared.
An explicit `closeCreatedTab: false` survives a worker restart.

Expired created tabs are checked again immediately before removal during restore.
An active tab or an activation observed during restore is retained. Chrome has
no atomic remove-if-inactive operation: activation after the final `tabs.get`
and before `tabs.remove` takes effect remains a small residual race.

### Unpinned MCP consent (2026-09-06)

Bare `/usr/bin/env` wrappers (including `--`) bind the inner executable and
interpreter file inputs as well as env itself. Environment assignments,
options, and other env paths are unsupported indirect identities and require
reconfirmation instead of reusable consent (2026-09-06).

Unresolved npx identities and legacy consent rows marked `unpinned` do not
authorize reuse. Swift execution surfaces a pin-and-reconfirm error rather than
silently renewing these grants, including read-tier auto-grants. Resolve the
implementation to verified executable contents, then explicitly grant consent again.
As of 2026-09-06, npm package versions alone cannot establish that binding;
all recognized npm exec/npx launches remain unpinned, including exact versions.
The renewed grant must be pinned and match the current identity and risk.

### Organism continuity restoration

`OrganismPersistentState` checks that node, edge, prediction, and reflex
dictionary keys match their embedded IDs while decoding. Inconsistent saved JSON
throws before decay can rebuild dictionaries, reaching the existing
`organism.restore_failed` receipt and session persistence freeze. The damaged
file stays intact for repair; valid continuity retains the same decay and limits.

### Attention delivery destinations

The default attention router does not derive a Telegram recipient from an
inbound allowlist. Without an explicitly supplied owner destination and topic,
a Telegram-targeted attention event falls back to paired-phone delivery.
Each new needs-you episode reserves a durable identifier before sending, so
equal-count episodes remain distinct while retries retain the same identity.
Concurrent callers for the same event and reason join one delivery task.
Successful sends merge into the latest ledger; failed sends release their
reservation for retry. Explicitly pinned tool notifications remain repeatable.
Desk notification identity uses the evaluated handle and its observed revision;
terminal events use that same snapshot's `closedAt` rather than rendered prose.
Chat-targeted `mobile.notify` carries the trusted task-local originating
`sessionId` to the notification sender; tool-supplied session fields cannot
redirect it. CloudKit's bounded routing projection must carry this field too
before its delivery path can select that chat on tap.

### Mac chat selection after removal

Archiving the selected chat and refreshing an index that no longer contains
the selected chat clear that unavailable destination and load a surviving chat
through transactional selection. The selection generation prevents a delayed
load from redirecting a newer choice; a loaded destination must still belong
to the current index before it can commit. A failed replacement load leaves
no removed conversation selected.

### Approval replay ownership

`NativeClient.applyResolvedChatToolApproval` holds one process-wide owner per
canonical data root and approval ID through execution and annotation. A duplicate
returns while that owner is live. An already-spent approval receives recovery's
unknown-outcome annotation only when no executor still owns it, so reconciliation
cannot invalidate the winning executor's replay verification.

MacSync approval responses carry decision acceptance separately from a bounded
execution annotation reread from the exact canonical approval row. Execution
errors, blocks, and unknown outcomes reach the phone's existing failure path
with a message that the decision was accepted; a missing annotation is unknown,
never evidence of successful execution. The phone must retain that distinction
when reconciling its local decision overlay.

Restore staging's safety backup is provisional while runtime owners remain live.
`resumeStagedBackupRestoreAtLaunch` captures and validates a final safety snapshot
before constructing those owners, then durably binds its ID/hash with the applying
intent before overwriting state. Application preserves effect fences from that
final snapshot; interrupted application rolls back to it. Both safety snapshots
remain available through Backup UI.
Backup registry writes retain every snapshot record rather than evicting names
while leaving their directories behind. Snapshot-directory retention remains an
explicit separate policy; the production-export listing retains its own cap.

### OAuth callback admission

Both Mac loopback listeners admit a callback only with the exact, single state
issued for the active sign-in attempt. Unrelated or mismatched requests leave
the listener waiting. The browser page acknowledges callback receipt; the app
reports sign-in completion after token exchange.
The socket-based listener shuts down its accepted client on cancellation or
deadline expiry, so a browser that sends no bytes cannot retain a blocked worker.

### GitHub check-run completeness

Exact PR observation, tracking detail and get-PR reads (2026-09-06) collect
check runs in 100-row pages before classification. Missing/malformed totals,
changing totals, duplicate run IDs, short incomplete pages and more than 1,000
runs fail the observation instead of reporting a truncated set as passing.
The get-PR projection still displays at most 100 rows and explicitly reports
its source count and display truncation; the summary uses all fetched runs.

### Connector registry preservation

Connector-auth registry updates (2026-09-06) only mutate an existing valid
array of objects under its file lock. Missing, unreadable, malformed or
wrongly shaped registry storage is left untouched. Registry writes remain
best effort and do not undo a completed credential operation.

### Mobile transcript publication

Shared `CloudKitTimeoutResultLatch.swift` owns the per-operation result and
single waiter used by Shared `DetachedCloudKitTimeoutRace.swift` and
`CloudKitDeviceTransport.swift`. It retains cancellation before waiter
registration, first-result wins, and result-before-cancel precedence in `wait`.
Mac and iOS `Diagnostics/CKLandmine.swift` call the shared detached diagnostic
race while keeping their local optional-result API, numeric conversion, and
distinct log wording. Mac also keeps KVS-health caching and entitlement/probe
policy. Shared owns utility-priority detached work, waiter-side error strings,
first-child selection, and child/work/waiter cancellation before returning.
Device transport keeps its distinct recovery-budget-aware optional/throwing
races, task-local budget inheritance, and CloudKit IO. No recovery budget,
canonical state, permission, memory, or turn-retry ownership moves.

CloudKit status writes are ordered per key through actual operation completion.
A caller timeout does not release that write lane; later publications wait for
the outstanding server operation before starting.

`MacSyncEngine.chatTranscriptSnapshots` retains its 2 MiB raw-byte limit and
checks the final candidate with `NAMobileSnapshotStatusCodec` against the actual
800 KiB transport envelope. Oversized candidates omit lowest-priority complete
sessions until they fit; omitted history is never represented as an authoritative
empty transcript.

### Telegram numeric fields

Telegram numeric field decoding retains truncation toward zero for representable
values. Nonfinite or out-of-range floating-point fields are treated as absent
through the existing optional/default paths, instead of trapping the process.

Slack, GitHub and X connector numeric options follow the same checked
truncation rule (2026-09-06). Unrepresentable values use each caller's existing
default before clamping; string and Boolean coercion is unchanged.

Telegram photo selection (2026-09-06) skips variants with negative dimensions
or overflowing pixel-area multiplication. Valid variants retain largest-area
ranking and last-variant tie breaking; no malformed size can terminate ingress.

### Mac control marks, approvals cap, and schedules

Screen-backed document reads (2026-09-06) capture a writable AX vertical
scrollbar's original value before moving. Restoration writes that exact value
and verifies readback, so zero-motion and partially clipped end probes cannot
cause a full inverse-wheel overshoot. A missing writable position limits the
read to the visible screenful without scrolling. Attention, cancellation and
captured-target checks still prevent restoration after user takeover or drift;
`scroll_restored` then remains false. Timeout wording does not claim restoration.

Telegram Speech recognition latches the first completion or cancellation even
before its task and continuation are registered. Registration delivers that
result exactly once and cancels a late task when cancellation won. Speech task
cancellation runs outside the state lock so a synchronous callback cannot
deadlock the cancellation path.

Mac AX read bounds, file-read byte limits, Spotlight result limits, and shell
timeouts use checked integer conversion before clamping. Representable fractions
still truncate toward zero; nonfinite or out-of-range values use the existing
defaults. An unrepresentable explicit path paired with a mark refuses as an
ambiguous target instead of trapping during path comparison.

Marked `mac_click` input re-resolves the captured app/window and element before
posting each move or mouse-down, using the live frame. Mouse-up finishes the
accepted press at its last posted position: the press itself may change or
remove the target. Each subsequent click still requires a fresh target check.
Missing, ambiguous, inferred-label,
unfocused, or drifted targets refuse with `mark_drifted`; a fresh view or an
unambiguous semantic target is required. A held button is released at the last
posted position on refusal.
Live value labels use the reader's AX string conversion and the mark selector's
whitespace trimming, including numeric and Boolean values.
Marked actions search the live captured window for a unique role/label identity;
child-index changes do not retarget an action. If the window walk exceeds 4,096
elements or pending children, it refuses (2026-09-06). Captured ancestor indices
are not identity evidence after relayout and cannot establish whole-window
uniqueness. Duplicate identities and AX read failures also refuse.
Marked `mac_ax_act` uses the same app/window and identity checks, then passes
that exact resolved target to the actuator; it never reinterprets the mark's
path in another frontmost window.
Click/drag execution checks task cancellation before each event and exits on a
cancelled drag delay. Cancellation releases a held button at the last posted
position and returns `cancelled`; remaining motion is never accelerated or replayed.
Approval creation and match-or-create share the 300-row terminal-first cap:
pending requests are never evicted. A new distinct request is refused before
writing when all 300 rows are pending; touching an existing pending request
remains allowed.
Approved requests without an `executedAction` receipt also count as pending for
eviction: approval is persisted before execution, and that row must survive
until the executor records its outcome. Denied, canceled and orphaned rows remain
terminal eviction candidates.
Hourly recurrence includes a candidate equal to the next whole minute: that
instant is already strictly after the reference time. A 10:59:30 reference
with `minute: 0` therefore schedules 11:00, without skipping to 12:00.
Activity capture's run loop waits for its retained command source and installed
events, without a routine one-minute timeout while locked. Shutdown still posts
its command and explicitly stops the run loop; only an actually finished loop
uses the existing short backoff.
AX action receipts retain the mark's label, enclosing-caption, and secure-field
redaction context for both the target and post-state. Path-only calls redact
values conservatively because equivalent contextual evidence is unavailable.

The phone's snapshot decoder ignores unknown projection filenames while still
rejecting known filenames carried in the wrong group and invalid paths. Only
recognized files are returned for installation. Older installed decoders still
require a compatible publication from the Mac.

### Mobile queued-send handoff

Queued chat handoff retains its queue row, user-message ID, placeholder ID and
exact signed envelope until transport acceptance. The envelope is checkpointed
before submission; restart resubmits the same identity and bytes through the
existing exact-replay check. Submission failure pauses the retained entry;
explicit Stop retires the active handoff. Sending entries are omitted from the
send-next strip while their transport call owns them.
Admission remains limited to 20 queued sends per session. Persistence and
restoration retain the entire accepted queue, including paused sessions; there
is no separate global truncation that can discard earlier accepted sends.
As of 2026-09-06, immediate composer sends also enter that retained handoff
before transport. The active send is excluded from the 20 waiting-entry limit;
failure can therefore retain that accepted send alongside 20 waiting entries.
Its transcript, attachments and Retry send control survive without new queue
admission or overwriting a newer draft. Retry reuses the retained envelope.

Passive iPhone provider-catalog refresh preserves a nonempty saved model,
including a canonical model adopted from the Mac. Catalog projections do not
carry completeness evidence. Explicit provider selection still chooses from
the selected provider's available models; an empty selection may be seeded.

### Mobile action uncertainty

Before CloudKit action submission the phone durably retains the exact signed
envelope. Ambiguous saves remain outcome_unknown and continue response polling;
retries of the same unresolved message and transaction reuse the original
envelope after relaunch. While an identical action remains unresolved, a separate
intentional request requires `intentionalNewRequest: true`; ordinary retries
recover the unique retained signed envelope even if the caller supplied fresh
provisional IDs. See [Phone pending-action retry identity](#phone-pending-action-retry-identity-2026-09-06).
Verified responses remain authoritative
over late send completions; retained envelopes retire when a caller observes
the result, preserving retries after background delivery. Unambiguous
first-attempt preflight failures remain send_failed.
As of 2026-09-06, the new Workshop task sheet retains its original action across
retries, including a replacement issued after a verified signature rejection.
Once submitted, its fields are frozen so Retry checks/resends that same intent.
Opening a new task sheet explicitly starts a new submission identity.

### Chat retention

Chat retention checkpoints each archived row's removal from the active index
after writing the archive copy and archive-index row, and before deleting the
hot transcript, while holding the session-index and transcript locks. A crash
before the checkpoint leaves hot history active; a crash after it may leave a
recoverable hot orphan, never an active row whose history was deleted by
retention. A later archival failure cannot roll back earlier index checkpoints.

### 1. Whole-turn budget (progress-aware)

`WholeTurnWallClockBudget` in
`Modules/NativeAgentCore/Sources/ChatOrchestration/ToolLoopSupport.swift`.

- Window per surface: 600 s interactive, 600 s Telegram, 3 900 s unattended
  (autonomy, workshop, swarm).
- `recordProgress()` on every round that lands a tool result slides the deadline
  forward by the window. A `waiting_approval` envelope is NOT a landed result
  (2026-09-06, both structured loops and the text-compat one): the tool did not
  run, so a model re-asking for the same CONFIRM cannot renew the budget round
  after round.
- Ceiling: `progressCeilingSeconds` (6 h). Before 2026-09-05 the ceiling was the
  unattended window, 65 min, and cut productive long turns.
- Expiry is a checkpoint between provider rounds, never a cancel. It takes
  `finishExhaustedTurn`, which keeps every tool result and receipt.

Regression looks like: a turn with tool results landing every minute ends with the
"exhausted" reply before an hour is up.

### 2. Iteration cap

`ToolLoopBudget` in the same file. 60 interactive, 180 Telegram and the agent
bridges, 80 unattended, hard cap 240. `ToolLoopNoProgressGuard` stops after sixteen
identical rounds. Both hand the model a plain "stopped, results preserved" reply.

The guard compares name, input and result. Since 2026-09-06 it compares an
approval envelope WITHOUT its `approvalId`, and `NativeAgentChatApprovalFiler`
returns the id of the identical pending request instead of filing a second one.
Before that, a repeated CONFIRM minted a fresh id every round, so the results
never compared equal, the streak never grew, and the one loop shape the guard
exists to stop was the one it could not see — while the person collected a
duplicate approval row per round.

### 3. Tool dispatch deadline

Comment block "Per-dispatch deadline" in the same file (search `dispatch deadline`).
The shared dispatch runner that applies it is in
`ChatOrchestration+ToolDispatch.swift` (`runSingleDispatch`).
A tool's own `timeout_seconds` is honored with a margin; otherwise a surface
default. On expiry the model receives a tool error that says the outcome is
uncertain and to reconcile before retrying. The turn continues.

The race is `IntraTurnContextCompaction.withDeadline`, the same resume-once gate
the provider wall uses (2026-09-06). It was a throwing task group, and leaving a
group waits for its cancelled children — so a connector that ignores cancellation
held the turn open past the ceiling. `WorkshopSession.runWithDeadline` had the
same shape and now calls the same helper.

Regression looks like: a hung connector call (MCP, browser) ends the turn instead
of producing a tool error the model answers.

### 4. Provider timeouts

`ProviderStreamGuardConfig` in
`Modules/NativeAgentCore/Sources/ProviderRouting/ProviderStreamGuard.swift`:
idle 90 s, wall 600 s. Env overrides
`NATIVE_AGENT_PROVIDER_STREAM_IDLE_TIMEOUT_SEC` and `..._WALL_TIMEOUT_SEC`.
Every configured value is CLAMPED to `[floor, 86400]` at construction
(2026-09-06): `TimeInterval("inf")` and `"1e400"` both parse, `max(0, …)` let
them through, and `UInt64(wall * 1e9)` in `withCompletionWall` traps on a
non-finite or out-of-range Double — one env-var typo crashed the process on the
next provider call. `callWallSeconds` never exceeds the configured value, so the
clamp covers the whole ladder.

- Streaming calls: wrapped by `ProviderStreamGuard` in `LLMClient+Real.swift`.
- Non-streaming calls: `withCompletionWall` in `LLMClient+Real.swift` races the
  adapter against the wall timeout and throws `LLMError.transient`. Added
  2026-09-05 after an OAuth-direct request sat open 17 minutes with no error.
  Both racers are UNSTRUCTURED tasks behind a resume-once gate (2026-09-06):
  the original raced them inside a task group, and leaving a group waits for
  its cancelled children, so a provider that ignored cancellation never let
  the timeout return. The cross-turn distiller's 120 s ceiling had the same
  shape and now calls `IntraTurnContextCompaction.withDeadline`. The timeout
  racer CLAIMS the resume-once gate before it cancels the call (2026-09-06):
  cancelling first let a cooperative provider throw `CancellationError` and win
  the gate, so a wall timeout surfaced as a user Stop — unretried, and
  persisted as cancelled. The morning brief's 120 s synthesis ceiling
  (`BackgroundLoopsAssembly.withBoundedMorningBriefTurn`, 2026-09-06) had the
  task-group shape too — it kept the trigger lane's loop execution gate while
  a wedged turn ignored its cancellation; it now uses the same resume-once
  shape around its injected deadline sleep.
- OAuth-direct URLSession: request 240 s, resource 600 s
  (`NATIVE_AGENT_OPENAI_OAUTH_REQUEST_TIMEOUT_SEC`, `..._RESOURCE_...`). These
  did not fire on a half-open connection; the wall above is the real floor.
- The wall a CALL actually gets is bounded by what the turn has left, sampled at the provider call itself (after context assembly)
  (`ProviderRecoveryPolicy.callWallSeconds`, fed `LLMCallContext.remainingTurnSeconds`
  — bound by both structured loops around their provider call, and by
  `streamTurn` around its two transports from the `remainingTurnSeconds`
  argument the text-compat loop passes it; that argument is explicit, not a
  `withValue` around the call, because a sync binding pops while streamTurn's
  spawned Task still holds it): remaining minus a 60 s reconnect
  reserve, floored at 60 s, never above the configured wall. Before
  2026-09-06 the wall (600 s) equalled the interactive and Telegram turn
  windows (600 s), so the FIRST hung call spent the whole budget — the ladder
  announced "try 2 of 10", slept, and exited on the budget without ever
  re-asking. The global default is untouched; only the per-call value shrinks.
  A remainder of ZERO means the turn is spent, not "no budget": it takes the
  floor like any other too-small remainder, never the full configured wall
  (2026-09-06). The proactive compaction that can produce a zero remainder —
  it distills through the model, so it costs real wall time — is followed by a
  second exhaustion check in both structured loops, so an exhausted turn ends
  at the iteration boundary instead of starting one more provider call.
  `streamTurn` checks the remainder it sampled, right before the transport, and
  raises `TurnBudgetSpentBeforeProviderCall` when it is zero or less, so no call
  starts (2026-09-06). The loop-head check runs BEFORE context assembly and
  assembly costs wall time, so that gap was the last way a spent turn could
  reach the 60 s floor. The text-compat loop reads that typed error as its
  exhausted exit, not as a provider failure — the reconnect ladder would replay
  a call there is equally no time for. Both structured loops now count the
  provider round immediately before making it, so an exit above the call (the
  post-compaction one, above all) no longer inflates the round count the
  exhaustion line reports.
- A buffered (non-streaming) OAuth-direct SSE body that ends without a
  terminal event is `streamTruncated`, not a completed reply. It used to be
  returned as text, which flushed half-arrived function calls with `{}`
  arguments and let the tool loop dispatch them (2026-09-06).
- Chat Completions `finish_reason: "length"` is a distinct
  `LLMError.outputLengthLimit(partial:)` terminal, never `streamTruncated`.
  OpenAI, OpenRouter, Moonshot and xAI apply it in both streaming and buffered
  parsers before releasing any tool calls, including valid-looking partial
  arguments. Structured and text-compatibility loops retain marker-safe prose,
  mark the turn incomplete, and end with “The answer hit the length limit.
  Ask to continue from here.” No automatic retry, reconnect notice, or
  connection-drop continuation request runs; a user continuation starts the
  next turn. Cancellation retains priority over this terminal. Provider-reported
  usage is recorded before terminal validation, so an incomplete answer retains
  its spend receipt even though its tools are withheld.
- The NATIVE Anthropic / kimi-code streaming lane buffers its tool calls until
  `message_stop` and validates them there (2026-09-06). It used to yield the
  assembled argument bytes as each `content_block_stop` arrived — before the
  `stop_reason` was known and without parsing them — so a block the output limit
  cut mid-JSON was dispatched with truncated arguments, and one cut before any
  argument text was dispatched as `{}`: the model's call with every argument
  invented. The release is ALL-OR-NOTHING: one call whose arguments do not parse
  as a JSON object condemns the whole buffered set, as a `stop_reason` of
  `max_tokens` already did, and the reply carries the same
  `[response incomplete: …]` note the OAuth-direct lane uses. Dropping only the
  malformed call and yielding its valid siblings executed a subset of a parallel
  response — half of a plan the model wrote as one decision, chosen by which
  block happened to survive. This is the streaming sibling of the OAuth rule
  below.
- The NON-streaming Chat Completions lanes (OpenAI api-key and the OpenRouter
  path that shares its parser, xAI, Moonshot) follow both of those rules as of
  2026-09-06. An empty reply is `streamTruncated`, not the empty string it used
  to be returned as — a silent no-reply reached the chat as a blank turn and
  the ladder had nothing to retry. And their `tool_calls` release is
  ALL-OR-NOTHING with the same `[response incomplete: …]` note: they used to
  drop the entries they could not execute and run the siblings.
- A non-2xx body from the OpenAI api-key and OpenRouter lanes now rides in the
  thrown error for every status, not only 401/429/5xx (2026-09-06). It was
  discarded for anything else, so a 400 whose message says "maximum context
  length" arrived as a bare `.invalidResponse(400)`, `isContextOverflow` had no
  text to read, and the turn retried the identical oversized prompt instead of
  running the reactive compaction below. The status is still named in the
  message, so the code-based classification is unchanged.
- A stream frame that will not parse is a FAILURE once the stream has produced
  output, not silence (2026-09-06) — in the shared chat-completions decoder
  (OpenAI api-key, OpenRouter, Moonshot, xAI) and in the OpenAI OAuth-direct
  parser. Both used to skip it, so a corrupted transport mid-answer dropped a
  chunk of the reply or of a tool call's arguments and the turn still finished
  successfully. It throws `LLMError.transient`, which the ladder re-asks on.
  Before any output a frame is still skipped: a provider preamble is not a
  corrupted answer. Moonshot and xAI also stopped accepting `[DONE]` with no
  content and no tool calls as success — the empty-stream rejection OpenAI and
  OpenRouter already applied. xAI's loop now counts reasoning frames and
  tool-argument fragments as liveness, so the idle clock stops cutting a stream
  that is thinking or assembling arguments.
- The non-streaming route carries the same `NativeToolCapability` guard the
  streaming one has (2026-09-06). `runEphemeralToolTurn` — Workshop, Studio,
  swarm workers, scheduler jobs — drives the structured loop through
  `completeMessages` with schemas attached, and on an Anthropic OAuth surface
  that reached the OAuth builder, which writes `body["tools"]`: the one request
  shape the capability predicate exists to keep off the Claude subscription
  connection.
- `response.incomplete` is a TERMINAL event in both OAuth-direct parsers
  (2026-09-06). Recognizing only `[DONE]` / `response.completed` / `.done` /
  `.failed` / `error` meant an output-limit stop looked like a cut transport:
  it threw `streamTruncated` and the reconnect ladder reissued the identical
  request to hit the identical limit. Its partial output is now a legitimate
  reply carrying a `[response incomplete: <reason>]` note — this lane returns a
  bare String and has no finish-reason channel — and the un-`done` function
  calls it cut mid-arguments are DROPPED rather than flushed with `{}`.

Regression looks like: a turn whose last trace row is `provider.requestStarted`
with nothing after it for more than ten minutes.

### 5. In-loop provider recovery (the reconnect ladder)

`ProviderRecoveryPolicy` in
`Modules/NativeAgentCore/Sources/ProviderRouting/ProviderRecoveryPolicy.swift`
(ProviderRouting, not ChatOrchestration, because Telegram deliberately does not
depend on the tool stack), with the wrapper-unwrapping half
`isRecoverableTurnFailure` in
`Modules/NativeAgentCore/Sources/ChatOrchestration/ProviderRecoveryPolicy.swift`.
Applied in `ChatOrchestration+ToolLoop.swift` (non-streaming `completeMessages`)
and `ChatOrchestration+StreamingToolLoop.swift` (streaming `streamMessages`).

PARTIAL COVERAGE (2026-09-06): the Anthropic / kimi_code text-compatibility
lane (`ChatOrchestrationClient+TextCompatibility.swift`, selected for chat,
Telegram, Slack and mobile whenever the provider is Anthropic-shaped) has a
REPLAY-ONLY ladder of its own, in the same file.

- What it covers: an attempt that failed with NOTHING on the surface — no delta
  flushed, and no tool dispatched (dispatch happens after the stream ends, so a
  failure during the stream has dispatched nothing this attempt). "Nothing on
  the surface" means nothing FLUSHED (2026-09-06): the condition used to read
  the raw accumulator, which counts the up-to-16-char tail the compatibility
  buffer is still holding back, so a provider that sent "Hello" and dropped had
  shown the user nothing and was still refused its replay — and the terminal
  branch then force-flushed that held text as the whole reply. The held-back
  buffer is DISCARDED on replay, like the streamed tool calls: the re-issued
  call emits its own bytes. Both failure
  shapes are classified on the TYPED error: `streamTurn` hands the error it is
  about to render to a string to a `streamFailureSink` (a sink, not a
  `TurnStreamEvent` payload, so no exhaustive switch on any surface changes),
  the loop stashes it per iteration, and the ladder classifies that — falling
  back to `LLMError.providerError(message:)` around the string only for a
  failure that carried no type. Before 2026-09-06 the string was all there was,
  so the commonest Anthropic drop of all — `LLMError.streamTruncated`, a clean
  EOF with no `message_stop` — arrived as prose the `.providerError` branch
  refused, and the ladder never ran on it. The thrown stream error is
  classified directly. The engine deliberately sinks NO type for its own
  "completed with no answer text" verdict: that stream ended cleanly, the
  empty-reply nudge owns it, and an identical replay is proven useless. Same
  `ProviderRecoveryPolicy.isRecoverableTurnFailure` verdict, same 10-per-call /
  20-per-turn budgets, same backoff and `Retry-After` rule, same
  `provider.retry` trace row and `provider_retry` notice, same
  "cancellation outranks recovery" ordering before and after the wait. The
  replay is `continue toolLoop`, which rebuilds the iteration-scoped
  accumulators and reissues the identical call — so a replay spends one
  tool-loop iteration out of the surface's cap. A replay that cannot get
  another iteration (the failure landed on the LAST one) is therefore never
  scheduled: no notice, no sleep, and the turn leaves through the exhausted
  path carrying the provider failure as its reason. Until 2026-09-06 it slept
  and then `continue`d off the end of the loop with `exhaustedToolLoop` unset,
  and the post-loop branch persisted the empty partial as `cancelled: true` —
  a provider drop shown to the user as a Stop the user never pressed.
- The exhausted reply on this lane carries the prose the user already watched
  render ahead of the exhaustion line (2026-09-06), the rule
  `finishExhaustedTurn` follows on the structured lanes. Before that, an
  exhaustion after narrated tool rounds persisted the fallback ALONE, so the
  narration vanished on reload. The composition reads `accumulated`, which
  absorbs EVERY round's marker-stripped prose as the round ends — a tool round
  before its dispatch, a call-free round at its final. It used to absorb only
  the call-free one, so it was empty after any narrated tool round and the
  composition it fed had nothing to keep.
- What it still does NOT cover: the CONTINUATION arm (an attempt that already
  streamed prose to the surface still persists the partial and ends the turn —
  there is no "continue exactly where you stopped" resume here), and
  `IntraTurnContextCompaction` in either direction (no pre-call measurement, no
  reactive context-overflow recovery; an overflow is not recoverable, so it
  falls through the ladder to the same terminal path as before). Both need the
  provider-call block in real attempt scope and a conversation handle only the
  append-only (`v2Prefix`) configuration has — still a rewrite of the loop, not
  a wiring change.

- Recoverable: `LLMError.transient`, `.streamTruncated`, `.providerError` only when
  its message carries the provider's own overload / rate-limit / 5xx words,
  `.invalidResponse` for 408/409/425/429/5xx, URLError timeouts and connection
  loss, and the transient phrase list Telegram's ladder also uses. Since
  2026-09-06 the status code is read out of the message too
  (`httpStatusCode(inDescription:)`: "HTTP 413", "status code 413", "status
  413" in the adapter's own prefix, "413 Request Entity Too Large") and
  classified by code whatever the error case, so recovery no longer depends on
  which adapter phrased the failure. The code must sit in HTTP or status-code
  context, or be followed by its own reason phrase: a `"status":503` field
  quoted inside a deterministic 400's body, and prose like "500 error records",
  are NOT statuses and no longer ride the ladder (second pass, 2026-09-06).
- Never recoverable: cancellation, `authRejected`, `notConfigured`,
  `modelUnavailable`.
- HTTP-description parsing and retryable-status classification remain internal
  to ProviderRouting's `ProviderRecoveryPolicy`; other modules use its higher-level
  policy APIs. The phrase matcher remains public for Telegram's retry ladder.
- Budget: 10 attempts per call, backoff 1, 2, 4, 8, 15, then 30 s; 20 recoveries
  per turn. A provider `Retry-After` (carried through
  `LLMError.rateLimited`'s ` [retry-after=Ns]` sentinel) wins when it is longer
  than the ladder's backoff. A wait the turn cannot afford ends the ladder with
  its own notice rather than a sleep past the budget (2026-09-06).
- Non-streaming: identical call, identical conversation.
- Streaming, nothing shown yet: identical call, partial discarded.
- Streaming, prose already shown: continuation. The visible partial is sent back
  as an assistant message with a "continue exactly where you stopped" user
  message on a local copy of the conversation. Shown text stays; the new
  deltas append. Neither message is persisted.
- Exhausted: the pre-existing `ProviderErrorAfterToolEffects` throw, which tells
  surface retry ladders not to replay the turn (tool effects present). When the
  ladder instead exits on the whole-turn budget, `finishExhaustedTurn` carries
  the attempt's visible prose ahead of the generic exhaustion reply, so text the
  user already watched render survives the reload (2026-09-06; before that a
  turn whose earlier round had tool calls persisted the generic reply alone).
  That rule now covers EVERY terminal line `finishExhaustedTurn` can pick
  (2026-09-06) — the no-progress stop and the protocol-violation reply too, not
  just the exhaustion fallback.
- Neither lane starts an attempt after the whole-turn budget is spent — the
  retry ladders and, since 2026-09-06, the non-streaming overflow-recovery
  re-issue too.
- A Stop that lands while a non-streaming call is in flight is re-read when the
  call returns, before its tool calls are parsed or dispatched (2026-09-06);
  the streaming lane already checked both signals at stream EOF.
- A Stop that lands DURING a batch stops the rest of the batch (2026-09-06).
  `runIterationDispatchGroups` polls both cancel signals before every dispatch,
  in the sequential slot and on every concurrent refill, so a Stop between two
  `write_file`s stops the second one. Slots the Stop reaches still emit their
  `onToolUse`/`onOutcome` pair and still produce a `tool_result`, because
  dropping one would leave a `tool_use` unpaired on the wire — their result
  says `status: cancelled`, not `failed`, and a dispatch that throws
  `CancellationError` gets the same shape rather than the generic failure
  envelope. A cancelled slot is then neither an EFFECT nor a FAILURE anywhere
  that grades the turn (2026-09-06): `ProviderErrorAfterToolEffects.effectfulCount`
  skips it (it used to count by tool name, so an undispatched `write_file`
  refused the turn a replay that was safe), the terminal trace's
  `failedToolDispatchCount` skips it, and `ChatToolOutcome.cognitiveResult` maps
  it to `unknown` instead of `failed` so a Stop cannot manufacture a
  low-confidence tool reflex.
- A Stop that lands during the LAST batch of a turn ends it as a CANCEL, not as
  exhaustion (2026-09-06). Both structured loops re-read the two cancel signals
  immediately after every dispatch round: without that, the loop fell out of its
  iteration range and left through `finishExhaustedTurn`, which records
  `.abandoned` and writes the generic "ran out of iterations" reply over the
  user's Stop. The streaming lane carries its visible partial through the throw,
  as every other Stop on that lane does.
- A Stop that lands after a dispatch STARTED is a third outcome (2026-09-06):
  `interruptedToolResult`, still `status: cancelled` and still not a failure,
  but carrying `effects_unknown: true`. Only the slots the Stop reached BEFORE
  they were handed to the dispatcher get the "was not run" receipt. Unknown
  effects are effects, so `effectfulCount` counts an interrupted call and the
  surface ladders will not replay the turn over it — before this, a
  `write_file` a Stop cut in half looked like a call that never happened.

Visibility: every retry emits a `provider.retry` trace row (attempt, delay,
reason, mode, recoveries so far) and a `.notice(kind: "provider_retry")` progress
event ("Reconnecting to the model, try N of 10"). Every chat surface already
renders notices whose kind contains "retry" as a retrying phase: the Mac turn card
(`MacChatTurnActivity.noticePhase`), Telegram's progress message
(`TelegramTurnPresentation`), and iOS through the iCloud runtime forwarder. A new
surface that consumes turn progress gets it with no extra wiring.

Slack (2026-09-07): accepted channel turns use one root-thread destination for
notices, final text, uploads, approvals and reconciliation; unthreaded DMs remain
unthreaded. The durable payload preserves the route choice across restart, with
legacy records retaining the prior destination. Session-map validation and
anchor adoption occur under one lock; damaged maps preserve their original and
a `.damaged` copy and refuse fresh bindings until repaired. Permanent attachment
failures prepare a durable explanatory reply (or prefix the answer when usable
input remains), so confirmed notice delivery settles the journal and allows
history to advance. HTTP 4xx attachment responses are permanent except
408/425/429. Those exceptions, 5xx and network failures remain claimed and
retryable without starting chat.

MCP UI (2026-09-07): effect-time allow, block and ask envelopes use the canonical
Security Center audit writer. Ask files through `NativeAgentChatApprovalFiler`
and returns the inbox ID; the existing chat-tool approval executor replays the
exact approved MCP tool and input under its durable one-shot execution claim.
The inner app dispatcher defers asks to that outer approval membrane when
autonomy enforcement is delegated; fresh hard blocks still prevent execution.

Slack (2026-09-06): the socket-mode loop passed NO progress callback and waited
for the whole reply, so a Slack turn spent its reconnect ladder or its
compaction in silence. `SlackSocketModeChatHandler` now takes a notice sink; the
loop posts one short message per notice KIND per turn, in the same thread
(`SlackSocketModeLoop.noticeSink`). One line per kind, not per notice — the
ladder can emit ten `provider_retry` notices and the channel gets one. The kind
is spent only by a notice Slack actually ACCEPTED (2026-09-06): a post that
throws or comes back `ok: false` gives the kind back, so one failed post no
longer silences that kind for the rest of the turn. Tool events are deliberately
not forwarded.

iOS notices (2026-09-06): the forwarder publishes a notice with `kind: "notice"`
plus its own `noticeKind` (`provider_retry`, `context_compaction`) into the KVS
key `chat_notice_latest` — its OWN latest-value key, not the `chat_progress_latest`
key that carries progress and tool events. Both are last-value-wins, so while
notices shared the progress key a tool event landing in the same sync window
replaced a reconnect or compaction notice before the phone ever read it, and the
kind was flattened to "progress" on the way out. The phone observes both keys and
renders a notice on the same status line as progress (`ChatStore.receiveICloudProgress`),
the way `TelegramTurnPresentation` renders `provider_retry` and `context_compaction`.
The same notice is ALSO mirrored into `chat_progress_latest` as `kind: "progress"`
(the only kinds a phone build predating the split admits), carrying the SAME
message id. A phone that reads both keys dedupes on that id and dispatches the
notice once; a phone that only knows the old key keeps receiving notices instead
of silently losing them.

Known limit, iOS KVS (2026-09-06, verified not fixed): both `chat_progress_latest`
and `chat_notice_latest` are ONE global last-value slot each, shared by every
paired device. The Mac writer replaces the slot (`iCloudBridge.sendKVSChatProgress`)
and addressing lives only in the payload's `targetSourceKey`, so with two paired
phones a notice addressed to one can replace the other's before it is read — the
second phone then drops the value it does find, because it is not addressed to it.
Scoping the key per device (`chat_notice_latest:<sourceKey>`) fits the KVS budget
(the store is capped at 1024 keys and the writer's own ceiling is well under it),
but it is a two-sided protocol change: a writer-only rename hides notices from
every phone that reads the old key, and the old-phone mirror that would fix that
lands back in the shared slot and can be clobbered exactly as before. It is
therefore deliberately NOT scoped today. With one paired phone the limit is
unobservable.

Regression looks like: a Telegram or chat reply that reads "provider failure after
N tool dispatch(es)" with no `provider.retry` rows before it in the day's trace.

### 6. Surface retry ladders

Telegram: `TelegramPollLoop.isRetryableChatHandlerError` in
`Modules/NativeAgentCore/Sources/TelegramBot/TelegramPollLoop+ChatProgress.swift`.
Whole-turn replay, only before any effectful tool ran. `readOnlyToolNames`
(`inner_state`, `agent_introspect`) do not count as effects.

Telegram session selection: `/new` (including `/start` and `/session new`)
and `/resume` finish their session-map mutation before ingress admits the
next update. Their reply sends and durable claim settlement remain in the
command task, so Telegram flood waits do not hold the poll loop.

Command tasks are registered atomically with creation in the turn coordinator
(2026-09-06). Shutdown closes admission and queue promotion, requests cancellation
of commands and turns, and waits for both before clearing in-flight ownership.
An uncooperative command can delay shutdown; it is never reported drained while
still executing. Session-mutation admission ordering remains unchanged.

Telegram approval continuations (2026-09-06): resolving an approval RUNS the
tool and only then hands the answer back as a continuation turn, and the record
is `resolved` from that moment, so a second `/approve` is refused as not
pending. The continuation is therefore durable —
`telegram/approval_continuations.json`, written before the turn is admitted
(`TelegramPollLoop+Approvals.swift`). On the first tick of a new process
(`replayApprovalContinuationsIfNeeded`) a continuation that never started is
replayed verbatim — the tool's result is inside the prompt, so nothing repeats —
and one that HAD started is not replayed, because its own tool calls would be:
that sender gets the acknowledgement plus a line saying the rest of the answer
was lost to the restart. Before this the follow-up simply vanished.

The record is a precondition, not a best effort (2026-09-06): if the initial
write fails the continuation is REFUSED before admission, and if the
`started: true` write fails the turn stops before it runs anything, because a
turn that runs while the record still reads `started: false` is replayed
verbatim after a restart and repeats every tool it called. Both paths tell the
sender to ask again; the second leaves the record in place, since a
never-started record is exactly what is safe to replay. The removal at the end
is awaited too — an unawaited removal could lose the race with process exit and
make the next start report a delivered answer as lost.

Ledger mutations keep the read, synchronous durable write, and cache update
inside one uninterrupted actor turn. Concurrent topic continuations cannot
replace another mutation with a stale copy that clears its started marker.

The Telegram update inbox holds one shared index-file lock across claim and
index mutations, always acquiring the index before an individual claim lock.
Recovery repair, first-index migration, and terminal pruning use that same
ownership, so concurrent topics cannot erase a recoverable update's index entry.

The work-card ledger separately holds storage ownership across initial loading,
durable saving, and cache publication. Upserts, removals, and restart reads
serialize through that owner even when the storage implementation suspends.

Approval recovery applies the current Telegram sender/chat allowlist before
sending a restart notice or scheduling a continuation. Records that are no
longer admitted remain on disk, paused until an admitted future restart.

### 7. The bridge (Claude and Codex lanes)

`Sources/NativeAgentApp/ClaudeBridge.swift`.

`ClaudeBridge.swift` retains authenticated transport/routing, message/tool
handling, connection state and response deadlines. `AppChatToolDispatcher.swift`
assembles the bridge chat and direct-tool stacks in their existing order and
injects the inner dispatcher into `ClaudeBridgeDenyDispatcher.swift`. That owner
provides only the external-MCP namespace fence and catalog projections (load/unload
input filtering, recursive result scrubbing/count projection, and list/schema
filtering); it owns no connection, memory or deadline state. TrustCenter and the
existing dispatch gates retain permission authority.

Outbound builder dispatch stays on `SwiftToolDispatcher`: `+CodexBridgeTools.swift`
owns message/wake submission, the Codex inbox directory-lock wait and bounded
`invoke_codex`; `+ClaudeBridgeTools.swift` owns message/wake submission,
`invoke_claude`, session-pointer lock waits/promotion and its cancellable
heartbeat. `+OMPBridgeTools.swift` owns OMP message/wake submission. All call
`+AgentBridgeTools.swift` for shared conversation/working-directory selection,
inbox deduplication/quarantine, replay guards and audit/run/wake receipts.
That shared extension also projects message IDs for all three lanes and selects
the legacy synchronous invoke cwd fallback for Codex/Claude; lane admission,
approval, allocation and launch ordering remain local. Async working-directory
trust checks and JavaScript wake lifecycles are unchanged.
Existing inbox, wake-job and session-pointer files retain durable state;
`SystemProcessAdapter` remains the wake subprocess lifecycle owner.
`DelegationStatusProjector.readSnapshot` reads source availability and decoded
job/delivery evidence in one epoch through `readDirectory` and `readDeliveries`.
Per-lane projectors require those decoded values and perform no fallback disk
reads. Existing wake files and delivery receipts retain authority and terminal
precedence; projection owns no durable state.
Core's `SwarmRuns` target remains linked through `ChatOrchestration` and retains
canonical swarm run state and lifecycle. It is not a separately selectable
package product; worker execution and recovery are unchanged.

`ChatSessionActiveTools.swift` and `HistoryWindowCursor.swift` retain independent
derived-state lifecycles, files, collection cadence and JSON cleanup. Both call
the stateless `ChatSessionLockSidecarCleanup.swift` helper for their second pass:
serial orphan lock-sidecar removal with the sibling rechecked under its
PersistenceCore lock. Active-tools declarations and history cursor advancement
remain store-owned; no canonical transcript, memory or retry authority moves.

`GitHubCommandCheckoutResolver` is internal to ChatOrchestration: Codex bridge
dispatch calls its stateless remote-verified checkout selection, and tests use
`@testable` access. The GitHub watcher never calls it.

`PersistenceCore/GitHubCommandStore.swift` retains sole ownership of GitHub
command append, reducer, replay, and durable state. It constructs/injects the
module-internal `GitHubCommandLiveStateMemo.swift` actor and supplies its replay
loaders and post-write projections. The memo owns only an eight-entry
insertion-order process-local cache and coalesced loader tasks, preserving
stamp matching, nil-stamp bypass, priming, counters, and cancellation on forget.
It adds no ledger, memory authority, turn recovery, or retry owner; GitHub
watcher and notification authority remain unchanged.

| Deadline | Seconds | On expiry |
|---|---|---|
| connection | 30 | drop the socket |
| enqueue ack | 30 | cancel before the turn starts |
| message work | 600 | answer 202 `still_working`; the turn keeps running |
| tool work | 300 | cancel that one tool call (bridge `/tool` endpoint only) |
| read work | 60 | state and read endpoints only |

Before 2026-09-05 the message-work deadline cancelled the task the turn ran inside
and killed it at ten minutes. Trace event `message_deadline_released` marks the new
behaviour.

### 8. Cancellation trace

`turn.cancelled` is fired at every `CancellationError` catch in
`ChatOrchestrationClient+StructuredChat.swift` and
`ChatOrchestrationClient+TextCompatibility.swift`,
payload `where`. A turn that ends without a terminal row and without
`turn.cancelled` is a hole to investigate. Two of those catches — the
`streamCancelled` partial-persistence branch and the bare cancellation catch —
were silent until 2026-09-06.

A Stop from the phone that names its run (`runId` on the `cancelChat` action)
is scoped: it cancels the registered task for that run and nothing else, and it
never writes the session-wide `cancelled.flag` — that marker is asynchronous and
belongs to the whole session, so a Stop landing as the next turn starts would
kill the wrong turn. When another run holds the session, or none does yet, the
run id is held as stop-requested in `MacSyncEngine` (5 min TTL, 64 entries) and
`registerActiveChatTask` cancels that turn the moment it registers — the Stop
can overtake its own turn's handoff and still land. Only an unscoped Stop (no
`runId`) writes the flag.

Provider-call telemetry has the same rule: both stream wrappers in
`LLMClient+Real.swift` re-check cancellation at stream EOF before recording
`.succeeded`, because a cancellation can resume `next()` with nil instead of
throwing and the in-loop check then never runs.

Bounded `invoke_codex` and `invoke_claude` processes share launch/cancellation
ownership. Stop before launch prevents spawning; Stop after launch kills the
identity-bound process tree. Termination still writes the audit and run receipt,
with cancelled effects marked unknown. A cancelled Claude session retains its
exact session ID in the audit for reconciliation; cancellation never proves
rollback or session creation. A fresh invocation promotes its resume pointer
only on uncancelled success, so Stop cannot install an uncreated UUID.
Pointer lock acquisition is bounded and never falls through to unlocked IO.
Failure before launch returns `session_pointer_lock_unavailable`; failure during
settlement leaves the pointer untouched and reports `sessionPointerStatus` with
the exact session ID and audit location in a successful invocation result.

Codex provider streams establish task cancellation before constructing the CLI
stream. The runner arms its deadline before handing stdin to a background writer;
a prompt larger than the pipe buffer cannot block stream construction.
Both provider runners settle cancellation independently of child exit and retain
process-tree ownership through a one-second TERM grace, identity-checked KILL,
and exit observation. Timeouts use the same shutdown owner.

MCP grants bind to the server's transport, endpoint, command/configuration, and
resolved executable path and SHA-256 contents. Direct interpreter launches also
bind the resolved paths and SHA-256 contents of local file operands, including
the server script and preload files. As of 2026-09-06, known local file options
for Node, Bun, Deno, Ruby, PHP and Bash include separate operands and inline
`--option=value` forms (plus attached short operands such as Node `-r/path`).
File URLs resolve to local paths before hashing. Changing those bytes invalidates consent
and retires the pooled process through the same identity comparison. `npx` and
`npm exec`/`npm x` additionally bind each package spec as written plus its exact
pinned version or the installed version read from that spec set's npm `_npx`
cache entry. This is offline, read-only evidence; no npm process or network
lookup runs. A cached version change invalidates consent and the warmer's
signature. All recognized npm exec/npx launches are `unpinned: true`: neither
version labels nor manifests prove the package's executable bytes and dependencies.
Partial resolution still binds known versions, but cannot authorize consent reuse.
The consent reader/writer expose this boolean for settings; missing legacy flags
decode as true. Unsupported env wrappers are likewise unpinned.
Unbound legacy grants do not
authorize execution. The shared consent reader validates that identity, and the
same dispatcher rechecks its captured identity against the uncached server and
the actual pooled process before dispatch. A binary replacement also changes the
pool specification, retiring the previous process. Read-tier automatic consent
and explicit Full Mac YOLO admission retain their existing policy.

MCP registry tool/resource counts retain truncation toward zero for representable
fractions. Nonfinite or out-of-range counts use the existing invalid-field zero
default instead of trapping during registry loading.

MCP subprocess crash generations are unique across server removal/re-addition.
Removed or reconfigured launches cannot publish crash backoff for a replacement.

Live MCP catalog cache keys include the registry root, server implementation and
query kind (plus an injected pool identity). Publication keys frame path and ID
separately. Equal server IDs in different registries cannot reuse cached catalogs.
As of 2026-09-06, subprocess pools are also scoped by canonical registry root.
Discovery validates the checked-out process against the same execution identity
captured for its cache key. Restart stops only that registry's server; app quit
stops every registry pool.

MCP consent mutations compare the exact server/tool fields as well as the legacy
combined key. A colliding grant fails without replacing another pair's row;
revoking an absent pair cannot revoke its colliding neighbor. Server IDs containing
the reserved `__` chat delimiter are omitted from advertised tools with a warning,
because the chat decoder cannot represent them without routing ambiguity.

HTTP and stdio MCP catalog discovery follow `nextCursor` before publishing a
complete tools/resources list. Malformed pages, repeated cursors and more than
1000 pages fail instead of publishing a partial catalog; cancellation is checked
before each page request.

OpenAI text streams and Moonshot streams use the same 4 KiB / 2 second
error-body drain as OpenAI tool streams. OpenAI OAuth, Anthropic text streams,
and xAI streams also use that exact-request two-second deadline; cancellation
propagates instead of becoming an HTTP failure. A stalled error body still reaches
HTTP status mapping; Stop cancels the request and remains cancellation.

Google connector reads distinguish rejected authorization from refresh or read
transport failures. Network failures, 429 and 5xx responses are retryable;
Stop remains cancelled and does not initiate a refresh or retried read.
Refresh commits use the sign-in/sign-out credential lock and compare the exact
credential bytes read before the request. A changed or removed connection
rejects the stale result before writing or using its access token.
A byte conflict is a typed retryable local failure; the next read reloads the
current credentials instead of reusing the rejected refresh result.

### 9. Context compaction

Two lanes, both mapped in detail so a wrong recollection can be traced to a line.

Exception, not a lane: the Telegram base `/compact` command runs
`TelegramSessionStore.compactSession` (its own summary, backup and rewrite;
its own summary and rewrite). Since 2026-09-07 it reads with the reporting
JSONL reader and refuses to compact when the read fails, a line is malformed or
the tail is torn, and its pre-compaction backup copy must succeed before the
transcript is replaced. It still lacks app chat compaction's distillation and
verified-backup contract below and must not be described as one owner with it.

**Cross-turn** (the persisted transcript). `ChatSessionAutocompactor` replaces
older rows with one `compaction_summary` row after a verified backup;
`ChatSessionAgingConsolidation` runs the same body in the background at a
quarter of the threshold; `ChatCompactionDistiller` rewrites the summary row as a
first-person recollection (its `distillSystem` prompt: chain in order, verbatim
lines that mattered, decisions with their why, open threads, corrections, the
emotional arc). All in `Modules/NativeAgentCore/Sources/ChatOrchestration/`.

- Threshold 200 000 tokens or 40 % of the model window; keep the newest 20 rows;
  aging at 25 % of the threshold. `nativeagent.compactionThresholdTokens`,
  `...DistillEnabled`, `...AgingEnabled` in UserDefaults.
- The prior recollection row is pinned: rendered first, always kept, truncated
  only to its own 12 000-character cap — and truncated from the TAIL, keeping
  the newest (2026-09-06). Before 2026-09-05 the distill prompt dropped it
  first whenever the replaced rows exceeded a fixed 96 000 characters, so a
  long session lost its whole earlier arc on the second pass.
- The MECHANICAL summary (the fallback that stands when no distiller runs) is
  one bounded rolling window, never over the same 12 000 characters: the prior
  recollection's tail claims at most two thirds and the newly replaced rows'
  tail takes the rest — the shape the in-turn fold uses. Until 2026-09-06 it emitted
  up to 24 000 (12 000 of prior note plus 12 000 of new rows) and the next pass
  read the row back head-first, so a repeated mechanical compaction threw away
  exactly the history it had just summarised. The cap covers the WHOLE stored
  value including its `[NativeAgent compacted N earlier message(s).]` header,
  which used to sit outside the budget and push the row past the length the
  next pass reads back.
- The aging lane never selects a replacement prefix that holds no raw turn
  (rewriting a recollection into one of identical coverage), and never one
  containing a summary still marked `distill: pending`. Before 2026-09-06 a
  backstop compaction that left one summary plus the retained tail scheduled
  aging, aging selected that lone summary, and the in-flight distillation
  landed on `row_missing` with its whole pass wasted.
- A summary-only history keeps its recollection: when projection produces no
  ordinary message (the backstop can retain only the current user row, which
  history reading excludes by run id) the recollection goes out as a user
  message of its own instead of the turn starting with no memory at all
  (2026-09-06).
- Budget scales with the distill model's window (45 % of the window in
  characters, floor 96 000, cap 600 000). Rows that still do not fit are
  distilled in chained passes oldest-first, the interim note pinned into the
  next pass, at most six passes, then the recency-biased single pass with the
  pinned note as the fallback.
- Distill model: the Providers "compaction" pin, else the turn model. 120 s per
  pass, enforced by `IntraTurnContextCompaction.withDeadline` so a
  non-cooperative provider cannot hold the pass open past it (2026-09-06). Any
  failure leaves the bounded mechanical summary standing: the prior
  recollection's tail gets at most two thirds of the body budget, and newer
  rows fill the remaining space from their tail. Older material can age out.
- Before each paid pass, the distiller checks that the exact destination
  summary row still exists. Missing/unreadable destinations stop further calls;
  the final locked swap still handles deletion during an in-flight call.
- A backstop compaction failure before context assembly no longer kills the
  turn: trace `compaction.backstop_failed`, the turn continues on the bounded
  history window, the aging lane retries later.

Trace: `context.compact.distill.v1` carries `distill.passes`,
`distill.promptCharsPerPass`, `distill.rowsOmitted` (0 in the normal case).

Regression looks like: `distill.rowsOmitted` above 0 on an ordinary session, or
a recollection that starts mid-story with no trace of the session's opening.

**In-turn** (the in-flight conversation of one tool loop; the transcript is never
touched). `IntraTurnContextCompaction` in the same folder, wired at both
provider call sites in `ChatOrchestration+ToolLoop.swift` and
`ChatOrchestration+StreamingToolLoop.swift`.

Both loops call `IntraTurnContextCompaction.compactProactivelyIfNeeded` for
the shared proactive pressure check, compaction and receipt publication.
The helper traces before awaiting the notice, publishes neither for mode
`none`, and returns pressure-branch entry even when nothing changed. Each
caller then rechecks its own wall-clock budget before incrementing the
provider-call count or starting another provider call. Cancellation, budget
exit, provider-round accounting, dispatch, streaming state and reactive
overflow recovery remain loop-owned. The helper mutates only the transient
conversation; persisted transcript, canonical memory and cross-turn
compaction retain their current owners.

- Measured before every provider call. Above 80 % of the effective window
  (characters at 3.2 per token; unknown model counts as 128 000 tokens) it
  compacts to 70 %. The effective window is the smaller of the model's window
  and the one whose 80 % point is the user's compaction threshold
  (`nativeagent.compactionThresholdTokens`, default 200 000), so a long tool
  loop on a 272k or 1M model still trims at the same 200k the transcript lane
  is set to. The transcript lane itself compacts at the smaller of that setting
  and 40 % of the window: on GPT-6 Astra (272k) that is about 109k tokens,
  aging from about 27k.
- Step one stubs every tool result before the last five rounds (180-character
  head plus a re-run marker). Step two folds this turn's older rounds into one
  assistant "working notes" message written by the turn model in first person
  (chain, decisions, what tools returned that still matters, open items, what
  I was about to do next) followed by one user continuation message. Distill
  deadline 60 s, mechanical fold as the fallback. The turn's request, the
  replayed prefix, and the last five rounds are never folded; no
  `tool_use`/`tool_result` pair is ever split.
- Step two renders the span as it stood BEFORE step one stubbed it (2026-09-06),
  so the distiller reads the renderer's full 600 characters of each tool result
  instead of the 180-character stub step one had just written over it. Only the
  array the provider sees is stubbed.
- A fold with NOTHING NEW in the span does nothing (2026-09-06): when the
  previous pass's note is all that is left there, the pass reports mode `none`
  rather than distilling the note from itself, and the overflow recursion widens
  the span instead. Before this, a repeated pass burned a model call and the
  mechanical fallback cut the surviving note to two thirds of the cap each time.
- Reactive: a provider context-overflow error
  (`ProviderRecoveryPolicy.isContextOverflow`: 413 or "prompt is too long",
  "context_length_exceeded" and friends) runs the same compaction under
  overflow pressure and re-issues the call. Under overflow the target is the
  smaller of the window target and 70 % of the refused body, the keep tail
  shrinks 5 → 2 → 0 rounds, and finally every remaining tool result is capped
  at 4 000 characters, so "nothing to trim" cannot end the turn while
  reducible content exists. Twice per call at most; counts toward the twenty
  per turn. On the streaming path only when nothing had streamed yet;
  otherwise the interrupted-stream path owns it. A Stop between attempts
  carries the visible partial like one inside the stream.
- Working notes are one bounded rolling window, never over 12 000 characters.
  The distiller gets the previous note pinned ahead of the newer steps and
  writes a fresh note. Without a distiller the fallback keeps the newest work:
  the last two thirds of the previous note plus the last third of the steps
  since, so a repeated mechanical fold loses the oldest material first and
  never the latest. This is recency retention by design, not preservation.
- Trace `context.intraTurnCompaction` (mode `stub` / `fold_llm` /
  `fold_mechanical` / `none`, chars before and after, trigger) and a
  `.notice(kind: "context_compaction")` line on every surface: "Trimming my
  working context to keep going".

Regression looks like: a turn that ends "provider failure after N tool
dispatch(es)" whose reason contains "too long" with no
`context.intraTurnCompaction` row before it.

## How to check it, one command

Turn traces live under the data root in `turn_traces/<date>.jsonl`, one JSON row per
event with `turnId`, `ts`, `kind`, `surface`. Group by turn and look at the last
kind:

- contains `context.intraTurnCompaction` then continues: piece 9 working as designed
- ends with a `turn.*` terminal row: normal
- ends with `turn.cancelled`: a stop, see `where`
- ends with `provider.requestStarted`: piece 4 regressed
- ends with `tool.dispatch`: piece 3 regressed, or the app was restarted
- contains `provider.retry` then continues: piece 5 working as designed

Diagnostics shows the same traces in the app.

## History

- 2026-08-27: whole-turn budget introduced at 180 s; raised to 600 s the same day
  after clipping real turns (p95 188 s).
- 2026-08-31: budget made progress-aware.
- 2026-09-04: read-only tools exempted from the "effects present" retry refusal.
- 2026-09-05: bridge deadline stopped cancelling turns; non-streaming wall timeout;
  `turn.cancelled` traces; in-loop recovery ladder with visible reconnect status;
  ceiling raised to 6 h.
- 2026-09-05 (later): distiller pins the prior recollection and scales with the
  window; chained passes; backstop failure no longer fatal; in-turn compaction
  with overflow recovery.
- 2026-09-06: compaction — mechanical summary is one bounded rolling window;
  aging refuses summary-only and pending-distill prefixes; a summary-only
  history keeps its recollection through projection.
- 2026-09-06: status codes classified by value, not adapter wording;
  read-only tools exempted on the text-compat error-event path too;
  the two silent cancellation catches now leave a `turn.cancelled` row.
- 2026-09-06: the text-compat ladder classifies the TYPED failure, not the
  string it was rendered to; its provider call binds the turn's remainder like
  the structured ones; a replay with no iteration left to run in exits
  exhausted with the failure as the reason instead of as a cancel.
- 2026-09-06: per-call provider wall bounded by the turn's remainder;
  `Retry-After` honored by both ladders; buffered OAuth SSE requires its
  terminal event; a Stop during a non-streaming call blocks its dispatches;
  exhaustion keeps the visible partial.
- 2026-09-06: a Stop mid-batch stops the remaining dispatches in that batch,
  and a cancelled tool call reports cancelled instead of failed.
- 2026-09-06: text-compat replay reads bytes FLUSHED, not bytes accumulated,
  and discards the held-back buffer on replay; its exhausted reply keeps the
  prose already shown.
- 2026-09-06: the pager's pages are bounded by their SERIALIZED size, so a page
  of escape-heavy or non-ASCII content no longer spills into another handle;
  the workshop's one-shot turn requires a completed reply to report completed.
- 2026-09-06: the completion wall claims its result before cancelling the call;
  a zero turn remainder no longer restores the full per-call wall, and both
  loops re-check exhaustion after proactive compaction.
- 2026-09-06: a Stop during the last batch ends the turn as a cancel, not as
  exhaustion; a dispatch the Stop interrupted after it started reports
  `effects_unknown` and counts as an effect; the exhaustion tail keeps the
  visible prose on every branch it can take.
- 2026-09-06: `waiting_approval` is not progress and not a fresh result — the
  budget stops renewing on it, the no-progress guard can see the repeat, and an
  identical pending request is not filed twice.
- 2026-09-06: the tool-dispatch deadline and the Workshop turn deadline use the
  resume-once gate instead of a task group, so the CALLER returns the moment
  its ceiling passes. The cancelled work itself may still be running: what the
  gate guarantees is that nothing waits for it. The deadline racer claims the
  gate BEFORE cancelling, so cooperative work that answers its cancellation
  cannot make an expiry look like a Stop; and once a Workshop session's
  deadline passes its artifact collector is closed, so a detached executor's
  later `workshop_artifact_write` is refused and the terminal receipt's
  `artifactPaths` stay true.
- 2026-09-06: intra-turn compaction distils from the pre-stub span, and a pass
  with nothing new to fold does nothing at all.
- 2026-09-06: a spill handle (`tool_result_page`) is not expired while its turn
  is still live, and reading a page renews it. The 30-minute clock ran from
  creation with no renewal, so a long permitted turn lost handles it had just
  been handed; a 6 h ceiling now bounds a scope whose turn never closed it.
- 2026-09-06: `streamTurn` refuses to START a call on a spent remainder, and
  the text-compat loop takes its exhausted exit on that refusal; the structured
  loops count a provider round immediately before making it; a cancelled slot
  counts as neither an effect nor a failure; `accumulated` on the text lane
  absorbs every round's prose, not only the call-free one.
- 2026-09-06 (providers pass): timeout config clamped finite; native Anthropic
  tool calls validated and released at `message_stop`; malformed and empty
  streams fail instead of finishing quietly; xAI reasoning and tool-argument
  frames count as liveness; Anthropic/kimi 5xx names its status so the ladder
  classifies by code; OAuth refresh 429s keep their `Retry-After`; the
  non-streaming route carries the native-tools capability guard.

## iPhone background recovery deadline

The silent-push recovery lanes share one absolute 25-second deadline. CloudKit
read waits are clamped to its remaining budget; status keys, query pages and
coalesced drains do not start after it expires. Snapshot fallback waits also
use the remaining budget. Successfully applied messages, pairing material and
status values update the completion gate immediately, so a later slow read
cannot turn a successful recovery into a watchdog `.noData` result. The gate
still calls UIKit exactly once. Ordinary foreground reads keep their existing
per-operation timeouts.

## Still open

- One unexplained death on 2026-09-05 (10:25 to 10:26:49, last row a tool end,
  no cancel row). `turn.cancelled` was not yet installed; the next one will show
  its `where`.
# MCP UI admission and trace credentials (2026-09-07)

`NativeClient.callMCPTool` retains pinned consent and evaluates SecurityCenter
with exact MCP identity, converted arguments, and `mcp_ui` origin immediately
before transport dispatch. Blocks (including unavailable policy) return blocked;
asks return needs_approval without execution. Consent does not override either.
Trace previews recursively redact credential fields before serialization and
bounding; the shared text scrubber also covers quoted and escaped assignments.
## 2026-09-07 delegation observation and mobile snapshot waits

Delegation status shares a process-local stamped delivery-ledger cache between
the status tool and outcome reconciliation. Display pages bound historical
candidate sorting; reconciliation retains every terminal identity, including
older settlement receipts. Replacement, truncation, malformed rows and missing
or unreadable files retain their distinct evidence/availability semantics.
iOS snapshot download waits suspend with cancellation-aware sleep before bounded
coordinated reads on a dedicated I/O queue. Timeout or cancellation returns no
replacement value, preserving the existing last-good publication rules.
# Release-gate execution (2026-09-07)

`script/test.sh --require-ios` collects every test-shard failure before refusing
release proof. `script/lib/test_gate.sh` owns bounded shell/Core process pools,
isolated fallback data roots, retained logs, counts and wall-time summaries.
Core builds its test bundle once; safe Swift Testing shards load that bundle
through Xcode's SwiftPM testing helper, avoiding SwiftPM's execution-time build
lock. ChatOrchestration, ProviderRouting and SelfImprovement remain serial.
StandingBots is explicitly included. Failed iOS runs retain their xcresult counts.
The engine's existing `providerRecoverySleep` seam still owns all three retry
waits; production timing, attempt budgets and cancellation boundaries do not change.
