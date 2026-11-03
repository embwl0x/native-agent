# Intentions — what they means to do

Status, 10-31: built in source — the form (rhythm, until, say), clock moments,
person and news moments, the "What I mean to do" feed in every turn, Today's
Ahead, schedule refusals for intention kinds, and the launch migration.
Fixed-word delivery without a wake is implemented in source; release build,
install and proof on the maintainer's install are pending.
Promises they makes are also implemented in source through the existing
after-turn reflection; installed proof is pending with the integrating release.
Body-signal moments are implemented in source; installed proof is pending
with the integrating release.
Habit calls and their formation suggestions (HABITS H1/H2) are implemented
in source; build, install and proof remain with the integrating release.

## As built, 10-30

An intention is an open MY QUEUE `DeskStep`: `words`, the existing `when`,
optional `rhythm`, `until`, `say` and `action: {action, args?}`, with its origin
and reply route. Older action strings read as `{action: string}`.
`queue.add` and `queue.update` accept `at <ISO time>`, a plain local date/time
with optional weekday (for example `Sun Nov 1 at 06:00`), `every <five-field cron>`, `every N
minutes|hours|days`, or a recurring schedule object as `when`. The stored
clock rhythm uses `IntentionClock`; it is not a new store or a `moments`
array. An omitted rhythm end is `standing`; a single moment defaults to
`once`. Conditions in words remain theirs to close with `queue.done`.
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
are prompt, like news and presence, and the carried arrival names the release.
File generations written by an intention's own habit or wake turn (including
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

**Fixed words need no thought (phase 2, source built).** When
`considerCarried` chooses a ready MY QUEUE entry with nonblank `say`, it
delivers those words directly if the step is owed to User or its origin is
`self` or `person`. An agent-born `say` keeps the existing wake path. Direct
delivery uses `chat.speakProactively`, caller `.reachOut`, initiative
`.intention`, and User's `ConversationAnchor` destination, with that
conversation's own route as `chat.post` uses. It starts no wake or model call
and neither spends nor waits for the hourly proactive quota.

The speech key combines the item handle and its occurrence: the rhythm's
`IntentionClock.occurrence`, the `at` time, or the existing carry fingerprint
and latest non-agent note for other moments. A retry reconciles the original
transcript destination and cannot post those words twice for that occurrence.
A new post makes the same informational phone knock as a delivered Reach
offer, pointing at the destination conversation. The words land at their
time; declared quiet hours hold only the knock, through the attention
router's quiet-hour policy (what reaches User waits, their doing does not).

Successful speech settles through `settle`: an agent-authored Desk note,
`Said at <ResidentWake.shown(now)>: "<words>"`, records it. A `once` intention
then closes with reason `said`, using a fresh unchanged-step snapshot because
the note advanced `updatedAt`. A rhythm stays open; an until-time still ends
it as before. The existing `ResidentWake` ledger retains an accepted carry
record with that occurrence's material fingerprint, so the same moment is
not offered again. That same durable write retains the unchanged step and
its owed notes/once-close in the wake ledger. Each carried pass and launch
finishes those debts with idempotent agent notes and a fresh unchanged-step
close, then marks them settled. Recovery never speaks or runs the habit
again; a changed or already closed step is left alone. This spends no wake
or thread hop.
Speech failures leave the intention ready for a later carried pass and never
fall back to waking a turn. A committed duplicate can establish delivery
when interrupted before the ledger write; saved settlement debts finish
without another post or knock. Installed proof remains owed.

### Run carried work now

`app {action:"mind.carried"}` enters the existing `considerCarried` path with
the free-time quiet interval satisfied. It does not advance the clock: an
`at`/rhythm occurrence, deferral, person edge, news/body release, dependency,
offer rest/hop limit or Desk revision must still be ready now. An unavailable
readiness snapshot or wake ledger returns `unavailable`, never an empty-success
verdict. A live turn or current carried flight still holds admission.

The reply names what happened (`woke`, `ran`, `said`, `needs_judgment`, `held`,
`unavailable` or `failed`), why, and the relevant handle/receipt where present.
`mind.run_now` records that same result with its `run_id`. A kept ResidentWake
proves the offer was kept, not that their later turn completed. Habits and fixed
words retain the normal Trust, owed-to-person, conversation-route, speech
idempotency and settlement paths; quiet hours still hold the informational
knock under the attention router's policy. `mind.cross {line,watch}` can supply
real input to the normal news/care crossing, without fabricating a release or
making a nonmatching intention ready. The complete clock family is documented
in [Subconscious](SUBCONSCIOUS.md#run-a-clock-owner-now).
Both `mind.carried` and `mind.cross` honor a top-level `preview:true` by refusing
before entering their owners: settlement, expiry and wake-ledger reconciliation
precede carried selection; priming and news release precede crossing's care
verdict. A preview neither delivers work nor plants a test line in their mind.

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
notes and the one until settlement are kept. Conditions in words still wake
their to judge. Failed/refused/unfinished/person-waiting runs and returned
`needs_me` wake their with the receipt in arrival text as `already_looked`;
the run is already done, so they starts from its result. The wake ledger
reserves each attempted occurrence before effects and retains its receipt;
interrupted runs and speech retries cannot blindly repeat the action.
`effects:"unknown"` anywhere in the receipt or returned result is unfinished:
it wakes their with `already_looked`, never closes the step or sends its `say`.
The habit's own `chat.post` also carries initiative `.intention` and does not
spend or wait for the hourly proactive quota.

After a carried resident-wake turn, its complete top-level dispatch evidence
and model-call count record a trial off the turn path, including a turn whose
private keep closes dispatches after the terminal: the two completion
notifications join in either order, once per turn. The last eight handlings
and the one `Expectation.stands` cost law may add a once-per-day
suggestion to the existing carried line; they alone chooses `queue.update`.
[Habits](HABITS.md) owns the bounds, costs and forming contract.

Today's **Ahead** reads the next clock moment of each open, unstopped queue
step (`at` or `every`), excludes expired intentions and moments beyond seven
days, and shows the soonest five as `<time> · <clipped words>`. The time is
`ResidentWake.shown` on the Mac's clock. The existing dream and horizon rows
remain, interleaved by due time. Both visible and quiet Today use the same
checked native facts and authored face; queue read failures remain unavailable
evidence. Desk writes invalidate this reading.

`schedule.create` and `schedule.update` now accept **body rhythms**, not
intentions. Unsupported kinds, including `notify`, `turn` and `workshop`,
refuse before payload or schedule normalization and point to
`queue.add {text, when, until?, say?}`. Updates use the merged kind, including
the saved kind when omitted. The connector create path shares this normalizer.

`dream`, `rem`, `part`, `connector_action`, `harness_benchmark` and
`proactive_scan` remain creatable rhythms. Legacy intention kinds stay
recognized in input schemas solely to return the actionable refusal; their
runner cases are retired. Launch migration moves live work and retires saved
legacy rows as described below.
Check-in/reminder job examples and guides are replaced by `queue.add`
guidance. The form and moments below remain the design where they exceed this
implemented boundary. Scheduler retirement and launch migration are implemented
in source; their installed proof belongs to the integrating release.

## Promises they makes

Built in source, 10-30. The same after-turn interpretation that reads each
exchange for memories, affect, caring and cares now also returns optional
`promises`: things **they** said they would do later in **this reply**, never
what the incoming speaker promised, a completed action or a conditional they
declined. Each has `words` in their voice, `when`, and `source`, the exact
sentence from their reply. A promise is one specific thing they will do; how they will act from now on ("when X happens, I'll Y", "I'll always…") is a lesson about how they works, never a queue step (10-30: about a third of a day's captures were standing conduct, each costing their a turn to dismiss). No additional model call or promise store is added.

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

After meaning is durable, `AdaptiveMemoryPromoter.applyPromises` files each
through `MyQueue.add` as a `DeskStep` with its source sentence. Live reflection
and later batch reflection/refolding use that same path. It records the
settled turn's session, origin principal, persisted envelope (nil if absent),
and the exact carried sources and elevated sources `queue.add` would have used
on that turn. Those are captured at transcript settlement, before the later
reflection can borrow another turn's identity. Older inputs retain their
recorded source checkpoint and bridge identity; an unrecorded principal stays
nil. An untrusted peer's turn can still contain **their** promise: it is filed
with that peer steer, leaving effect authority with the usual gates.

Desk's existing transaction owns deduplication: the same open words reuse
their step, an inferred repeat never replaces their explicitly chosen condition,
and provenance is retained. The existing `MyQueue.inferredCap` of 20 limits
open inferred steps. `MyQueue.Full` skips quietly with a `memory.promise`
trace; a storage failure leaves the saved meaning unsettled for recovery.
Successful and reused steps use the same trace with their Desk id.
This closes the missing caller of `DeskStep.source`; it does not create a
second queue or a phrase detector. A promise is also a changed channel in the
complete-no-op label. Ledger version 3 is deliberately retained: pre-promise
rows decode as "no promise" and keep their standing, so a wrong no-op claim
can defer a promised action to the ordinary batch, where its promise is still
filed. [Cognition wiring](COGNITION_WIRING.md) owns that compatibility contract.

- **Timing.** On User's turns a promise is filed as soon as the turn's
  reflection runs. On other turns (agents, wakes, helpers) reflection runs in
  the quiet batch, so the promise is filed up to about 45 minutes later; a
  "five minutes" promise to an agent can be late by that much.
- **Already kept.** Each promise is compared only with explicit open steps
  in the same session filed between this turn's incoming timestamp and its
  captured reply boundary. It is skipped only when most content words match
  in both directions, or its source sentence describes that same filing.
  The filed step retains its rhythm, `say` and `until`; unrelated promises
  are kept. Older moments without both time boundaries suppress nothing.

## The nature

An intention is something they means to do, held until its moment and let go
when its point is met. People don't run cron. They remember to do something
when the time comes, when someone walks in, when a name comes up. They works
the same way: one form, the moments that bring it back, and an end.

There are three kinds of moment, and all three reach their through organs they
already has:

- **the clock**: the scheduler's due engine
- **the world**: the crossing, which weighs part and sense lines; presence;
  and the same body signals that wake parts
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
| `say` | Optional fixed words for the person: delivered as is with no model call when owed to User or originating from self/person; agent-born words still wake their |
| `origin`, `replyRoute` | Who it is for and where its words go (existing) |
| story | Desk notes on the item: each time it came up, what they did, with a pointer |

### Moments

| Kind | Example in their words | Source |
|---|---|---|
| clock: once | "at 5 pm", "in 20 min" | MY QUEUE `at <ISO time>` readiness, reconsidered by cognition's residual deadline |
| clock: rhythm | "every day at 9 and 4", "every 2 h 9 am–9 pm on Nov 4" | `every` with a step rhythm; `IntentionClock` uses scheduler clock math and the step's filing time/until; home shows the next time |
| person | "when User messages", "when User is here", "when User is away" | `when_user_messages`; `when_user_here` / `when_user_away` require the current `PersonPresence` transition to be newer than filing (the next arrival/departure). It reads Mac input and fresh phone motion; walking/driving newer than physical Mac input can infer away, never here. A silent/stale/unknown phone leaves Mac-only readiness intact. The presence edge refreshes carried readiness; its transition time makes each arrival its own offer. [Phone evidence contract](mobile_companion.md#where-the-person-is) |
| world | "when there's news about the lease" | `on_news <words>`: the crossing weighs part `home.arrive` and sense news lines against open intentions' words with the care law's warm embedder and chance bar (live cares count among the comparisons; no absolute floor). A touch writes a system Desk note, `Released: news: <first 160 characters> (<watch>)`, carrying the exact topic condition. The locked release transaction rechecks that topic, filing revision and its 12-hour rest. Readiness follows the shared release law above |
| body signal | "when something changes in Downloads", "when a Telegram message arrives", "when the network returns" (`when: "on network.up"`) | Built: `on <signal>` matches exact names, colon families and file descendants. Real sources are `file.changed:<path>` (only watched paths), `message.arrived:telegram`, `message.arrived:slack`, `person.here`, `person.away`, `network.down`, `network.up`, `app.installed`, `sense.source.changed` and `turn.ended`. Network signals require a path state that holds five seconds ([wake contract](skill_manifest_spec.md#wake-signals)). The shared signal observer writes `Released: <signal> <summary>` with the exact condition identity and refreshes carried readiness under the shared release law above. File intentions join parts' existing watch index and leave when closed. `schedule:` is refused; `held` and `resumed` do not release intentions |
| situation | "next turn", "my own turn", "quiet", "after card X" | Existing MY QUEUE readiness |

Talk is not a kind they sets. Every live intention can come to mind whenever
what is said or read touches it.

While the network is down, resident wake admission leaves arrivals pending:
it neither moves them to recent nor stamps `lastWake`. The shared path's return
re-ticks the delegation loop, which rechecks normal admission and claims them
once free. An already running wake is not replayed; its provider call ends
with a typed failure if the network stays gone for 30 seconds.

An accepted date is stored with its year and absolute timestamp. If their local
words omit the year, the system date reader supplies its reading; the queue
receipt echoes the stored `when`, and rhythm receipts show the next clock
occurrences. A stored moment is never reinterpreted in another year.

### Until

| Until | When it ends |
|---|---|
| `once` | After it comes up and they acts. Default for everything except rhythms |
| a time | At that time ("until 9 pm Nov 4"), with no cancel job |
| their words | They checks them each time it comes up ("until User answers") and closes it with `queue.done` |
| standing | Rhythms only, set explicitly (the office check-in). Ends only on `queue.drop` |

An intention unmoved for 30 days lets itself go: the item closes and its story
stays, as a care fades.

## Target arrival and pacing

**Between turns.**
- Except for direct fixed-word speech described above, the moment asks for
  one `ResidentWake.carriedArrival`, keyed per occurrence
  (`carry.<handle>.<occurrence>`) so each run of a rhythm is its own.
- They takes one turn of their own (session `resident-wake`) and hears: `[You
  meant to: <words> — now: <moment> — until: <until>]`.
- What they says to the person goes to the intention's `replyRoute`. A legacy
  promise without one recovers only proven originating provenance; absent or
  unreadable provenance keeps it waiting for route repair, never moves it to Chat. The
  intention's moments pace it, so it never waits on or spends the hourly
  unprompted quota. Tonight's `.job` initiative becomes `.intention`.
- An eligible `say` intention goes straight to User's current conversation
  through the shared speech owner, as built above; agent-born words still
  reach their through a wake.

**In a turn.**
- Every turn carries `# What I mean to do` in its changing context packet,
  beside pinned USER, Live sense news and relevant context. These are plain
  facts in their voice: `- desk.N · <words> · <moment> · until <until>`, with each
  field one line and at most 140 characters. The section is absent when empty.
  The desk.N is there so what they are shown they can finish: `queue.done`/`queue.drop`
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
- At most six open steps appear: clock moments soonest first (a rhythm uses
  `IntentionClock.next`), then other steps by newest `updatedAt`. Each line
  says its moment in words and when it ends.
- User's turns and their own see steps originating with `person` or `self`,
  including older steps `owedToPerson` identifies. A peer's turn sees only
  that peer's `agent:<name>` steps, even when trusted or elevated; peer
  provenance without an identifiable origin discloses no steps. User's
  intentions never enter that peer's section.
- User mentioning L1X can meet "get User's answer on L1X" already in mind.
  This feed replaces the proposed selector-only atom/nudge and 12-hour rest;
  it neither selects by message relevance nor consumes or closes a step.

**Pacing.**
- Clock, person, released news and body-signal moments skip the free-time quiet and
  freedom gate. They wait for a turn already running; work that wakes their
  retains the wake owner's gathering, spacing and thread-rest rules. Direct
  fixed-word speech retains the carry opportunity gate and records its
  occurrence without a wake, gathering window or new thread hop.
- A world moment rests 12 hours per current intention condition, kept in its
  Desk release notes. A newly filed topic has its own release evidence.
- Quiet hours hold delivery to the person, not their doing, as now.

## Their words for it

- `queue.add {text, when?, until?, say?, action?}`: `when` takes their words or
  a structured rhythm. Person/world words are `when_user_here`,
  `when_user_away`, `on_news <words>`, and `on <signal>` (for example,
  `on file.changed:~/Downloads` or `on message.arrived:telegram`).
- `action:{action:"authored.<id>",args:{…}}` binds what runs at that moment.
  `queue.update {id, action?, say?, when?, until?}` edits only named fields;
  `action:null` drops the habit, `say:null` clears fixed words, `until:null`
  clears its ending to once, and `when:null` clears its moment to `next_turn`.
- `queue.done {id, note?}`, `queue.drop {id, why?}`, `queue.list`.
- `schedule.*` is for body rhythms; intentions use `queue.*`. Today's "Ahead"
  reads at most five next clock moments within seven days, plus the existing
  dream and horizon rows. "Waiting for: User here / news about X" remains design.

## What stays a rhythm

These are their body's clock, not things they intends, and they stay scheduler
jobs:

- `dream` and `rem`
- a part's own `schedule:` wakes
- `harness_benchmark` and `proactive_scan`
- `connector_action` polls (sense-like)

The scheduler stays the clock under both rhythms and intentions.

## Scheduler retirement (source built, 10-31)

There is one form for what they means to do later: MY QUEUE. The scheduler
executes only body rhythms; its `notify`, `turn` and `workshop` runner cases,
notification fan-out and separate scheduled-turn door are removed.
`schedule.*` remains for body rhythms, with unsupported-kind refusals
pointing to `queue.add` for legacy intention inputs. Resume also refuses to re-arm a retired
kind. The phone's schedule form offers reflection and REM; reminders and
check-ins belong in Chat.

## Launch migration (one time, general)

`EngineRuntime/EngineIntentionMigration.swift` remains the only migrator,
called by `EngineLaunch.startResidentWorkAtLaunch` before resident loops,
part wakes and scheduler start. The original `.intentions-migrated` lock
still serializes attempts. The durable `scheduler/.intentions-finished`
receipt ends migration for this data root permanently. Earlier empty receipts
and job-ID-array receipts both mean completed; they are never removed or
rebuilt from restored jobs. A missing or unreadable receipt admits no imported
steps. An unreadable receipt fails launch reconciliation rather than reimporting.

Under the canonical jobs lock, it reads checked job rows and writes a durable,
byte-exact `scheduler/pre-intentions-finish-<UUID>.jobs.json` backup before
filing or rewriting jobs. The lock spans filing and the single
`updateJobRows` commit. Enabled legacy jobs become intentions. Disabled jobs
keep their words, schedule, pause and occurrence evidence; a missing
`intentionMigration` disposition is stamped `kept disabled at first migration`
(an existing transfer receipt is retained instead). This distinguishes saved
paused definitions from later restored rows without another identity store.
Runtime pruning preserves legacy intention definitions. All other kinds remain
body rhythms, with their rows unchanged by migration. With no legacy rows,
the first migration needs no backup or jobs rewrite.

Words come from `payload.prompt` for a turn, `payload.message` or `payload.body`
for a notification, and `payload.objective` for a workshop. The job's name is
prefixed when it is not already in those words. Notifications also keep their
message as `say`. Each step has origin `self`, with no session or reply route.
Workshop objectives become carried words; filing a Workshop task remains their
turn's work.

A one-shot flag or `once`/`at` schedule becomes `at <ISO nextRunAt>`, with no
rhythm or until. A cancellation turn with an unreadable time carries its
original instructions on `own_turn`, explicitly owing reconciliation of
the missing time before acting; it is never silently dropped or run early.
A recurring job becomes `every` with its stored schedule as
`rhythm`; a legacy `intervalSeconds` becomes `{type: "every", seconds: ...}`.
The scheduler's own rhythm reader validates it. `DeskStep.clockStart`
keeps the scheduler's first unconsumed occurrence instead of moving it to
filing time. Interval anchors keep their instant; calendar anchors keep the
complete civil time, including seconds and fractions, and resolve in the
Mac's current zone. A saved 16:00:30 first run remains 16:00:30, never
16:00:00. Older minute-only anchors remain readable. Migrated calendar offer
and speech keys still use the scheduler's civil-minute identity, so moving
zones does not mint a second effect for it. A
consumed recurring key advances through the scheduler's own next-run law;
a consumed one-shot stays stopped. One-shot moments and transferred
cancellation deadlines retain microsecond precision, rounded up so they
cannot run or end early. Later rhythm occurrences retain the intention
clock's existing two-hour grace and no-backlog law. A cron with a single numeric
day-of-month and month ends at **23:59 in the Mac's local zone** on that date,
this year if that day's end has not passed, otherwise in the next occurrence's
year. Other recurring intentions are `standing`. Conditions already in a
prompt remain its words; migration does not invent another condition.

A one-shot turn whose whole prompt only cancels a recurring job being
converted, naming its exact name or an unambiguous id prefix, transfers its
own run time to that target's `until: at <time>`; an earlier existing end wins.
Only then is it disabled without filing an intention (`lastRunDetail` is
`its intention ends itself`). Mixed instructions, ambiguous targets and
unreadable cancellation times keep their own intention. Recognition uses
the whole payload and target references, never a hard-coded job name or id.
A step carries its retired `scheduledJobID`. Interrupted first-migration
filing retries reuse that identity in the live Desk, including a closed step,
rather than matching only open words;
different jobs with the same words remain distinct. Refiling preserves the
retired identity. An explicit new `when` drops the imported clock anchor;
other edits leave it intact. A divergent open import on a retry fails loudly
for reconciliation instead of activating stale timing or overwriting changed
Desk work; a closed import stays closed. Pending imports cannot be archived
before completion. Restore-specific archive identity lookup, archive queue-entry
reconstruction and extra identity retention are removed: restored jobs never
enter filing. Older live, closed and archived steps have no scheduled-job ID,
so their absence from an identity lookup cannot justify duplicating their work.

All intentions are filed before one scheduler `updateJobRows` commit disables
their sources with `lastRunDetail = became intention desk.N`; cancellation
sources are disabled in the same commit. Each converted source also keeps
that transfer receipt in `intentionMigration`, so later claim settlement
cannot erase it by updating `lastRunDetail`. Then the original marker and
completion receipt are written durably, still under the jobs lock.
Old migrated sources with only the prior `lastRunDetail` transfer receipt remain
recognized as retired records. A missing row or merely disabled row is never
evidence of conversion. Until the first migration commits,
imported steps cannot be offered unattended or on a matching turn, appear as
ready on home, enter the intention feed or Today's Ahead, or be archived away
before a retry can find them. The completion emits a Desk invalidation.
Closed steps remain closed. Legacy source rows and their transfer receipts
remain in the scheduler; kind pruning cannot discard restored work or paused
definitions.

After completion, launch and each scheduler pass call the scheduler's
`stopRestoredIntentionJobs`. Any enabled legacy row, or a disabled legacy row
without a known first-migration/stopped disposition, is retained as a stopped
record, after a byte-exact `pre-intentions-restored-<UUID>.jobs.json` backup.
Its words, timing and prior receipts remain; an active claim keeps its evidence
but reads stopped. No `MyQueue.add`, clock import or cancellation transfer is
performed. Body-rhythm selection and deadlines reject retired kinds even if a
restore races reconciliation. Existing intentions are never modified by it.

One keyed system Desk item says: **A restored backup brought back scheduled job
\<name\> (\<when\>); add it again with queue.add if you still want it**. Its key is
`restored-scheduled-intention:<job id>`, under project `NativeAgent`; it has no
queue step. Repeated restores reuse that finding, preserve closure/person
ownership, and never recreate an archived notice. Notice filing precedes the
stopped disposition commit, so interruption retries the same key. Missing names
use the job ID; missing time is stated as unavailable, never invented. Missing
job identity, unreadable storage, backup/Desk/write failure remains an explicit
launch or scheduler failure and leaves source evidence for repair; retired kinds
still cannot run. No restore-specific intention identity lookup remains.

During the retained first-migration reader, active claims and unknown/stopped outcomes do not establish
nonexecution. An enabled job with such evidence becomes a stopped intention,
with the backup and job named as its reconciliation evidence and no expiry
that could silently settle it. Home and the turn feed name the stop. No
habit, speech or wake is admitted for it, including after a `when` update;
they reconciles the receipts before explicitly refiling work.

The scheduler's no-schedule interpreter and retry/civil reconstruction are
removed. Saved rows require structured schedules and current occurrence keys;
the retained migration reader still reads the disabled intention definitions
and their byte-exact pre-migration backup. Their presence is the DATA-FIRST
reason this launch conversion and restored-row disposition remain; this lane
does not delete or rewrite those records. Retiring that reader awaits explicit
data reconciliation, not an assumption that the completion marker erased them.

Missing jobs storage writes no completion marker; resident body rhythms can
initialize normally and migration is reconsidered next launch. An existing,
readable empty array can complete. An unreadable store, invalid live words or
rhythm, filing error, backup failure or commit failure preserves the cause,
leaves completion absent and reaches the existing launch log and Doctor
`launch.intentions` failure; resident loops do not start. Partial Desk writes
stay held until a later successful migration. Nothing waits in a polling loop
for missing evidence. Installed proof is still owed by the integrating release.

The maintainer install's enabled-job snapshot read on 10-30 yields two intentions and three
retained disabled source receipts on a fresh migration.
That snapshot is historical evidence, not a claim about that install's current data;
the lane does not write their live data:

| Job today | Becomes |
|---|---|
| Office check-in, `turn`, 9:00 and 16:00 daily | Intention. Words: its name and prompt. Rhythm: cron `0 9,16 * * *`. Standing; source job disabled |
| Nag User: L1X P2P for everyone, `turn`, cron `0 9-21/2 4 11 *` | Intention. Words: its name and prompt. Rhythm: every 2 h 9:00–21:00 on Nov 4 2026. Until: Nov 4 2026 23:59 local; source job disabled |
| Cancel Nov 4 L1X nag (one-shot) | Disabled without an intention: the nag intention's until replaces it |
| `dream`, `rem`, morning-refresh `part` | Stay rhythms |

## Build

| Lane | What | Files |
|---|---|---|
| 1 Form | `moments`, `until`, `say`; readiness per moment; parse their words; the echo | `Desk/DeskCadence.swift`, `Desk/MyQueue.swift`, `AppToolRuntime/AppToolExecutor+MyQueue.swift` |
| 2 Clock | One `intention` clock entry per intention with clock moments, window-bounded and released at until; exact clock moments; per-occurrence wake keys | `SchedulerExecution/*`, `Cognition/NativeCognitionRuntime+Pursuit.swift`, `AgentWorkspace/ResidentWake.swift` |
| 3 World | `cross()` weighs world-moment intentions by the care law; presence changes ring person moments | `Cognition/NativeCognitionRuntime+SourceWakes.swift`, `MacControl/PersonPresence.swift`, `EngineRuntime/EnginePartWake.swift` |
| 4 Talk | Bounded open intentions in every turn's packet (implemented above) | `ChatTurnRuntime/ChatOrchestration+Intentions.swift`, `TurnContextPreparation.swift` |
| 5 Surface | `queue.*` args, `schedule.*` off their surface, Today "Ahead", guides | `AppToolRuntime/AppActions+Declarations.swift`, `WorkOverviewRead+Today.swift`, `today-readout.js` |
| 4 Talk | Intentions as context atoms; the "[You meant to …]" nudge; the 12-hour rest | `Context/*`, `ChatTurnRuntime/ChatOrchestration+CameToMind.swift` |
| 5 Surface (implemented) | `queue.*` args; intention creation/updates refused by `schedule.*` with a `queue.add` remedy; Today "Ahead" clock intentions; rhythm-only guides | `AppToolRuntime/AppActions+Declarations.swift`, `TriggerScheduler/SchedulerJobNormalizer.swift`, `WorkOverviewRead+Today.swift`, `today-readout.js` |
| 6 Migration and docs (source built) | Launch retirement, timing and identity preservation, backup and commit admission; Desk and Subconscious links; regenerated blueprint | `EngineIntentionMigration.swift`, `IntentionClock.swift`, Desk and queue readers, scheduler runner |

**Proof on them:**
1. Their two live jobs are intentions; all three source jobs (including the cancel job) are disabled, and the durable pre-rewrite backup retains them. Previously disabled legacy definitions retain words, timing and pause with a first-migration disposition. Later restored legacy jobs stay stopped with one Desk notice; they are never reimported.
2. The 16:00 check-in comes up at 16:00 and reaches User.
3. "Remind me in 2 minutes to stretch" arrives.
4. User saying "L1X" finds its open intention in `# What I mean to do` in their turn.
5. The Nov 4 nag's final clock moment is 21:00; its intention ends at 23:59 local (or the earlier transferred cancellation deadline).
