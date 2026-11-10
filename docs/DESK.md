# Desk vocabulary

The Desk is the agent's durable work. `ledger.list` reads the shared task
ledger, a separate list; an empty ledger says nothing about the Desk.

What they means to do later lives here as a MY QUEUE intention, filed with
`queue.add {text, when, until?, say?, action?}`. Its `DeskStep` owns the words,
moment or rhythm, ending, fixed words, habit and origin. Promise capture also
attaches a step to the existing agent-assigned
row when it restates that work; it uses the same readiness and settlement as
MY QUEUE. Its canonical `promiseCaptures` identities survive refiling, closure
and archive so unfinished reflection cannot create the same source again.
A reference refresh containing only other evidence retains the captured step.
Attaching a captured step updates the row's title to the same words and peer
provenance used for a newly filed step and its approval follow-up.
`queue.update` changes
named fields; `queue.done` and `queue.drop` settle it by hand, by its exact handle
or number. A step also closes by itself when the after-turn judgment sees its
deed ([Intentions](INTENTIONS.md#promises-they-makes)), in any conversation and
in turns with no incoming message, their own stream and lines included; nothing they are shown teaches closing one by
hand. Words never select a different step. A committed closure keeps its
receipt if checkpoint cleanup fails, with the cleanup cause in
`settlement_failures`. Repeating `queue.done` on a done step, or `queue.drop`
on a dropped one, is granted as `no_change` with its saved completion time and
evidence. Any other call against a terminal step is refused as `already_done`
or `already_dropped` with the same evidence, without changing it. Live steps supply
their outcome, notes and refs; archived steps, looked up by exact handle,
supply their outcome, retained refs, decisions and artifacts. The archive
does not retain visible numbers or notes. An unknown id remains `not_found`;
absence is not completion evidence. An unreadable required archive remains a
storage failure, never `not_found`.
Each step's time is a `moment:<handle>` time on the one
clock; what comes due is posted once as a `moment` happening, never a second queue
of reminders or turns. The [intention contract](INTENTIONS.md) owns the form,
readiness and delivery. A step imported from a scheduler job keeps its job identity
(`scheduledJobID`), so the same job never files a second step. A stopped import names the
evidence to reconcile before refiling it.

Each item's `workAttempts` ledger holds both pursuit and owner-cadence work.
Only current attempt records enter that ledger; retired reservation formats
require explicit retained-data conversion before admission. Pursuit daily and
lifetime accounting, retained goal evidence, and receipt handoff keep their
existing limits. Today's pursuit count is projected for the Mac's current
calendar day from the canonical accounting and pursuit-lane attempts; it is
never a persisted display counter.

The journal admits every retained line or reports the named unavailable
record with its cause and repair. It never skips a create, alias, finding or
blocker. Every append validates the complete current serialized operation
before writing. Materialized state requires version 2 and its actual work-slot
ledger. Current origin values are `owner`, `agent` and `system`.
`findingKey` alone owns a system finding's identity; notes remain ordinary
text. Care evidence uses current `care` citations, with no retired
standing-view or open-question bridge. Saved policies, conditions and
provenance decode completely; invalid saved values never become new defaults,
empty peers, or next-turn readiness.

An item's name is `handle`. A stable handle, its permanent visible number, or
`desk.<number>` addresses it. On `desk.add_ref`, an `id` supplied beside `handle` identifies
the linked approval or trace.

`desk.read` lists all live board items, including parts and recently closed
items, with `limit` (default 25, 1–100), `offset` (default zero), `total`,
`count`, and `has_more`. Copy `next_read` to continue. `query` searches the
full live store; `handle` opens one exact record and pages its parts, notes
and refs. Complete record text uses `detail_offset` and `detail_version`.
`sort:"recent"` is the default; `sort:"stale"` orders oldest first. Sorting
changes neither the matching items nor the fields each row returns: handle,
status, summary when present, notes, refs, dates and sequencing evidence.
Rooms use the canonical returned `display_status` and continuations.

A committed mutation whose confirmation read fails reports the Desk read's
cause with `effects:occurred`; read its handle before repeating the mutation.
Equivalent creation and plan breakdown use the same locked store transaction,
matching kind, parent, lane, assignee, project and title. Breakdown retains
every returned handle, alias and reuse flag in `committed`, and completed
sequencing operations in `committed_operations`, including when its final
readback fails. A partial receipt does not depend on another successful read.
`desk.blocked_on` requires its `blocked_on` string and `desk.defer` its `until`
string; an explicit empty string clears, while absence or an invalid type
refuses before mutation. Direct tools, the app door and part/ability calls
judge the caller's original value; numeric values are never converted into
valid blocker or defer strings.
`desk.work_log` selects a pursuit receipt or an ordinary item's note under the
Desk store's own lock, without retrying through another tool after a failure.

The default `desk.read` includes board rows and open MY QUEUE intentions in one
paged list; `place` keeps the two distinguishable. Board counts and the open
intention count remain separate. The agent's Desk page shows the same queue
with each intention's name, words, filing time and outstanding waits.
[Intentions](INTENTIONS.md#their-words-for-it) owns that readout.

With `include_archived:true`, `archives` contains its own paged `items`,
`limit`, `offset`, `total`, `count`, and `has_more`. Its initial offset is the
ordinary `offset`; `next_archive_read` carries the separate `archived_offset`
for continuation. The shared task ledger also accepts `limit`/`offset` and
returns `total`, `has_more`, and `next_offset` for summaries and an exact
task's events (`next_offset` is null on the final page). The workspace offers
**More shared work** and **More timeline events** from that continuation,
preserving the task, page size, and finished-work filter.
Archive and shared-ledger histories decode every record and link, or expose
that history as unavailable with its cause and repair. The shared ledger's
actor is `agent`, `user` or one saved contact as `peer:<id>`; its compaction
base requires its recorded operation count.

The `task-ledger` CLI parses every option, including `--data-root`, before
accessing the ledger. A value option followed by another `--option` or the end
of the command is refused; literal values beginning with `--` use equals,
for example `--note='--literal text'`. Single-value options cannot repeat;
`--ref` may repeat. Unknown options and options belonging to another command
are refused before any ledger write.

Bare defer days include the named day. Snooze choices therefore say
**Through tomorrow** and **Through [date]**, resuming at the following local
midnight; a full timestamp keeps its exact instant.

`desk.add` takes an optional `summary`. `desk.close` takes `reason`, the same word
`queue.done` and `queue.drop` take. For `desk.close`, reason names the owner's
explicit instruction or the fresh canonical commit/receipt/observed result
proving the tracked outcome; the instruction alone suffices without claiming
the underlying work happened. `queue.done` uses reason for why the step is done.
The shared door records any unique declared interpretation of another supplied
name. Wait explanations use `note`.
Desk actions keep `handle`, queue actions keep `id`, and page reads keep `item`;
the shared door binds a single alternative address word to the schema's sole
declared one when that declared field is absent, before validation and Trust.

`desk.wait {handle, on:"User", note?}` puts an item in **waiting on User** in
one call. `on:"owner"` names the owner without needing their name.
`desk.set_status {handle, status:"waiting on User"}` reaches the same writer.
Waiting status updates apply `remaining_work`, `progress`, `assignee`, and
`lane_of` through the ordinary status path before confirming. Invalid fields
are refused by name; an explicit `waiting_on` must agree with the status text.
The existing persisted blocked status and `waitingOn` field hold this state;
readers present it as `waiting on <person>`. No stored items are rewritten.
An owner wait contributes to the page's waiting-on-owner count through
`OwnerAttentionPolicy`. Changing the status clears that person wait.

Desk stores eight states: `watch`, `flag`, `now`, `next`, `todo`, `done`, `blocked`
and `canceled`. Only `done` and `canceled` are terminal.
Every newly created item starts at `watch` (displayed as "watching"), including
one whose `kind` is `plan`; kind and work state are separate. The store's
`createItem` reduction owns that default. The textual board uses the kind as
the status token for a top-level item still at `watch`, so a new plan reads
`plan` there while its structured status remains `watch`.

`on` also accepts an observed Desk handle/number or experience id (a card,
including the `approval:<id>` its Home row shows, message, reply delivery or repair), or a nonempty list of those dependency
ids. These waits retain automatic release when the named conditions settle.
The wait action has its own typed guide. Unknown identifier-shaped conditions
are refused; a single person's name is a person wait. `note` explains either
kind of wait.

A single conversation id also names a wait, whether it belongs to a saved chat
session or an agent conversation. `desk.wait` uses the same exact agent-conversation
resolver as `agent.read` (record id, protocol conversation id or contact-session id)
and conversation page item reads. It checks chat identities in the session
index rather than guessing from a transcript filename. An unavailable identity owner is reported unless the other
owner positively resolves that conversation. This is a durable waiting status,
not a blocking tool call: if no message comes, the item stays waiting until its
status is changed.

The **Replies owed** finding counts the completion delivery owner's `owed` and
`sent_unconfirmed` records. Its `reply_delivery` refs name the exact ids accepted
by `repair.let_go {id, reason}`. Release consults that delivery owner under its
lock, even before the advisory experience projection arrives; the finding's
next reconciliation reads the saved release and removes that reply from its count.

The Desk page lists each item under one heading: Waiting on the owner,
Blocked, or In play. Its count explains the `desk.wait` call that puts an item
there. Input mistakes, including unknown handles, return `invalid_input`,
the argument path, and `effects:"none"` rather than a blocked dispatch error.

For a four-call work record (using the handle returned by the first call):

1. `desk.add {kind:"plan", project:"Example", title:"Review the draft", summary:"Two review steps"}`
2. `desk.note {handle, text:"1. Read the draft.\n2. Record the requested changes."}`
3. `desk.wait {handle, on:"User", note:"Awaiting the decision"}`
4. `desk.close {handle, reason:"User asked to close this record"}`

These are action argument shapes for `app {action:"desk.…", args:{…}}`.
Recorded notes and summaries are records, not proof of external work.

A task the person starts (the Mac's new-task sheet, the phone's
`submitDeskTask`, the Shortcuts intent) creates a Desk item and starts a
[line of theirs](agent-communication.md#jobs) with `desk:` set to that item
(`NativeAgentEngine.submitDeskTask`, `EngineRuntime/EngineDesk.swift`). The
line's ending is a `returned` happening with no conversation route, so it opens a
thought in the agent's mind stream, where the agent settles the item
(`AgentJobStem.swift`).
A job that carries a Desk item is that item's movement: Desk activity, the live
strip, the widget's **Working on…** line and the phone's `desk.json` evidence
come from their jobs (`DeskMovementPresentation.evidence`,
`EngineRuntime/DeskActivityPresentation.swift`), and the Work overview's
execution rows are their jobs.
