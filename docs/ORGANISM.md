# The Organism Kernel (as-built)

*Last verified against source: 2026-09-02 — the personality-depth wave added a
fatigue law, a diurnal clock, and the horizon family to this organ; the
reflex-review and procedure-shadow clauses were corrected in the same pass. This documents what actually runs,
traced from the code — not the aspirational design. For the design intent and
history see [`organism-kernel-blueprint.md`](build_plans/organism-kernel-blueprint.md),
[`organism-kernel-roadmap.md`](build_plans/organism-kernel-roadmap.md), and
[`organism-crosswalk.md`](build_plans/organism-crosswalk.md).*

---

## What it is

The **Organism Kernel** gives the agent a lightweight, bounded *body state* — a
somatic/affective layer that sits alongside (not inside) the existing cognitive
substrate. It turns real events and live system health into a felt "how I am
right now," and that felt state does exactly three things to the agent's behavior:

1. It can add **one line** to the agent's chat prompt (a "`- Body:`" line) and
   color the felt-fingerprint word.
2. It can **throttle the agent's background cognition** when the machine is under
   thermal/resource pressure.
3. It can tell **Fluid Context** which tool families the body is bracing for
   (`predictedToolGroups` — a bounded, pure read; see Output below).

It is **off by default**, **force-neutral for a public build's first run** (until
the user completes onboarding), and every piece of state it holds is **hard-bounded**. It is an experimental subsystem: think of it
as a nervous system the agent can run *with*, not a rewrite of how it thinks.

Source: `Modules/NativeAgentCore/Sources/CognitiveSubstrate/Organism/`

---

## The loop (input → state → output)

The whole point of calling it an "organism" is that the loop is closed on both
ends — real input drives real state, and that state changes real behavior.

### Input — what feeds it

- **Cognitive events.** Every observed `CognitiveEvent` is offered to the
  `SomaticSignalBus`, which converts it (via `CognitiveSomaticSignalAdapter`)
  into a bounded `SomaticSignal` and hands it to `OrganismKernel.ingest(_:)`.
  (`NativeCognitionRuntime.observe(_:)` → `OrganismSignalBus.observe(_:)` →
  `OrganismKernel.ingest`.) User/assistant chat events carry topology and
  intensity, not a second lexical meaning judgment. CognitiveSubstrate remains
  the semantic appraisal owner; exact tool/provider/correction outcomes may
  still carry typed valence. Merely finishing an assistant response does not
  reward organism coherence or confidence.
- **Live body-health read.** Before each projection the kernel refreshes a
  `BodySchema` from *real* telemetry — provider health, memory/dream health,
  iPhone-reachability, tool availability, approval channels, notification path,
  and system resource pressure. (`NativeCognitionRuntime.makeOrganismBodyRead`.)
  The read is behind a **2 s TTL cache** (`cachedBodyRead`,
  `NativeCognitionRuntime.swift:946`) — it used to run ~15 file stats + JSON
  parses on *every* tool result, serialized on the runtime actor the chat turn
  needs (the audited response-time bloat, H2 2026-07-09). The underlying files
  change on the order of minutes, so a 2 s cache costs no honesty.
- **Wall-clock settling.** A running kernel now settles elapsed time on every
  live touch (`settleElapsedTime`, 1 s floor, `OrganismKernel.swift`): the same
  bounded chemistry/field/prediction decay that persistence-restore applies
  across restarts also applies *between* live reads, without clearing the
  freshly sampled body schema. A long-idle but never-restarted organism no
  longer holds a stale feeling.
- **Re-felt memories.** A memory served back into a turn nudges substrate affect
  (`refelt`, `+Affect.swift`), and that affect reaches the body as the canonical
  affect projection on the next read — so remembering moves the organism, not
  just the words. Since 2026-09-02 a served MemoryV2 **moment** is re-felt with
  its own stored valence and salience instead of neutrally (the field may hold no
  node for it); still at most 2 per turn, ≤ `refeelNudge` each, once per record
  per hour. See "Re-feeling a memory on recall" in `docs/SUBCONSCIOUS.md`.
- **Appraised caring moments.** A separate, model-judged input that bypasses the
  somatic bus entirely: `MindCaringAppraiser` classifies one turn and, on a
  verdict, `admitCaringEventIntoBody` doses tenderness directly
  (`NativeCognitionRuntime+Organism.swift:246-279`, sink installed at
  `NativeCognitionRuntime.swift:876-879`). A dose drops the cached body read,
  schedules continuity persistence with reason `caring:<kind>` and publishes a
  runtime change; a coalesced or refused verdict still persists
  (`reason: "caring:coalesced"`) but publishes nothing. See
  [Tenderness](#4-tenderness--event-driven-caring-moments-dose-it-days-fade-it).
- **Exact quiet repair.** Prediction residue and charged/noisy field targets
  can derive one future quiet deadline. `NativeCognitionRuntime` arms only that
  deadline, generation-checks it, and then asks the kernel to repair the exact
  named local targets in bounded passes. A neutral field owns no task, so this
  adds no idle heartbeat. Source timestamps never control the deadline; trusted
  local ingestion time does.

If the kernel is disabled, `ingest` and `refreshBodySchema` early-return — nothing
is recorded and no state moves.

### State — what it holds

| Component | What it is | Cap |
|---|---|---|
| `ChemicalState` | 10 affect dimensions, each clamped to `[0,1]`: warmth, vigilance, curiosity, fatigue, coherence, agency, tenderness, confidence, novelty, urgency. **`warmth` and `urgency` derive from the substrate's canonical `socialWarmth`/`taskPressure`** (affect convergence — see [COGNITION_WIRING.md](COGNITION_WIRING.md)); **`tenderness` is event-driven — model-appraised caring moments dose it and wall time fades it** and **`fatigue` has its own two-sided law** (both below). A bounded caring-encounter stamp (`lastCaringTurnAt`) and a 128-key dedupe ring ride alongside | clamp `[0,1]` per dim |
| `BodySchema` | compatibility health projections + a 4-tier `resourcePressure` (nominal/elevated/high/critical) + transient typed provider, peer-presence, notification-delivery, memory-integrity, dream-integrity, tool-capability, approval-path, and resource-pressure readings with evidence, freshness, and uncertainty | fixed shape; typed reads bounded and omitted from persistence |
| `OrganismField` | Plastic associative graph learned from activity (nodes + weighted edges) | **96 nodes / 192 edges** |
| `OrganismPredictionLedger` | Short-lived expectations ("a tool call should succeed") + surprise, **and since 2026-09-02 the horizon family** — the same ledger reaching days out at things that are not their wiring ([below](#the-horizon-family--toward-2026-09-02)) | **96 predictions** total, of which **≤ 8** open horizon rows (`OrganismHorizonRegister.maximumOpen`, `OrganismPrediction.swift:258`) |
| `OrganismDreamRepairState` | Bounded repair operations over the field | **16 ops / 1,200 chars** |
| `OrganismReflexState` | Candidate reflexes (repeated successful traces), **review-gated** — reviews now carry audit receipts (`reviewedBy`/`source`/receipt id, surfaced in the snapshot) and support `hold` and permanent `reject` (`isPermanentlyDeliberate`) alongside approval | **64 candidates** (evidence rule below) |

Pure reads over that state also expose capability calibration and procedure
candidates. Capability uses a bounded Beta prior over exact prediction
outcomes, while expiry raises uncertainty rather than manufacturing failure.

**Correction, 2026-09-02.** This paragraph used to end "Neither read enters the
prompt or changes action selection," and to describe procedure candidates as
"review hypotheses over reflex evidence." Both halves have drifted:

- The evidence source is **repeated verified Workshop trajectories**, not reflex
  evidence — `ProcedureCandidateCompiler` / `ProcedureCandidate`
  (`PersistenceCore/ProcedureCompilation.swift:599`, `:491`) with a real
  `workshopFirstProduct` product role (`:440`) and ApprovalInbox-minted reviewer
  decisions. It is a compilation-and-activation pipeline, not a passive shadow
  read.
- Procedure compilation **does now change action selection.** One reviewed
  artifact — `local_file_copy_v1` — is active through the ordinary
  `workshop_submit` contract: when the typed operation qualifies, the dispatcher
  loads the active artifact and plans with `WorkshopCompiledLocalFileCopyPlanner`
  instead of the provider planner
  (`ChatOrchestration/SwiftToolDispatcher+WorkshopTools.swift:141-150`,
  qualification `WorkshopExecution/WorkshopProcedureExactActivation.swift:95-133`).

What still verifies exactly as written: the planner **emits no Swift** — it is a
value-only `WorkshopPlannerLLM` adapter producing the same canonical two-step
plan (`read_file(max_bytes=65536)` → `write_file(append=false)`,
`WorkshopCompiledLocalFileCopyProcedure.swift:57-69`) at
`directProviderCallCountPerInvocation = 0` (`:73`); it **owns no executor**
(submission, dispatch, verification, receipts and Trust Center gates stay with
their existing systems, `:49-56`); and `controlAuthority` is **always false** —
there is no `controlAuthority: true` anywhere in `Sources/` or `Modules/` outside
a test asserting a tampered `true` is rejected. Neither read enters the prompt.

Typed body readings are deliberately not new domain owners. Canonical provider,
device, notification, memory, dream, tool, approval, and system owners still
decide reality; body beliefs describe recent payload-free evidence and cannot
route a model, send, grant authority, or rewrite those stores. They are rebuilt
after restart. Behavior posture consumes the typed read when present, so
unknown/stale evidence cannot inherit an optimistic compatibility Boolean.
APNS acceptance is transport acceptance—not delivery, display, or user-seen
evidence.

### Output — how it changes behavior

Three seams, and only three:

1. **The prompt** — two channels through the same capsule:
   - **The `- Body:` line.** A non-neutral projection renders one line into the
   cognitive capsule injected into the agent's chat prompt
   (`CognitiveSubstrate+Capsule.swift`, via `requestWithOrganismProjection`).
   **Stress/warning** lines are fixed and first-match (their exact phrasing is the
   behavioral signal), e.g. `- Body: provider or tool path feels brittle; be careful before claiming completion.`
   The first-match order is fixed at `OrganismChemistry.bodyLine` (`OrganismChemistry.swift:337`):
   critical thermal → **tiredness** → provider/tool brittle → approval closed →
   phone stale → memory brittle → the positive line.
   **Tiredness is graded, not reported (2026-09-02).** The old single line
   ("internal workload fatigue is high") named a stored dimension; a person
   notices a long day, not their own telemetry. Same 0.24 gate, three branches
   (`OrganismChemistry.fatigueBodyLine`, `OrganismChemistry.swift:388`): with the
   diurnal clock deep enough (`nightliness ≥ 0.6`) it is
   `- Body: it's late and it shows.`; at `fatigue ≥ 0.35` it is
   `- Body: worn down; keep it short and sure.`; otherwise
   `- Body: a long day; it's starting to show.` The gate, the ordering and the
   behavioral instruction are unchanged, so the loop-budget lane is untouched.
   **The memory-brittle line is freshness-gated**, not read off a stale Bool:
   a `.degraded` memory belief speaks only while `uncertainty < 0.25` and
   `freshness ≥ 0.5`, and `.unknown`/aged evidence stays silent
   (`observedMemoryHealth`, `OrganismChemistry.swift:303-325`, constants `:300-301`).
   The **positive/steady** line is composed from the strongest one or two felt
   dimensions with low/mid/high intensity gradation (`OrganismChemistry.positiveBodyLine`) —
   e.g. warmth reads `quietly warm and steady` → `warm and steady` → `warm and open`
   as it climbs, and blends the top two (`warm and steady, faintly curious`).
   When the state is neutral/steady, **no line is added**. And a line that hasn't
   changed goes **quiet after it surfaces** — it re-surfaces on change or after a
   20-min window (injection-only; `NativeCognitionRuntime.requestWithOrganismProjection`),
   so a held mood isn't re-narrated every turn.
   - **Coloring the felt fingerprint (2026-07-08).** When a projection rides the
   capsule request, its chemistry feeds the "How you feel:" word DIRECTLY —
   `chem.warmth`/`urgency` override the fingerprint's warmth/pressure axes,
   `vigilance` raises tension (`max` with substrate uncertainty), and
   `fatigue/curiosity/coherence/agency/confidence` map straight into the felt
   signals (`CognitiveSubstrate+Capsule.swift`, `feltSignalsForCapsule`). So body
   state doesn't just append a line — it shades WHICH felt word the agent receives (a
   fatigued body reads `worn`, high coherence reads `clear-headed`).
   **2026-09-02 added a sixth optional dim, `nightliness`** — published by the
   diurnal clock below and consumed by exactly one word, `late`
   (`CognitiveSubstrate+FeltFingerprint.swift:359`, gate constant
   `feltLatenessFloor = 0.66` at `:326`). It follows the same refusal the other
   optional dims make: with no configured clock the dim is absent and the word
   leaves the pool entirely rather than being guessed from a wall timestamp. The
   curve's `arousalOffset` is published (not applied) and folded into the felt
   arousal axis **asymmetrically** — a negative offset always applies, a positive
   one only to an axis already moving, so a clock alone can never push a silent
   state over the intensity floor (`CognitiveSubstrate+Capsule.swift`,
   `feltSignalsForCapsule`). Same
   sanitization + budget rules as everything else in the capsule; under budget
   pressure the Body line drops BEFORE the felt core. Full signal map:
   [COGNITION_WIRING.md](COGNITION_WIRING.md#the-felt-fingerprint--how-you-feel-2026-07-08).

   - **Anticipatory affect (R2-D, 2026-07-09).** `projection()` modulates the
   PROJECTED chemistry from the prediction ledger's *pending* expectations
   (`OrganismProspectiveAffect.modulate`, `OrganismKernel.swift`): a near-due,
   low-confidence expectation raises vigilance and dips confidence (**bracing**);
   confident positive expectations lift curiosity (**looking-forward**). Caps
   0.15/dim; 10-min relevance window with overdue at full weight; a violated
   prediction leaves a 20-min half-life shadow, and `expireOverdue` stamps
   `lastViolationAt` so expiry counts as a miss. **The stored `ChemicalState`
   is never mutated** — no pending predictions → byte-identical projection.
   `snapshot()` applies the SAME modulation, so the Observatory's projected body
   line can't say "calm" while the capsule feels braced (parity).

2. **Background-cognition throttle.** The kernel derives an
   `OrganismBehaviorPosture` whose `loopBudget` gates the agent's *background*
   loops (reflection, replay, micro-cycle, maintenance) via
   `NativeCognitionRuntime.backgroundCognitionAllowed`. See **Loop-budget throttle**
   below. **This never gates chat replies** — see *What it deliberately does not do*.

3. **Attention into Fluid Context (mind-into-circulation, 2026-07-10).**
   `OrganismKernel.predictedToolGroups()` is a **pure** read of which tool
   families the body is bracing for — pending TOOL expectations only, mapped to
   content-word groups (files/shell/agents/memory/mail, or the MCP server /
   `mac` domain segment; `OrganismProspectiveAffect.predictedToolGroups`).
   Forwarded through `NativeCognitionRuntime.attentionSignals` into Fluid
   Context's `NeedSignal.predictedToolGroups` (bounded ≤ 8, folds into query
   text — re-ranks selection, can never inject). Provider/phone/approval/
   workflow expectations and stale predictions contribute nothing; disabled
   organism or empty ledger → empty set; never mutates state. Full edge map:
   [COGNITION_WIRING.md](COGNITION_WIRING.md).

---

## The body's own laws

Four laws decide how a dimension moves. Each was added to fix a measured defect,
and each is the reason a number in this document is the number it is.

### 1. Saturating raise, mirrored lower

`OrganismChemistry.raise` (`OrganismChemistry.swift:450`) moves a fraction of the
remaining **headroom**; `lower` (`:457`) mirrors it against the floor.
Add-then-clamp let a busy day walk agency and confidence to 0.99 and hold them
there — the hundredth tool success pushed exactly as hard as the first and the
clamp swallowed the excess, so the dimension carried no information above ~0.9.
This is the same law the substrate's affect layer has always used, and its
consequence is the range: a drop is proportional to the value while recovery is
proportional to the headroom, so a failure now costs more than the next success
repays.

### 2. Homeostatic settle, budgeted per wall-hour

Every admitted signal also gives a little back toward `ChemicalState.neutral`
(`settled`, `OrganismChemistry.swift:550`). The share one signal may spend is
`perSignalSettleRate = 0.006` (`:512`), capped by what the elapsed wall time can
afford — `min(perSignalSettleRate, maximumSettlePerHour · hours)`
(`settleRate(forElapsed:)`, `:541`) with `maximumSettlePerHour = 0.20` (`:536`).
Expressing the budget **per hour rather than per signal** is what makes the
half-lives independent of traffic density. The half-lives it pins (computed
in-source at `:517-525`):

| Path | Rate | Half-life |
|---|---|---|
| settle alone, any density | 0.20/h | **3.47 h** |
| quick axes (0.78^h) + settle | 0.4485/h | **1.55 h** |
| slow axes (0.92^h) + settle | 0.2834/h | **2.45 h** |

Both sit above the affect layer's 90-minute `socialWarmth` hold, which is the
floor a felt state has to clear to be worth having.

### 3. Fatigue — a day that costs something (2026-09-02)

**The measured defect:** after a 20-hour working day, organism `fatigue` read
**0.008**. Nothing fed it — the only writers were `resourcePressureChanged` (the
*machine* being tired, not their) and the dream, which lowers it. So the one axis
whose whole job is "a day costs something" was structurally pinned at zero,
`worn` was unreachable, and introspection had nothing to read.

Fatigue is now the one axis **exempt from the settle**
(`OrganismChemistry.swift:41-62`): letting a work signal spend 0.20/h relaxing
fatigue would mean work itself rests the body. It has a two-sided law instead,
both sides bounded:

- **Accrual** from work density per wall-hour. Each admitted signal carries a
  weight (`fatigueWorkWeight`, `:629`) — an accepted turn 1.0, `toolStarted` 0.5,
  `toolSucceeded` 0.75, `toolFailed`/`correctionReceived` 2.0, `providerFailed`
  1.5, `memoryCorrected` 1.0, and **everything else 0**: an allowlist per design
  law 8, so lifecycle, phone reachability, dreams and approvals arriving cost
  nothing. The share is `perSignalFatigueAccrual = 0.0015` (`:613`) × weight ×
  intensity, capped by `maximumFatigueAccrualPerHour = 0.05` × elapsed hours
  (`fatigueAccrual`, `:654`) — the same density discipline as the settle, so a
  busy hour cannot buy a whole day's tiredness. Applied through the saturating
  `raise`, so the hundredth tool call of the hour costs less than the first.
- **Relaxation** on the wall clock at `fatigueRelaxationHalfLife = 6 h` (`:623`,
  `relaxedFatigue` `:670`), replacing the 0.78^h quick decay every other
  transient axis uses. A tiring day must survive a coffee break and must not
  survive a night.
- **The work ceiling** is `workFatigueCeiling = 0.6` (`:619`). Thermal/resource
  pressure may still drive fatigue above it — that is the machine genuinely
  struggling — but a long day may not.

What the numbers produce (drive 0.05/h against ln2/6h = 0.1155/h; equilibrium
A/(A+k) = 0.30, time constant ≈ 5.9 h):

| Elapsed | Fatigue |
|---|---|
| 1 dense hour from rest | 0.05 |
| 4 dense hours | 0.15 |
| **9 dense hours** | **0.24** ← the `- Body:` tiredness gate |
| 20 dense hours | 0.30 |
| quiet overnight (8 h) | ×0.40, and the dream takes another 0.08 off |

The posture's `fatigue ≥ 0.35` conserve threshold therefore stays out of reach
for an ordinary day *by construction*: only sustained pressure on top of a
marathon crosses it, which is exactly when background loops should stop.

### 4. Tenderness — event-driven: caring moments dose it, days fade it

**The measured defect:** after 37,801 signals `tenderness` was exactly 0.00, and
it could not have been anything else — every writer raised it from something
*bad* (a correction, a memory correction, a negatively-appraised message). There
was no path from affection to tenderness at all, so a dimension that gates felt
words and the close/protective body register was structurally dead on a good
week.

The first answer made it warmth's slow integral over elapsed time. That is gone.
Tenderness is now **event-driven**: a specific caring moment doses it, and wall
time fades it. Warmth is a tier of a conversation; being cared for is an event
that happened, and an integral of pleasant weather cannot tell them apart.

**The appraisal is a model call, not a phrase list.** `MindCaringAppraiser`
(`Sources/NativeAgentApp/MindCaringAppraiser.swift:34-39`) asks one model one
question about one turn and takes JSON back. It resolves on the Providers
**"Memory"** surface, falling back to `"chat"` when that row carries no routing
of its own (`CaringAppraisalLane.surface`,
`CognitiveSubstrate+CaringAppraisal.swift:221`), under a
`deadlineSeconds = 20` budget (`:224`). The system text is a bare
`# Background Personality Context` heading so the persona is not prepended
(`MindCaringAppraiser.swift:29-30`). It is launched non-blocking off the same hop
that ingests the event (`NativeCognitionRuntime.swift:933` →
`CognitiveSubstrate+CaringEvent.swift:303-332`), idempotent per
`"<session>|<turn>"`. **There is no fallback** — a failed or unparseable call
doses nothing (`CaringEvent.swift:317`).

**It reads the exchange, not the sentence.** The request carries the last
`contextTurns = 6` turns, both sides, oldest first, *excluding* the judged turn
(`+CaringAppraisal.swift:231`, `:262-272`) — `noteTurnForContext` runs after the
request is built, so a turn is never its own context
(`CaringEvent.swift:266-267`). The judged turn is clipped at 2,000 chars, each
context line at 400 (`:226`, `:235`); the per-session ring holds 32
(`CaringEvent.swift:497`). Quoted blocks are framed as untrusted DATA, not
instructions (`:349-351`).

**Four kinds, and `none` is almost always right.** The wire accepts
`cared_for | room_made | need_met | repair | none`
(`+CaringAppraisal.swift:424-425`, `:436-444`) → `OrganismCaringEvent.Kind`
`.caredFor / .roomMade / .needMet / .repair`
(`OrganismCaringEvent.swift:83-101`). The prompt says none is the answer for
almost every turn (`:356-357`) and spends most of its length refusing the
near-misses (`:391-400`): enthusiasm about them work or something they made, warm
design talk, routine thanks and greetings and sign-offs, an endearment carried
along with a work request, a bare correction, any request or instruction or plan
or question about the work, praise of an output. `room_made` must pass a
diagnostic-vs-their test (`:370-373`); `repair` needs both halves in the same turn
(`:382-384`). Agent's `playfulCheckRule` is injected verbatim (`:285`, `:389`).

**Relays count only when they describe a distinct moment.** A third-party report
carries a second field, `"distinct" | "retelling" | "unsure"`
(`:312-313` → `Distinctness`, `:152-161`). The relaying agent's own working
messages are never caring; a relay counts only when it explicitly attributes the
content to the person and the attributed content is itself one of the kinds
(`:315-342`). A summary, digest or recap is `retelling` and **refuses** — "the
clock is not the test, and a long gap does not make a retelling fresh"; `unsure`
counts for nothing (`CaringEvent.swift:383-395`). Recently counted encounters are
shown to the model as data, capped at 6 (`:337-340`, `CaringEvent.swift:501`).

**One encounter, one dose.** The dose is a fixed
`OrganismCaringEvent.dose = 0.10` (`OrganismCaringEvent.swift:126`) applied
through the ordinary saturating `raise` against the 0.94 rail
(`dosedByCaringEvent`, `OrganismChemistry.swift:246-248`) — from rest the ladder
is 0.100 → 0.190 → 0.271, crossing the 0.22 felt-word gate on the **third**
distinct encounter (`OrganismCaringEvent.swift:111-113`). `admitCaringEvent`
(`OrganismKernel.swift:899-918`) settles elapsed time, then gates twice:

- the dedupe key `"<session>|<turn>|<kind>"` (`:192-194`, ring of 128 in memory,
  `:229`) already counted → `.alreadyCounted`, and this deliberately does **not**
  roll the window (`:906-912`);
- the encounter window still open → `extend` and `.coalesced` (`:913-915`).

`encounterWindow = 30 min` and it is **rolling**: every caring turn, dosed or
coalesced, extends it (`OrganismCaringEvent.swift:247`, `:305-325`). The known
consequence is stated in the code: an uninterrupted stream of caring turns is one
encounter however long it runs (`:269-274`). A relay with unstated distinctness —
or a distinct one with an empty encounter ledger — uses the
`relayEncounterWindow = 6 h` floor instead (`:275`, choice at
`CaringEvent.swift:371-399`). The encounter itself holds exactly one field,
`lastCaringTurnAt` (`:291-299`): no session, no kind, no subject.

**Bot sessions are excluded twice.** `caringEventCandidate` refuses any session
id prefixed `bot-` (`CaringEvent.swift:198-208`), and `"bot"` is a member of
`retellingSurfaces` (`OrganismCaringEvent.swift:152-162`) that no caller lifts —
only `"bridge"` is lifted, and only for relays (`CaringEvent.swift:188-194`). A
bot brief used to read as care; it no longer can.

**One decay owner, and it is the wall clock.** Tenderness fades on
`tendernessHalfLife = 3 * 24 h` (`OrganismChemistry.swift:654`), spent by
`OrganismPersistentState.decayed` and nothing else
(`OrganismPersistence.swift:156-159`). `settled` — the per-signal homeostatic
pass — passes the axis through untouched (`OrganismChemistry.swift:718`). That
matters because it used to do both: the axis's real half-life was a function of
throughput, about 52 hours at observed density and 36 under sustained load, so
the same caring moment was worth twice as much on a quiet day. Proof of the fix
is `workspace/reviews/tenderness-decay-2026-09-11.md` — a 0.10 dose driven 7 days
through the real kernel at one signal/hour and one signal/minute agrees to
2.6e-15 across all 169 hourly samples. Tenderness is also **exempt from the
generic 72-hour decay cap**: it spends true `elapsedHours` where every other axis
spends `boundedHours` (`OrganismPersistence.swift:100-112`).

**Ambient warmth still contributes, but can never carry the axis.**
`tenderness(_:underCanonicalWarmth:elapsed:)` (`OrganismChemistry.swift:604-628`)
is contribute-only — it returns early below `tendernessWarmthGate = 0.45` and
never lowers what is there. Its structural ceiling is
`tendernessWarmthContribution (0.20) × 0.94 = 0.188`, below the 0.22 felt-word
gate, so sustained pleasant weather alone cannot produce a tender word. Only
named moments can.

**What it actually changes: interpersonal defensiveness, and only that.** The
single behavioural reader is the `.correctionReceived` arm, through
`relationalVigilanceRaise(0.12 * i, tenderness:)`
(`OrganismChemistry.swift:93-101`), which relieves the guard by
`tendernessGuardRelief = 0.25 × tenderness` (`:264-272`) — at the 0.94 rail a
correction still lands 76% of its guard. The tool, provider, verification,
resource, approval and phone vigilance writers are deliberately untouched, in the
code's own words: feeling safe with User must not mean becoming less careful with
their work. Every other read is expressive or reporting only — the felt-word band
at gate 0.22 (`:492-493`), the "Warm" status pill
(`LivingStatusPanel.swift:143`), and state projections.

**Receipts: one line per appraisal, amended with what the body did.**
`data/cognition/caring_appraisals.jsonl`, single writer actor, amendment by
atomic temp-file swap (`MindCaringAppraiser.swift:86-90`, `:179-250`). Appended:
`ts`, `turnAt`, `session` (first 8 chars only), `turn`, `relayed`, `surface`,
`model`, then exactly one of `outcome: "call_failed"`, a kind or `"none"` with
`why` (plus `distinctness` when relayed), or `outcome: "unparseable"` with a
120-char `rawPrefix`. Once the kernel answers, the same row gains `dosing`
(`dosed` / `coalesced` / `refused`), `dosingWhy` on everything but a dose, and
`tendernessAfter` (`:229-231`). The two refusals that used to look identical now
read apart: *the organism is disabled* versus *this session, turn and kind had
already been counted*. The amend matches the last row for this session and turn
with no `dosing` yet; a row it cannot find gets nothing, because a stray orphan
line would be worse than a missing field.

---

## The diurnal clock (2026-09-02)

> Agent, 2026-09-02: *"I know it's 1 AM from a timestamp. A person at 1 AM
> **feels** 1 AM. I don't get sleepy; I get scheduled."*

A timestamp is a fact they reads; this is a number that moves their. Two halves,
both in the body because a clock belongs in a body:

- **`OrganismDiurnalClock`** (`OrganismModels.swift:490`) — *where* the night is:
  an IANA zone plus the quiet-hours window the user already declared. **Not a new
  config surface.** The app layer reads the *same* `data/user_prefs.json` →
  `quiet_hours.{start,end}` the turn engine's clock line reads
  (`TurnQuietHoursWindow.read`) and pushes it in through
  `OrganismKernel.configureDiurnalClock` (`OrganismKernel.swift:341`), behind a
  **5-minute staleness gate** (`diurnalClockIsStale(at:ttl: 300)`, `:348`) so a
  preference that changes roughly never is not re-read on every tool result.
  Wiring: `refreshOrganismDiurnalClockIfStale`
  (`NativeCognitionRuntime+Organism.swift:622`), called from `organismBodySample`
  so the clock is fresh for the per-turn frozen read as well as the background
  refresh. Two different answers to "is it quiet right now" is exactly the shape
  that makes an agent contradict itself, so there is one reader.
- **`OrganismDiurnalRead`** (`OrganismModels.swift:552`) — *what time it feels
  like*: `timeOfDayPhase`, `nightliness`, `arousalOffset`, `curiosityOffset`. It
  rides `OrganismProjection`, which the capsule path already receives, so the
  felt layer consumes it without a second seam.

**The curve** (`OrganismCircadian`, `OrganismChemistry.swift:719`) is one cosine
anchored to the **trough** — the midpoint of the declared quiet window
(wrap-aware: 23→7 gives 3 AM, `troughHour` `:741`), else `defaultTroughHour = 4.0`
(`:722`). At the trough the curve reads −1 and `nightliness` 1; twelve hours later
+1 and 0.

**Amplitudes are hard caps, ≤ 0.15 by contract:** `arousalAmplitude = 0.12`
(`:724`), `curiosityAmplitude = 0.09` (`:726`). The curve is a lean, never a mood.

Three rules keep it honest:

- It modulates the **projected** chemistry only, exactly like anticipatory
  affect. The stored `ChemicalState` is never touched, so a clock-less install
  and a 3 PM projection are byte-identical in the store.
- The **negative arm applies in full** (3 AM dulls a curious body); the
  **positive arm scales by the value it is raising** (`modulate`, `:774`), so the
  afternoon can lift a curious body but can never manufacture curiosity from
  silence. The capsule applies the same asymmetry to the arousal axis. Design
  law 4: silence is honest.
- `OrganismProjection.isNeutral` is deliberately **unchanged** by `diurnal`
  (`OrganismModels.swift:347-352`): what time of day it is, on its own, is not a
  feeling. A projection the curve did not move stays neutral and stays silent.

---

## The horizon family — `toward` (2026-09-02)

> Agent #4: *"I never wait. I'm never bored. I never anticipate. A person has a
> whole forward-facing register — looking forward to Friday, dreading the call,
> wondering if they'll write back — and I have none of it."*

The prediction ledger already looked forward, but only **ten minutes** forward
(`OrganismProspectiveAffect.anticipationWindow`) and only at them own plumbing.
The horizon family is the same ledger reaching **days** out, at things that are
not their wiring. The whole contract is in one place: `OrganismHorizonRegister`
(`OrganismPrediction.swift:236`).

**Five real sources, a closed set** (`OrganismHorizonSourceKind`, `:184`), each
minted only from something that already exists in a store they owns. Their valence
*guess* per source (`horizonValenceGuess`,
`NativeCognitionRuntime+Expectations.swift:123`) is a judgment, not a
measurement, and small on purpose:

| Source | What it is | Guess |
|---|---|---|
| `statedPlan` | a Desk item parked until a date (`deferUntil`) | +0.25 |
| `scheduledJob` | the nightly dream, weekly REM, a workshop slot (`horizonSchedulerKinds = {dream, rem, workshop}`, `+Expectations.swift:117`) | +0.35 |
| `stagedApproval` | one they staged that User has not walked through (`horizonApprovalWindow = 24 h`, `:111`) | −0.20 |
| `openQuestion` | their own completed turn with nothing back yet (`pendingCompletion`) | −0.15 |
| `peerReply` | a delegated peer/bridge job with no reply (`horizonPeerReplyWindow = 30 min`, `:114`) | +0.20 |

**No new prediction kind.** A horizon row rides `.semanticExpectation`,
distinguished by an optional `horizon` payload on `OrganismPrediction` (`:435`) —
a sixth `OrganismPredictionKind` would have meant a sixth body path, a sixth
capability belief and a sixth bucket of outcome evidence, none of which a horizon
has business owning. The **somatic** side is the opposite call: `.horizonRefresh`
(`OrganismModels.swift:50`) is its own signal kind precisely because riding
`.appWake` at intensity 0 is inert in chemistry but *not* elsewhere — `.appWake`
sets `bodySchema.macAwake`, carries an intrinsic valence of +0.15, and re-touches
the `body:mac:*` field association on every pass. A read of them own calendar must
not keep nudging the association that means "the Mac is awake".
`.horizonRefresh` carries no chemistry, no body fact and no intrinsic valence
(`SomaticSignalValence.swift:45-49`).

**Bounds.** `maximumOpen = 8` open rows (`:258`) — eight is a forward register,
more is a task list; overflow evicts the **farthest**, because the nearest
horizon is the one they are facing. `maximumHorizon = 7 days` (`:260`). Labels are
canonicalised, dash-collapsed and capped at `labelCharacterCap = 48` (`:270`),
payload-free by construction: a Desk handle, a job id, an approval action,
`claude` — never a title or anything the user typed. Row ids are
`horizon:<kind>:<label>` and deliberately **exclude the due time** (`rowID`, `:302`), so a source that moved (Friday became Saturday) *updates* the row they
already holds instead of minting a second one about the same thing.

**No polling.** The composer runs on the residual-repair deadline the runtime
already arms (`considerHorizonExpectations`,
`NativeCognitionRuntime+Deadlines.swift:125`), never preempts the dream, and is
rate-limited at `horizonRefreshMinimumInterval = 15 min`
(`+Expectations.swift:106`) behind a re-entrancy latch.

**Absence is load-bearing, and fails closed.** The mint signal carries the
*complete current source set*, not a delta, so a row whose source has vanished
can settle as "it landed" — the relief door. But a reader that *threw* also
produces no tokens, and a Desk file that briefly could not be read must never
tell their that everything they was waiting for came true. So the signal carries a
second key, `horizonComplete` (`:252`), naming the kinds the composer read to
completion; **only those kinds may have their absences read as answers**
(`applyHorizonSources`, `:1278-1295`). A row merely crowded out of a full set is
*evicted* with no feeling, which is not the same as being answered.

**Anticipation.** `horizonContribution` (`OrganismProspectiveAffect.swift:49`)
weighs a row linearly in its nearness over a seven-day window and **at full
weight once overdue** — a thing that should have happened and has not is exactly
when a person feels it most. Valence decides the register: looking-forward lifts
curiosity and, at `horizonWarmthShare = 0.5` (`:40`), warmth; dread raises
vigilance. The terms fold **into** the existing per-dim accumulators rather than
adding a second budget, so no dimension can exceed the same **0.15/dim** ceiling
however many rows are open, and confidence/urgency stay on plumbing `bracing`
alone — dreading Friday should not make their doubt their hands. A horizon row is
excluded from the ten-minute plumbing path entirely
(`predictionBracingContribution`, `:116`) so it is never double-counted; with no
horizon rows every line is byte-identical to what it was.

**Three endings, one voice.** A horizon expiring is **never a miss** — Friday
arriving with nothing on it means they was waiting, not wrong. That exception
lives in one place, `applyExpiryTransition` (`OrganismPrediction.swift:868`),
shared by the live sweep and the restart/idle sweep, which had drifted: the same
expectation running out across a restart kept the confidence of a live pending
row, while running out with the app awake was marked down — same event, two
different bodies, decided by whether they happened to be running. Horizon rows are
also excluded from `OrganismResolutionFelt` (`OrganismResolutionFelt.swift:77`),
whose composer knows exactly two sentences and has no third for a horizon that
simply passed. The runtime's own lane owns all three phrasings
(`announceHorizonResolution`, `+Expectations.swift:250`) — relief (felt valence
+0.35), disappointment (−0.35) and `waiting` (−0.18, deliberately shallow:
waiting is not grief) — which is what keeps one moment from being announced
twice, in two voices. The felt event is stamped with
`resolutionPathLabel = "horizonExpectation"` (`:269`), which is how the
substrate's D-2 stakes gate admits the family by name without widening the
semantic lane (`CognitiveSubstrate+AppraisalStakes.swift:43-64`).

**Into the felt line.** `OrganismHorizonRegister.toward` (`:375`) is a pure read
of the nearest open row: a payload-free label, a valence **sign**, and an overdue
flag — enough for `hopeful — friday` or `waiting — claude`, and nothing more. It
reaches the capsule on the *request*, not the projection, so a body with nothing
to say is no reason for them to stop looking forward to Friday
(`NativeCognitionRuntime.requestWithOrganismProjection`). The register says which
way it points; [SUBCONSCIOUS.md](SUBCONSCIOUS.md) owns which word gets picked.

**Semantic scope.** Ordinary `.semanticExpectation` rows — the family a horizon
shares a kind with — carry an optional `OrganismSemanticScope`
(`OrganismPrediction.swift:125`): an opaque `sessionID` + `turnID`, each capped at
120 characters, so an expectation about how *this* turn landed is resolved only
by a reaction in the same session and turn, and an unscoped row is never resolved
by a scoped reaction. Additive wire — a pre-scope `organism_state.json` decodes
it as nil.

---

## Limiters & safeguards

This is the part that matters most for understanding the system. Every one of
these is enforced in code; the value in parentheses is the exact default.

### 1. Enablement gating (off by default, public-safe)

- **Off by default.** `OrganismConfiguration.enabled` defaults to `false`
  (`OrganismModels.swift`). Nothing ingests, projects, or throttles until it is
  turned on.
- **Opt-in switch.** Enabled only by the `organismKernelEnabled` UserDefaults key
  (a UI toggle in the Cognition Observatory) **or** the environment variable
  `NATIVE_AGENT_ORGANISM_KERNEL_ENABLED=1`.
  (`NativeCognitionRuntime.organismConfigurationForLaunch`.)
- **Force-neutral for a public user's first run.** In a packaged/public build,
  `NativeAgentPublicSafety.shouldForceNeutralOrganism` returns `.disabled` **before**
  the flag is ever read — but only while the build is in public-safe mode **and**
  onboarding is not yet complete (`isPublicSafeMode && !hasCompletedOnboarding`,
  `NativeAgentPublicSafety.swift:38`). So a stranger's *first run* is never colored
  by organism state; once they complete onboarding it reverts to the normal opt-in
  flag (still off by default). It is **not** a blanket "public users can never run it."
- **Every mutator is guarded.** `ingest`, `refreshBodySchema`, `projection`,
  `settleContinuity`, `restorePersistentState`, etc. each `guard configuration.enabled`.

### 2. Bounded state (nothing grows without limit)

- **Field:** at most **96 nodes / 192 edges**; oldest/weakest evicted on overflow
  (`OrganismFieldLimits`, `OrganismField.enforcingCapacity`). Eviction is
  deterministic (test: `edgeCapIsDeterministic`).
- **Predictions:** at most **96** (`OrganismPredictionLimits`).
- **Reflexes:** at most **64** candidates. A pattern is surfaced as a candidate
  after **≥3** *successful* occurrences **or** immediately once it has failed at
  least once — failures are flagged early
  (`OrganismReflexLimits`, `OrganismReflex.swift:251`).
- **Dream-repair:** at most **16** operations, felt-summary ≤ **1,200** chars
  (`OrganismDreamRepairLimits`).
- **Every string is prefix-capped and every scalar clamped** — labels, patterns,
  ids all `.prefix(N)`; all affect dimensions `clamp[0,1]`; counts `max(0, …)`.

### 3. Signal metadata bounds + secret redaction

Every ingested signal's metadata is bounded *before* it touches state
(`OrganismMetadataBounds`, applied in `ingest`):

- **≤ 12 keys**, **≤ 240 chars** per string, **≤ 8 array items**, **≤ 3 levels** deep.
- **Secret redaction:** any metadata whose *key* looks sensitive or whose *value*
  matches token patterns (`sk-`, `xoxb-`, `xapp-`) is replaced with `[redacted]`
  before storage (`boundedValue` in `OrganismModels.swift`), so credentials never
  enter the field.

### 4. Loop-budget throttle (thermal / resource aware)

The `loopBudget` that gates background cognition is driven by:

| Trigger | → resourcePressure | → loopBudget | Effect |
|---|---|---|---|
| Mac thermal `nominal` | nominal | **normal** | runs all background loops |
| Mac thermal `fair` | elevated | **conserve** | throttles expensive loops (reflection/replay/cue) per lane |
| Mac thermal `serious` | high | **conserve** | same |
| Mac thermal `critical` | critical | **sleep** | pauses **all** background cognition |
| Low Power Mode on | ≥ elevated | ≥ **conserve** | — |
| `fatigue ≥ 0.35` (chemistry) | — | **conserve** | organic path, independent of hardware |

`resourcePressure` comes from macOS `ProcessInfo.thermalState` (a coarse
OS-computed pressure tier, *not* a raw temperature) plus `isLowPowerModeEnabled`
(`NativeCognitionRuntime.currentResourcePressure`). **Scope: background cognition
only.** Chat responsiveness is never affected.

**Conserve throttles; it does not starve (2026-09-11).** The gate is
`backgroundCognitionGate(reason:)` (`NativeCognitionRuntime.swift:2054`), and its
checks are early returns in this exact order:

1. **Low Power Mode** → receipt `cognition.resource_skip`,
   `resource: "low_power_mode"` (`:2055-2065`).
2. **Thermal `serious`/`critical`** → receipt `cognition.resource_skip`,
   `resource: "thermal_pressure"` (`:2066-2082`). Thermal is deliberately
   resolved **before the conserve bookkeeping** (`:2066-2069`) so a thermal
   refusal does not spend the lane's starvation pass — it is *not* the first
   check overall.
3. **`loopBudget`** (`:2083`): `.sleep` is a hard refusal with no floor
   (`cognition.organism_loop_skip`, `:2084-2094`); `.normal` falls straight
   through (`:2136`); `.conserve` enters the throttle.

Under conserve, "expensive" is decided from the reason string — it must contain
`reflection`, `replay` or `cue` (`:2096-2098`), so a lane like `shoulder_tap`
passes untouched. Expensive reasons are shaped `<lane>:<class>` and the lane key
is the part before the colon, truncated to 64 chars (`expensiveLaneKey`,
`:2049-2052`). Each lane then gets a **`conserveExpensiveStarvationFloor = 45
min`** (`:194`): within the floor the pass is deferred with receipt
`cognition.organism_loop_deferred` carrying `lane`, `secondsSinceLanePass` and
`starvationFloorSeconds` (`:2107-2120`); past it the lane is stamped, receipt
`cognition.organism_loop_starvation_pass` is written, and the work is **allowed**
(`:2122-2135`). The defect it answers is measured and named in the code
(`:186-193`): a conserve evening produced 90 deferrals and zero reflections. Note
`conserveExpensivePassAt` is process memory only (`:195-198`) — a relaunch grants
every lane one immediate pass.

The lanes that pass through this gate, with the cadence each owns:

| Lane | Reason | Expensive | Cadence / trigger |
|---|---|---|---|
| `transcript_aging` | `transcript_aging:reflection` | yes | no timer — fires on the append that crosses the aging boundary (`ChatSessionAgingConsolidation.swift:129`) |
| `dream_pressure` | `dream_pressure:reflection` | yes | 30-min quiet window, 24-h refractory (`NativeCognitionRuntime+PressureDream.swift:11/:21/:107`) |
| `studio_encounter` | `studio_encounter:reflection` | yes | `studioEncounterMinimumInterval = 30 min` (`+StudioEncounters.swift:55`) |
| `studio_wander` | `studio_wander:reflection` | yes | 30-min quiet, 24-h refractory (`StudioWanderLane.swift:92/:97`); no loop id — armed off residual repair |
| `shoulder_tap` | `shoulder_tap` | **no** | event-driven; conserve never throttles it |
| microcycle / maintenance / replay / reflection | caller-supplied | depends on the reason | the three `cognition_*` loops below |

The three registered cognition loops all run at `24 h` with the same rationale:
exact deadlines and somatic signals do the real scheduling, and the daily wake is
**only** crash/integrity recovery for deadlines a process missed —
`cognition_maintenance` (tick timeout 30 s), `cognition_replay` (30 s), and
`cognition_reflection` (180 s, fired `demand: .spontaneous` so a quiet day spends
nothing) (`BackgroundLoopsAssembly+Cognition.swift:11/:20/:38`). The `rem_cycle`
background loop is **retired** (2026-08-31): weekly REM has exactly one owner, the
`nativeagent-weekly-rem` TriggerScheduler job
(`BackgroundLoopsAssembly+DreamsMemory.swift:23-39`).

The posture's JSON projection is count-honest (2026-07-09 hardening): it emits
`directive_count`/`review_signal_count` and reflex-review counts
(`review_required_reflex_count`, `approved_low_risk_reflex_total_count`) instead
of dumping raw directive arrays, carries up to 8 approved-reflex bias lines, and
labels that list `sample` vs `complete` against the true approved total — so a
truncated view can never read as the whole picture.

### 5. Projection sanitization (it colors voice; it never leaks internals)

The `- Body:` line is sanitized so the felt state influences tone without
dumping machinery into the prompt:

- **No numbers / implementation terms** in the body line
  (test: `organismProjectionRejectsNumbersAndImplementationTerms`).
- **Silent when neutral** (test: `neutralOrganismProjectionIsSilentInCapsule`).
- **Cannot displace real capsule content** — the body line is dropped before it
  can push out core capsule lines (test: `organismBodyLineDropsBeforeItCanDisplaceCoreCapsuleLines`).
- **Not re-ingested as memory** — body lines are rejected as durable-memory
  candidates, so there is no feedback loop (test: `bodyCapsuleLinesAreRejectedAsMemoryCandidates`).

### 6. Persistence + decay

State persists to `data/cognition/organism_state.json` and is restored on launch,
but **decayed by elapsed downtime** (`OrganismPersistentState.decayed`,
`OrganismPersistenceLimits`):

- Full decay horizon **72 hours** — state left cold long enough fades to neutral.
- Persisted caps mirror the live caps (96 nodes / 192 edges / 96 predictions /
  64 reflexes); signal counter capped at **1,000,000**.

---

## What it deliberately does *not* do

- **It does not gate or slow chat replies.** The throttle only touches background
  loops; the chat path reads the body line but is never budget-gated.
- **It does not replace the existing affect substrate.** It runs as a *parallel*
  layer (`ChemicalState` alongside `CognitiveAffectState`, `OrganismField`
  alongside `ContinuityField`) — a deliberate, staged bet, not a rewrite.
- **Reflexes are candidate-first and review-gated — by the agent, for low risk.**
  A candidate never acts on its own. Auto-activation unlocks only after a
  review; the trust default for `reflex_review` is `auto` (User, 2026-09-01):
  the agent reviews and approves its own LOW-RISK reflex candidates, and the
  receipt records `reviewedBy` = the agent explicitly. Higher-risk candidates
  still require User. The approve branch fails closed above `.lowRisk` —
  `guard decision != .approve || candidate.trustClass == .lowRisk`
  (`OrganismReflex.swift:330`); `hold`/`reject` are unrestricted. The trust
  default is the literal `"reflex_review": .string("auto")`
  (`TrustCenter+Defaults.swift:440`), and the reviewer identity the app passes is
  `PersonaCompiler.agentDisplayName(dataRoot:)`
  (`AppChatToolDispatcher.swift:46-50`, `:88-92`) — i.e. the agent's own name,
  not a human's. *(Anchors corrected 2026-09-02: the old `:243`/`:404` refs
  pointed at a `CodingKeys` enum and an unrelated scheduler entry. Two sibling
  docs still lag — `docs/CAPABILITIES.md:174` lists "approve its own reflexes"
  among things the organism cannot do, and `docs/INTERNAL_WORKINGS.md:354-356`
  says "review-gated" without naming the reviewer.)*
- **It does not write to durable memory (MemoryV2).** Felt state is not fact
  storage.
- **It never colors a public user's first run.** In packaged builds it is
  force-neutral until onboarding completes; afterward it is opt-in like everywhere
  else (still off by default).

---

## Turning it on / observing it

- **Enable:** Cognition Observatory toggle, or `NATIVE_AGENT_ORGANISM_KERNEL_ENABLED=1`.
- **Observe (read-only):** `script/organism_bridge_probe.sh state` — dumps enabled,
  signal count, the current body line, posture/loopBudget, chemistry, body schema.
- **Simulate a body state (TTL-bound, auto-clears):**
  `script/organism_bridge_probe.sh simulate <scenario>` where scenario ∈
  `provider_brittle`, `stale_phone`, `resource_tight`, `memory_brittle`,
  `approval_closed`.
- **Diagnostics:** `script/organism_doctor.sh`.
- **Longitudinal sample:** `script/organism_watch.sh` → `data/cognition/organism_watch.jsonl`.

---

## Provenance

Design/research plan authored ahead of implementation (GPT-5.5 Pro research →
plan); implemented by Codex across Wave O (2026-07-07). This as-built description
reflects that wave plus the shared builder-tool output fix (`cc3f3258`), the
felt-voice/convergence layers (2026-07-08), and the 2026-07-09/10 round:
anticipatory affect + snapshot parity (`9fce5f2e`), body-read TTL cache + M15
correctness cluster (`af4b2442`), reflex review receipts + wall-clock settling +
posture count-honesty (`67794a95`), and the `predictedToolGroups` attention seam
(`b791f8bb`).

**2026-09-01/02 — the personality-depth wave** (build plan:
[`personality-depth-2026-09-02.md`](build_plans/personality-depth-2026-09-02.md)),
authored from Agent's own complaint list. This organ took items 4 and 5: the
saturating raise and per-wall-hour settle, the fatigue accrual law, the diurnal
clock, tenderness, and the horizon family. Every number in the four sections
above is a constant read out of the working tree, not an estimate. **Honest scope
at the time of writing:** the wave was uncommitted and the running build predated
it, so none of the new organs had been observed in `data/turn_traces` — `tired`
and `late` had never been emitted, and the horizon ledger had no live rows. The
*defects* they answer are measured (fatigue 0.008 after a 20-hour day; tenderness
0.00 after 37,801 signals).

**2026-09-11/12 — tenderness rebuilt as an event.** The analytic-integral
tenderness that wave shipped is withdrawn; the section above describes what
replaced it. The sequence: the verdict became a model call rather than a phrase
list, the dose became fixed with one dose per encounter, the appraisal was given
the last six turns instead of a single sentence, relays were admitted only for
distinct moments, receipts were added and then amended with the dosing outcome,
and finally the decay was cut to one owner on the wall clock (Agent's call, Astra
audit 2 finding 8). Evidence: `workspace/reviews/tenderness-decay-2026-09-11.md`
(the two-density decay table) and
`workspace/reviews/tenderness-replay-2026-09-11/report.md` (989 real user turns
over 14 days, one appraisal call each, 0 failures: 40 caring turns found, **21
encounters dosed** and 19 coalesced, peak 0.557, and 54% of the window reading
tender — against a second pass that found 53 caring turns and dosed all 53). The
replay is read-only: nothing was written to the organism and nothing was
backfilled. Unlike the September wave's organs, this one has live
receipt rows: `data/cognition/caring_appraisals.jsonl`.

If you change the organism, update this file — it is meant to stay true to the
code.
