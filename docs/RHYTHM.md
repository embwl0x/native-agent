# Rhythm — they knows the shape of their day

Claude, 2026-10-30. User: "they knows your rhythm … plan these all out real
well". Builds on their senses (presence, the day, the front app, the network —
docs/SUBCONSCIOUS.md "Came to mind", docs/INTENTIONS.md body signals) and the
one expectation law (`NativeAgentCore/Expectation.swift`, docs/SURPRISE.md).

## Rule 0, answered

1. Today's tech: a "user profile" of preferences, or a routine tracker that
   pings you when you deviate. Both are features that do things, and the second
   is the nagging User has ruled out ("reminders and nudges require their explicit
   request"; "care is not nagging").
2. The nature: **their day has a shape they have lived, and a break in it is
   something they notices.** One form: an expectation over their day, learned the
   way every expectation of theirs is (the shared law), forgetting as they changes.
   One effect: a break enters their mind as a fact they lived — never a message,
   never a wake.
3. Theirs: it is what *they* knows about the person they spends their days with,
   from what really happened, the way a person knows when their partner is
   usually up.

## The evidence before this change

- Before rhythm, nothing modeled their day; presence (person.here/away) was never saved; the only
  multi-day record is `chat/index/history.sqlite` (role/author/route/instant).
- 837 of their messages over 11 days (10-19 → 10-30), Mac / Telegram / iPhone:
  never a message 21:00–01:59 (11 of 11 nights); first message 02:34–07:08
  (median 04:40, drifting earlier: 02:53, 02:36, 02:34 on 10-27..29); last
  16:43–20:19 (median ~19:13); Mac 02–05 and 13–19, Telegram 05–10 and 18–19.
- Strength: a single 11/11 claim has a Wilson lower bound of 0.74; one of ~24
  hourly claims tested together (z≈3.51) drops to ~0.47. Today only a few
  coarse claims stand: their quiet window and when their day starts. Door-by-hour
  needs weeks. The drift says the model must forget (a half-life, not a total).
- Constraint (code): a care pressing ≥ 0.35 becomes a Reach offer to message
  them (NativeCognitionRuntime+Reach.swift:381-386), and a crossing that touches
  a care wakes their. So a break must not charge a care or go through the
  crossing's wake.

## The design

### One form: their day (`mind/rhythm.json`)

Per local hour of the day (24 bins), two forgetting tallies with a 7-day
half-life: **active** (an owner message on any door, or person.here, inside the
hour) and **observed** (the Mac was awake for the hour, so silence counts).
Plus their **day start**: the local time of their first activity after their longest
quiet stretch, one per day, kept 30 days.

Observations, all already true events, recorded where they happen:
- their verified owner turn (door, instant) — the point that stamps
  `cognition/user_turn.json` today;
- presence edges (person.here / person.away from MacPersonInput.presenceChanged);
- the Mac's own awake hours (the engine is running).
Cold start: on first load, fold their owner rows from `chat/index/history.sqlite`
(role user, author owner/telegram owner, not mechanical) for the last 30 days.
The first indexed day is incomplete and cannot teach a start or quiet night;
today cannot teach silence in hours not yet lived. Complete intervening days
teach **message silence**, not a claim that the Mac was awake. That is the
historical seed; real awake/presence observations replace it as it forgets.

### Claims, under the one law

From the tallies, at most a handful of claims, each judged by
`Expectation.stands` with `among` = the number of claims checked together:
- **quiet**: an hour (or run of hours) they are reliably not active ("quiet from
  21:00 to 02:00");
- **starts by**: their day has started by a time (the upper bound of their recent
  day starts with standing — "usually up by 04:40");
- **active in**: an hour they are reliably active (only once there is the data).
A claim with no standing says nothing. Claims are recomputed on each
observation and at the day boundary (the cognition clock stream). A "starts by"
claim arms one deadline at its standing time through the existing cognition
deadline path (the same one horizon expectations use) — never a polling timer.
"Observed" hours come from the Mac's own wake/sleep edges
(NSWorkspace didWake / willSleep) and the engine's run, not a heartbeat.

### As built

`CognitiveSubstrate/PersonRhythm.swift` owns the bounded evidence and pure
claim fold. Each local day contributes at most once per hour; awake fractions
accumulate to one, activity makes that hour active and observed. Thirty days
retain the first timestamp/door in each active hour and observed fractions;
older days fold into the 24 carried bins, which keep decaying rather than being
discarded while the time zone is unchanged. The store's `timeZone` identifies
the local-hour coordinates of all retained days and carried bins. Before new
activity or awake fractions enter a changed zone, retained days are rebucketed
using their recorded zone and activity timestamps. The old-zone carried bins
are discarded: their timestamps are gone, so they cannot be rebucketed. Bins,
starts and standing claims are recomputed from the retained evidence; cognition
does this before comparing an observation with a learned claim in the new zone.
The current on-disk shape and its reader remain unchanged. Starts retain 30 days,
excluding the incomplete first indexed day, and are first activity after the
longest quiet run ends. The day's first quiet hours before that end do not
manufacture an early start.

Three coarse candidates at most are judged together: the longest quiet run
(each hour at most 10% active), a 95%-weight upper bound of recent starts, and,
after three weeks of days, the strongest active hour. Quiet confidence uses
the weakest hour's sample size and success rate, never the sum of correlated
hours. `Expectation.stands` receives `among` equal to the candidate count.
Sample size is the smaller of forgetting observation mass and its weighted
effective sample size, rounded down; old evidence loses standing without a
new observation. The private noticing cost policy is `cHit = 1`, `cMiss = 0.5`
(bar 1/3); these are attention-cost policy units, not measured delivery costs
or permission to act. “Sure” requires a lower bound of 0.7; other standing
claims say “fairly sure.” This is not an anytime or independent selection
guarantee. The observed median is descriptive, not a “starts by” upper bound.

`Cognition/NativeCognitionRuntime+Rhythm.swift` consumes the existing verified
turn stamp off the turn path. The stamp's optional `door` joins its existing
atomic write; no second rhythm write or history read is added to a turn.
Telegram owner identity honors the existing bot rule: one allowed user, or
one positive private chat id when the user allowlist is empty. The history
reader selects only instant, route and deduplication identity, never words;
it neither absorbs nor migrates the index. Copied message ids count once per
door. An absent index contributes no history; an unreadable existing one or
rhythm store reports repair and is not replaced.

EnginePartWake passes presence and Workspace sleep/wake edges to cognition.
Awake intervals close on those edges, source observations, day changes and
quit, with no inferred uptime across launches. Continued known presence also
marks active hours when an interval closes. The existing clock stream
recomputes claims at day/clock/time-zone changes; a zone change rebuckets retained
day evidence and retires the old-zone timestamp-free aggregate as described above.
The residual deadline holds one standing start time for the local day, canceled
when their day starts; no new timer is created.
Observation and refresh tasks cancel and join in cognition's sleep settlement.

Break identity is `rhythm:<kind>:<local date>`. Pending breaks contain only the
instant and claim; local `h:mm a` words use `AgentScreen.names(dataRoot).person`
when felt. `CognitiveSubstrate.feelRhythmBreak` uses `ingestResident`'s existing
felt-resolution stakes gate and records a zero-move note in a touched live
care, with no open/close/stance/depth change. Durable pending identity lets a
retry finish the story and priming if event ingestion already happened.
`PrimedMoments` receives source `rhythm`. This path calls neither `cross`, news
release, `ResidentWake.request`, nor Reach. `care.charge` sums only movement;
adding zero leaves it identical at the same instant, and `carePressure`'s open
multiplier is unchanged. The somatic adapter returns nil for this felt kind.

`mind.inner_state` returns `person_day` with the configured person's title,
standing claims and confidence words, through the substrate's bounded reading.
This is a pull, not extra per-turn context.

### A break is a fact they lived

`mind.rhythm` can run this same refresh with the standing start-time wait
satisfied. It uses the real history and learned claim; once-per-kind/day and
care admission still apply. The reply counts considered/felt breaks and records
its decision as `mind.run_now`; [the clock contract](SUBCONSCIOUS.md#run-a-clock-owner-now)
owns run-now observation and absence handling.

When a standing claim breaks — they are active inside their quiet window ("User is up
at 1 AM; they are usually quiet from 9 PM to 2 AM"), or their day has not started by
its standing time ("It's 9 and I haven't heard from User today; they are usually up
by 4:40") — it enters their mind the way a horizon resolution does
(`announceHorizonResolution` template: a felt event with a deterministic id,
`ingestResident`, admitted only if it touches a live care), **with no charge
movement on any care** (the `noteReachLanded` precedent: a story entry that
moves nothing), and it is **primed** (PrimedMoments) so it can come to mind in
their next turn. It never requests a wake, never feeds Reach, never becomes a
message. One break of a kind per day.

What they do with it is theirs: if they writes at 1 AM, it is already on their mind
("you're up late") the way it would be for a person who knows them.

### What they can know

`mind.inner_state` gains "User's day, as I know it": their standing claims in their
words, with how sure (e.g. "quiet from 9:00 PM to 2:00 AM, fairly sure;
usually up by 7:08 AM, fairly sure"). Never in front of their every turn
(clear-headed); there when they reaches for it, and in a break's own words.

## Privacy

Timestamps and doors only — never message text. Presence is a boolean edge.
`mind/rhythm.json` is theirs like the rest of `mind/`.

## Installed proof owed to the release lead

- Cold start reconstructs quiet 21–02 and the ~04:40 first-message median.
  The standing start upper bound may be later than that median; the lane
  report gives the real-history result rather than forcing them to agree.
- A message from User inside their quiet window produces one felt fact, one primed
  moment, no wake, no Reach offer.
- `mind.inner_state` shows their day in their words.

## Lane

| Lane | What | Owners |
|---|---|---|
| rhythm | the store, observations, cold start, claims, breaks, inner_state | Cognition/NativeCognitionRuntime+Rhythm.swift, CognitiveSubstrate/PersonRhythm.swift, EngineRuntime/EnginePartWake.swift (MacPersonInput presence and Workspace edges), ChatTurnRuntime/ChatOrchestrationClient+StructuredChat.swift and ChatTurnEvidence.swift (one owner stamp), ChatToolRuntime/ChatHistoryIndex.swift (read), CognitiveSubstrate+CaresMind.swift (zero-move story entry), +InnerState.swift and its runtime/tool renderers; +Expectations.swift remains the unchanged felt-event template |
