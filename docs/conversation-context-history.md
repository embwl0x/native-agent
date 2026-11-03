# Conversation context stays as sent

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

Carried recollection compares `SnapshotTailOpLog.FileStamp` and reuses a prior
cursor only with a verified append checkpoint; its optional source carries the
cursor and completed recollections together, without a force-unwrapped cache entry.
Only a checked empty scan proves that this conversation has no recollection
of its own. Failed stats, reads, row decoding or frozen-donor validation stop
borrowing and reach history preparation as unavailable evidence. Carried rows
retain the donor's saved row identity; none is synthesized from text length.

Canonical history requires valid UTF-8 and complete JSON message rows in its
selected coverage. Damaged rows withhold that history and report
`invalid_encoding` or `damaged_history`; replacement characters and an alternate
parser cannot stand in for saved speech. A failed resident history read or
validation stops context preparation with `transcript_unavailable` and repair
owed before any previous-session handoff or provider call. A present malformed
provenance stamp withholds the row with its row identity and repair cause. Only genuinely
unstamped retained history uses the historical provenance reader.

Prompt and compaction budgets require the selected provider/model's verified
window. Missing window evidence is a Providers configuration failure; it never
selects the fixed small-window budget. Small verified windows retain that
budget as their explicit policy. Invalid saved context-window settings remain
unavailable until corrected in Settings. Custom size uses
`nativeagent.contextWindowTokens`, with an explicit `nativeagent.contextWindowMode`.

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
remains what the person said. Recall, search and compaction prose continue to
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
is not reconstructed. Tool receipts, assistant rows and recollections retain
their existing projections. Regenerate names the original user row explicitly,
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
Sent-context saves and compaction row edits share `ContactThread.editingRow`;
callers retain their locks and selection rules, while untouched bytes and
final-newline state remain exact.

Send a full block (a keyframe) when that replayed history has no full block,
or its model, provider or window differs, or the preceding row lacks complete-state
metadata (including legacy deliveries). The window identity comprises the
retained recollection row identities, so compaction folds start a new keyframe.
There is no replay-head cursor. The baseline comes only
from rows actually replayed; there is no independent cache of remembered context.
Helpers use the same metadata, delta selection, projection and budget accounting
with their own transcript and changing contact thread.
The composer ring and its page readout use the owner's measured fraction and
configured trigger, including the measurement source; they retain no separate
budget. The chat item's composer state exposes `context_compact_at_percent`,
`context_compact_at_tokens` and `context_measurement_source` beside that fraction.

Replay admission carries every retained row's rendered body;
projection gathers each role run before creating its immutable message.
Positive history limits never cap replay rows; nonpositive limits explicitly
disable history. Only the built request's measured fit at the configured
percentage of the detected window, capped at window minus the actual request
output allowance, folds old turns into recollection. The landing target is
capped by that same room. Before sending, measured input plus the selected
adapter's wire output allowance must fit the window. The adapter supplies the
allowance; a transport that sends no output-cap field explicitly declares zero
wire reservation. The ring and setting.get show the effective trigger. Character
and row pressure never discard a prefix. The retired local
`chat/prefix_window/*.json` files are untouched and unread. Leading
assistant/tool rows receive a historical header instead of being dropped.
Compaction pressure also counts that delivery mass, while its distiller still
receives only transcript speech and receipts. The prefix telemetry reports
`historyContextWindow` (the retained recollection identities),
`volatileFullBlockBytes`, `volatileDeltaBlockBytes` (the delivered block size,
equal to the full size on a keyframe), and `volatileKeyframe`. Existing
`wireItemDigests` remain the proof of the encoded input items.

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

Stored recollections enter history rendering and distillation without regex-based
semantic deletion. Rendering still applies its structural normalization and
budgets; it does not classify sentences as traits to remove. Any historical
meaning repair belongs to the recollection owner with explicit source evidence
and the original preserved, rather than a read-time rewrite.
