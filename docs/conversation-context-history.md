# A moment's context is sent once

What the agent perceives in a moment (the clock, recall, the capsule, recent
receipts) belongs to that moment. This public block leads the current user
message whole, is saved on that row and is never replayed; the next moment perceives afresh.
What the person and the agent said and did is the conversation, each exchange
with its time. Quiet never ends what they holds. A conversation is held whole
until the request reaches the input budget; then the oldest whole turns go in
half-budget jumps. The input budget is min(model window minus response allowance,
200,000 tokens). History fitting uses the input budget; refusal and result
pointers use model window minus response allowance, the physical limit.
Older words are reached through the existing leads and
`context.expand`.

Every provider uses one layout: stable system material, held conversation
history, then the current user turn with its public context block as a
leading text block. A held private choice precedes that public block only in
live provider input; its owner remains conversation scratch.
`ConversationPrefixSeeding` lifts the full built dynamic block, including the
text-tool catalog appendix when present. It does not use a
system-message delivery ladder or `clear_at`.

The sent block lives in `metadata.sentTurnContext` on that user row in
`chat/messages/<session>.jsonl`. It records `block` (the public moment block the
model received), `model`, `provider` and the exact model-facing `userText`.
Private working-memory words are excluded; size receipts include their byte and
character counts. `block` is kept as evidence of the public moment; no later
request carries it. No other key in a saved `sentTurnContext` is read. The
row's `content` remains what the person said. Recall and search continue to
read that content; they never treat delivered context as the person's speech.
Image pixels retain their current-turn-only delivery policy.

Sent-context metadata is evidence on initial resident turns, helper startup and
resident reseeding alike. Its owner logs a save failure and continues with the
in-memory seed; a row without it replays its transcript words. Ordinary
transcript speech writes remain required.

On resident turn dispatch, the opening seed's locked metadata write runs
beside the provider request. It settles despite Stop and joins before tool
execution, reply settlement or a throwing exit releases the turn's transcript.
Reseeding joins the preceding write before starting the next one beside its
request. Neither request encoding nor provider admission reads the saved row;
the next turn's replay does. Helper startup retains its existing write order.
See the [turn timeline](ANATOMY_OF_A_TURN.md#measuring-the-work-before-the-model)
for the separate dispatch and bookkeeping timing receipts.

## The exchange and its time

Replay sends each held row's words (a user row's sent `userText` when present)
without historical whitespace normalization, role caps or display labels,
which would rewrite an item already sent. A replayed user row opens with its
own absolute local time from the row's `createdAt`, on its own line before the
words: a bracketed weekday, full date, time of day and time zone. The time
comes from the saved row, so its bytes are the same on every later call; a
time-zone change rewrites the cached history once. An unreadable time shows no
time. Tool receipts retain their evidence projection, replayed as `[Earlier call]` records and never as call-shaped JSON, which the model imitated as text instead of calling; assistant speech stays
whole. A leading assistant or tool row receives an explicit historical header.
Replay never emits an empty text block. Regenerate names the original user row
explicitly, excludes the replaced turn from history, and updates only its
delivery metadata.

A replayed message is one text block. Rows that share a role are joined with a
blank line into one block, so an exchange is two blocks: the person's message,
and the agent's reply with its tool receipts. The reason is the cache. A
request's bytes through the end of the exchange before the current one stay
identical in the next request, while the current message's leading block is
not replayed, so that is the last byte-stable boundary. Anthropic finds a
cached prefix only within about 20 content blocks back from a marker. The
Anthropic API and OAuth routes share previous/current conversation breakpoint
placement, within the four-marker budget after tools and system; the previous
marker sits at the boundary before the current user message. With one block
per message, the boundary the last request marked is always two blocks behind
the next request's previous marker, however many tool rows a turn had. Native
encoding maps boundaries past omitted empty messages. Every Anthropic cache
marker uses the shared one-hour lifetime on both API-key and OAuth routes;
placement is separate from lifetime. OpenAI's Responses/Codex routes, Kimi Code
and other providers receive the same layout. Actual cache hits remain provider
evidence, not a guarantee: route/window changes, existing tool or image
projections, provider retention and other request changes can limit reuse.

## The conversation is held

Quiet never ends what they holds. A conversation is held whole until the request
reaches the input budget; then the oldest whole turns go in half-budget jumps.
The input budget is min(model window minus response allowance, 200,000 tokens).
History fitting uses the input budget; refusal and result pointers use model
window minus response allowance, the physical limit.
Missing or unreadable times affect only the displayed timestamp, never selection.
History only appends between checkpoint jumps; the provider's cache lifetime
does not decide what the conversation holds.

`SessionHistoryMessages.admission` admits the whole selected transcript. Every
caller (the live turn, helper turns, saved-plan sizing and the composer ring)
uses that admission without a clock argument.
Replay admission carries every held row's rendered body; projection gathers
each role run before creating its immutable message. Positive history limits
never cap replay rows; nonpositive limits explicitly disable history.

## Older words are reached: leads

Every composed request selects leads only from rows outside its held replay and
recent receipts. `SessionReplaySpec` binds one transcript, raw query and checked
relevance budget in memory. `ConversationPrefixSeeding.seed` applies the renderer's
one ranking rule to that snapshot, excluding the identities in the request's
actual replay bodies and recent-receipt strip. Each fitting cut therefore makes
its dropped words eligible before the rebuilt request is measured; the measured
size includes its leads. No transcript is reread and no lead selection is saved.
Up to four leads ride the now-block, each with its
time, its role, at most 400 characters (`packetAtomExpandThresholdChars`) and
`[context.expand history:<id>]`, which opens the saved row across conversations.
An exact history id is not constrained by the serving conversation; offered
context atoms retain their turn-generation scope. The
[tool contract](TOOL_LOADING.md) owns history-reference argument binding and
unreadable coverage. Beyond the leads,
the agent reaches older words itself: it opens the conversation, recalls, or
asks. What it still owes rides its intentions in the now-block.

## The input budget and the physical limit

Quiet never ends what they holds. A conversation is held whole until the request
reaches the input budget; then the oldest whole turns go in half-budget jumps.
The input budget is min(model window minus response allowance, 200,000 tokens).
History fitting uses the input budget; refusal and result pointers use model
window minus response allowance, the physical limit.
`ContextBudgetPolicy.inputTokens` owns that budget for live fitting, saved-plan
sizing and uncalibrated readouts. `ContextBudgetPolicy.physicalInputTokens` owns
the physical limit for result pointers and final admission. The 200,000-token
budget bounds held conversation, not what current input may send.
`SessionContextMeasurement` sizes
the composed request, using its matching provider receipt's characters/input-token
ratio or an explicitly labelled 3.5-character estimate when that calibration is
absent. The adapter owns the response allowance. Missing window or unreadable
sizing evidence is unavailable and stops preparation. The composer ring reports
the last observed provider input against the model's default window; missing
usage remains unavailable.

`SessionHistoryTail` derives whole-turn checkpoints from the whole transcript
already admitted for replay and its existing row character counts. At each
multiple of half the input budget, the first whole-turn start whose cumulative
size from the transcript's start reaches that multiple becomes a checkpoint.
The grid uses half the shared input budget at the fixed transcript character
ratio; changing provider calibration does not
move that grid. A run spanning several user rows cannot be split. The end of
prior history is also a whole-turn start, so a large prior turn can drop whole.

When measured input exceeds the input budget, `fitSessionRequest` skips directly
to the first checkpoint whose remaining row-body characters can fit alongside
the non-history request. It projects and measures that suffix, advancing only
if the complete request still exceeds the budget. Saved-plan and uncalibrated
readouts use the same skip. The initial full admission, projection and size
observation each happen once; skipped checkpoints construct no messages and
perform no request measurements. This drops one oldest
block in half-budget jumps, keeping its prefix fixed between jumps for unchanged
window, response allowance and sizing evidence. Selection is recomputed from the current
transcript on each turn, including after relaunch, clear, rewind or rewrite.
There is no boundary file, stored cut pointer, tail repair path or second
transcript read during fitting. An empty conversation has no checkpoints.
Final admission follows result pointer delivery; oversized current input can
still be refused at the physical limit. If the request without replay fits the
input budget, a long chat reaches at most 200,000 measured input tokens (or the
smaller physical limit), including required context and leads. Whole-turn jumps
can leave spare room. If current input and required context alone exceed the
input budget, history can drop entirely and the request can still use the
physical limit: a 300,000-token attachment or turn on a 1,000,000-token window
fits when its complete measured input plus response allowance fits that window.
It is neither refused nor turned into result pointers merely for crossing
200,000. `context.tail.cut` records the checkpoint threshold, cumulative
dropped size, previous whole-turn-start size and before/after measurement only
when the head differs from the last successful request's observed head on this
route. `provider_usage.json` retains that head from the existing prefix receipt;
it is diagnostic evidence and never selects replay. Without that observation,
movement is unknown and no cut event is emitted. No new boundary store exists.
Dropped rows stay on disk and remain reachable through existing transcript reads
and recall. Regenerate applies its original-question boundary before deriving
checkpoints, never including future rows. Saved-plan and uncalibrated readouts
use the same checkpoint mechanism over their one transcript observation.

Within one turn, `TurnToolResultPointers` visits oldest tool-result bodies only
when the complete request exceeds the physical limit. It delegates retention
and the bounded view to `ProviderToolResultPage` / `ProviderToolResultRecoveryStore`, the same
owner as live results and dispatch previews. Each replaced body is written
verbatim to `chat/tool_results/<turn-hash>/<result-hash>.txt` before its pointer
replaces it in the provider context. The pointer names its live `result_handle`,
`result.page` continuation and `saved_result_path`; the file remains with chat
after turn-scoped handles are released, including across app restart.
Call IDs, error flags, calls, speech and
images keep their order. Native and text-marker transports share the typed
result boundary; marker encoding happens at request delivery. Resident and
helper rounds use this same mechanism. A failed save keeps the body and reports
the failure; if all eligible bodies are replaced and the request still cannot
fit, `context_window_exceeded` refuses it. `context.tool_result.pointer` records
body counts and measured size. No model is called to select, shorten or rewrite
history or tool results.

## What the history is not

No transcript compaction, digest, carried recollection, working-note, handoff
or aging-consolidation pass runs. Their writers, readers, prompts, settings,
manual commands and maintenance sweep are removed. An existing summary row is
an ordinary saved row: its kind neither hides it nor changes the rows after it.
It has no privileged replay or dream interpretation. No legacy summary store is
read. `ConversationHistory` retains exchange pairing, provenance, experience
identity resolution and the dream consumption mark; those duties do not write
or replay summaries.

Launch recovery and stale-row repair share one locked, validated transcript
observation. Its sidebar preview and row stamp come from the latest conversational
row, including an empty caption; absence clears both. A repaired preview advances
the transcript generation before acknowledging the recovered transcript version.

Tool history renders receipt-aware evidence at its actual rendered length;
the context budget has no separate per-tool-row cap. Replay and the bounded
recent-receipt strip reconstruct saved evidence through
`ChatTranscriptEvidenceRendering`, retaining their separate presentation limits.

Relevance preprocessing preserves message text, including leading bracketed
headings. Punctuation does not establish ingress provenance; the text-only
reader cannot remove framing without recorded metadata identifying it.
Recall queries use neutral recent user/assistant evidence and initial anchors;
English substring lists no longer label text as corrections or open work.

Canonical history requires valid UTF-8 and complete JSON message rows in its
selected coverage. Damaged rows withhold that history and report
`invalid_encoding` or `damaged_history`; replacement characters and an alternate
parser cannot stand in for saved speech. A failed resident history read or
validation stops context preparation with `transcript_unavailable` and repair
owed before any provider call. A present malformed
provenance stamp withholds the row with its row identity and repair cause. Only genuinely
unstamped retained history uses the historical provenance reader.

Prompt preparation reads its provider/model from the admission on the turn it
serves through `ContextBudgetPolicy.resolve(turn:dataRoot:)`. Its ingress admits
that turn before preparation, including fresh Desk synthesis; preparation cannot
choose a route or reconstruct one from its output context. Structured replay and
earlier snippets require the same resolved budget, with no optional-window
overload. `ContextBudgetPolicy` retains its memory, packet, capsule and relevance
allowances; it no longer defines a compaction-summary allowance. Speech rows
are not clipped or whitespace-normalized for replay.

Retained receipt replay labels an absent recorded outcome `unknown`; transport
`ok` cannot establish execution status. Encoding failures preserve unavailable
receipt evidence and their cause rather than empty results or zero byte counts.

One-shot session directives use checked reads and validated creation times.
Only absence, expiry or a delivered stamp means no pending directive. Provider
acceptance stamps delivery durably; a failed stamp remains owed and reports its
failure. Retired Jev advisory fields and the old `session_search` handoff grammar
are removed after read-only confirmation that none remain on this installation.

The reader's bounded in-memory memo reuses decoding and the same pure
rendering only for identical line bytes, including delivery metadata. It does
not retain a session's selected history or replace a current transcript read;
exclusion and per-row budget decisions are made anew. Missing or unreadable
input cannot select retained rows. Bounds and timing evidence live in the
[turn anatomy](ANATOMY_OF_A_TURN.md#measuring-the-work-before-the-model).

## Receipts

`context.history.summary` counts `history.heldRows` and `history.reachedRows` at
whole-transcript admission, before input-budget fitting, beside
`prefix.replayedTurnCount`. The assembly-time `history.earlier.leads` count is
removed: leads belong to each composed request, after its replay selection.
`context.history.fit`
reports `history.heldRows` for rows with delivered replay bodies and
`history.reachedRows` for admitted rows outside those bodies after fitting,
alongside the selected head and measured input budget. Empty bodies carry no
words; a missing fitted snapshot emits no fitted-history claim.
`context.request.fit` reports the complete final `inputTokens`, the history
`inputBudgetTokens` and `physicalInputLimitTokens`; only the physical limit
decides its `ready` or `refused` status. An accepted request can exceed the
history budget when current input requires it.
Prefix telemetry records `historyContextWindow` (the first held row's identity,
which the Doctor's recollection exemption and refit detection read) and exact
`wireItemDigests`.

The old `TurnVolatileArchive` sidecar reader/writer, pruning and retention loop,
system delivery rungs, and `clear_at` message flags, catalog capability and
adapter/header paths are removed. Existing sidecar files are left untouched and
are no longer read. Parts' `model.call` messages still accept a `system` role
(`ToolExecution+RunSandbox.swift`). Offered tools travel in the request tool
array; action discovery travels through app results. Dormant tool-change
declarations and deferred-loading carriers are removed.
The turn part, persona, memory content and built paragraph text are unchanged.

Source owners: `ChatSessionWork/SentTurnContext.swift`,
`SessionHistoryMessageProjection.swift`, `SessionHistoryTail.swift`,
`SessionHistoryPromptRenderer.swift`, `ChatTurnRuntime/ConversationPrefixSeeding.swift`,
`ChatOrchestration+SessionHistory.swift`, `ChatOrchestration+StreamingToolLoop.swift`
and `StandingBotModel.swift`.
