# Conversation context stays as sent

The conversation travels as its verbatim tail. The powering model's verified
default window is the only window; there is no Custom cap or early token-saving
threshold. `SessionContextMeasurement` sizes the composed request, using its
matching provider receipt's characters/input-token ratio or an explicitly
labelled 3.5-character estimate when that calibration is absent. The adapter
owns the response allowance. Missing window or unreadable sizing evidence is
unavailable and stops preparation.

`SessionHistoryTail` derives whole-turn checkpoints from the transcript snapshot
already admitted for replay and its existing row character counts. At each
multiple of half the input budget, the first whole-turn start whose cumulative
size from the transcript's start reaches that multiple becomes a checkpoint.
The grid uses the model-default window minus the adapter's response allowance
at the fixed transcript character ratio; changing provider calibration does not
move that grid. A run spanning several user rows cannot be split. The end of
prior history is also a whole-turn start, so a large prior turn can drop whole.

When measured input exceeds the available window, `fitSessionRequest` advances
over these checkpoints until the composed request fits. This drops one oldest
block in half-budget jumps, keeping its prefix fixed between jumps for unchanged
window, response allowance and sizing evidence. Selection is recomputed from the current
transcript on each turn, including after relaunch, clear, rewind or rewrite.
There is no boundary file, stored cut pointer, tail repair path or second
transcript read during fitting. An empty conversation has no checkpoints.
Final admission follows result pointer delivery; oversized current input can
still be refused. `context.tail.cut` records the checkpoint threshold, cumulative
dropped size, previous whole-turn-start size and before/after measurement.
Dropped rows stay on disk and remain reachable through existing transcript reads
and recall. Regenerate applies its original-question boundary before deriving
checkpoints, never including future rows. Saved-plan and uncalibrated readouts
use the same checkpoint mechanism over their one transcript observation.

Within one turn, `TurnToolResultPointers` visits oldest tool-result bodies only
when the complete request overflows. Each replaced body is written verbatim to
`chat/tool_results/<turn-hash>/<result-hash>.txt` before a one-line file pointer
replaces it in the provider context. Call IDs, error flags, calls, speech and
images keep their order. Native and text-marker transports share the typed
result boundary; marker encoding happens at request delivery. Resident and
helper rounds use this same mechanism. A failed save keeps the body and reports
the failure; if all eligible bodies are replaced and the request still cannot
fit, `context_window_exceeded` refuses it. `context.tool_result.pointer` records
body counts and measured size. No model is called to select, shorten or rewrite
history or tool results.

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
Earlier snippets exclude the row identities actually delivered by replay and the
recent-receipt strip, after replay admission and role handling.

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

Every provider uses one layout: stable system material, replayed history, then
the current user turn with its changing context as a leading text block.
`ConversationPrefixSeeding` lifts the full built dynamic block, including the
text-tool catalog appendix when present. It does not use a system-message
delivery ladder or `clear_at`.

The sent block lives in `metadata.sentTurnContext` on that user row in
`chat/messages/<session>.jsonl`. It records `block`, `keyframe`, `model`,
`provider`, `window`, the complete resulting `fullBlock` and the exact model-facing
`userText`. `fullBlock` is delivery metadata used to compute the next delta; it
is not replayed as an additional block. The row's `content`
remains what the person said. Recall and search continue to
read that content; they never treat delivered context as the person's speech.
Image pixels retain their current-turn-only delivery policy.

Sent-context metadata is optional replay evidence on initial resident turns,
helper startup and resident reseeding alike. Its owner logs a save failure
and continues with the in-memory seed; missing metadata makes a later turn
send absent context again. Ordinary transcript speech writes remain required.

On resident turn dispatch, the opening seed's locked metadata write runs
beside the provider request. It settles despite Stop and joins before tool
execution, reply settlement or a throwing exit releases the turn's transcript.
Reseeding joins the preceding write before starting the next one beside its
request. Neither request encoding nor provider admission reads the saved row;
the next turn's replay does. Helper startup retains its existing write order.
See the [turn timeline](ANATOMY_OF_A_TURN.md#measuring-the-work-before-the-model)
for the separate dispatch and bookkeeping timing receipts.

Structured replay emits the stored block followed by the stored words as
separate text blocks, preserving their bytes and block boundaries. Those
words bypass historical whitespace normalization, role caps and display
labels, which would rewrite an item already sent. A captionless image's empty
stored words produce no text block; nonempty words, including whitespace-only
text, keep their exact bytes and boundary. Replay never emits an empty text
block. Rows from before this
metadata existed keep their existing projection; missing historical context
is not reconstructed. Tool receipts retain their evidence projection; assistant speech stays whole. Regenerate names the original user row explicitly,
excludes the replaced turn from history, and updates only its delivery metadata.

The reader's bounded in-memory memo reuses decoding and the same pure
rendering only for identical line bytes, including delivery metadata. It does
not retain a session's selected history or replace a current transcript read;
exclusion and per-row budget decisions are made anew. Missing or unreadable
input cannot select retained rows. Bounds and timing evidence live in the
[turn anatomy](ANATOMY_OF_A_TURN.md#measuring-the-work-before-the-model).

The delta rule compares the built block with the preceding replayed complete
state, with no field-specific logic. Split both on blank lines (`\n\n`), treating
an empty block as zero paragraphs. Compare paragraph UTF-8 bytes, retain their
common prefix and suffix, and send one ordered replacement for the intervening
span. Its header states how many paragraphs to skip, remove and insert; removed
text is superseded. This carries returns to earlier values, removals, duplicates
and reordering. Inserted paragraph bytes stay unchanged. When the states are
identical, send no new leading block. Earlier deliveries are never rewritten.
Sent-context saves use `ContactThread.editingRow`;
callers retain their locks and selection rules, while untouched bytes and
final-newline state remain exact.

Send a full block (a keyframe) when that replayed history has no full block,
or its model, provider or window differs, or the preceding row lacks complete-state
metadata. The window identity is the first admitted row identity, so a tail cut
starts a fresh keyframe when no matching baseline survives. The context baseline
comes only from replayed rows. Helpers use the same delivery and replay rules.
The composer ring reports the last observed provider input against the model's
default window; missing usage remains unavailable.

Replay admission carries every retained row's rendered body;
projection gathers each role run before creating its immutable message.
Positive history limits never cap replay rows; nonpositive limits explicitly
disable history. A leading assistant or tool row receives an explicit historical
header. Prefix telemetry records `historyContextWindow`, `volatileFullBlockBytes`,
`volatileDeltaBlockBytes`, `volatileKeyframe` and exact `wireItemDigests`.

This removes the previous cross-turn divergence at the preceding user turn.
OpenAI's Responses/Codex cache can reuse an exact request extension; Anthropic
API and OAuth routes share previous/current conversation breakpoint placement,
within the four-marker budget after tools and system; native encoding maps
boundaries past omitted empty messages. Every Anthropic cache marker uses the
shared one-hour lifetime on both API-key and OAuth routes; placement is separate
from lifetime. Kimi Code and other
providers receive the same append-only context layout. Actual cache hits remain
provider evidence, not a guarantee: route/window changes, existing tool or image
projections, provider retention and other request changes can limit reuse.

The old `TurnVolatileArchive` sidecar reader/writer, pruning and retention loop,
system delivery rungs, and `clear_at` message flags, catalog capability and
adapter/header paths are removed. Existing sidecar files are left untouched and
are no longer read. Parts' `model.call` messages still accept a `system` role
(`ToolExecution+RunSandbox.swift`). Offered tools travel in the request tool
array; action discovery travels through app results. Dormant tool-change
declarations and deferred-loading carriers are removed.
The turn part, persona, memory content and built paragraph text are unchanged.

Source owners: `ChatSessionWork/SentTurnContext.swift`,
`SessionHistoryMessageProjection.swift`, `ChatTurnRuntime/ConversationPrefixSeeding.swift`,
`ChatOrchestration+SessionHistory.swift`, `ChatOrchestration+StreamingToolLoop.swift`
and `StandingBotModel.swift`.
