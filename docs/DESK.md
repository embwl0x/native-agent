# Desk vocabulary

The Desk is the agent's durable work. `ledger.list` reads the shared task
ledger, a separate list; an empty ledger says nothing about the Desk.

Each item's `workAttempts` ledger holds both pursuit and owner-cadence work.
Historical reservation rows decode into that ledger; pursuit daily and lifetime
accounting, retained goal evidence, and receipt handoff keep their existing limits.

An item's name is `handle`. A stable handle, its permanent visible number, or
`desk.<number>` addresses it. `id` is accepted as an alias for the item's
handle. On `desk.add_ref`, an `id` supplied beside `handle` still identifies
the linked approval or trace.

`desk.read` lists all live board items, including parts and recently closed
items, with `limit` (default 25, 1–100), `offset` (default zero), `total`,
`count`, and `has_more`. Copy `next_read` to continue. `query` searches the
full live store; `handle` opens one exact record and pages its parts, notes
and refs. Complete record text uses `detail_offset` and `detail_version`.
`sort:"recent"` is the default; `sort:"stale"` orders oldest first. Sorting
changes neither the matching items nor the fields each row returns: handle,
status, summary when present, notes, refs, dates and sequencing evidence.
`structured` remains accepted; rooms use returned `display_status` and continuations.

With `include_archived:true`, `archives` contains its own paged `items`,
`limit`, `offset`, `total`, `count`, and `has_more`. Its initial offset is the
ordinary `offset`; `next_archive_read` carries the separate `archived_offset`
for continuation. The shared task ledger also accepts `limit`/`offset` and
returns `total`, `has_more`, and `next_offset` for summaries and an exact
task's events (`next_offset` is null on the final page). The workspace offers
**More shared work** and **More timeline events** from that continuation,
preserving the task, page size, and finished-work filter.

`summary` is the word on both `desk.add` and `desk.close`. Close still accepts
the previous summary spelling for existing callers. Conflicting spellings
refuse the input.

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

`on` also accepts an observed Desk handle/number or experience id (a card,
message, reply delivery or repair), or a nonempty list of those dependency
ids. These waits retain automatic release when the named conditions settle.
The wait action has its own typed guide. Unknown identifier-shaped conditions
are refused; a single person's name is a person wait. `note` explains either
kind of wait.

The Desk page lists each item under one heading: Waiting on the owner,
Blocked, or In play. Its count explains the `desk.wait` call that puts an item
there. Input mistakes, including unknown handles, return `invalid_input`,
the argument path, and `effects:"none"` rather than a blocked dispatch error.

For a four-call work record (using the handle returned by the first call):

1. `desk.add {kind:"plan", project:"Example", title:"Review the draft", summary:"Two review steps"}`
2. `desk.note {handle, text:"1. Read the draft.\n2. Record the requested changes."}`
3. `desk.wait {handle, on:"User", note:"Awaiting the decision"}`
4. `desk.close {handle, summary:"User asked to close this record"}`

These are action argument shapes for `app {action:"desk.…", args:{…}}`.
Recorded notes and summaries are records, not proof of external work.

Workshop reads retain complete, partial, absent or unavailable evidence.
Partial reads continue; absent or unavailable reads continue only when optional.
The action's read contract applies even when Trust assigns a different permission class.
Cancellation, failed effects and unresolved effects stop traversal; outcome
details name the resolved tool.

`WorkshopDeskReceiptBridge` maps successful execution to `done`, retaining unverified
or missing verification in the summary and receipt. Failed declared postconditions
block on `domain verification`; canceled/stopped executions become `canceled`,
and other execution failures block.
Work-session disposition settlement separately closes pursuits as `done` for retained
`goalSatisfied` or `canceled` for `abandon`, under its existing revision and latest-attempt guards.
`WorkshopExecutionRecord` owns execution terminality and success, including historical
spellings. File writes verify by bounded byte read-back, commands by exit/timeout evidence,
and reads by saved complete/partial coverage. Declared output phrases are exact postconditions.
