# The Organism Kernel (as-built)

The organism turns admitted events and current system evidence into bounded
body state. Its implementation is in
`Modules/NativeAgentCore/Sources/CognitiveSubstrate/Organism/`; integration
lives in the core `Cognition/NativeCognitionRuntime` files.

See [COGNITION_WIRING.md](COGNITION_WIRING.md) for the connections to memory,
turns and background work.

## What it is

`OrganismKernel` owns chemistry, body beliefs, an associative field,
predictions and repair state. Its projections can
color a cognitive capsule, guide attention and throttle background cognition.
It owns no tool executor, canonical memory store or persona writer.

`CognitiveSubstrate` remains the owner of conversational appraisal and
attentional continuity. Its `ContinuityField` and the organism's
`OrganismField` have separate roles and exchange typed signals and projections.

## The loop (input → state → output)

### Input — what feeds it

- `NativeCognitionRuntime.observe` admits a cognitive event to the substrate
  and offers it to `SomaticSignalBus`. `CognitiveSomaticSignalAdapter` maps
  accepted event kinds to bounded somatic signals. Debug and verification
  events do not become somatic input.
- The adapter carries event identity, topology, intensity and typed outcomes.
  It does not re-appraise conversational text. Provider lifecycle ownership is
  marked so the same provider failure does not produce a second body signal.
- The runtime samples body evidence and canonical affect before projection.
  `NativeCognitionRuntime.organismBodySample` caches its base body read for
  two seconds; provider health is derived from lifecycle evidence.
- The shared after-turn interpretation supplies caring judgments.
  `CognitiveSubstrate.finishAfterTurn` applies affect and validates caring
  admission; its sink calls `admitCaringEventIntoBody` directly.
- `OrganismKernel.settleElapsedTime` applies elapsed-time decay on live
  touches. Residual repair uses a derived quiet deadline in
  `NativeCognitionRuntime+Deadlines.swift`, with bounded exact repair targets.

Disabled kernel ingestion returns without recording the signal.

### State — what it holds

These are the default bounds, defined by the corresponding configuration types.

| Component | State and bound | Owner |
| --- | --- | --- |
| `ChemicalState` | Ten dimensions clamped to 0…1: warmth, vigilance, curiosity, fatigue, coherence, agency, tenderness, confidence, novelty, urgency. | `OrganismModels.swift`, `OrganismChemistry.swift` |
| `BodySchema` | Fixed domain readings with evidence, freshness and uncertainty; typed readings are transient and rebuilt after restart. | `OrganismModels.swift`, `OrganismTypedBodyBeliefs.swift` |
| `OrganismField` | At most 96 nodes and 192 edges. | `OrganismField.swift` |
| `OrganismPredictionLedger` | At most 96 predictions; at most eight open horizon rows, looking no more than seven days ahead. | `OrganismPrediction.swift`, `OrganismPredictionModels.swift` |
| `OrganismDreamRepairState` | At most 16 operations and a 1,200-character felt summary. | `OrganismDreamRepair.swift` |

Canonical domain owners still decide provider, device, notification, memory,
tool and approval reality. A body belief is evidence about those domains, not
permission to mutate them. Unknown or stale evidence must remain uncertain.

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
selection hint, not another tool list or a grant of access.

**Background budget.** `OrganismBehaviorPosture.loopBudget` contributes
`normal`, `conserve` or `sleep` to
`NativeCognitionRuntime.backgroundCognitionGate`. This gate regulates
background cognition, not chat admission.

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
relaxes on its own six-hour half-life; a completed dream can reduce it.
Wakefulness contributes a separately capped share while the process is running.
Restart does not claim unobserved downtime as either sleep or wakefulness.

Owners: `OrganismChemistry.swift`, `OrganismKernel.swift`.

### 4. Tenderness — event-driven: caring moments dose it, days fade it

A caring judgment arrives through the shared interpretation in
`ChatTurnRuntime/MindMemoryManager.swift`. `CognitiveSubstrate+CaringEvent.swift`
checks the originating turn and relay/encounter evidence before admitting it.
Failed or unavailable interpretation supplies no caring verdict.

`OrganismCaringEvent` defines a 0.10 saturating dose and a rolling encounter
window: repeated turns from one encounter do not each earn a dose. The
encounter stamp persists; the bounded seen-turn ring is process-local.
Tenderness fades on a three-day half-life. Sustained canonical warmth can
contribute a smaller bounded undertone.

Its interpersonal effect is confined to softening the correction-related
vigilance increase. It does not relax tool, provider, permission or verification
policy. Dream completion does not dose tenderness.

## The diurnal clock

`NativeCognitionRuntime+Organism.swift` builds `OrganismDiurnalClock` from
the current time zone and the existing `TurnQuietHoursWindow` reader. With no
quiet-hours window it uses the zone and default trough. A kernel with no clock
has no diurnal contribution.

`OrganismChemistry` supplies projected curiosity/arousal offsets and nightliness.
The felt-signal builder applies a negative arousal offset directly but allows
a positive offset only on an already-moving axis. The clock alone cannot make
a neutral state start declaring a feeling.

## The horizon family — `toward`

`NativeCognitionRuntime+Expectations.swift` composes dated expectations from
Desk deferrals, scheduled jobs, staged approvals, unanswered completions and
peer jobs. It refreshes through the existing deadline path with a 15-minute
minimum interval.

`OrganismPrediction+Horizon.swift` only treats a missing source as settled
when that source kind was read completely. Expiry means waiting, not a failed
tool prediction. The horizon shares the existing prediction ledger.

`OrganismProspectiveAffect` derives anticipation from that ledger into
**projected** chemistry, with a shared maximum delta of 0.15 per dimension.
It does not mutate stored chemistry. The separate `toward` read reaches the
capsule request, where a bounded label can name what the feeling concerns.

## Limiters & safeguards

### Enablement

`OrganismConfiguration` defaults to disabled.
`NativeCognitionRuntime.organismConfigurationForLaunch` respects public
pre-onboarding neutralization, explicit organism settings and the subconscious
master. After onboarding and a configured Chat provider, the runtime initializes
missing inner-life preferences to enabled. An explicit stored choice is
preserved.

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

### Background resource gate

`backgroundCognitionGate` checks Low Power Mode and serious/critical thermal
pressure before organism budgeting. `sleep` skips work. `conserve` throttles
reflection, replay and cue lanes separately, permitting a lane again after its
45-minute starvation floor. A thermal refusal does not spend that allowance.

### Persistence + decay

`NativeCognitionRuntime+Organism.swift` owns
`<dataRoot>/cognition/organism_state.json`; `OrganismPersistence.swift` defines
the stored state and restoration/decay behavior. Typed domain evidence is
rebuilt rather than restored as fresh health. Damaged saved continuity remains
unavailable and is not overwritten by a freshly initialized snapshot.

Reflexes were retired in Phase 5 F (frozen since 08-16, never active in a
prompt). The stored file keeps an empty `reflexState` so an older build can
still restore it.

## Turning it on / observing it

Read the Settings page through `app {"page":"settings"}`; the organism row is
`settings.organism_kernel`. Its value is handled by the shared settings action.
For a bounded inner-state read:

```text
app {"action":"mind.inner_state","args":{"detail":"compact"}}
```

Diagnostics and `NativeCognitionRuntime.observatoryDetailRead` expose the
underlying state. Observation, a projected feeling and an authorized action
are distinct: TrustCenter and each action's domain owner decide execution.
