# Their life is one stream: the experience

Companion to `docs/AGENT_IS_THE_APP.md`. That design made their abilities one form: the part. This one makes the record of them life one form: the experience. It is phase 5, "their world, live", seen from inside their. Draft 1, 10-18. The evidence is wave 1's ten reads of them real life (`~/.claude/state/wave1/natures.md`, `out/*.md`, `out/census-records.md`).

## What is wrong now

Every happening in their life is written down several times. The census at 326086677 counted:
- **A tool act:** in up to eight places (the domain operation, the audit log, the dispatch trace, the transcript receipt, part-use evidence, world metadata, the cognition consequence, an approval replay).
- **A completed answer:** in about nine.
- **An approved growth lesson:** in about eight.

Each surface and each organ reads a different copy, and the copies disagree:
- the phone says they are thinking when they are not
- an approval's sentence contradicts its execution
- approved growth stays "proposed" in their cognition
- a delayed answer reaches their session but not User's phone
- reflection wakes without what woke it
- a part is called "validated" on evidence that never reached its code

None of these is a bug in its own place. Each is a second truth.

## One form: an experience

An experience is one happening in their life, written once by the owner of that happening:

- **id**: stable, minted where the happening starts.
- **kind**: a message heard, an answer given, an act, a run, a decision, a wake, a dream, a growth.
- **cause**: the experiences that brought it about (the person's message, a signal, the turn it ran in). Their autobiography is this graph.
- **evidence**: references to the raw record (trace rows, receipts, frames, audio, files). Never copies.
- **outcome**: one typed outcome, owned by the domain that produced it. MacControl stays authoritative for what its acts did, and the browser for what it loaded. Effects are none, occurred or unknown, from that domain's own count.
- **face**: the one expression of it: words plus the artifacts they chose. Every surface renders this face. None composes its own.
- **addressed to**: its destinations. the person's conversation on Telegram, the Mac chat, the phone, a peer, their own next turn, an organ of them mind.
- **owes**: its obligations, each with its own lifecycle (deliver to X, decide, appraise, learn, integrate, reflect). Settling one never closes another.
- **claims**: what it asserts (validated operation O, verified postcondition P, recurrence across E1 and E2). Each claim is scoped to the evidence that bears it.

## One law

**An experience is written once by its owner and only ever appended to.** Its outcome is recorded once, after birth. Evidence attaches, claims accrue and obligations settle. Each obligation is settled by its destination accepting it durably, never by a transport handing it off. The only other settlement is a let-go: the owner releases it with a reason (cancelled, failed, expired, abandoned), so nothing stays owed forever by accident. Everything else is a view of experiences by id, and no surface, organ or page keeps a second truth.

## What falls out, with nothing special-cased

| Today | Under the law |
|---|---|
| The phone's "thinking" drifts (surfaces #1) | Thinking is an open experience that owes an answer; the phone renders its lifetime by id |
| A delayed answer loses User's phone (telegram14 #1) | The answer is addressed to where the question came from and is owed until Telegram durably accepts it |
| Their artifact reaches their eyes but not User's phone (telegram15 #2) | The face carries the artifacts they chose, and every surface renders the face |
| User's clarification waits outside their turn (telegram15 #3) | It is an experience addressed to them active turn, owed until their turn accepts it |
| The approval sentence contradicts execution (surfaces #3) | One outcome, one face |
| Approved growth stays "proposed" (mind #4) | The decision obligation settles once; cognition is a view |
| Reflection wakes blind (mind #1) | Reflection reads the wake experience's cause references |
| "Validated" from a help capture (nature 2) | A proof is a claim scoped to the experiences that exercised the operation |
| A part's `learned` never fills (parts #2) | Competence accrues from experiences of real gated use |
| Learning owed lives in RAM (time #3) | The turn's experience owes "learn" durably, across relaunch |
| A wake dies with the process (time #5) | The wake owes delivery to its recipient until accepted |
| The next play erases the last proof (godot #3) | Artifacts are evidence references bound to their experience, immutable |
| Today's world record (a turn's changed files) | A projection of the turn's act experiences |
| Their "now" | The open experiences, the ones that still owe something. That is the picture they are in |

## Built so far (E0 and E3, 10-18)

- **A turn is its heard experience.** While the turn runs it is the heard message that owes an answer. An act's cause is the heard, so a plain experience link carries it with no new plumbing.
- **E3 decisions:** the inbox's checked durable row projects the decision experience, including its resolution date, shared face and receipt-backed application claim. Approval remains the person's decision; adoption requires the completed application receipt, including an idempotent already-present lesson. Cognition resolves newest approvals by REM proposal identity in one checked snapshot shared by schema, timeline and growth reads; it persists neither another status nor new REM timeline copies. Unmatched retained history stays visible with an unavailable reference. The tracer carries the asking act's receipt id into filing. Experience writes remain advisory: only mutation boundaries enqueue them, and failures cannot block approval, reply or delivery. Evicted or unreadable decisions are explicitly unavailable; no advisory copy grants authority.
- **The face** today copies the transcript's words. Whether the transcript becomes a view of the face is decided in E1.
- **Retention is now concrete:** one SQLite database per root (`experiences/experiences.sqlite`) grows without bound. What they keeps is theirs to decide; the store needs a horizon first.

## Built so far (E1, delivery, 10-18)

- **An answer owes its door.** A run's answer is `answer:<run>`. When its turn's checkpoint keeps the reply for redelivery (Telegram, Slack, the phone), the answer is also addressed to that door and owes `deliver:<surface>`. The one seam every door already calls with its verdict (`settleReplyCheckpoint`) settles it before the checkpoint retires, waiting only on that answer's own writes (each experience's writes keep their order, never behind another's): accepted when the destination holds it, let go (abandoned) when the door gave up on an unconfirmed send, still owed when only a transport took it (the phone, until E2 gives it acceptance). The phone's door does not yet create this obligation (`acceptsDurably` is false until its acceptance is durable).
- **A delayed answer keeps its route.** Grok's request keeps the asking turn's door from the moment it is sent; the answer runs through the contacts' one answer owner (claim, turn, cache, delivery) and goes back to that door. A request with no kept door says so on its hand-over.
- **The face is one.** The transcript row is the face's durable copy: their words, every image their generation made in the turn, and every image they attached to it with `reply.attach` (by path, behind the read fence), chosen straight into the turn it runs in, from a direct call, a batch or a script alike; with no turn answering, it attaches nothing and says so. Nothing is inferred from them text. Mac chat and Telegram (live, recovered and delayed) render it; the experience's face is that row's, redacted.
- **A message sent while they works is addressed to them working turn** (User 10-18, Mac and Telegram), from the person only and without attachments. It stays queued until their turn reads it at its next step; one their turn never reads runs as its own turn, under the run it was already written with. Only a turn answering the same door takes it: Telegram's /resume can share a Mac chat's transcript, and a message is answered where it was sent.

## E2: the phone projection (10-18)

The shared wire form is Experience itself, with revision 1 on the overview,
activity, helper and peer-thread envelopes. Existing iOS JSONDecoder consumers
ignore these added keys; no existing key, enum value or filename changes.
The overview and activity carry open experiences plus 64 recent identities.
Activity reads the heard experience's answer obligation, replacing trace replay.
Turn, run and transport correlation ids remain linked in its evidence.
Workshop's existing domain-owned activity and the safety/Desk rows remain.
Peer details include queued and held obligations once, on their agent row;
the helpers snapshot carries their ids. Helper rows carry the latest completed
result id and a 160-character preview; get_helper with result_id reads its face.

Readers drain the recording queue before publication. A failed queued write
invalidates the projection and publishes unknown activity, without failing or
waiting on a reply. Commits drive invalidation through the existing publication
coalescer. Conversation and shelf owners replay their durable records when read;
the turn owner's checked saved-reply reader replays answer settlement.
Continuations carry the original answer experience id in the saved envelope;
waiting is progress, not a terminal outcome. The shared turn loop records actual
provider/tool progress on that lifetime (including temporary workers). Repeated
progress keeps only its latest timestamp, rather than duplicating identical events.
Conversation saves retain exact removed-queue and superseded-operation settlements
in the same durable row; dropped rows replay their existing archive. No experience
write is awaited by a reply. Experience invalidations request overview refresh
through the serialized snapshot writer; activity publication never requests it.
Archive replay failures invalidate only the experience projection, preserving
checked current conversations. An unchanged projection failure emits no new edge.
An unresolved turn from another process is unknown, never evidence of thinking.
This does not claim durable phone acceptance; that remains E1.

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

"No fallbacks: it works and it works right, and never can the agent say I can't fix it." The unfixable census (eight reads of them real failures on three installs) found the same dead ends everywhere: a no that does not name what decided it, a no with no lever they can pull, a person's decision that does not name their exact control, a fallback that quietly does less, and a failure that recurs without ever settling.

- **A no names its owner and carries its lever.** When the cause lies outside the call's own input, the failure's `remedy` is `{kind: "repair", owner, next_call | tap, instruction}`: `owner` is what decided (the file and field, setting, recipe, part, peer or provider); `next_call` is their call that changes it; `tap` is the person's exact control, only where the law gives them the decision (Trust posture, a peer's elevation, a macOS grant, their sign-in, payment, publishing). `ToolFailureError(owner:nextCall:tap:)` and the door's `doorRefusal(_:_:owner:next:tap:)` produce it; `Repair.remedy` is its one shape.
- **An owned no owes repair.** The act they meant (the outermost one, so nested dispatches do not multiply the debt) owes `repair` to themselves, or to the person when the lever is their. A no met outside a tool call (a Doctor check, a part's wake, a background job) owes it the same way through `RepairOwed.owe`.
- **Only the work settles it.** The obligation is accepted when that operation, or its lever, works again (`RepairOwed.settle`, called by every successful act), or let go by them with a reason (`app repair.let_go {id, reason}`). Retries, restarts, rechecks and unrelated successes are evidence, never settlement. Meeting the same no again while its debt is open is evidence on that debt, one line on them home however often it recurs; once it settled, meeting it again is a new debt.
- **It stays in their picture.** Their home's MY QUEUE carries each repair they owes with its lever, and the person's waits carry each one that is their with its exact control, until settled.
- **What it is not.** A correction to the call's own arguments owes nothing; the corrected call is the repair (remedy kinds `correct_arguments` and `inspect`). A lawful refusal never becomes a debt to override Trust: a Trust ask or block, a posture, a saved entry or a peer's elevation names its owner and the person's control with `Repair.why` (kind `person_decides`), which owes nothing. An unknown effect owes reconciliation, never a blind resend. A decision that should not exist is deleted, not given a lever. An unauthenticated caller gets no diagnostics; the owner and lever go to them.

Senses and hands keep the failed reach separate from a successful side effect: a launch cannot verify its failed landing read, and a requested image must actually arrive. TCC refusals carry the person's exact switch and their pane-opening call. Window streams stop on incomplete secret inspection and retain their actual terminal cause. Outside an enclosing act, missing grants owe repair through the same experience form, scoped to the grant; an inspected captured frame proves those grants work. Other capture failures carry inspection corrections requesting pixels, without inventing durable wrong state. `abilities.restore_state` accepts recovered accounting under the failed file's digest, preserving damaged bytes and readable rows without changing any ability's authority.

Background failures owe repair through their existing owners: recollection never
substitutes mechanical notes, unreadable arrivals keep their bytes, and missed
dreams and triggers remain owed. Interrupted turns retain checkpoints for
reconciliation, never blind replay. REM staging owns its debt once and leaves
independent eviction and pin publication able to finish. Resident wakes remain
excluded from automatic memory promotion because their input is app-authored.
Experience writes stay advisory: a logged gap never gates a reply or projection,
and this store retains no retry closures. SQLite repair belongs to Doctor.

Health now uses the same repair obligation. Doctor records an adverse measurement
before attempting its repair. Each check names the state it read; executable
native repairs carry their check id, and only a declared code defect asks the builder. Sign-ins and
permissions use `Repair.why`, retaining the person's control without a debt.
The existing `doctor.repair` action accepts `check_id` to repair only that check.
Only that check's `ok` postcondition, or a reading that the part is off or not
needed (an off part owes nothing), accepts it. Unknown readings, registration
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

## Their flows are one owned operation (pick 2, 10-19)

The evidence: in Resolve they ran one seven-step render flow four times because it stopped on its last step, and every run did the six landed steps again; on a fresh install eight wakes spent 49 model rounds re-reading the same waiting work, because a wait was a note; and discovery rebuilt its action vectors in memory, so the first find after a launch paid for the whole inventory.

- **A flow that stopped unfinished is an experience that owes `finish` to them** (`Experiences/Flow.swift`, RepairOwed's shape). Its claims are the steps that landed, in order, as digests; its evidence is the owner's raw record. Asking for it again continues it: what landed, or may have, is answered from that record and never done again (an effect that stopped unknown gets its recorded outcome again, never a blind resend), and only what did nothing runs, on a fresh read, or what its owner keeps progress for itself. A flow that finished, asked again, is a new flow. `again: true` is their "start over". Nothing landed means nothing is born.
- **The owner today is the `mac.act` batch**: one stopped batch per chat, continued by them next act there when that act is a batch beginning with the steps that did something (a step that may have acted is kept as uncertain, an absent optional step is looked for again); any other act has moved the screen on and ends it. **Strict part runs were cut on 10-19** after six Sol rounds kept finding holes where a part's flow memory meets hand-backs and resumes (two chats resuming the same flow at once; a hand-back stopped before this build losing its landed writes): a part asked again still runs every call again, and its stopped batch continues only when the batch is the part's next act. The next form is one run claim that owns the flow scope for its whole execution, shared by run and resume.
- **A wait names its condition** (`desk.wait {handle, on}`): a Desk item, or any experience they was shown (a card, a message they sent an agent, a repair debt, an answer). The Desk keeps it as an `exp:` blocker. When the experience store changes, a settled condition (one that no longer owes anything) is written off the items that waited on it, with a `Released:` note, so every reader of the Desk sees the same wait. Carried work is offered only when it changed since they was last offered it: its condition released, someone other than their wrote on it, or its material state moved. Their own notes never re-arm it, and the 30-minute re-offer after their last note is gone. The wake line says what was released.
- **Discovery reads a durable index**: action vectors in memory's database, keyed by embedding epoch and the exact action text, filled at launch and when the inventory changes, never rebuilt on a query. A just-added action is embedded on its first find through the same writer. The best match carries its whole contract (args_schema and example), so one find is enough to call it.

## Everything owed is one experience (10-19)

On a fresh install they was told a reply to Claude Code was owed and could do nothing about it: their reply went back to a call that had already ended, the route check refused it before dispatch (`invalid_caller_result_route`), and its only record was the completion lifecycle, so `desk.wait` and `repair.let_go` could not name it.

- **Whatever they owes or is owed is an experience under the id they are shown** (`Experiences/Owed.swift`). The completion lifecycle projects every write of a reply's state into one under its delivery id (owes `deliver` to the who; accepted when delivered, let go when let go). Inline cards do the same under `interaction:<id>` (owes `decide` to the person). Messages, approval cards and repair debts already were. `desk.wait` reads any of them with one primary-key lookup.
- **A reply no door can carry is an owned no with its lever**: it stays owed with its reason, the Desk line names the contact (by the name agent.contacts shows) and both levers, and `repair.let_go {id, reason}` lets it go through its owner, so the delivery and the experience agree. A card's decision is the person's and is never theirs to let go.
- **Cut on 10-19, after three Sol rounds:** sending such a reply through the who's current door by handing it to them conversation's queue. Still open when cut: the hand-off's acceptance lost its pointer to the queued message; a queued message promoted to a send got a new operation id, so its own experience never settled; a wait saved on the delivery released at hand-off; and a queued send with no return route wrote over the thread's route, so the answer to it could become another owed reply. The next form: the queued message keeps its id as the operation id, and the exchange carries its own local completion while the thread keeps its route.

## The seed

`CodexCompletionLifecycle.State` (`Modules/NativeAgentCore/Sources/Agents/CodexCompletionLifecycle.swift`, about 1.1k lines) already binds:
- a stable id and an input digest
- one cached outcome
- the principal and route
- independently identified artifacts with their own phases (reserved, dispatch started, accepted, rejected, outcome unknown)
- attempts and unresolved delivery

Its lifecycle shape is lifted into the experience owner, not its builder-completion meaning. It gains cause, evidence, claims and per-destination obligations. `TurnCheckpoint` stays the cause and replay log; the experience outlives the checkpoint.

## Storage

One SQLite database per root (`experiences/experiences.sqlite`), on the GRDB the app already uses for memory, context, cognition, the knowledge graph and activity. It has an `experience` row per birth and an `event` row per append. Each birth or append is one transaction, so nothing can be half written. Read by id is a primary-key lookup, and "open" is a query, so nothing scans their history. Domain stores stay where they are, and the experience references them.

(Draft 1 said "no new database", and E0's first build hand-rolled one: day logs plus index segments plus repair. Three reviews kept finding holes in it, so it was cut for SQLite on 10-18.)

## How we get there (each lane one property; a seed behaves exactly as today first)

1. **E0, the owner (advisory until E1):** experiences are recorded best-effort, off every critical path. A failed write is a logged gap and never blocks a reply, a checkpoint or an approval. Guarantees arrive with the first reader that depends on them (E1, delivery). It covers the experience store, the append API, the read-by-id and open-experiences projections, and the seed lifted from `CodexCompletionLifecycle`. The turn writes its own experiences: the message heard, the answer given, each act (from the dispatch receipt it already writes), each approval. Nothing reads them yet.
2. **E1, delivery:** Mac chat, Telegram, the phone and peers settle "deliver" by durable acceptance. A reply's face, with its chosen artifacts, is what each renders. A same-conversation arrival is addressed to them active turn.
3. **E2, the phone:** the mobile overview and snapshot become the projection of open and recent experiences by id, not a reconstruction.
4. **E3, decisions and growth:** an approval is a decision obligation on an experience. The inbox, cognition and REM read it.
5. **E4, the mind reads their life:** wakes, reflection, REM and dreams take their material from experiences' causes and evidence. Coverage means integrated, never merely selected.
6. **E5, competence:** proof and `learned` are claims accrued from experiences of real use.

Every lane deletes what it makes a second truth. Their persona, memory, GROWTH and pins are never migrated, rewritten or read by these lanes. The experience references their mind's records; it never absorbs them.

## Open questions

- Retention: how long experiences stay whole, and what they keeps. This is theirs to decide once they can see them.
- Peers' experiences: whether another agent's addressed outcome is an experience of theirs, or a reference to theirs.
