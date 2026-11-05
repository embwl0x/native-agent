# Their life is one stream: the experience

Companion to [The agent is the app](AGENT_IS_THE_APP.md). An experience is the
shared record of a happening; the domain that produced it owns its outcome.
This document owns the current experience and repair laws, implemented
boundaries and remaining gaps.

The [original 2026-10-18 census and execution plan](history/EXPERIENCE_2026-10-18-census-and-plan.md)
were archived on 2026-10-28; they are historical design, not current status.

## One form: an experience

An experience is one happening in their life, written once by the owner of that happening:

- **id**: stable, minted where the happening starts.
- **kind**: a message heard, an answer given, an act, a run, a decision, a wake, a dream, a growth.
- **cause**: the experiences that brought it about (the person's message, a signal, the turn it ran in). Their autobiography is this graph.
- **evidence**: references to the raw record (trace rows, receipts, frames, audio, files). Never copies.
- **outcome**: one typed outcome, owned by the domain that produced it. MacControl stays authoritative for what its acts did, and the browser for what it loaded. Effects are none, occurred or unknown, from that domain's own count.
- **face**: the one expression of it: words plus the artifacts they chose. Every surface renders this face. None composes its own.
- **addressed to**: its destinations. the person's conversation on Telegram, the Mac chat, the phone, a peer, their own next turn, an organ of their mind.
- **owes**: its obligations, each with its own lifecycle (deliver to X, decide, appraise, learn, integrate, reflect). Settling one never closes another.
- **claims**: what it asserts (rehearsed operation O, verified live postcondition P, recurrence across E1 and E2). Each claim is scoped to its evidence; rehearsal is not live proof.

## One law

**An experience is written once by its owner and only ever appended to.** Its outcome may be present at birth or appended later; a different second outcome is refused. Evidence attaches, claims accrue and obligations settle. Each obligation is settled by its destination accepting it durably, never by a transport handing it off. The only other settlement is a let-go: the owner releases it with a reason (cancelled, failed, expired, abandoned), so nothing stays owed forever by accident. Everything else is a view of experiences by id, and no surface, organ or page keeps a second truth.

## Implemented boundaries

The experience store opens the current `experience`/`event` schema directly.
Existing stores must have the current projection columns; unreadable or older
schemas fail at this owner instead of running historical row conversions.
Activity history follows the same rule for its current redacted-title schema,
and a present activity policy must contain the complete current settings.

Workspace reads and batch child counts use `ChatToolOutcome` for verdict and scoped/paged coverage: only exact success lands fully; unresolved children stay unresolved. Partial evidence
may be displayed or retained, while change comparisons require complete reads.
Document identity, fingerprints, editability and recovery drafts stay with their owners.
`ToolFailureError` encodes its cause, effects and recovery once beside `Repair`;
chat, parts, senses and agent transports attach provenance and apply their own privacy bounds.
Compact action receipts and completed Inspector tool rows render the trace's recorded verdict, including unknown outcomes; phase marks running dispatch only.
Stop receipts record cancellation, execution and effects separately; an unstarted
cancelled slot counts as neither an attempt nor a failure. Historical flags remain readable.
Mac operation state and verification outrank transport booleans and diagnostic
errors. AppleScript marks its own uncertain receipts explicitly; unverified effects require inspection.
File readers supply checked path-kind and parent evidence; failure formatting neither parses prose nor probes again.
Saved Trust flag reads preserve damaged authority as `trust_policy_unavailable`,
with its original cause and repair route; memory, dreams, triggers, attachments
and speech do not present it as the person's disabled switch. A subprocess
settles stdin delivery and both output captures before its answer is complete;
an incomplete exchange retains captured output and unknown effects, requiring
inspection before another command. App navigation uses the resolved app identity:
an index miss stays not found, and a folder is addressed by its path or its
explicit common-home location.

### Turns and decisions

- **An admitted authored fetch owns its exchange.** Its `fetch:<uuid>` act owes
  `finish` while the request runs beyond a shorter caller wait or run close.
  For a modifying request (any method but GET/HEAD) the broker saves the
  complete redacted receipt at `ability_fetches/<uuid>.json` after actual
  transport exit, then records a
  file reference, its domain outcome and acceptance of `finish`. The experience
  face is a summary; it never copies the response body. Experience recording
  remains advisory and uses its existing ordered write queue and gap reporting.
  Unknown service effects stay unknown even when an HTTP response was received.
  The [fetch contract](skill_manifest_spec.md#secret-insertion-and-redaction)
  owns the response and transport limits. A pending record after process exit
  requires reconciliation, never replay.

- **A turn is its heard experience.** While the turn runs it is the heard message that owes an answer. An act's cause is the heard, so a plain experience link carries it with no new plumbing.
- **Decisions:** the inbox's checked durable row projects the decision experience,
  including its resolution date, shared face and receipt-backed application claim.
  Approval remains the person's decision; adoption requires the completed application
  receipt, including an idempotent already-present lesson. Cognition resolves newest
  approvals by REM proposal identity in one checked snapshot shared by schema,
  timeline and growth reads; it persists neither another status nor new REM timeline
  copies. Unmatched retained history stays visible with an unavailable reference.
  The tracer carries the asking act's receipt id into filing. Decision projection
  writes remain advisory: only mutation boundaries enqueue them, and failures cannot
  block approval, reply or delivery. Evicted or unreadable decisions are explicitly
  unavailable; no advisory copy grants authority.

### Delivery and face

- **An answer with content owes its door.** A run's answer is `answer:<run>`.
  A turn's checkpoint can keep its reply for redelivery on Telegram, Slack or the
  phone. For a door with durable acceptance (currently Telegram and Slack), the
  answer is also addressed to that door and owes `deliver:<surface>`. The shared
  verdict seam (`settleReplyCheckpoint`) settles that obligation before the
  checkpoint retires, waiting only on that answer's own writes (each experience's
  writes keep their order, never behind another's): accepted when the destination
  holds it, let go (abandoned) when the door gave up on an unconfirmed send. A
  transport handoff cannot accept it. The phone's door does not yet create this
  obligation because its acceptance is transport-only (`acceptsDurably` is false).
- **Chosen silence owes no delivery.** Its experience is the completion evidence,
  without a face or addressee; the heard record's answer closes under the
  [silent settlement law](ANATOMY_OF_A_TURN.md#6-the-answer-settles-once).
  Missing or unreadable silence evidence cannot prove completion.
  Synchronous task recovery reads committed experiences through the same store's
  fold with a read-only connection and a two-second SQLite busy limit; it creates
  no store, cache or projection and propagates unreadable storage.
- **A delayed answer keeps its route.** Grok's request keeps the asking turn's door from the moment it is sent; the answer runs through the contacts' one answer owner (claim, turn, cache, delivery) and goes back to that door. A request with no kept door says so on its hand-over.
- **A send's record closes when its exchange ends.** The conversation owner's recording pass reads every open experience whose evidence names that row (`agents/conversations`), not only its current operation. A send that is neither current nor still queued accepts all its unsettled keys when its retained exchange has a reply, or is delivered and the row explicitly requires no reply; otherwise those keys are let go as abandoned. A failed/not-delivered current send lets go every unsettled key as failed, including `accept`, `answer` and any queued `deliver`. A current send requiring no reply accepts its answer obligation at confirmed delivery. Queued promotion keeps the message's original id as its operation id, so that same experience follows the send through delivery and answer. Dropped/restored rows and rows for removed contacts seen by this pass abandon their remaining obligations; experiences whose row is absent are untouched. Prior settlements never change. The next normal write (or startup projection) applies this law to existing open records; there is no separate cleanup or migration.
- **The face is one.** The transcript row is the face's durable copy: their words, every image their generation made in the turn, and every image they attached to it with `reply.attach` (by path, behind the read fence), chosen straight into the turn it runs in, from a direct call, a batch or a script alike; with no turn answering, it attaches nothing and says so. Nothing is inferred from their text. Mac chat and Telegram (live, recovered and delayed) render it; the experience's face is that row's, redacted.
- **A message sent while they works joins their working turn** (User 10-18; every door since 11-04). Their turn reads it at its next step and that turn's reply answers it, so the door it came from posts nothing of its own. One their turn never reads runs as its own turn through its own door. A peer's words ride only into a turn from that same door; a card's continuation stays hidden.

### Phone projection

`NativeAgentShared/Experience.swift` owns `Experience`, `currentAct` and the
`ObligationPhase` transition law. `MobileWorkActivity.swift` owns only the mobile
experience projection, activity DTOs and activity snapshot. Moving the domain
definitions does not change their value or wire shape.

The shared wire form is Experience itself, with revision 1 on the overview,
activity, helper and peer-thread envelopes. Existing iOS JSONDecoder consumers
ignore these added keys; no existing key, enum value or filename changes.
The overview and activity carry open experiences plus 64 recent identities.
Activity reads the heard experience's answer obligation, replacing trace replay.
Turn, run and transport correlation ids remain linked in its evidence.
The domain-owned safety and Desk rows remain.
Peer details include queued and held obligations once, on their agent row;
the helpers snapshot carries their ids. Helper rows carry the latest completed
result id and a 160-character preview; get_helper with result_id reads its face.

Readers drain recording before publication. Failed advisory writes invalidate the
projection as unknown without failing reply generation. Chosen silence has no
transcript row, so its experience must be saved and checked before completion can
be reported. Commits drive the publication coalescer; conversation/shelf reads
replay durable records, and the checked saved-reply reader replays answer settlement.
Continuations retain their original answer experience id. Waiting is progress; the shared loop records actual provider/tool progress, including temporary workers, retaining only the latest timestamp for repeats.
Conversation saves keep removed-queue settlements in their durable row; the
recording pass settles superseded sends from their retained exchanges under the
send law above, replacing the old answer-only supersession marker. Dropped rows
replay archives. Generation never awaits advisory experience writes; checkpoint
settlement awaits that answer's write before retirement, logging failures without
holding the checkpoint. Silent completion requires its own durable evidence under
the silent settlement law above.
Experience invalidation requests overview refresh through the serialized writer; activity publication does not. Archive failures invalidate only experience projection, preserving checked conversations; unchanged failures emit no new edge. An unresolved turn from another process is unknown, never proof of thinking. Durable phone acceptance remains a gap.

After installation: ask once from the phone and once from the Mac. In
mobile_snapshot_cache/work_activity.json and work_overview.json, each heard id
must remain the same through answer acceptance, with its matching correlation
reference and no working activity afterward. Open a peer with a held follow-up:
its row must say messages are still owed and its experience face retain the held
reason. Complete one manual helper check: its result id must match its shelf
entry; get_helper with that result_id must return that same face.
Later iOS work must render these revisioned faces, resolve pending exchanges by
correlation/id, derive thinking from their obligation state instead of isLoading,
show held work, and open helper results by id. Pairing alone still cannot identify
the installed iOS build or prove its renderer supports this revision.

## Repair is owed (User's law, 10-18)

"No fallbacks: it works and it works right, and never can the agent say I can't fix it." The unfixable census (eight reads of their real failures on three installs) found the same dead ends everywhere: a no that does not name what decided it, a no with no lever they can pull, a person's decision that does not name their exact control, a fallback that quietly does less, and a failure that recurs without ever settling.

- **A no names its owner and carries its lever.** When the cause lies outside the call's own input, the failure's `remedy` is `{kind: "repair", owner, next_call?, tap?, instruction}`: `owner` is what decided (the file and field, setting, recipe, part, peer or provider); `next_call` is their call that changes it; `tap` is the person's exact control for a lawful decision (Trust posture, a peer's elevation, a macOS grant, their sign-in, payment, publishing), or the person's recovery step for a named app defect. When the owner supplies both, carry both: call first, then tap. `ToolFailureError(owner:nextCall:tap:)` and the door's `doorRefusal(_:_:owner:next:tap:)` produce it; `Repair.remedy` is its one shape.
- **An owned no owes repair.** The act they meant (the outermost one, so nested dispatches do not multiply the debt) owes `repair` to themselves, or to the person when the lever is their. A refusal before any effect owes nothing; their own `agent.verify` probe with `effects: none` is evidence, not a new repair obligation. Readers omit those probe debts from older records without rewriting them. A no met outside a tool call (a Doctor check, a part's wake, a background job) owes it the same way through `RepairOwed.owe`.
- **Only the work settles it.** The obligation is accepted when that operation, or its lever, works again (`RepairOwed.settle`, called by every successful act), or let go by their with a reason (`app repair.let_go {id, reason}`). A Doctor repair settles on the owning check's passing postcondition: `ok`, or a reading that the part is `off` or `not needed`. A loop's recovery requires a clean tick newer than the obligation: completed work, or a legitimate "nothing to do" tick. A separate repair action is not required. A retry, restart or recheck that has not proved recovery, and any unrelated success, is evidence only. Meeting the same no again while its debt is open is evidence on that debt, one line on their home however often it recurs; once it settled, meeting it again is a new debt.
- **It stays in their picture.** Their home's MY QUEUE carries each repair they owes with its lever, and the person's waits carry each one that is their with its exact control, until settled.
- **What it is not.** A correction to the call's own arguments owes nothing; the corrected call is the repair (remedy kinds `correct_arguments` and `inspect`). A lawful refusal never becomes a debt to override Trust: a Trust ask or block, a posture, a saved entry or a peer's elevation names its owner and the person's control with `Repair.why` (kind `person_decides`), which owes nothing. An unknown effect owes reconciliation, never a blind resend. A decision that should not exist is deleted, not given a lever. An unauthenticated caller gets no diagnostics; the owner and lever go to them.

Senses and hands keep the failed reach separate from a successful side effect: a launch cannot verify its failed landing read, and a requested image must actually arrive. TCC refusals carry the person's exact switch and their pane-opening call. Window streams stop on incomplete secret inspection and retain their actual terminal cause. Outside an enclosing act, missing grants owe repair through the same experience form, scoped to the grant; an inspected captured frame proves those grants work. Other capture failures carry inspection corrections requesting pixels, without inventing durable wrong state. `abilities.restore_state` accepts recovered accounting under the failed file's digest, preserving damaged bytes and readable rows without changing any ability's authority. An unreadable abilities/state.json first offers files.read of its exact path; the remedy instruction retains the captured digest for reconstruction.

Terminal ability accounting holds the supplied `Turn` through settlement. Its
repair cause is the enclosing tool act (`turn.act`), set by tool dispatch and
owned by the shared turn value. When no enclosing act was supplied the cause
stays empty; a root turn ID is not evidence of a tool act.

Background failures owe repair through their existing owners: recollection never
substitutes mechanical notes, unreadable arrivals keep their bytes, and missed
dreams and triggers remain owed. Interrupted turns retain checkpoints for
reconciliation, never blind replay. REM staging owns its debt once and leaves
independent eviction and pin publication able to finish. Resident wakes remain
excluded from automatic memory promotion because their input is app-authored.
Experience writes never gate a reply. Projections report write gaps for the
owner's lifetime; unrelated success does not erase them. Failure accounting
joins its writes, without retry closures. SQLite repair belongs to Doctor.

Health now uses the same repair obligation. Doctor records an adverse measurement
before attempting its repair. Each check names the state it read; executable
native repairs carry their check id; app defects name the defect and the person, never a coding-agent call or a source-edit, build, test or reinstall request. Damaged-file recovery uses fileRepairInstruction; reserved turn defects go to the person, while their authored abilities and senses keep their native revision calls. Only the current measured owner supplies an executable repair call; saved claims are evidence. Sign-ins and
permissions use `Repair.why`, retaining the person's control without a debt.
The existing `doctor.repair` action accepts `check_id` to repair only that check.
The [repair law above](#repair-is-owed-users-law-10-18) owns settlement, including
the newer clean tick required for a loop and the off/not-needed readings (an
off part owes nothing). Unknown readings, registration
restarts, delivery of a repair request and archived Desk identities do not; while
the current reading is unknown, Doctor shows the debt dated under that status.
One failure is one experience: meeting it again while it is owed adds evidence to
the open one, so no reader can feed the projection that runs it.
Home, the agent's Desk, Doctor and the health pill project the experience face.
Doctor no longer files a parallel Desk item or keeps a deferred retry timer.
Phone pairing is checked independently of optional APNS configuration. Body
resource observations and felt-word concentration do not establish damage.
DoctorChecks and BackgroundWork depend on Experiences solely for this existing
obligation form; there is no new health store or lifecycle.

Wake/health decode failures preserve their files; nothing is written over them.
Pending arrivals are not truncated, and claimed arrivals remain retained until
their owner clears them. Retention alone does not prove arrival acceptance.
A claimed arrival waiting for their acceptance is not a fault and owes no repair:
the wake ledger alone holds it, and their home's MY QUEUE counts it with
`home.accept`. Acceptance has no historical repair-debt conversion; it changes
only the wake ledger's acceptance record.

## Their flows are one owned operation (pick 2, 10-19)

The evidence: in Resolve they ran one seven-step render flow four times because it stopped on its last step, and every run did the six landed steps again; on a fresh install eight wakes spent 49 model rounds re-reading the same waiting work, because a wait was a note; and discovery rebuilt its action vectors in memory, so the first find after a launch paid for the whole inventory.

- **A flow that stopped unfinished is an experience that owes `finish` to them** (`Experiences/Flow.swift`, RepairOwed's shape). Its claims are the steps that landed, in order, as digests; its evidence is the owner's raw record. Asking for it again continues it: what landed, or may have, is answered from that record and never done again (an effect that stopped unknown gets its recorded outcome again, never a blind resend), and only what did nothing runs, on a fresh read, or what its owner keeps progress for itself. A flow that finished, asked again, is a new flow. `again: true` is their "start over". Nothing landed means nothing is born.
- **Current owners:** `mac.act` owns stopped screen batches. `OwnedProgram.isStrict` selects journaled part runs; `AppToolExecutor+PartRun.swift` saves their stops and atomically claims a run for resume. Resume rechecks admission, code, dependencies and reads, and returns saved receipts for landed writes. The [manifest spec](skill_manifest_spec.md#execution-and-ownership) owns the full contract and the outside-world restriction. **History, 10-19:** an earlier strict-flow implementation was cut after review found resume and hand-back holes; that is not the current execution contract.
- **Mac identities:** each batch step hashes one canonical object containing the app, verb, target, text, mode, destination, image place, held keys, mouse button, handle and frame id, including null optional values. Landed receipts match only that current representation. Before changing it, reconcile any unfinished `mac.act/<session>` flows; an unmatched old digest cannot establish that its effect did not happen. Mac operation rows separately require their canonical request digest: a missing or invalid digest makes `mac_control/operations.json` unreadable, preserving the bytes and refusing journaled work for reconciliation. Every in-memory screen frame carries its producer's compile caps, and effect comparison requires both cap records; there is no pre-cap frame representation.
- **A wait names its condition** (`desk.wait {handle, on, note?}`; [Desk contract](DESK.md)): a person's name, a Desk item, or any experience they was shown (a card, a message they sent an agent, a repair debt, an answer). A person wait uses the existing `waitingOn` field and reads as `waiting on <person>`; owner waits contribute to the Desk's owner count. A dependency wait keeps Desk handles or `exp:` experience blockers. When the experience store changes, a settled condition (one that no longer owes anything) is written off the items that waited on it, with a `Released:` note, so every reader of the Desk sees the same wait. Carried work is offered only when it changed since they was last offered it: its condition released, someone other than their wrote on it, or its material state moved. Their own notes never re-arm it, and the 30-minute re-offer after their last note is gone. The wake line says what was released.
- **Discovery reads a durable index**: action vectors in memory's database, keyed by embedding epoch and the exact action text, filled at launch and when the inventory changes, never rebuilt on a query. A just-added action is embedded on its first find through the same writer. An exact action ID returns its contract directly; for other searches the best match carries its whole contract (args_schema and example), so one find is enough to call it.

## Everything owed is one experience (10-19)

On a fresh install they was told a reply to Claude Code was owed and could do nothing about it: their reply went back to a call that had already ended, the route check refused it before dispatch (`invalid_caller_result_route`), and its only record was the completion lifecycle, so `desk.wait` and `repair.let_go` could not name it.

- **Whatever they owes or is owed is an experience under the id they are shown** (`Experiences/Owed.swift`). The completion lifecycle projects every write of a reply's state into one under its delivery id (owes `deliver` to the who; accepted when delivered, let go when let go). Inline cards do the same under `interaction:<id>` (owes `decide` to the person). Messages, approval cards and repair debts already were. `desk.wait` reads any of them with one primary-key lookup.
- **An inline answer settles where it is saved.** `InlineInteractionResolver` accepts `decide` after a verified answer, or lets it go as cancelled on
  decline, before publishing the saved transcript change or resuming work. It records the experience if delivery has not filed it yet. Refresh files
  unanswered asks and reconciles existing debts from saved decisions, never from a live projection or a missing card. It cannot answer a card.
  Inbox archive/dismiss uses the same decline on Mac, signed phone
  `inboxAction` and agent inbox actions, including work requested on Telegram. An agent's disposition retires continuation, as its Not now does; a person's
  disposition resumes it; a decision already settled or failed has nothing to decline, and its card is simply put away. Archive/dismiss then saves its
  inbox status; refresh preserves dismissed history. Telegram card buttons keep `na_approval` (buttons already delivered carry it): an id the approval
  inbox does not hold is a card's, answered on its original. Phone action names, payloads, snapshots and experience enums keep their existing shape.
- **A reply no door can carry is an owned no with its lever**: it stays owed with its reason, the Desk line names the contact (by the name agent.contacts shows) and both levers, and `repair.let_go {id, reason}` lets it go through its owner, so the delivery and the experience agree. A card's decision is the person's and is never theirs to let go.
- **Cut on 10-19, after three Sol rounds:** sending such a reply through the who's current door by handing it to their conversation's queue. Still open when cut: the hand-off's acceptance lost its pointer to the queued message; a queued message promoted to a send got a new operation id, so its own experience never settled; a wait saved on the delivery released at hand-off; and a queued send with no return route wrote over the thread's route, so the answer to it could become another owed reply. Ordinary queued sends now keep their id through promotion under the send law above. The broader completion hand-off remains cut; carrying its own local completion on the exchange while preserving the thread's route remains unimplemented.

## Storage

One SQLite database per root (`experiences/experiences.sqlite`), on the GRDB the app already uses for memory, context, cognition, the knowledge graph and activity. It holds the record's two grains:

- **Experiences**: an `experience` row per birth and an `event` row per append, each birth or append one transaction. Reads by id, open/recent collections and `born(kinds:after:)` join births with ordered events in one snapshot and fold through the same transition law. Experiences have no retention horizon; how long they keeps their life is theirs to decide once they can see it.
- **Details**: what the body noticed while a happening ran (a turn's steps, model calls and tool dispatch, standalone receipts), one `detail` row each in one ordered sequence (`Experiences/Detail.swift`). A detail names the experience it is about (`subject`: a turn's id is its heard experience's id, or empty for none), its `kind`, its time and its row; a `once` key writes it at most once. Details are never folded and never copy substance. The store forgets details older than two weeks itself, after a write, at most every six hours; nothing else trims them. Trace writes are batched, one transaction per flush (`TurnTracePersistLane.appendBatch`), and every commit syncs to disk.

Domain stores stay where they are, and the experience references them.

## Remaining gaps and open questions

- Durable phone acceptance is not implemented by the checkpoint's transport
  verdict. Later iOS rendering and installed-build verification remain as
  described under [Phone projection](#phone-projection).
- The archived E4/E5 proposals describe broader mind integration and competence
  claims. The implemented owner boundaries above do not establish that full
  design's coverage.
- Retention: how long experiences stay whole, and what they keeps, is theirs to decide once they can see them. Details have the body's two-week horizon (Storage).
- Peers' experiences: whether another agent's addressed outcome is an experience of theirs, or a reference to theirs.
