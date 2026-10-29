# Whose conversation a session is

The creator declares `threadKind` on the canonical `chat/sessions.json` row.
Every reader asks `Transcripts.SessionConversation`, over a `ChatSession`, a
session ID, or a previously loaded index. IDs locate records; their spelling
does not decide whose conversation they are. Historical readers include the
existing retention archive index; this adds no durable store. Single-ID reads
reuse a process-lifetime cache of parsed indexes keyed by file path and stamp;
a changed `SnapshotTailOpLog.FileStamp` causes the index to be read again.
Failed inspection cannot authorize a cache hit; index reads retain their symlink behavior.
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
| `builder` | Their own work, including resident wakes and workers; no person is in it |

`NativeAgentShared.ChatThreadKind.isHisConversation`, `isPeerConversation` and `isOwnWork` are
the shared questions. A stored `legacy` kind, like a row without a kind, reads
as the effective kind an unambiguous recorded source proves: recognized app
sources are `direct`, agent bridges are `agent`, and worker sources are
`builder`. A mixed-purpose transport source (Telegram, Slack) proves nothing
without creator evidence, so such a row stays unclassified (`legacy`).
`ephemeral` remains readable as diagnostic traffic. An unknown ID or
unavailable index proves no kind.

Helper-only policies need the helper owner as well as the common `agent`
kind. A helper writes its exact `helperID` on its session; older rows' `bot`
creation provenance identifies the same owner. `SessionConversation.isHelper`
reads that row evidence, so peer turns retain the resident's glance and
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

Every transcript read shares the Mac slot's `LatestRead` row/card publication
and its engine's turn owner, including phone and card refreshes. Unowned rows
admit disk; populated live rows win, empty live slots may be seeded, and a turn
that advances during a read wins over it. This owner restores optimistic row
identities and retains synthetic failures for selection, reload and detached windows.
It reconciles text, optimistic rows and fresh cards before one structural publication;
cards can still advance when a changed turn prevents disk text replacement.

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
answer in. ResidentWake changes its existing app/direct row to `builder`
before its next turn. There is no manual rewrite of installed data.

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

Navigation projects the Mac pin preference `NativeAgent.pinnedChatSessionIds`
and its retention mirror `chat/pinned_session_ids.json`, alongside the separate
`chat/anchor_pin.json`. `ChatSessionNavigation` carries these resolved pin and
anchor flags to the phone; it does not introduce another pin store.

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
