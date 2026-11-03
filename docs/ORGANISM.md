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
  `NativeCognitionRuntime.organismBodySample` caches its base body read for
  two seconds; provider health is derived only from checked lifecycle evidence. Unreadable trace history owes repair and never selects a cumulative capability belief as a substitute. Status-less outcomes remain unknown; summaries cannot attest success. The unproduced Workshop cognitive event/node and memory-hygiene signal vocabularies are removed.
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
previews and failed turns do not consume cadence. Candidates that are not shown
remain owed rather than counting as presented.

**Felt state.** `CognitiveSubstrate+CapsuleFeltSignals.swift` maps projected
chemistry into the felt fingerprint. `OrganismChemistry.bodyLine` can supply a
bounded `- Body:` candidate. Ordinary turns select one non-rut felt cue or none,
with an optional separate Sound rut line; private reflection is cadence-exempt.
Unchanged body lines are suppressed between presentation windows. Losing the
cue slot or fitting budget does not count a body line as presented.

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

### 2. Homeostatic settle, budgeted per wall-hour

Per-signal settling has an elapsed-time ceiling
(`maximumSettlePerHour = 0.20`). The kernel uses local ingestion time to
measure the gap, so a delayed source timestamp cannot buy extra settling.
Elapsed-time continuity decay also runs during restore.
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

Its interpersonal effect is confined to softening the correction-related
vigilance increase. It does not relax tool, provider, permission or verification
policy. Dream completion does not dose tenderness.

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
or relief. Held rows reach their actual due instants and expire as waiting,
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
shared two-hour Workshop slot, unused-claim release and spent-window retention.

### Persistence + decay

`NativeCognitionRuntime+BodyContinuity.swift` owns
`<dataRoot>/cognition/organism_state.json`; `OrganismPersistence.swift` defines
the stored state and restoration/decay behavior. Only its current schema is accepted: encounter, epoch, lived watermark, field identities, outcome weights and current body fields are checked, with no rekeying or invented old defaults. The persisted body bits remain the continuity representation and transient typed readings rebuild from their sensors. Capability outcome weights
spend the full elapsed interval on their seven-day half-life, independently of
the 72-hour tissue-decay cap. Dream completion evidence reads only the checked
`ChatSessionRecollections.dreamConsolidationMark` owner (`lastDreamedAt`);
diary modification times and parent writability cannot establish completion or
store health. Missing marks contribute no completion evidence; damaged marks
make the reading unavailable. The completion effect follows the
[dream settlement law](COGNITION_WIRING.md#the-subconscious-loops--schedule-artifacts-re-entry): its original section
UUID, time and felt summary are saved before publication. An enabled kernel stores
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
`settings.organism_kernel`. Its value is handled by the shared settings action.
For a bounded inner-state read:

```text
app {"action":"mind.inner_state","args":{"detail":"compact"}}
```

`NativeCognitionRuntime.observatoryDetail` samples body and canonical affect at one
timestamp; one frozen value supplies snapshot, projection and horizon. Inspection
preserves cadence and mirrors last delivery; TrustCenter and domain owners govern actions.
