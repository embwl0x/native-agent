# Turn resilience map

A turn that is working must never die. A turn that is stuck must be unstuck at the
stuck step, keep its work, and continue. The user should only ever see a failure
after every recovery is spent. User, 2026-09-05: "Their turn shouldn't be dying on them
while they are working."

This is the map of every clock, guard, and recovery in a turn, where each lives,
how to see it working, and what it looks like when it regresses. Read
[Anatomy of a Turn](ANATOMY_OF_A_TURN.md) first for the turn itself.

## The rule each piece follows

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
envelope after relaunch. A newly minted message or transaction remains a distinct
intentional request even when its action and payload are identical.
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
