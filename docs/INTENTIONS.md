# Intentions — what they means to do

Status, 11-05: built in source — the form (rhythm, until, say), clock moments,
person and news moments,
the "What I mean to do (mine; I do what's safe now, and raise one only when it's done, it needs someone, or I'm asked)" feed in every turn, Today's
Ahead, and moments as clock times and owed `moment` happenings
([Moments, as built](#moments-as-built-11-05)). Fixed-word delivery without a
thought, promises the agent makes (through the existing after-turn reflection),
body-signal moments and habit calls with their formation suggestions (HABITS
H1/H2) are implemented in source; release build, install and proof on the
maintainer's install are pending with the integrating release.

## As built, 10-30

An intention is an open `DeskStep` in MY QUEUE or a captured promise on work
assigned to the agent: `words`, the existing `when`,
optional `rhythm`, `until`, `say` and `action: {action, args?}`, with its origin
and reply route. Older action strings read as `{action: string}`.
`queue.add` and `queue.update` accept `at <ISO time>`, a plain local date/time
with optional weekday (for example `Sun Nov 1 at 06:00`), `every <five-field cron>`, `every N
minutes|hours|days`, or a recurring schedule object as `when`. The stored
clock rhythm uses `IntentionClock`; it is not a new store or a `moments`
array. An omitted rhythm end is `standing`; a single moment defaults to
`once`. A condition in words closes when the after-turn judgment sees it met.
The system date reader interprets local words in the Mac's zone; accepted
moments persist as absolute ISO timestamps. An incomplete match, a range or
a repeated local clock time refuses with the supplied text and its reading;
an ISO timestamp with its UTC offset resolves a repeated time. No detected
date is an unrecognized input, never a ready/done verdict.
An explicit `standing` end is retained for person/news/signal moments too;
it is not coerced to `once` when no clock rhythm is present.

**Body signals (source built).** `queue.add` also accepts `on <signal>`,
stored in the existing `when`. A nonempty name matches itself or its
colon-delimited family; file paths also match descendants at a `/` boundary,
so `on file.changed` means any watched file and
`on file.changed:~/Downloads` means that folder and below. A leading `~`
expands before storage; file matching uses the same workspace/path resolution
as part watches. `on message.arrived:telegram` waits for that door.
`schedule:` names are refused in favor of rhythms. `held` and `resumed` are
part lifecycle signals and do not release intentions.

`EnginePartWake`'s existing signal observer releases matching open,
unstopped, unexpired intentions through system Desk notes:
`Released: <signal> <one-line payload summary>`, with the summary redacted
and bounded to 160 characters. The Desk lock reads and appends together, so a
closed or refiled intention cannot be released from an older snapshot. News
and body signals share one readiness law: a system note carries the exact
current condition in `releaseCondition`, newer than both its current `filedAt`
and their last agent handling note. The `Released: ` text is presentation only;
ordinary notes never satisfy a condition. A changed topic or signal cannot
reuse the previous condition's release. If no release arrives, the intention
remains waiting. Each source edge then uses the same pursuit refresh
as news; a part's deferred delivery does not release it again. Signal moments
are prompt, like news and presence, and the moment's line names the release.
File generations written by an intention's own habit or thought (including
parts called within it) do not release that same intention. Its work identity
owns the self-write stamp independently of the called part; other intentions
watching that file still receive the change. Suppression uses the same exact
file-generation registry as part echoes, never a time window; directory
metadata alone cannot prove an echo and does not suppress member news.

Open file-path intentions join the same `EnginePartWake` watch index as part
headers, one watch per canonical path. Desk changes refresh their membership
through `LatestRead`; closing an intention removes its watch unless another
intention or part still needs it. Directory watches share the senses' existing
8,000-member bound and symlink/type refusals; nested file edits count even
when the folder's own timestamp is unchanged. Ordinary directories now use
the same gated metadata-only admission as document packages, replacing the
package-only restriction for watch metadata. No second watcher or signal
store is added. Home and the turn's intention feed name `on <signal>`;
Today's Ahead remains clock-only.

<a id="moments-as-built-11-05"></a>

**Moments, as built (11-05).** Each open step's next time (`at`, `every`) is a
time on the one clock, `moment:<handle>`; when work for when the agent is free
waits, the agent's next free time is `moment:free`, 30 minutes after the last
turn settles with no conversation open (`MyQueue.freeAfter`). A time whose step
closed or changed is withdrawn (`NativeCognitionRuntime+Pursuit.swift`,
`keepTimes`). Each delivery, Desk change and release reads MY QUEUE once
(`MyQueueReady.due`): steps whose until-time passed close; what came due (its
time or rhythm's occurrence, its released signal or news, the person arriving
or leaving, its card succeeding, or free time) is taken once per occurrence,
keyed `queue:<handle>:<occurrence>`. `next_turn` and `when_user_messages` steps
join turns instead; the agent's own next turn is its next thought.
The Desk's terminal state also owns a moment already posted to attention.
Before carrying it into a thought or returning it to a conversation,
`MindStream.currentQueueMoments` reads the Desk: done settles the moment with
the Desk handle as evidence, canceled lets it go. An explicit archived record
provides the same terminal evidence. Missing or unreadable Desk evidence makes
no terminal decision: that moment stays owed with a named repair while unrelated
happenings proceed. The existing Desk observation includes its archive; a change
re-offers still-owed queue moments through their recorded routes, including returns
to conversations, for a fresh Desk read. An offer invalidates its route; the stream
reads owed happenings at entry and on carry release, including failed delivery.
Desk evidence is checked before taking a carry. Offers during that work coalesce
into another read; failure alone never retries the same happening in that drain.
Before any admission or model work, one `attention.batch` detail accepts the whole
return: route, unique delivery id, ordered happening ids and text digest. Its once
key is the delivery id. A failed write runs no model and leaves every member owed
with the cause. Entry and carry release read open batches first; recovery uses
their exact members and digest. Those members cannot join a new batch with later
offers. The batch row is acceptance; there are no claim-time member acceptances.
Its one `attention.batch.terminal` record and every member's resulting obligation
commit in a single experience-store transaction; any member-write failure rolls
back that terminal and all member changes, leaving the batch open for settlement.
No member can escape into a separate return after partial acceptance. Batch rows and
terminal records are retained beyond the ordinary detail horizon.
Older interrupted return claims without rows adopt today's whole-route grouping
once, under their existing delivery id and digest; their model work is never
replayed. After recording, recovery reads the batch rather than the old claim.
Ledger-owned returns are checked before steering as well as before a model run.
Returned output is cached through `settle`; stopped output and its lifecycle
`stopped` phase commit together. Transcript recovery preserves that phase, and
delivery reconciliation cannot deliver the partial. The batch's same settlement
path stops its lifecycle delivery before writing the batch terminal. Stop leaves
its happening members owed, as a stopped thought does today; only a later real
offer can accept them into a new batch with a new delivery id. The stopped
delivery never reopens. Stop releases the carry and reads what remains owed
without starting another effect in that drain.
Claimed care crossings and night readings retain their own thought admission.
Idle refreshes and unrelated source changes do not re-offer moments. No repeated
post, restart, timer or second pending-moment list is needed.
The due selector, next-clock selector and next-turn selector all exclude
terminal Desk items; no second completed-step list is kept.

Taking a moment runs its reflex or posts it. A habit runs first (below). Fixed
words (`say`) owed to the person or originating with `self` are said as they are.
Each admission reuses `MyQueueReady.due` at the current time against the
current Desk revision, including after suspension before a habit call, speech,
or a new moment post. A changed or unreadable revision returns the remaining batch
to the fresh readiness pass; a crossed until-time or grace boundary admits no
old occurrence. Each check reads free time from `ChatTurnSteering`, so a turn
that began and ended during an earlier habit renews the free-time wait. Time
alone making a captured occurrence ineligible requests a fresh pass to close
or re-arm it. A pre-call reservation whose admission changed is withdrawn
through settlement only if its exact receipt and data-root life still match;
no action began and the fresh pass may admit unchanged work. Once an action
begins, its real receipt and owed settlement are kept however work ends.
Handing an already-run habit's receipt to attention is settlement, not new
admission: it keeps the original occurrence and route even if readiness changed
or Stop arrived. The carried pass awaits that handoff through `settle` before
a later occurrence can replace the run.
Everything else is a `moment` happening (`MyQueueReady.line` as its words):
owed to the agent's mind stream, or, for a promise to the person, to the
conversation it was made in, replying by its recorded route. It opens a thought
at once; a thought carrying exactly one step is that step's work
(`workIdentity` `carry.<handle>`). Speech uses locked claims and transcript
commitment evidence, without a clock-based quota.

**Fixed words need no thought (source built).** Direct delivery uses
`chat.speakProactively`, caller `.reachOut`, and the
person's `ConversationAnchor` destination, with that conversation's own route as
`chat.post` uses, while no conversation is live. It starts no thought or model
call. The speech key combines the item handle and
the moment's key, so a retry reconciles the original transcript destination and
cannot post those words twice for that occurrence. A new post makes the neutral
shoulder tap "Left you something in chat. No reply needed.", pointing at the
destination conversation. The words land at their time; declared quiet hours
hold only the tap, through the attention router's quiet-hour policy.

Successful speech settles through `settle`: an agent-authored Desk note,
`Said <MyQueue.shown(now)>: "<words>"`, records it. A `once` intention then
closes with reason `said`, using a fresh unchanged-step snapshot because the
note advanced `updatedAt`. A rhythm stays open; an until-time still ends it.
MY QUEUE's carried ledger (`desk/my-queue-carried.json`, `MyQueueCarried`)
records the delivered occurrence and its owed notes/once-close in one write.
Each pass finishes those debts with idempotent agent notes and a fresh
unchanged-step close, then marks them settled. Recovery never speaks or runs
the habit again; a changed or already closed step is left alone. Speech
failures leave the intention due for the next read, never turned into a
thought. Installed proof remains owed.

`mind.cross {line, watch}` posts real input as a `world` happening: it releases
the news intentions it touches like any source's line, without fabricating a
release or making a nonmatching intention ready. Its `preview:true` refuses
before posting ([Subconscious](SUBCONSCIOUS.md#run-a-clock-owner-now)).

**Habits (H1/H2, source built).** `queue.add` can bind an `action` call;
`queue.update {id, action?, say?, when?, until?}` changes only named fields
under the Desk's unchanged-revision transaction. `action:null` drops a habit,
`say:null` clears its words, and binding/changing/dropping leaves a step note.
`until:null` removes the ending condition (once); `when:null` resets the
moment to `next_turn` and clears its card/rhythm. Omitted fields stay intact.
Receipts name the stored habit. At a carried moment the action runs first,
through the same self door, Autonomy and Trust posture as a part wake, with
the step's peer steering retained. A successful run without `needs_me` gets
its `Ran h:mm a: <one-line result>` note and the same until settlement as
speech. If `say` is present it is spoken only after that success, then both
notes and the one until settlement are kept. Conditions in words still post
the moment for the agent to judge. Failed/refused/unfinished/person-waiting runs
and returned `needs_me` post the moment with the receipt beside it as
`already_looked`; the run is already done, so the thought starts from its
result. The carried ledger keeps each attempted run before its effects and
retains its receipt; interrupted runs and speech retries cannot blindly repeat
the action. `effects:"unknown"` anywhere in the receipt or returned result is
unfinished: its moment is posted with `already_looked`, never closing the step
or sending its `say`.
The habit's own `chat.post` uses the same deduplicated speech owner without
a clock-based quota.

After a thought carrying one step, its complete top-level dispatch evidence
and model-call count record a trial off the turn path: the two completion
notifications join in either order, once per turn. The last eight handlings
and the one `Expectation.stands` cost law may add a once-per-day
suggestion beside the step's moment; the agent alone chooses `queue.update`.
[Habits](HABITS.md) owns the bounds, costs and forming contract.

Today's **Ahead** reads the next clock moment of each open, unstopped queue
step (`at` or `every`), excludes expired intentions and moments beyond seven
days, and shows the soonest five as `<time> · <clipped words>`: the words are
cut at a word (`TodayWords.spoken`, an ellipsis where cut) and before any file
path or id, and the row's detail keeps every word as the pill's tooltip. The
time is `MyQueue.shown` on the Mac's clock. The existing dream and horizon rows
remain, interleaved by due time. Both visible and quiet Today use the same
checked native facts and authored face; queue read failures remain unavailable
evidence. Desk writes invalidate this reading.

`schedule.create` schedules reads only: `connector_action` (a watch) and
`proactive_scan`, each a time on the one clock (`TriggerScheduler/ScheduledReads.swift`,
`watch:<id>`, `scan:<id>`); any other kind refuses as unsupported, and the action's
description points intentions, check-ins and reminders to `queue.add`.
`schedule.list` and `schedule.delete` read and withdraw them. The night, REM and
part schedules are the app's and the parts' own clock times
([What stays a rhythm](#what-stays-a-rhythm)).

## Promises they makes

The same after-turn interpretation that reads each
exchange for memories, affect, caring and cares returns optional
`promises`: things **they** said they would do later in **this reply**, never
what the incoming speaker promised, a completed action or a conditional they
declined. A draft, idea, possibility or offer awaiting someone's choice undertakes
no work, even if a sentence uses "I'll"; the whole reply decides its meaning.
Live interpretation requires `committed: true` for their own specific undertaking;
missing or false commitment evidence refuses interpretation and leaves it owed.
Saved meanings retain their accepted promises without rejudging them on recovery.
Each has `words` in their voice, `when`, and `source`, the exact
sentence from their reply. A promise is one specific thing they will do; how they
will act from now on ("when X happens, I'll Y", "I'll always…") is a lesson
about how they works, never a queue step. No separate promise store exists.

The supported moments are `next_turn`, `own_turn`, `when_user_messages`,
`after_card <id>` only when their reply names that approval id, and
`at <ISO time>` only when they named a time, resolved on the exchange's Mac
clock. A commitment without a named supported moment uses `own_turn`.
The native parser checks nonblank words, an exact reply source and a supported
moment; an approval id must also occur in their reply. No promises is `[]`;
an absent section in a model reply also means none. A malformed present section
refuses interpretation with its exact validation cause and leaves the turn owed.
Saved meanings require their promises array; missing or invalid saved promises
stay unavailable or meant for repair, never settle as an empty judgment. The
[memory map](MEMORY_SYSTEM_MAP.md#the-memory-manager-lane) owns this parse contract.

Cancellation creates no failure wait. A matching judgment returned before Stop
is retained through settlement and files on the next drain without rematching.

A promise closes because their body saw the deed; they never files the closing.
The shared after-turn interpretation, at once or when owed, receives open moments
across conversations, the person's recorded incoming words, this turn's
completed acts and whether their reply reached a person (`reply_delivered`).
Each `settled` entry names the shown handle, `outcome:done|let_go`,
`basis:person_words|act|reply`, an exact evidence quote and the model's reason.
Person-origin words can say work is done or release it, wherever spoken,
including channels and groups. Letting go closes as `canceled`, never `done`.
Peer and self words grant no person authority; their reply, a page or a card
cannot supply it. Their delivered reply proves only its own saying: `reply` is
`done` only, needs `reply_delivered`, quotes their reply on this turn exactly (the
same check their promise sources use) and settles only a moment that ends once
whose deed is saying something to this person (telling, answering, reminding,
reporting back, asking); a rhythm or standing step is never ended by one
saying. A reply that says other work was done is a claim, not proof of it.
`reply_delivered` is true only when the recorded turn's reply settled
(`repliedAt`; a failed or stopped turn records none), is not empty (a chosen
silence), went out on a local route where saving it is delivering it
(`AgentBridgeCompletionRoute.Kind.local`: the app's own chat), answers the
person or their own moment rather than a peer or standing agent, and sits in a
direct or channel conversation (never their own stream or a peer's). A surface
that posts after the after-turn work starts (Slack, Telegram, the phone) has no
delivered fact at judgment, so its reply settles nothing; person words and acts
still settle there. A repeating or standing moment is done only when its work
is finished for good, never by one occurrence's act; when it is, it closes for
good, as `queue.done` closes it. An act can prove only `done`: its exact `act_id` must name
a successful non-preview closing dispatch from this recorded turn. The quote
must occur in its result or receipt, not just its intended arguments.
The model judges whether the result fulfills the specific promise, including
its target, scope and delivery. Similar work, accepted requests, failed or
refused acts, unknown effects and missing evidence do not prove fulfillment.
No keyword matcher or second settlement call makes that judgment.

The act read uses the trace owner's `tool.dispatch` records under the turn id,
including nested calls, using whatever completed receipts are recorded so far.
No `tool.dispatch.closed` record is required: joined arrivals and other turns
without one still receive the same interpretation of their incoming words.
Missing acts supply no evidence and never hold those words unjudged. An unavailable
read is disclosed as `completed_acts_unavailable` and traced through
`memory.promise.evidence`; interpretation proceeds with the words' own authority.
No clock chooses an outcome. An unreadable sibling
detail is reported by `memory.promise.evidence` and supplies no evidence; usable
siblings proceed. Arguments retain the trace's existing preview, the result
contributes at most 1,024 characters with an explicit shortening flag, and the
owner's compact receipt remains alongside it. No history is added to these acts.
Only references, the evidence quote and the reason persist in the saved judgment;
the owner is read again before an act-based closure writes. Person chats and
peer turns carry their own acts. Care-bearing self wakes also settle work from
their acts; their interpretation prompt asks for no new promises from the thought,
as before. Application preserves the returned promise judgment. Any turn without
an incoming message from someone (their own stream and lines, returns, approval
continuations, ephemeral turns) is a moment only when it completed an act while a
moment was open, judged for settlement alone with basis `act`
([lived moments](SUBCONSCIOUS.md#lived-moments)); with no completed act it is not
a moment and costs no model call.

No evidence closes nothing; malformed or incomplete judgment stays owed.
Both model and saved interpretations require `settled`; missing outcomes or
evidence have no default. A turn left owed runs no interpretation or
settlement at once; its owed judgment does, when they are idle. An unavailable
open-moment read leaves interpretation owed, never an empty Desk.
Settlements use `MyQueue.finish`, the same closure as `queue.done` or `queue.drop`,
with the reason, outcome, evidence quote and recorded turn; act reasons also name
the dispatch receipt id. A `settled` trace names its basis (`person_words`, `act`
or `reply`), never the quote. The Desk checks
the judged row's `updatedAt` before closing it, so newer work is kept. A closed
resume step also releases its saved run through that shared closure owner.
`desk.read {handle}` exposes that reason; `desk.set_status {handle,status:"todo"}`
reopens a live terminal row, subject to the existing parent and hold rules. The judgment is retained
before writing; replay recognizes its exact terminal reason in live or archived
Desk evidence rather than closing or recreating work again. Missing evidence
never means settled, and one failed settlement leaves usable siblings proceeding.
After meaning is durable, `AdaptiveMemoryPromoter.applyPromises` reads its saved
settlements. Only promise candidates without a recorded landing ask
`capturePromises` to match against fresh open carried rows: MY QUEUE and work
assigned to `agent`, excluding pursuits. That filing call receives no person
words and makes no settlement judgment. It groups a burst about one commitment,
selects the open row holding
that intent despite different wording or session, and creates only when none
holds it. Desk housekeeping (tidying, merging, collapsing or closing their own
rows) is an act on those rows or nothing, never another step. Only substantive
work in a mixed sentence is kept. No word-overlap rule or guard list judges
intent. Live reflection and later owed reflection/refolding use this same
path. A fresh match sees earlier landings; refolding reuses its retained
matching judgment and reads landing identities before filing.

`MyQueue.capture` lands the burst under the Desk write lock. The judgment covers
the open rows it was shown; selected rows are matched by id in the current
carried work at write time, even if they changed since judgment. Unrelated row
edits do not invalidate capture. A missing or no longer carried target leaves
that filing owed; it never becomes permission to create. Restatements update
the existing step's words, condition and exact reply evidence; a repeat without
an explicit moment change keeps its
condition. Rhythm, action, `say`, `until` and original provenance remain held.
An agent-assigned row without a step receives one on that same row; captured
steps use the same readiness reader. Attaching a step stamps its own filing
time after the row's latest change, giving it a new occurrence rather than
reusing the row's earlier occurrence. New commitments use the ordinary queue
creation transaction without a second lexical match. Filing, attachment and
approval resumption share the step's title projection. Attachment writes that
title before the step, so a landed capture cannot retain an unrelated title
that makes its approval follow-up appear changed. The step records the
settled turn's session, origin principal, persisted envelope (nil if absent),
and the exact carried sources and elevated sources `queue.add` would have used
on that turn. Those are captured at transcript settlement, before the later
reflection can borrow another turn's identity. Older inputs retain their
recorded source checkpoint and bridge identity; an unrecorded principal stays
nil. An untrusted peer's turn can still contain **their** promise: it is filed
with that peer steer, leaving effect authority with the usual gates.

Each original moment/candidate has a `promiseCaptures` identity on the canonical
`DeskStep`. Refiling and step replacement carry those identities forward;
reference refreshes without an incoming step retain the capture-bearing step.
The archive retains it too. Recovery reads live, terminal and
archived refs before judging, so a landed promise cannot be recreated because
another channel stayed owed and its row was subsequently closed. A missing
identity supplies no semantic verdict; remaining candidates still need the
filing judgment. Capturing a promise never merges or closes existing rows;
only an evidence-backed settlement in the saved interpretation closes one.

Meaning matching and their own closing bound inferred work; there is no count cap.
An unreadable Desk/archive, invalid judgment or incomplete provenance leaves the
saved meaning owed with its actual cause in `RepairOwed`. The moment retains its
matching result before filing, including abstentions, so refolding and partial
filing do not purchase that judgment again or recreate captured rows. A retained
judgment's local write has no wait and retries once on the next drain. Before
matching, a typed wait is kept in the journal: provider waits require a changed
route or another answer there; a Desk read before matching waits on its live,
base and archive file identities and access attributes. Missing provenance or a
damaged retained judgment states its cause and owes repair without a wait.
Eligibility reads only its named dependency. A newly held turn releases neither
provider nor Desk waits. With no promises, saved settlements or retained filing
judgment, application reads no Desk state or recovery dependencies. Settlements
already retained in meaning need no provider wait. [Cognition wiring](COGNITION_WIRING.md) lists
every remaining model wait and its exact release.
The judgment must classify every candidate exactly once; missing groups never
mean ignored. `memory.promise` traces report `matching`, `ignored`, `added`,
`updated`, `reused`, `already_captured`, `settled`, `already_settled` or `failed`; landings name their Desk id.
A provider that never settles leaves matching open until its terminal event or
cancellation; no clock chooses an outcome.

- **Timing.** On User's turns a promise is filed as soon as the turn's
  reflection runs. On other turns (agents, wakes, helpers) reflection runs
  alone, in their quiet, when live work releases the interpretation owner. No elapsed delay runs; unavailable judgment or
  incomplete recorded provenance leaves the moment owed. A queue refusal preserves the promise obligation with its actual cause.
- **Already kept.** Explicit filings from the turn are part of the same open
  Desk input. The filing judgment recognizes them by intent and preserves their
  conditions unless the reply explicitly changes the moment. Original capture
  identities prevent refolding from filing the same source again.

## The nature

An intention is something they means to do, held until its moment and let go
when its point is met. People don't run cron. They remember to do something
when the time comes, when someone walks in, when a name comes up. They works
the same way: one form, the moments that bring it back, and an end.

There are three kinds of moment, and all three reach their through organs they
already has:

- **the clock**: MY QUEUE's times on the one clock
- **the world**: every `world` happening, whose words weigh open news
  intentions; presence; and the same body signals that wake parts
- **talk**: "came to mind", which weighs what is said and read

## Why (their data before this change, 10-29)

Before this change, they had two forms for one thing (10-29 snapshot).

- **MY QUEUE** (`Desk/MyQueue.swift`): what they carries. It held their words,
  a `when`, an `origin`, a `replyRoute`, and `queue.done` / `queue.drop`, and
  it woke their through `ResidentWake.carriedArrival`. They used it 10 times in
  10 days, mostly with `after_card`. It had no time rhythm and no end.
- **The scheduler** (`scheduler/jobs.json`): everything timed. It holds 35
  jobs, 29 of them dead. It has no end at all (`ScheduledJob`: only `oneShot`).
  The cost of that:
  - "Hourly until 3 AM" became 9 one-shot jobs.
  - "Nag User on Nov 4" needed a second job to cancel the first.
  - A day-pinned cron with no year rolls over to next year.
  - They had to pick a kind (`turn`, `workshop`, `notify`) before they could
    mean anything.
  - The 4 PM check-in User set up was refused by the hourly unprompted-post
    limit, because a job's post looked like their own reach-out.

## The target form

One `DeskStep` in MY QUEUE, grown. Nothing new is stored elsewhere.

| Field | Meaning |
|---|---|
| `words` | What they means to do, in their words ("get User's answer on L1X P2P for everyone") |
| `moments` | Design: what brings it back (below). As built, `DeskStep.when` stores one moment |
| `until` | When it is done (below) |
| `say` | Optional fixed words for the person: delivered as is with no model call when owed to the person or originating from self; otherwise the moment opens a thought |
| `origin`, `replyRoute` | Who it is for and where its words go (existing) |
| story | Desk notes on the item: each time it came up, what they did, with a pointer |

### Moments

| Kind | Example in their words | Source |
|---|---|---|
| clock: once | "at 5 pm", "in 20 min" | MY QUEUE `at <ISO time>`, a `moment:<handle>` time on the one clock |
| clock: rhythm | "every day at 9 and 4", "every 2 h 9 am–9 pm on Nov 4" | `every` with a step rhythm, a `moment:<handle>` time on the one clock; `IntentionClock` uses the clock's rhythm math and the step's filing time/until; home shows the next time |
| person | "when User messages", "when User is here", "when User is away" | `when_user_messages`; `when_user_here` / `when_user_away` require the current `PersonPresence` transition to be newer than filing (the next arrival/departure). It reads Mac input and fresh phone motion; walking/driving newer than physical Mac input can infer away, never here. A silent/stale/unknown phone leaves Mac-only readiness intact. The presence edge refreshes carried readiness; its transition time makes each arrival its own offer. [Phone evidence contract](mobile_companion.md#where-the-person-is) |
| world | "when there's news about the lease" | `on_news <words>`: each `world` happening's words are weighed against open intentions' words with the care law's warm embedder and chance bar (live cares count among the comparisons; no absolute floor), while the agent sleeps too. A touch writes a system Desk note, `Released: news: <first 160 characters> (<door>)`, carrying the exact topic condition. The locked release transaction rechecks that topic and filing revision. Readiness follows the shared release law above |
| body signal | "when something changes in Downloads", "when a Telegram message arrives", "when the network returns" (`when: "on network.up"`), "when the person takes my tab" (`when: "on chrome.tab_taken"`) | Built: `on <signal>` matches exact names, colon families and file descendants. Real sources are `file.changed:<path>` (only watched paths), `message.arrived:telegram`, `message.arrived:slack`, `person.here`, `person.away`, `network.down`, `network.up`, `app.installed`, `sense.source.changed` and `turn.ended`. Network signals require a path state that holds five seconds ([wake contract](skill_manifest_spec.md#wake-signals)). The shared signal observer writes `Released: <signal> <summary>` with the exact condition identity and refreshes carried readiness under the shared release law above. File intentions join parts' existing watch index and leave when closed. `schedule:` is refused; `held` and `resumed` do not release intentions |
| situation | "next turn", "my own turn", "quiet", "after card X" | Existing MY QUEUE readiness |

Talk is not a kind they sets. Every live intention can come to mind whenever
what is said or read touches it.

An accepted date is stored with its year and absolute timestamp. If their local
words omit the year, the system date reader supplies its reading; the queue
receipt echoes the stored `when`, and rhythm receipts show the next clock
occurrences. A stored moment is never reinterpreted in another year.

### Until

| Until | When it ends |
|---|---|
| `once` | After it comes up and they acts. Default for everything except rhythms |
| a time | At that time ("until 9 pm Nov 4"), with no cancel job |
| their words | Checked each time it comes up ("until User answers"); it closes when the after-turn judgment sees them met |
| standing | Rhythms only, set explicitly (the office check-in). Ends only on `queue.drop` |

Elapsed inactivity does not close an intention. MY QUEUE expires only an explicit
`until` time; a deed the after-turn judgment sees, or `queue.drop`, closes it through
its owner (`queue.done` stays their free act, untaught).

## Arrival and pacing

**Between turns.**
- Except for a habit or direct fixed-word speech, a due occurrence is one
  `moment` happening, keyed per occurrence (`queue:<handle>:<occurrence>`) so
  each run of a rhythm is its own, written once in the record.
- It opens a thought in the agent's mind stream (or, for a promise to the
  person, in the conversation it was made in) whose line is
  `You meant to (<desk.N>): <words> …` with its moment and until.
- What the agent says to the person goes to the intention's `replyRoute`. A
  legacy promise without one recovers only proven originating provenance;
  absent or unreadable provenance keeps it waiting for route repair, never
  moves it to Chat. The intention's moments pace it; speech has no hourly quota.
- An eligible `say` intention goes straight to the person's current
  conversation through the shared speech owner, as built above.

**In a turn.**
- A message is only what its sender said. Next-turn and message-triggered
  steps appear only in the changing moment packet, never appended to a person's
  or peer's words. `MyQueueReady.forTurn` marks matching steps `due now`;
  reading them neither runs nor closes them. A dedicated step's thought keeps
  its own `MyQueueReady.line` opening: do it now when safe, reversible and
  allowed, it closes by itself once the work is seen done, or `desk.wait` holds
  it on what it needs. No line teaches closing a row by hand.
  Trust and posture still judge every act; the words grant no authority.
- Every turn carries
  `# What I mean to do (mine; I do what's safe now, and raise one only when it's done, it needs someone, or I'm asked)`
  in its changing context packet,
  beside pinned USER, Live sense news and relevant context. These are plain
  facts in their voice: `- desk.N · <words> · <moment> · until <until>`, with each
  field one line and at most 140 characters. The section is absent when empty.
  A due line reads
  `- desk.N · due now · <head> <rest>` with the whole `MyQueueReady.line`,
  uncapped, including fixed `say` words and the wait instruction.
  The desk.N names what they are shown; `queue.drop` (and `queue.done`, untaught)
  take it as `id` — or the step's own words, when exactly one open step has
  those words (or, failing that, contains them); several matches refuse and name them.
  The carried line that brings a step back (`You meant to …`) and home's MY QUEUE
  rows (ready and waiting alike) name it the same way, `desk.read {query: <its words>}`
  finds it, and `desk.read {query: "my queue"}` lists the whole queue.
- `ChatTurnRuntime/ChatOrchestration+Intentions.swift` reads
  `SwiftNativeDeskStore(dataRoot:).liveState()` and `MyQueue.entries` each
  turn; `TurnContextPreparation.swift` puts the result in `TurnReach.packet`,
  so it reaches both the provider and `diagnostics/fed/<session>.json`.
  No separate store or cache holds it.
  An unread Desk or a failed person-name read withholds that projection and
  puts `MY QUEUE is unavailable; no queued step was admitted this turn.` in
  the changing packet, with its cause and repair owed under the
  [turn's unavailability contract](ANATOMY_OF_A_TURN.md#recall-unavailability);
  unrelated conversation continues. Empty successfully read intentions still
  omit the section without an unavailable verdict.
- A person's turn carries only the steps due on it, plus a count of the rest and
  `queue.list`: handed the whole list every turn, they recited it to the person. Their
  own turns and peer turns carry their lists as below.
- At most six open steps appear: steps due on this turn first, marked `due now`,
  then clock moments soonest first (a rhythm uses `IntentionClock.next`), then
  other steps by newest `updatedAt`. Each line says its moment in words and
  when it ends. The moment packet is retained as sent evidence, never replayed;
  later turns read the live owner again.
- User's turns and their own see steps originating with `person` or `self`,
  including older steps `owedToPerson` identifies. A peer's turn sees only
  that peer's `agent:<name>` steps, even when trusted or elevated; peer
  provenance without an identifiable origin discloses no steps. User's
  intentions never enter that peer's section.
- User mentioning L1X can meet "get User's answer on L1X" already in mind.
  This feed replaces the proposed selector-only atom/nudge and 12-hour rest;
  it neither selects by message relevance nor consumes or closes a step.

**Pacing.**
- A moment opens its thought at once; there is no gathering window, spacing,
  hop limit or rest between moments. A thought that comes while another is open
  joins it by the steering offer. A step with `own_turn` or `quiet` means free
  time: it comes 30 minutes after the last turn settles with no conversation
  open (`moment:free`). Named clock, person, news, body-signal, message and card
  moments never wait for free time.
- A world moment is released once per world happening that touches it; each
  happening is written once under its key.
- Quiet hours hold delivery to the person, not the agent's doing.

## Their words for it

- `queue.add {text, when?, until?, say?, action?}`: `when` takes their words or
  a structured rhythm. Person/world words are `when_user_here`,
  `when_user_away`, `on_news <words>`, and `on <signal>` (for example,
  `on file.changed:~/Downloads` or `on message.arrived:telegram`).
- `action:{action:"authored.<id>",args:{…}}` binds what runs at that moment.
  `queue.update {id, action?, say?, when?, until?}` edits only named fields;
  `action:null` drops the habit, `say:null` clears fixed words, `until:null`
  clears its ending to once, and `when:null` clears its moment to `next_turn`.
- `queue.done {id, reason?}`, `queue.drop {id, reason?}`, `queue.list`.
- The default `desk.read` includes board work and open MY QUEUE intentions in
  one paged list; its agent page shows the same queue separately from the board.
  `place` distinguishes `board` from `MY QUEUE`; each intention carries `name`,
  full `words`, `filed_at`, its recorded `when` and current `waits_on`.
  `liveItemCount`/`topLevelItemCount` count the board; `openIntentionCount` counts
  open MY QUEUE intentions, and `board_counts` says both. Exact, query and
  complete-record reads retain that intention detail. Archives remain explicit reads.
  Waits use the Desk's effective dependencies. A released signal/news condition
  and a clock time already reached are absent from `waits_on`; `when` retains
  the filed condition. Missing release evidence leaves its wait visible.
- `schedule.*` schedules reads (watches, proactive scans); intentions use `queue.*`. Today's "Ahead"
  reads at most five next clock moments within seven days, plus the existing
  dream and horizon rows. "Waiting for: User here / news about X" remains design.

## What stays a rhythm

These are the body's clock, not things the agent intends. Each is a time on the
one clock (`TriggerScheduler/OneClock.swift`), delivered to whoever declared it:

- a part's own `schedule:` wakes (`part:<id>:<cron>`), from its header
- `connector_action` watches (`watch:<id>`) and `proactive_scan` (`scan:<id>`)
- inbox briefs (`brief:<name>`) and helpers' cadences

MY QUEUE's moments are times on that same clock under owner `moment`.
Their own hour is an attention opportunity on a presence edge, not a declared time ([Subconscious](SUBCONSCIOUS.md#the-hour)).

## The one clock (source built, 11-05)

There is one form for what the agent means to do later: MY QUEUE. The one clock
delivers each declared time to its owner; its next occurrence is saved before
delivery, and one missed while the app was quit is delivered once when its owner
registers. The scheduler's job machinery, its runner and its pages are removed.
`clock/times.json` holds the current declarations and delivery or withdrawal
evidence. Launch reads no retired scheduler format or carry-over marker.
Watch and scan handlers register independently: a failed item names its cause
while healthy siblings keep running from their declarations.

## Steps from the scheduler's intentions

Steps filed from the scheduler's intention jobs carry `scheduledJobID`, so the same job never
files a second step. They are ready and archive like any other step.

## Build

| Lane | What | Files |
|---|---|---|
| 1 Form | `moments`, `until`, `say`; readiness per moment; parse their words; the echo | `Desk/DeskCadence.swift`, `Desk/MyQueue.swift`, `AppToolRuntime/AppToolExecutor+MyQueue.swift` |
| 2 Clock | One `moment:<handle>` time per step on the one clock, withdrawn at until; per-occurrence moment keys | `TriggerScheduler/OneClock.swift`, `Cognition/NativeCognitionRuntime+Pursuit.swift`, `AgentWorkspace/AgentQueue.swift` |
| 3 World | Each world happening weighs world-moment intentions by the care law; presence changes ring person moments | `Cognition/NativeCognitionRuntime+Attention.swift`, `Cognition/NativeCognitionRuntime+Pursuit.swift`, `MacControl/PersonPresence.swift`, `EngineRuntime/EnginePartWake.swift` |
| 4 Talk | Bounded open intentions in every turn's packet (implemented above) | `ChatTurnRuntime/ChatOrchestration+Intentions.swift`, `TurnContextPreparation.swift` |
| 5 Surface | `queue.*` args, `schedule.*` off their surface, Today "Ahead", guides | `AppToolRuntime/AppActions+Declarations.swift`, `WorkOverviewRead+Today.swift`, `today-readout.js` |
| 4 Talk | Intentions as context atoms; the "[You meant to …]" nudge; the 12-hour rest | `Context/*`, `ChatTurnRuntime/ChatOrchestration+CameToMind.swift` |
| 5 Surface (implemented) | `queue.*` args; intention creation/updates refused by `schedule.*` with a `queue.add` remedy; Today "Ahead" clock intentions; rhythm-only guides | `AppToolRuntime/AppActions+Declarations.swift`, `TriggerScheduler/SchedulerJobNormalizer.swift`, `WorkOverviewRead+Today.swift`, `today-readout.js` |
| 6 Clock and docs (source built) | MY QUEUE times on the one clock; the scheduler's next occurrences carried over once; Desk and Subconscious links | `IntentionClock.swift`, `EngineRuntime/EngineScheduledWork.swift`, Desk and queue readers |

**Proof on them:**
1. Their two live jobs are intentions; all three source jobs (including the cancel job) are disabled, and the durable pre-rewrite backup retains them. Previously disabled legacy definitions retain words, timing and pause with a first-migration disposition. Later restored legacy jobs stay stopped with one Desk notice; they are never reimported.
2. The 16:00 check-in comes up at 16:00 and reaches User.
3. "Remind me in 2 minutes to stretch" arrives.
4. User saying "L1X" finds its open intention in
   `# What I mean to do (mine; I do what's safe now, and raise one only when it's done, it needs someone, or I'm asked)`
   in their turn.
5. The Nov 4 nag's final clock moment is 21:00; its intention ends at 23:59 local (or the earlier transferred cancellation deadline).
