# Whose conversation a session is

The creator declares `threadKind` on the canonical `chat/sessions.json` row.
Every reader asks `Transcripts.SessionConversation`, over a `ChatSession`, a
session ID, or a previously loaded index. IDs locate records; their spelling
does not decide whose conversation they are. Historical readers include the
existing retention archive index; this adds no durable store. Single-ID reads
reuse a process-lifetime cache of parsed indexes keyed by file path and stamp;
a changed `SnapshotTailOpLog.FileStamp` causes the index to be read again.
Failed inspection cannot authorize a cache hit; index reads retain their symlink behavior.
Every new empty session records `transcriptGeneration: 0`; the canonical
message transaction advances it on append or rewrite. Restoring a retained
session keeps its existing generation rather than declaring it new.
Mac selection remembers the anchor already published by `TranscriptsFacade`
only when the conversation is actually selected, with no synchronous
anchor/index read on MainActor. Creating a room only publishes its row; quiet
`chat.new` never marks an anchor followed or changes the visible selection.
The person's New Chat records the anchor after selecting its new room. Simple
records a moved anchor only when that conversation is selected or already visible;
failed or superseded navigation leaves it available to follow.
Launch's permission-card anchor reads also run off MainActor. A failed navigation
refresh retains its prior publication and issue; selecting a room does not
reinterpret that unavailable read as a missing anchor.
Mac conversation lists draw the [session faces](designs/separate-face.md#stage-one-conversation-lists).
The index, pins and anchor remain engine command state; the window reads finished
row slots and ordered identity sections. Unread metadata does not hide a committed
room, and an unknown message count does not establish an empty conversation.
An archive row whose transcript path or bytes are unavailable refuses restoration;
only a missing archive row permits creation of a new session. Manual archive uses
the same index → transcript → archive transaction as retention: durable cold bytes
and `messagesArchivePath` precede hot-index removal, then the hot transcript goes.
A positively indexed empty conversation gets an empty archived transcript;
unreadable or missing known nonempty bytes refuse archival. Contention leaves it
hot. An interrupted manual archive reuses its identical cold bytes and locator
before completing index removal. Existing locator-free archives are not repaired
automatically. Clear changes the
canonical `chat/messages/<id>.jsonl` only; compaction backups and archived originals
remain retained evidence, never a second nested transcript cleared on its behalf.
Peer provenance, dreams, cares, capsules and moment recall pass their owning
app's data root into this read, including when another app data root is active.
Dream gathering excludes own-work and helper-owned sessions, and reads the
writer's mechanical provenance before selecting exchanges. Replies enter only
with an admitted origin, joined by run ID or by the preceding origin on legacy rows.
A reply newer than the watermark retains its admitted origin even when that
origin predates the watermark; wholly consumed exchanges remain excluded.

| Kind | Meaning |
|---|---|
| `direct` | The person's private conversation with them, through any door |
| `channel` | A room or thread with other people |
| `agent` | Their conversation with another agent or one of their helpers |
| `builder` | The agent's own work: its mind stream (`mind`, titled Thoughts), lines and workers; no person is in it |

`NativeAgentShared.ChatThreadKind.isPersonConversation`, `isPeerConversation` and `isOwnWork` are
the shared questions. A stored `legacy` kind, like a row without a kind, reads
as the effective kind an unambiguous recorded source proves: recognized app
sources are `direct`, agent bridges are `agent`, and worker sources are
`builder`. A mixed-purpose transport source (Telegram, Slack) proves nothing
without creator evidence, so such a row stays unclassified (`legacy`).
`ephemeral` remains readable as diagnostic traffic. An unknown ID or
unavailable index proves no kind.
Without a mounted recipient or explicit reply route, live delivery reads this checked declaration: `builder`, `agent` and `ephemeral`
conversations owe no human delivery. Missing ownership and unavailable routes in human conversations keep their exact-run repair debt
([turn delivery](ANATOMY_OF_A_TURN.md#6-the-answer-settles-once)).

Helper-only policies need the helper owner as well as the common `agent`
kind. A helper writes its exact `helperID` on its session. Admission calls
`SessionConversation.checkedIsHelper`; unavailable index reads throw before
choosing resident or helper behavior. A successfully read index with no owner
is distinct from an unreadable index. The row evidence lets peer turns retain the resident's glance and
context while helper loops remain independent. Routing a particular helper
uses the helper owner's locator inverse, `BotDefinition.id(forSession:)`;
this is identity resolution, not conversation classification.
That lookup reads only the resolved owner's definition, with no all-definition
ownership map or cache; damage in another helper cannot block this conversation.
Composer controls and quiet reads take helper routing, model menus, effort and
Fast facts from the provider owner's checked session presentation. A recognized
helper with an unavailable definition keeps its unavailable helper contract.
Missing presentations disable model/effort controls; only a checked resident
presentation admits pending picks and model, effort or Fast writes to Chat defaults.
Phone ingress, steering, memory and caring policies, composer controls and
the resident glance use that checked ownership boundary. Failed ownership
inspection withholds the dependent work and reports the index's cause; it
never becomes a resident conversation.

A conversation on screen is the saved conversation with the live turn over it.
`saved` is the last read of the store (rows with their cards); only a read writes
it, and a mounted conversation reads when its file changes, whoever wrote it.
`live` holds the rows the turn owns (the optimistic request, the streaming reply,
an unsaved notice), each under the id the store will save it with. While its turn
leads, a live row is drawn over its saved copy (a resumed reply over the partials
it replaces); when the turn settles, the row leaves the moment the store holds it.
A row the store never takes stays until a newer completed reply lands. No turn
refreshes a view, so Stop or a cancelled task can never hide what was saved.
The Mac document reserves the running reply's word block before the first
chunk, so the same row keeps its growing text across document reprojections.
The Mac's built groups carry the structural revision they were actually built
from. Its existing block cache compares that revision and row ids rather than
whole message values on unchanged updates; cards, face inputs and authored
words still invalidate their blocks. A new session gets a new block cache.
Content edits advance that same revision and invalidate pending group reads,
including a tool result or corrected reply in the last row. Only the turn
owner's current streaming reply may update its tail box without advancing the
revision; chunks do not compare or regroup the whole message array.
Raw-row doors retain value identity because they have no owner revision.

Phone transcript snapshots prepare cards and attachment previews through the
plain projection reader, without publishing saved rows into a Mac screen slot.
Row faces and tool-fold facts are prepared off main; the presentation owner
alone publishes authored words. Pin and anchor reads likewise finish off main
before their navigation owner publishes through `LatestRead`.
Pin, unpin, pruning and publication verification also perform their complete
storage operation on serial `VolumeIO`, including decode and durable save.
Pin and pruning read the durable list inside that operation, so concurrent
callers do not replace it from a stale navigation copy. Equal pin lists do not
write; unchanged pin and prune operations request no phone publication.
The navigation owner publishes completed writes through
`navigationRead.write`; failed storage leaves the previous pins visible.
Detached-window creation waits for its pin to commit before opening or persisting
the panel. Phone unpin uses the same close owner and keeps its existing reply fields.
An I/O deadline ends only the caller's wait; an issued write can finish later.
That outcome is unconfirmed until the navigation owner's next read reconciles
the file. It never authorizes replay from an old list.

Today is a reader of conversations, not their screen owner. It uses the open
conversation's in-memory rows without loading that conversation from disk;
other conversations use the existing plain transcript read, without publishing
saved rows, building cards or decoding thumbnails. Whole-file transcript
reads and JSON decoding run off the main actor, including mirror-card reads.
Displayed image previews share one thumbnail per inspected attachment file
identity (device, inode, size, mtime and ctime), with only that path's current
identity retained. Missing or uninspectable files supply no preview and no
cache hit; a changed identity is decoded on its next read.
The shared preview cache retains at most 128 entries and 16 MiB of PNG bytes,
evicting least recently read paths before insertion. A preview larger than the
byte limit serves its current read without entering the cache. These bounds
cover cache retention; a displayed transcript holds its own preview values.

Only the creator corrects a kind its older writer recorded incorrectly.
For Telegram and Slack, `SessionConversation` reads historical hot and archived
rows with the creator's current declaration from `source` plus `sourceKey`:
Telegram positive private chats are direct, groups/topics channel; Slack DMs
are direct and other rooms channel. This takes precedence over an obsolete
recorded kind, without rewriting data or classifying by session ID. A row
without that creator evidence keeps its recorded kind. Telegram and Slack
alone prove no kind: a missing or legacy kind without a usable creator key
stays unclassified.
Helpers first restore any retained archived row and transcript under the
session-index transaction, then correct kind and ownership when opening their
session; a contact corrects its exact owned
session on its next write, never an arbitrary conversation it was asked to
answer in. The mind stream declares `mind` as `builder` before each thought
(`Agents/MindStream.swift`). There is no manual rewrite of installed data.

An own line (`agent.job` with `agent: "self"`) uses the `chat` surface, chosen
by `Agents/OwnLineDoor.swift` where its conversation is minted. Its arriving
message's origin, request and turn envelope all carry `chat`, which has a
Context Flow persona kernel. The declaration derives its source through
`ChatThreadKind.transcriptSource(surface:)`, so the index and message rows
both carry `app`. The recorded `builder` kind identifies their own work; the
job ID locates the conversation. New and resumed turns use that same surface.
Resuming does not redeclare or repair saved rows; historical source and origin
values remain as recorded. Only arriving messages have origin metadata;
replies carry the turn envelope and transcript source.

Only a `direct` row may be the conversation anchor or appear in the person's
conversation column. Publishing before a row exists uses the creator's
declared kind; reading an existing pin requires its row. Opening a helper
from the phone declares that helper's row before anchor publication. A
message arriving through another door never changes an existing row's kind.
Automatic Mac selection in Simple and Advanced chooses a live direct row,
preferring the anchor, then a valid saved/current direct row, then an existing
direct conversation or a newly created one. Helpers stay selected only through
an explicit choice in the current launch; automatic moves do not mark a user
choice. Removing or archiving the selected row uses the same resolver.
Anchor publication preserves the accepted intent's activity time across awaits
and detached writes, rather than stamping lock acquisition. The pin retains
full activity precision as well as its ISO timestamp; older publications cannot
replace newer activity, including activity in the already anchored session.
Mac composer activity, the phone, Siri and the owner's private Telegram chat
publish the anchor. Slack declares conversation kinds but does not publish it.
Mac messages and New Chat settle anchor publication separately from successful
chat acceptance. A publication write failure keeps its cause in a dismissible
notice and warns that other surfaces may still open the preceding conversation;
it does not reject the accepted message or erase the new session.

Navigation, retention and phone publication read one ordered durable pin list,
`chat/pinned_session_ids.json`, alongside the separate `chat/anchor_pin.json`.
There is no persisted defaults copy or union of pin authorities. An absent pin
file is an empty list; an unreadable or malformed file preserves the current UI
publication, reports its cause and halts retention. Navigation watches the pin
file itself. `ChatSessionNavigation` carries the resolved pin and anchor flags
to the phone; it does not introduce another pin store.

History search accepts one explicit scope (`all_sessions`, `current_session`,
`previous_session`) and sort (`relevance`, `oldest`, `newest`). It never widens a
weak search into another scope. Unresolved current/previous scope returns
`status: unavailable`, `coverage.scope_resolution_failed: true` and incomplete
coverage. Exact-message reads include selected-but-missing transcripts in
incomplete coverage; a missing result then proves no absence. Conversation
projections expose unavailable source/revision as null, never a guessed app
source or a synthetic historical revision. The human index accepts current
declared sources (`app`, `ios`, `telegram`, `slack`).

The conversation page item (`app {page:"chat", item:<id>}`) reads every saved
session that `chat.list` names, including bridge sessions, and the exact record,
protocol conversation or contact-session ids an agent contact gives. Page reads
and `desk.wait` share `AgentConversationStore.resolveConversation`; `agent.read`
uses its same exact contact-record selector. A session reads its indexed hot or
archived transcript; a contact-only record reads through `AgentConversationView`,
the same retained-history projection as `agent.read`. These are the owners of
different conversations, never substitute readers after a failed transcript read.
Only a unique current session title resolves as a name. A contact record has
history without a mounted draft; reading it never creates or selects a chat.
If a live session's composer cannot read its draft, that part keeps its failure
while the indexed conversation still supplies history; the page reports partial.
The person-only index remains the list and reply boundary for conversations
with the person; it no longer gates a conversation page's history. The page's
`reply_available` uses the same person-index resolver as `chat.reply`, in addition
to the intact-tail and recorded-route requirements below. Archived sessions
remain readable but have `reply_available:false` and no `saved_route` reply kind.

Recent session-conversation reads use `SwiftNativePersistenceCore.tailPhysicalLines`
Mounted Mac conversations watch their own transcript file and accept card/message
notifications only for that exact session ID. The main conversation displays a
read failure before its first successful load as well as beside retained rows;
its explicit retry awaits one fresh read's completion, error or cancellation.
Neither a failed read nor silence turns an unread conversation into an empty one.
Broken card, approval, image, voice, file and envelope references draw their
identity and read remedy. A missing Inbox projection reads the exact saved
matter for its cause, retaining the card's protected Mac entry. Live reply text
reads the transcript owner's current row when its tail box clears; a missing
row or word block draws an unconfirmed reading rather than blank or stale text.
End-position decisions ensure layout; unavailable residual geometry stays absent.
Copy as Markdown acknowledges only a successful clipboard write.
Shared bounded Markdown and fence caches serve Copy, attachment tables and
thread previews.

Recent human-conversation reads use `SwiftNativePersistenceCore.tailPhysicalLines`
over at most 2,048 physical rows and 1 MiB, then expose up to the latest 128
user/assistant message rows. Total transcript size never
refuses this read or `chat.post`. The same tail supplies the last message ID,
latest user-row candidate and reply route; no earlier history is scanned to
fill a missing fact. A leading fragment is discarded. Missing facts stay null
and `unavailable_fields` names why (including a human route outside the tail);
`recent_read` reports the read's byte/row bounds, actual selection and damaged
row count. `recent_read.unreadable_row_details` identifies every damaged row
by its physical position within the returned tail, saved message ID when
readable, reason and SHA-256 of its bytes. Page coverage judges the requested
message limit (default 8, at most 128): an intact latest eight is `ok` even
when the byte/row window cannot supply 128. Fewer messages are complete only
when the undamaged transcript was read to its beginning. A gap inside the
requested history keeps the read partial; older gaps remain named in the
read evidence without making an intact requested tail partial.
A user row with unreadable routing cannot be skipped to reuse an
older destination. Damaged rows retain their place as evidence gaps while
readable siblings return; explicit saved-route replies
still require an intact tail and exact last message ID. Saving a reply rechecks
that ID under the transcript lock using the same bounded tail, without a
whole-transcript size gate. Duplicate reply identities are checked across the
full history. A missing transcript is unavailable; an unreadable file reports
its actual read failure. Neither case proves that the conversation or its
remote doors are absent.

A page with an unavailable, failed or partial conversation read reports
`status:"partial"` at the top and retains the conversation's own cause and
readable messages. Other readable page parts remain available. Read parts in
page content, settings and selected items follow the same aggregation; saved
send outcomes remain historical evidence, not a failure of the read showing them.

Contact reply projections quote only the matching canonical conversation line.
A retained reply record with no matching line reports incomplete history; its
cached answer cannot stand in as transcript speech. Run-origin indexes inspect
the transcript's shared filesystem version before cache hits, extend only
in-place appends, and rebuild after replacement or a same-size/shrinking rewrite.
An in-place append during a read preserves the prefix bounded by the initial
file stamp; only whole rows in that prefix enter the index, and later bytes
are picked up on the next read. Replacement, shrink or a same-size rewrite
during the read leaves provenance unavailable until a subsequent read.
Delegation reads name each lifecycle decode or transcript-origin read gap in
`source_availability.detail` and mark that source `partial`; readable sibling
jobs still return. Exact-message and agent-filtered reads retain these gaps:
an unknown principal cannot establish that the failed item belongs elsewhere.

Destructive compaction keeps an inline card unless its interaction is terminal
and its continuation is explicitly absent/null or spent (`resumed`, `invalidated`).
A malformed continuation is unknown and the card stays verbatim.

The old contact-ID regex and scattered bot/agent/wake prefix classifications
are removed. Exact contact namespaces for finding that contact's history,
helper locator decoding, per-message authorship and worker checkpoint
ownership still serve their separate identity/provenance purposes.

Composer drafts and pending attachments belong to their session identity.
Shotgun retains its selected conversation when the driving turn ends. Its
composer shares that session's Mac draft, and acceptance clears only the
submitted edit; switching the driver never carries text into another session.
Mac index pruning evicts only empty derived composer state; leaving the hot
index or having many drafts never discards unsent text or attachments.
The Mac moves its pre-session text only into an empty destination composer,
clearing the source after the move. If the destination already has a draft,
both texts stay in memory and a notice explains that New Chat can receive the
earlier draft.
The iPhone retains text, prepared photos and files per selected session and
restores them when returning. Main's initial automatic binding carries its
pre-anchor text, prepared photos and files into the resolved session; explicit
session choices keep separate composers. Switching invalidates file/photo
preparation; late photo results and picker selections cannot enter the
destination composer.
Opening a helper publishes its canonical row through the Mac index owner's
committed-write boundary before selection begins.
Telegram identity traces report the locked resolution: minting a new identity,
adopting the anchor, or reusing the mapped identity.
The owner's Telegram `/sessions` list includes only live direct conversations.
`/resume` validates that same rule under the index transaction before changing
the binding, and reports the exact bound identity without resolving it again.
The owner's `/new` and `/resume` report success only after the anchor owner
confirms publication; a refused or failed publication is reported as a failed
selection. Ordinary message admission may continue when activity publication fails.
Telegram Stop can show stopped after the card's terminal identity is persisted;
the coordinator retains the task for quit and idle joins until its operation,
receipts, ingress settlement and card close return. Only completion releases
the slot and admits the next queued turn.
