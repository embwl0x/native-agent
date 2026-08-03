# The Organism Kernel (as-built)

*Last verified against source: 2026-07-13. This documents what actually runs,
traced from the code — not the aspirational design. For the design intent and
history see [`organism-kernel-blueprint.md`](build_plans/organism-kernel-blueprint.md),
[`organism-kernel-roadmap.md`](build_plans/organism-kernel-roadmap.md), and
[`organism-crosswalk.md`](build_plans/organism-crosswalk.md).*

---

## What it is

The **Organism Kernel** gives the agent a lightweight, bounded *body state* — a
somatic/affective layer that sits alongside (not inside) the existing cognitive
substrate. It turns real events and live system health into a felt "how I am
right now," and that felt state does exactly two things to the agent's behavior:

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
| `ChemicalState` | 10 affect dimensions, each clamped to `[0,1]`: warmth, vigilance, curiosity, fatigue, coherence, agency, tenderness, confidence, novelty, urgency. **`warmth` and `urgency` derive from the substrate's canonical `socialWarmth`/`taskPressure`** (affect convergence — see [COGNITION_WIRING.md](COGNITION_WIRING.md)) | clamp `[0,1]` per dim |
| `BodySchema` | compatibility health projections + a 4-tier `resourcePressure` (nominal/elevated/high/critical) + transient typed provider, peer-presence, notification-delivery, memory-integrity, dream-integrity, tool-capability, approval-path, and resource-pressure readings with evidence, freshness, and uncertainty | fixed shape; typed reads bounded and omitted from persistence |
| `OrganismField` | Plastic associative graph learned from activity (nodes + weighted edges) | **96 nodes / 192 edges** |
| `OrganismPredictionLedger` | Short-lived expectations ("a tool call should succeed") + surprise | **96 predictions** |
| `OrganismDreamRepairState` | Bounded repair operations over the field | **16 ops / 1,200 chars** |
| `OrganismReflexState` | Candidate reflexes (repeated successful traces), **review-gated** — reviews now carry audit receipts (`reviewedBy`/`source`/receipt id, surfaced in the snapshot) and support `hold` and permanent `reject` (`isPermanentlyDeliberate`) alongside approval | **64 candidates** (evidence rule below) |

Pure reads over that state also expose capability calibration and procedure
shadow candidates. Capability uses a bounded Beta prior over exact prediction
outcomes, while expiry raises uncertainty rather than manufacturing failure.
Procedure candidates are review hypotheses over reflex evidence: they emit no
Swift, own no executor, and always report `controlAuthority=false`. Neither read
enters the prompt or changes action selection.

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
   fatigued body reads `worn`, high coherence reads `clear-headed`). Same
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
| Mac thermal `fair` | elevated | **conserve** | defers expensive loops (reflection/replay/cue) |
| Mac thermal `serious` | high | **conserve** | same |
| Mac thermal `critical` | critical | **sleep** | pauses **all** background cognition |
| Low Power Mode on | ≥ elevated | ≥ **conserve** | — |
| `fatigue ≥ 0.35` (chemistry) | — | **conserve** | organic path, independent of hardware |

`resourcePressure` comes from macOS `ProcessInfo.thermalState` (a coarse
OS-computed pressure tier, *not* a raw temperature) plus `isLowPowerModeEnabled`
(`NativeCognitionRuntime.currentResourcePressure`). **Scope: background cognition
only.** Chat responsiveness is never affected.

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
- **Reflexes are candidate-first and approval-gated.** A candidate never acts on
  its own; auto-activation only unlocks *after* a human approves a low-risk reflex
  (`OrganismReflex.swift:243`).
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
(`b791f8bb`). If you change the organism, update this file — it is meant to stay
true to the code.
