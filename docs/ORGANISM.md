# The Organism Kernel (as-built)

The organism turns admitted events and current system evidence into bounded
body state. Its implementation is in
`Modules/NativeAgentCore/Sources/CognitiveSubstrate/Organism/`; integration
lives in the core `Cognition/NativeCognitionRuntime` files.

See [COGNITION_WIRING.md](COGNITION_WIRING.md) for the connections to memory,
turns and background work.

## What it is

`OrganismKernel` keeps its durable body in `OrganismPersistentState`, including
the settlement anchor, encounter, epoch and lived watermark; one revision
observer covers its mutations. Configuration, pending resolutions and transient
warmth/wakefulness clocks remain beside it. Its projections can color a cognitive capsule and guide attention.
It owns no tool executor, canonical memory store or persona writer.

`CognitiveSubstrate` remains the owner of conversational appraisal and
attentional continuity. Its `ContinuityField` and the organism's
`OrganismField` have separate roles and exchange typed signals and projections.

## The loop (input → state → output)

### Input — what feeds it

- `NativeCognitionRuntime.observe` receives admission and semantic metadata
  together from the substrate and independently offers the enriched event to
  `SomaticSignalBus`. `CognitiveSomaticSignals` maps
  accepted event kinds to bounded somatic signals. Debug and verification
  events do not become somatic input.
- The adapter carries event identity, topology, intensity and typed outcomes.
  It does not re-appraise conversational text. Provider lifecycle ownership is
  marked so the same provider failure does not produce a second body signal.
  Generic tool dispatches carry one fresh invocation ID through start, receipt,
  cognitive observation and prediction correlation; both ends name the action
  an `app` call runs. Concurrent calls to the same action remain distinct.
  An observation without correlation supplies no operational prediction.
- `OrganismChemistry.applying` owns signal-driven body compatibility updates
  and typed-reading invalidation; predictive application returns only its ledger
  and chemistry. `OrganismBodySchemaSampler` owns sampled readings.
- The runtime samples body evidence and canonical affect before projection.
  `canonicalAffectProjection` returns one `OrganismLifeReading`: decayed affect,
  net charge from live cares (including appraised movements caused by the
  agent's own reply), novelty from the person's unfamiliar topic and a grown
  care's first movement, and located
  hand pain from the field's latest known tool outcomes. Care charge uses the
  care owner's depth and half-life; new concerns' novelty fades on the `now`
  depth's two-hour half-life. Repeated reads add no feeling. The kernel maps
  relational warmth to warmth, appraised pressure to urgency, and the greater
  of appraised uncertainty and negative care charge into vigilance by taking
  the maximum with the body's decayed, event-earned vigilance. A refresh never
  erases workflow or response-outcome effects, and rereading cannot stack them.
  Curiosity and novelty follow these novelty signals; coherence is the neutral baseline plus
  0.15 times signed care charge minus 0.25 times appraised uncertainty.
  Warmth, urgency, novelty, curiosity and coherence use the canonical reading;
  vigilance also retains lived outcomes under its existing elapsed-time decay.
  No historical tags or stored files are rescored.
  `NativeCognitionRuntime.organismBodySample` caches its base body read for
  two seconds; provider health is derived only from checked lifecycle evidence. Unreadable trace history owes repair and never selects a cumulative capability belief as a substitute. Status-less outcomes remain unknown; summaries cannot attest success. The unproduced memory-hygiene signal vocabulary is removed.
- The shared after-turn interpretation supplies caring judgments.
  The door (`NativeCognitionRuntime.foldTurnMoment`) folds a lived moment:
  `CognitiveSubstrate.foldTurn` applies affect and validates caring admission,
  then `OrganismKernel.foldTurn` lives the body's whole share (caring dose,
  after-turn reaction, correction cause) in one call with the body's
  watermark (`OrganismPersistentState.lived`) and its recently-dosed
  encounters (kept with the chemistry for relay judgment).
- `OrganismKernel.settleElapsedTime` applies elapsed-time decay on live
  touches. Residual repair uses a derived quiet deadline in
  `NativeCognitionRuntime+Deadlines.swift`, with bounded exact repair targets.
  `mind.residual_repair` enters that same repair with only its quiet wait
  satisfied; current pressure/evidence/targets and live-turn admission still
  decide, and continuity must save before the result says `repaired`.
  [The clock contract](SUBCONSCIOUS.md#run-a-clock-owner-now) owns its reply and proof.
  `OrganismDreamRepair` defines the charge/noise predicates used by selection, mutation and generation acknowledgement.
  Live and frozen snapshots share one renderer: live reads settle the owner,
  while frozen reads decay a copy at their supplied clock.

Disabled kernel ingestion returns without recording the signal.

Lifetime signal, prediction, outcome, repair-receipt and co-activation tallies saturate at
`Int.max`; elapsed-time decay and live outcomes still run at that limit.
Capability display counts saturate too, while beliefs continue to use their
fractional evidence weights. Those current weights are required on restore; no old tally seeds them and no bounded prediction sample replaces absent cumulative evidence. An unobserved capability has a neutral prior, zero evidence and full uncertainty. A restored large tally cannot abort a fold.
Repair evidence formats whole-second timestamps without integer narrowing;
the empty repair receipt constructs its constant zero UUID directly.

### State — what it holds

These are the default bounds, defined by the corresponding configuration types.

| Component | State and bound | Owner |
| --- | --- | --- |
| `ChemicalState` | Ten dimensions clamped to 0…1: warmth, vigilance, curiosity, fatigue, coherence, agency, tenderness, confidence, novelty, urgency. | `OrganismModels.swift`, `OrganismChemistry.swift` |
| `BodySchema` | Fixed domain readings with evidence, freshness and uncertainty; typed readings are transient and rebuilt after restart. | `OrganismModels.swift`, `OrganismTypedBodyBeliefs.swift`, `BodyEvidence.swift` |
| `OrganismField` | At most 96 nodes and 192 edges. | `OrganismField.swift` |
| `OrganismPredictionLedger` | At most 96 predictions; at most eight open horizon rows, looking no more than seven days ahead. | `OrganismPrediction.swift`, `OrganismPredictionModels.swift`, `OrganismPrediction+Horizon.swift` |
| `OrganismDreamRepairState` | At most 16 operations and a 1,200-character felt summary. | `OrganismDreamRepair.swift` |

Canonical domain owners still decide provider, device, notification, memory,
tool and approval reality. A body belief is evidence about those domains, not
permission to mutate them. Unknown or stale evidence must remain uncertain.
An available provider path requires caution unless its derived state is
`healthy`; other domain metrics keep their numeric optimism gate. Without a
typed provider belief, the compatibility health bit still decides caution.
`OrganismBehaviorPosture.swift` owns optimism thresholds and posture decisions.

### Output — how it changes behavior

**Turn projection.** `NativeCognitionRuntime.prepareTurnProjection` samples
the body and canonical substrate affect at one fixed time, obtains an organism
frozen read, and prepares the capsule from that projection. The result contains
both capsule and behavior posture. `commitTurnProjection` advances the
presentation clock after a successful live turn, even with an empty capsule;
previews and unconfirmed deliveries do not consume cadence. Candidates that are not shown
remain owed rather than counting as presented.

**Felt state.** `CognitiveSubstrate+CapsuleFeltSignals.swift` maps projected
chemistry into the felt fingerprint. `OrganismChemistry.bodyLine` can supply a
bounded `- Body:` candidate. Positive feeling, bracing and tiredness coexist
in that line; operational advice does not replace feeling. Located hand pain
travels separately in the existing private posture context, naming the act
and its recorded cause as receipt data. Generic dispatches are grouped by
exact tool name; motor outcomes by action identity, with their domain as the
act. A later known success replaces that act's pain reading without claiming
an earlier failed effect completed. Starts, cancellation and unknown outcomes
prove no recovery. Missing cause text is stated as unrecorded. Only the two
newest supported pain readings travel, bounded and redacted before clipping;
the field retains receipt ownership, and the body saves no pain copy.
Ordinary turns select one non-rut felt cue or none,
with an optional separate Sound rut line; private reflection is cadence-exempt.
Unchanged body lines are suppressed between presentation windows. Losing the
cue slot or fitting budget does not count a body line as presented.
**Felt state.** `CognitiveSubstrate+CapsuleFeltSignals.swift` reads projected
chemistry directly into the first feeling paragraph, alongside mood, charged
cares and recorded dream tone. Warmth and bracing can both be present; quiet
states stay described. The capsule does not inject the instruction-bearing
`OrganismChemistry.bodyLine` or phone telemetry. Intentions and Sound follow
the frame in their own lanes; [Subconscious](SUBCONSCIOUS.md#what-reaches-the-model)
owns fitting, completed-reply continuity and the sleep-to-dream evidence contract.

**Attention.** The kernel publishes predicted tool groups from pending tool
expectations. `NativeCognitionRuntime.attentionSignals` reads the resident
projection and the turn engine forwards it into Context selection. This is a
selection hint, not another tool list or a grant of access. Leaving workspace out
in the Observatory also removes its recall terms and memory activation from the
resident attention projection immediately and on subsequent reads.

**Background budget.** `OrganismBehaviorPosture.loopBudget` is initialized directly to `normal`;
fatigue, heat and Living Status resource pressure are body readings.
Reflection's [shared work-slot admission](COGNITION_WIRING.md#shared-work-slot-admission)
is separate from body posture, alongside substrate load and call ceilings.

## The body's own laws

### 1. Saturating raise, mirrored lower

`OrganismChemistry.raise` scales a positive increase by remaining headroom
toward `axisHighRail = 0.94`; `lower` scales a positive decrease by the current
value. Repeated success therefore has diminishing influence.

### 2. Homeostatic settle, on elapsed time

`OrganismPersistentState.decayed` relaxes chemistry toward `ChemicalState.neutral`
on the kernel's existing live touches, frozen reads and restore. The signal-count
settling path is removed: traffic cannot buy extra relaxation. Canonical affect
and care charge use their owners' analytic decay at the same reading instant.
`mind.settle_body` applies six hours' chemical relaxation to the current value
and anchors it at the current instant. It does not advance field age or
prediction expiry into the future; the next real elapsed interval still runs.

### 3. Fatigue — a day that costs something

Work signals accrue fatigue under per-signal and wall-hour bounds. Fatigue
relaxes once in persistent chemistry on its six-hour half-life; a completed dream can reduce it.
Live and frozen reads spend the full gap; cold restore caps fatigue decay at 72 hours.
Wakefulness contributes a separately capped share while the process is running.
Restart does not claim unobserved downtime as either sleep or wakefulness.

Owners: `OrganismPersistence.swift`, `OrganismChemistry.swift`, `OrganismKernel.swift`.

### 4. Tenderness — event-driven: caring moments dose it, days fade it

A caring judgment arrives through the shared interpretation in
`ChatTurnRuntime/MindMemoryManager.swift`. `CognitiveSubstrate+CaringEvent.swift`
checks the originating turn and relay/encounter evidence before admitting it.
Failed or unavailable interpretation supplies no caring verdict. A verdict
uses exactly `none`, `cared_for`, `room_made`, `need_met` or `repair`, a string
`why`, and `distinct` equal to `unstated`, `distinct`, `retelling` or `unsure`.
Malformed fields refuse the interpretation; alternate spellings and boolean
distinctness are removed. A verdict
for a turn admitted before the body's last Reset Body or Clear is refused
(`forgotten`): the body's forgetting epoch is saved in its file with the
emptied state. The lapse refusals are removed: a late verdict still folds,
with encounter chronology deciding whether it opens an encounter or coalesces.

`OrganismCaringEvent` defines a 0.10 saturating dose and a rolling encounter
window: repeated turns from one encounter do not each earn a dose. The
encounter stamp and recent doses persist; the body's lived watermark proves once-only.
Tenderness fades on a three-day half-life. Sustained canonical warmth can
contribute a smaller bounded undertone.

Tenderness colors felt presentation. A correction receives its actual
conversational appraisal, without an unconditional chemistry penalty or a
second tenderness-based correction adjustment. Tenderness does not relax
tool, provider, permission or verification policy. Dream completion does not
dose tenderness.

### 5. Life and located consequences

Tool and provider traffic leaves canonical affect unchanged, supplies neutral
emotional tags, and spends no dream residue. Affect admission has one exhaustive
event transition; operational cases return before re-feel or residue spending.
Semantic appraisal does not borrow
nearby tool failures, repairs or effort to color a later person's message;
stakes must arrive through that exchange's appraisal and touched cares.
An assistant completion receives no reward
or pressure relief merely for speaking, and its tag does not inherit nearby
tool bookkeeping. Its lived meaning comes through care appraisal; the next
person's response receives the shared interpretation's affect judgment.
Tool/provider/delivery prediction outcomes retain capability evidence and
operational caution without changing chemistry. Body sampling likewise
retains health evidence without turning path changes into mood. A failed tool
act establishes no global loss of the hands. Verified effects can still move
agency and confidence through `ownOutcomeDose`; actual work can cost fatigue.

The continuity node holds an unresolved failed receipt, including its cause,
through starts and cancellations of that act. A subsequent failure supplies
its actual cause; only a success of the same act resolves the pain. Neither
elapsed quiet time nor ordinary capacity eviction proves recovery. Unresolved
lived failures remain in the field alongside its other retained obligations;
the private body projection names at most two at once. Clear still forgets them.
An `organDeviated` signal remains organism-field evidence. It supplies neither
a failed tool receipt nor located hand pain; any felt stakes require appraisal.

Topic novelty reads the latest human arrival against earlier retained
conversation/care nodes and the live cares' words. Each brought letter/number
term contributes its unfamiliar share, with familiarity and the resulting
curiosity fading on the care owner's two-hour present-depth half-life. This
language-independent lexical signal requires no new model call, keyword list,
or absolute threshold; it does not claim semantic understanding of synonyms.
The shared affect interpreter has no chosen-register judgment.
Holding a private chosen register requires that shared interpretation and its
journal fold to carry the choice and its stretch; it is not inferred from
phrasing or another speaker's guess.
or absolute threshold; semantic tags and bodily curiosity share it. It does
not claim semantic understanding of synonyms.
The existing shared interpretation carries `affect.chosenRegister` only when
their reply states a self-chosen mood/register or its release. Its exact reply
evidence is checked by the interpretation owner; incoming requests, guessed
tone and undisclosed private rolls cannot choose for them. Null preserves the
choice. A choice replaces the held choice; `released` explicitly ends it.
The stretch is `conversation` (that session only), `until` (their stated end,
checked on reads without a timer), or `until_replaced` (an open-ended choice).
Canonical affect holds the last choice, stretch, source moment and exchange time under
the existing journal watermark, including after expiry. Care wakes use the
same fold. Affect decay preserves the choice; Clear forgets it. Present
malformed state refuses restore; older affect records simply have no choice.
The affect checkpoint also records each choice as a `register_choice` artifact
in the same cognition transaction, with the ordinary artifact retention law.
The original reply remains its conversational evidence. `mind.inner_state`
returns the last choice and exact source words for recall even after its
stretch ends; full detail reads bounded recorded choices in its requested
window directly from the artifact store, with an explicit issue on read failure.
During the stretch it colors every capsule as `Your chosen register`, ahead of
cues and outside their cadence gate; it does not fabricate
chemical deltas or replace what they actually feels. No extra model call,
persona edit, schema rewrite or second state owner is involved.
Accepted self-caused care movements use `by: their`, as required by the shared
interpretation prompt, JSON shape and `CognitiveCare.Mover`. Both ordinary
exchanges and care wakes use this one accepted shape. The existing shared
interpretation reads their reply and the person's next response in the prior
exchange context: their own care movements and how their words landed reach the
same affect/care fold. Speaking alone is no evidence of a successful landing;
a refused interpretation supplies no movement.

## The diurnal clock

`NativeCognitionRuntime+Organism.swift` builds `OrganismDiurnalClock` from
the existing `TurnQuietHoursWindow` reader; hours are read on the Mac's local
clock, whatever zone it is in now. With no configured quiet-hours window, or
an unavailable preference read, it supplies no clock and no diurnal contribution.
The default 4 AM trough is removed; a clock requires two valid, distinct hours.

`OrganismChemistry` supplies projected curiosity/arousal offsets and nightliness.
The felt-signal builder applies a negative arousal offset directly but allows
a positive offset only on an already-moving axis. The clock alone cannot make
a neutral state start declaring a feeling.

## The horizon family — `toward`

Canonical field and prediction labels retain Unicode letters and decimal digits
within the existing 48-character bound; other runs normalize to separators.

`NativeCognitionRuntime+Expectations.swift` composes dated expectations from
Desk deferrals, staged approvals, unanswered completions and peer jobs.
Scheduled-job horizons and their availability-only drain are removed. Source invalidations and meaningful boundaries
refresh through one retained, coalesced task, without a minimum interval.

`OrganismPrediction+Semantic.swift` owns conversational metadata, scope, minting and IDs.
One reaction admission serves expiry protection and settlement. Shared settlement
and retention stay in `OrganismPrediction.swift`.
Conversational belief evidence comes from the existing turn interpretation's
optional `affect.beliefReaction`, independently of affect valence. It must judge
an actual disagreement/correction (`pushback`) or explicit confirmation
(`confirmed`) of the supplied prior completion, with exact supporting spans
from that completion and the incoming words. Journal folds, including replay,
read the full incoming words from the moment's recorded `turn.asked`, not the
500-character event summary; missing recorded words give no reaction verdict.
The substrate checks those spans,
the recorded completion/session scope and the ten-minute reaction window on
both admission and journal folding. Missing, malformed, unrelated or ungrounded
readings do not settle a prediction; neither mood sign nor moving on confirms
or contradicts a belief. Unknown labels (including the retired `neutral` label)
do not settle. An unanswered conversational expectation expires after its
24-hour horizon without a confidence penalty or violation effect. This removes
the former valence-sign verdict, neutral-as-satisfaction and silence-as-miss.
`OrganismPrediction+Horizon.swift` owns horizon vocabulary, reads and transitions.
A missing source proves no terminal outcome, even after a complete inventory
read. Empty, unreadable and truncated source sets do not award success, confidence
or relief. A source store never written (a Desk with neither op-log nor compaction
base) is complete and empty; only a written store that cannot be read is
incomplete, so a fresh install with nothing on its horizon reads `nothing`, not
`unavailable`. Held rows reach their actual due instants and expire as waiting,
without a confidence penalty or violation effect; capacity eviction likewise
awards no outcome. Source completeness remains visible in `mind.horizon` replies,
but its old somatic settlement key and absence-to-success path are removed.
The horizon shares the existing prediction ledger.
Stated plans have the identity their source gives them: Desk titles supply
bounded canonical labels and name identity; memory atoms have no name and carry
empty labels, keyed by their due instants at whole-second resolution (the legacy
encoder's nearest-second rounding). Desk plans deduplicate by name and atoms by
instant. Named plans display their labels; only unnamed atoms derive time words
against every display read's clock, including toward and resolution between
source scans. Stored `due_label` never supplies current atom words.
On load, pending time-word-named rows become unnamed atoms; other names remain
Desk plans. Due-keyed rows recover a non-time name retained in `sourceOrgan`.
Rekeying preserves held state without settlement or minting; duplicate
identities keep the latest held row and terminal IDs remain stable. The former
rule that keyed every plan by due instant and replaced Desk names with time
words is removed. Other source kinds retain label identity.
See [plan dates](MEMORY_SYSTEM_MAP.md#plan-dates).

`OrganismProspectiveAffect` derives anticipation from that ledger into
**projected** chemistry, with a shared maximum delta of 0.15 per dimension.
It does not mutate stored chemistry. The frozen body value carries `toward`
from its copied ledger at the same instant; the standalone read uses this path.

## Limiters & safeguards

### Enablement

`OrganismConfiguration` defaults to disabled.
`NativeCognitionRuntime.organismConfigurationForLaunch` respects public
pre-onboarding neutralization and the explicit organism setting. It no longer inherits or writes the retired subconscious-master choice during launch. After onboarding and a configured Chat provider, the runtime initializes
missing inner-life preferences to enabled. An explicit stored choice is
preserved.

The body restores once, at the cognition opening, whether or not its effects
are enabled. A disabled body is dormant: it takes no signals or doses, its
state is kept and saved (`OrganismKernel.exportContinuity`), and enabling it,
switching the subconscious back on or finishing onboarding never reloads the
file over a live body.

### Signal and projection bounds

`OrganismMetadataBounds` limits signal metadata to 12 keys, 240 characters per
string, eight array items and depth three. Somatic input is bounded before
kernel updates. Posture strings and directives have separate
bounds in `OrganismBehaviorPosture.swift`.

Before kernel ingestion, metadata passes through `JSONValueBounding` with
secret redaction enabled; recognized sensitive keys and token-like values
become `[redacted]`.

The adapter refuses `organismResolutionFelt` as somatic input.
`NativeCognitionRuntime+Organism.swift` drains those resolutions directly into
the substrate, so a body consequence cannot feed back into itself.

The [wiring map](COGNITION_WIRING.md#shared-work-slot-admission) owns reflection's
two-hour background slot, unused-claim release and spent-window retention.

### Persistence + decay

`NativeCognitionRuntime+BodyContinuity.swift` owns
`<dataRoot>/cognition/organism_state.json`; `OrganismPersistence.swift` defines
the stored state and restoration/decay behavior. Its sole writer compares the
decoded stored value with the value at persisted date precision before writing;
JSON key or set order causes no write. Unreadable stored continuity remains a
failure and is preserved. `savedAt` remains the chemistry's settlement anchor,
so genuine elapsed decay is saved with the values it anchors.
Only its current schema is accepted: encounter, epoch, lived watermark, field
identities, outcome weights and current body fields are checked, with no rekeying
or invented old defaults. The persisted body bits remain the continuity
representation and transient typed readings rebuild from their sensors. Capability outcome weights
spend the full elapsed interval on their seven-day half-life, independently of
the 72-hour tissue-decay cap. Dream completion evidence reads only the checked
`ConversationHistory.dreamConsolidationMark` owner (`lastDreamedAt`);
diary modification times and parent writability cannot establish completion or
store health. Missing marks contribute no completion evidence; damaged marks
make the reading unavailable. The completion effect follows the
[dream settlement law](COGNITION_WIRING.md#the-subconscious-loops--schedule-artifacts-re-entry): its original section
UUID, time and felt summary are saved before publication. Attention receives
that completion before optional body effects. The feeling frame reads the
recorded night admission and the diary journal's retained published completion,
including after relaunch, for a neutral dream or disabled body. Missing evidence
stays unknown. A matching readable completion answers despite damaged sibling
journals; with no match, journal failures name their paths and causes. An enabled kernel stores
that UUID with dream repair and wakefulness reset; retry saves that owner state
without reapplying the signal. A disabled body records an explicit journal skip.
Stop or a recovered diary publication cannot discard this step.
Every actual provider call, including diagnostic
and bridge calls, contributes vitals evidence; no debug-session exclusion exists.
`NativeCognitionRuntime+BodyEvidence.swift`
rebuilds typed domain evidence rather than restoring it as fresh health. The
provider and body evidence identities share `BodyEvidenceReference.digest`;
construction hashes supplied identifiers, while decoding requires canonical
64-character lowercase SHA-256 digests and rejects raw IDs. Current dream repair
reads only `feltDaySummary`; pressure signal metadata uses only `resourcePressure`
with the enum's current raw values. Cognitive session metadata uses only `sessionId`.
The sampler derives compatibility values from those readings; configuration availability
remains exact and separate. APNs receipts with no HTTP answer remain unknown;
only an actual HTTP rejection supplies provider-failure evidence. A missing
fan-out receipt or diagnostic error alone never establishes a rejected write.
Signed-phone, notification-target, APNs and ability/trace read failures carry `sourceUnavailable` and an owner repair obligation; failed inventory is never off/unconfigured, damaged newest outcomes never select older rows, and missing metadata never becomes now. Signed-phone writes first read the existing record under the same lock and refuse to overwrite unreadable evidence. Damaged
remains exact and separate. Signed-phone, notification-target and ability/trace read failures carry `sourceUnavailable` and an owner repair obligation; failed inventory is never off/unconfigured, damaged newest outcomes never select older rows, and missing metadata never becomes now. Notification delivery reads the live kernel's current keyless publication-failure/signed-phone-receipt prediction, never optional APNS outcomes. Missing, pending and expired predictions supply no terminal evidence; the optional `notificationPathHealthy` projection becomes unknown without a supported delivery verdict, including when unconfigured. Its neutral value is unknown; a delivery start clears it, a signed receipt supports true and publication failure supports false. Reachable/stale peer signals change reachability alone. Current notification readings replace persisted compatibility values rather than preserving unsupported health. Neither publication nor process receipt proves display or user attention. Signed-phone writes first read the existing record under the same lock and refuse to overwrite unreadable evidence. Damaged
saved continuity remains unavailable and is not overwritten by a freshly initialized snapshot. Nothing
writes the file before its restore has finished: the caring sink, the
after-turn reaction, settle and reset join the cognition opening first (see
SUBCONSCIOUS.md, Opening).

Reflexes were retired in Phase 5 F (frozen since 08-16, never active in a
prompt). Current continuity writes omit the retired `reflexState` field;
restoration ignores it in older files.

Repair receipts retain current operations and evidence, ignoring retired proposal keys.
The unproduced `proposeStandingView` operation and its decode support are removed;
mobile proposal fields stay nil.

## Turning it on / observing it

Read the Settings page through `app {"page":"settings"}`; the organism row is
`settings.organism_kernel`, under Preferences ▸ Inner life. Its value is handled
by the shared settings action. For a bounded inner-state read:

```text
app {"action":"mind.inner_state","args":{"detail":"compact"}}
```

`NativeCognitionRuntime.observatoryDetail` samples body and canonical affect at one
timestamp; one frozen value supplies snapshot, projection and horizon. Inspection
preserves cadence and mirrors last delivery; TrustCenter and domain owners govern actions.
