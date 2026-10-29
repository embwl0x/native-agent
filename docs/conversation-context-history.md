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
recent-receipt strip, after cursor admission and role handling.

Relevance preprocessing preserves message text, including leading bracketed
headings. Punctuation does not establish ingress provenance; the text-only
reader cannot remove framing without recorded metadata identifying it.
Recall queries use neutral recent user/assistant evidence and initial anchors;
English substring lists no longer label text as corrections or open work.

Carried recollection compares `SnapshotTailOpLog.FileStamp` and reuses a prior
cursor only with a verified append checkpoint; its optional source carries the
cursor and completed recollections together, without a force-unwrapped cache entry.

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
persisted cursor boundary and retained recollection row identities, so cursor
advancement and compaction folds start a new keyframe. The baseline comes only
from rows actually replayed; there is no independent cache of remembered context.
Helpers use the same metadata, delta selection, projection and budget accounting
with their own transcript and changing contact thread.

Cursor admission carries the replay bodies whose UTF-8 bytes it measured;
projection gathers each role run before creating its immutable message.
The public history builder admits its row budget before reading context, using
checked doubling for prefix and tail selection. Unsupported positive limits
throw `TurnHistoryError.unsupportedLimit`; nonpositive limits disable history.
Persisted cursor advance counters must be nonnegative representable integers.
Increment uses checked arithmetic; an invalid or exhausted counter throws through
the cursor owner without changing its stored bytes or claiming an advance.
Compaction pressure also counts that delivery mass, while its distiller still
receives only transcript speech and receipts. The prefix telemetry reports
`volatileFullBlockBytes`, `volatileDeltaBlockBytes` (the delivered block size,
equal to the full size on a keyframe), and `volatileKeyframe`. Existing
`wireItemDigests` remain the proof of the encoded input items.

This removes the previous cross-turn divergence at the preceding user turn.
OpenAI's Responses/Codex cache can reuse an exact request extension; Anthropic
API and OAuth routes share previous/current conversation breakpoint placement,
within the four-marker budget after tools and system; native encoding maps
boundaries past omitted empty messages. OAuth's segmented prefix permits a 1h
previous boundary; API markers use 5m. Kimi Code and other
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
