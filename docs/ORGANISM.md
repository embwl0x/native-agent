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
- `OrganismChemistry.applying` owns signal-driven body compatibility updates
  and typed-reading invalidation; predictive application returns only its ledger
  and chemistry. `OrganismBodySchemaSampler` owns sampled readings.
- The runtime samples body evidence and canonical affect before projection.
  `NativeCognitionRuntime.organismBodySample` caches its base body read for
  two seconds; provider health is derived from lifecycle evidence.
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
  `OrganismDreamRepair` defines the charge/noise predicates used by selection, mutation and generation acknowledgement.
  Live and frozen snapshots share one renderer: live reads settle the owner,
  while frozen reads decay a copy at their supplied clock.

Disabled kernel ingestion returns without recording the signal.

Lifetime signal, prediction, outcome, repair-receipt and co-activation tallies saturate at
`Int.max`; elapsed-time decay and live outcomes still run at that limit.
Capability display counts saturate too, while beliefs continue to use their
fractional evidence weights. A restored large tally cannot abort a fold.
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
clock, whatever zone it is in now. With no quiet-hours window it uses the
default trough. A kernel with no clock
has no diurnal contribution.

`OrganismChemistry` supplies projected curiosity/arousal offsets and nightliness.
The felt-signal builder applies a negative arousal offset directly but allows
a positive offset only on an already-moving axis. The clock alone cannot make
a neutral state start declaring a feeling.

## The horizon family — `toward`

Canonical field and prediction labels retain Unicode letters and decimal digits
within the existing 48-character bound; other runs normalize to separators.

`NativeCognitionRuntime+Expectations.swift` composes dated expectations from
Desk deferrals, staged approvals, unanswered completions and peer jobs.
Scheduled-job availability only settles legacy horizons. Source invalidations and meaningful boundaries
refresh through one retained, coalesced task, without a minimum interval.

`OrganismPrediction+Semantic.swift` owns conversational metadata, scope, minting and IDs.
One reaction admission serves expiry protection and settlement. Shared settlement
and retention stay in `OrganismPrediction.swift`.
`OrganismPrediction+Horizon.swift` owns horizon vocabulary, reads and transitions;
it only treats a missing source as settled
when that source kind was read completely. Expiry means waiting, not a failed
tool prediction. The horizon shares the existing prediction ledger.
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
pre-onboarding neutralization, explicit organism settings and the subconscious
master. After onboarding and a configured Chat provider, the runtime initializes
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
the stored state and restoration/decay behavior. Capability outcome weights
spend the full elapsed interval on their seven-day half-life, independently of
the 72-hour tissue-decay cap. `NativeCognitionRuntime+BodyEvidence.swift`
rebuilds typed domain evidence rather than restoring it as fresh health. The
provider and body evidence identities share `BodyEvidenceReference.digest`;
construction hashes supplied identifiers, while decoding preserves canonical digests.
The sampler derives compatibility values from those readings; configuration availability
remains exact and separate. Damaged
saved continuity remains unavailable and is not overwritten by a freshly initialized snapshot. Nothing
writes the file before its restore has finished: the caring sink, the
after-turn reaction, settle and reset join the cognition opening first (see
SUBCONSCIOUS.md, Opening).

Reflexes were retired in Phase 5 F (frozen since 08-16, never active in a
prompt). The stored file keeps an empty `reflexState` so an older build can
still restore it.

Repair receipts retain operations and evidence, ignoring retired proposal keys.
Historical `proposeStandingView` operations still decode; mobile proposal fields stay nil.

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
