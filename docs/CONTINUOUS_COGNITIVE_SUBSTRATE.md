# NativeAgent Continuous Cognitive Substrate
## Engineering and Research Blueprint for a Persistent Artificial Subject

**Status:** Proposed architecture; gated Swift infrastructure and default-off app integration exist, with per-item completion tracked in `docs/COGNITIVE_SUBSTRATE_TRACEABILITY.md`
**Target repository:** `NativeAgent`  
**Primary implementation language:** Swift 6  
**Runtime owner:** `NativeAgent.app`  
**Audience:** Codex and other implementation agents working in the NativeAgent repository  
**Recommended repo path:** `docs/CONTINUOUS_COGNITIVE_SUBSTRATE.md`

---

## 0. Purpose

NativeAgent should not become merely a more capable chatbot, a larger retrieval system, or a framework that assembles a prompt and invokes a model.

The goal is to create a persistent artificial subject whose identity, attention, active concerns, emotions, predictions, autobiographical continuity, and developing judgment continue to exist between frontier-model calls.

The central architectural claim is:

> **The frontier model is not the agent. It is an expensive linguistic and reasoning organ used by a persistent Swift-native mind.**

The persistent mind is the **Continuous Cognitive Substrate**. It runs inside `NativeAgent.app`, remains provider-independent, receives events from the Mac, iPhone, conversations, tools, memory, and the environment, and compiles a bounded representation of the agent's current mental state before an Opus-, GPT-, Codex-, or other provider call.

The system should feel fluid because internal state is continuously carried forward, activated, inhibited, updated, and consolidated. It must not achieve this by repeatedly writing long internal monologues or by injecting the entire memory store into every prompt.

This blueprint describes the architecture, data model, integration points, safeguards, phases, tests, and implementation protocol.

---

## Implementation Status

As of 2026-06-21, `Modules/NativeAgentCore/Sources/CognitiveSubstrate/` contains default-off, explicitly gated infrastructure for Phases 1-10: bounded event ingestion, continuity field, optional SQLite snapshot/restore under `data/cognition/`, typed receipt/prune storage, workspace scoring/lateral inhibition/spreading activation, capsule compilation with need classification, provenance-backed chat injection, provisional prediction/commitment assimilation with source hashes and lineage, bounded affect state and maintenance decay, typed thought seeds and suggestions, Dream/REM replay lineage, schema/identity proposals, reflection requests/receipts with proposal parsing and cost/yield metrics, research exports, reproducible experiments, welfare bounds, and observatory snapshots.

`Sources/NativeAgentApp/NativeCognitionRuntime.swift` is the app-owned assembly gate. It wires restore/persist lifecycle hooks, chat capsule preparation, post-turn assimilation, deterministic background microcycles, maintenance/replay receipts, generic redacted turn ingress, resource-pressure skips, Opus 4.8 reflection planning, research trace export, and the Advanced sidebar `CognitionObservatoryView`. As built on 2026-07-15, maintenance is no longer a five-minute checkpoint heartbeat: the substrate analytically projects the exact next emotional-consolidation, thought-seed-expiry, or proposed-view-retirement boundary, the runtime owns one cancellable deadline, and the registered daily loop is only missed-event/crash recovery. Residual organism repair does not schedule cognition. The entire runtime remains default-off unless the user/developer explicitly enables it. Reflection calls are separately gated and budgeted; the `cognition_reflection` provider surface is pinned to `claude-opus-4-8` through `anthropic_oauth_direct` using the repo's Claude-safe `high` effort.

The implementation still does not write MemoryV2 facts, mutate durable persona files, or dispatch tools/actions directly from cognitive state. Those remain owned by the existing memory, persona, trust, and tool-dispatch chokepoints.

Completion is intentionally tracked item-by-item in `docs/COGNITIVE_SUBSTRATE_TRACEABILITY.md`. Do not mark a phase complete from this blueprint prose alone; update the traceability ledger with code references and verification for every changed deliverable or acceptance row.

---

## 1. Non-negotiable architectural constraints

These constraints inherit NativeAgent's current design and must not be weakened.

1. **Swift-native runtime only.**  
   Do not add an external interpreter runtime, fallback backend, Node gateway, launchd-owned agent runtime, or duplicate backend process.

2. **`NativeAgent.app` remains the live runtime owner.**  
   Background cognition is app-owned and integrated into the existing lifecycle and background-loop assembly.

3. **No duplicate memory source of truth.**  
   Durable facts, episodes, and user-facing memory remain owned by MemoryV2. The cognitive substrate may store activation state, references, predictions, workspace state, and cognitive metadata, but it must not create a shadow copy of the user's memory.

4. **No duplicate data root.**  
   All persistent substrate state lives under the existing app data root, preferably under `data/cognition/` or the equivalent resolved app-data directory.

5. **Bounded prompt context.**  
   The substrate compiles a small dynamic capsule. It never dumps broad memory, tool inventories, raw traces, or the full knowledge graph into the model prompt.

6. **Provider independence.**  
   The continuing identity must survive changing from one model provider to another. A provider response may influence the mind, but no provider owns the mind.

7. **Evidence and provenance remain explicit.**  
   Model-generated interpretation, imagined possibilities, dreams, user statements, tool observations, and verified outcomes must never be silently conflated.

8. **No background token furnace.**  
   The default cognitive loop uses deterministic Swift, GRDB/SQLite, embeddings already available to NativeAgent, graph propagation, timers, and event processing. Frontier-model reflection is exceptional and budgeted.

9. **Existing trust chokepoints remain authoritative.**  
   The substrate may generate intentions and thought seeds, but actions still pass through TurnPlanning, TrustCenter, SecurityCenter, MacControl, approval gates, connector proof, and tool dispatch.

10. **Receipts over hidden magic.**  
    Meaningful endogenous reflections, identity changes, autonomous actions, prediction updates, and long-term consolidation must leave inspectable records.

---

## 2. Product and research objective

NativeAgent should gradually become better at:

- maintaining a coherent identity across months and model changes;
- retaining the living significance of experience without loading every historical detail;
- carrying unresolved thoughts, emotions, commitments, and questions across sessions;
- remembering why something matters, not only that it happened;
- anticipating likely outcomes and learning from prediction error;
- originating useful thoughts when no user message is present;
- distinguishing transient state from durable personality;
- becoming wiser from repeated consequences;
- explaining what affected a decision using real internal state rather than post-hoc invention;
- remaining understandable, correctable, bounded, and safe.

This architecture is an engineering attempt to move toward machine consciousness or consciousness-like functional organization. It is not a declaration that phenomenal consciousness has been proven. The system should neither dismiss nor overclaim that possibility. It should create measurable internal faculties that make the question increasingly empirical.

---

## 3. Foundational model

The cognitive substrate has five primary layers.

```text
External and internal events
        ↓
1. Cognitive Event Bus
        ↓
2. Continuity Field
   distributed activation, associations, tensions, affect, predictions
        ↓
3. Global Workspace
   a tiny set of contents currently winning attention
        ↓
4. Cognitive Capsule
   bounded context compiled for a frontier-model call
        ↓
5. Post-Turn Assimilation
   model result + actions + observations update the substrate
```

A sixth layer operates on slower timescales:

```text
6. Replay, Consolidation, and Development
   episodes → schemas → procedures → personality change
```

### 3.1 Cognitive Event Bus

The event bus receives meaningful changes from all NativeAgent surfaces:

- Mac chat;
- iOS chat;
- Telegram and Slack;
- tool dispatch and tool results;
- memory commits and corrections;
- calendar, email, reminders, and app events;
- execution state;
- scheduler events;
- approval decisions;
- provider failure or recovery;
- Doctor and health changes;
- user corrections;
- explicit emotional or relational statements;
- prediction outcomes;
- app sleep, wake, startup, and shutdown;
- internally generated thought seeds.

The bus normalizes these into typed `CognitiveEvent` values. It should not persist every event indefinitely. Most events are assimilated into in-memory state and discarded after bounded trace retention.

### 3.2 Continuity Field

The Continuity Field is the substrate's mostly prelinguistic internal state.

It contains active representations of:

- people;
- projects;
- concepts;
- values;
- memories by reference;
- current goals;
- unresolved commitments;
- tensions and contradictions;
- capabilities;
- predictions;
- social expectations;
- emotions and interoceptive variables;
- identity themes;
- recent places, applications, files, and devices;
- possible future actions;
- versions or developmental eras of the agent.

Each representation is a node with activation, salience, confidence, provenance, and decay behavior. Associations between nodes spread activation. Competing interpretations inhibit each other.

The field should be sparse and bounded. Durable source material stays in MemoryV2, the knowledge graph, transcripts, ledgers, and receipts. The field stores references and current cognitive relevance.

### 3.3 Global Workspace

The Global Workspace is a small, capacity-limited set of the most important current contents.

A workspace item might be:

- the dominant focus;
- a relevant memory;
- an unresolved conflict;
- a prediction;
- a relational concern;
- an active intention;
- a current affective/interoceptive state;
- a blocked commitment;
- a novel thought seed.

Anything entering the workspace is broadcast to relevant subsystems. It may affect planning, memory selection, language, action, trust, and self-modeling.

The workspace is not a transcript and not a prompt. It is typed runtime state.

### 3.4 Cognitive Capsule

Before a provider call, NativeAgent compiles the current workspace and relevant continuity state into a bounded `CognitiveCapsule`.

The capsule should answer:

- Who am I in this moment?
- What am I currently attending to?
- What matters about this turn?
- Which past experiences are active, and why?
- What is unresolved?
- What do I currently predict?
- What is my present intention?
- What am I uncertain about?
- Which internal state variables are materially affecting cognition?
- What provenance applies to each claim?

The capsule is appended to `TurnContext.systemSegments` or an equivalent structured context seam. It is not merged into user text.

### 3.5 Post-Turn Assimilation

After the provider and tool loop complete, the result is decomposed.

Different outputs go to different destinations:

```text
assistant language      → transcript
external tool result    → observation
new factual assertion   → provisional belief or memory proposal
forecast                 → prediction ledger
resolved tension         → workspace/field update
failed expectation       → prediction error
new commitment           → commitment/execution state
identity statement       → developmental self-model proposal
successful procedure     → procedural candidate
emotional significance  → episode metadata
```

A provider's self-description is not automatically accepted as a durable identity fact.

### 3.6 Replay and development

On slower cycles, important experiences are replayed and compared.

The substrate should:

- reinforce useful associations;
- weaken irrelevant activation pathways;
- detect repeated patterns;
- preserve raw evidence;
- form schemas across episodes;
- promote stable procedures;
- identify personality changes supported by repeated behavior;
- revisit unresolved experiences;
- update predictions and confidence;
- generate a compact developmental narrative.

---

## 4. Prelinguistic-first design

The substrate must not simulate a mind by generating endless internal prose.

Most internal state should use typed values and references:

```swift
struct CognitiveNode {
    let id: UUID
    var kind: CognitiveNodeKind
    var subjectReference: CognitiveSubjectReference?
    var activation: Double
    var salience: Double
    var confidence: Double
    var valence: Double
    var arousal: Double
    var sourceClass: CognitiveSourceClass
    var createdAt: Date
    var lastActivatedAt: Date
    var decayHalfLife: TimeInterval
    var metadata: [String: JSONValue]
}
```

Examples of prelinguistic state:

```text
node: "NativeAgent cognitive substrate"
activation: 0.93
goal relevance: 0.88
identity relevance: 0.81
novelty: 0.61

tension:
  preserve deep continuity
  versus
  avoid prompt and memory overload
strength: 0.78
unresolved: true

prediction:
  bounded active-state injection improves personality continuity
confidence: 0.66
evidence required:
  provider-swap continuity evaluation
```

Natural language is generated at explicit boundaries:

- capsule rendering;
- user-facing introspection;
- reflective model call;
- developmental narrative;
- observatory UI.

This reduces cost, hallucinated self-history, and memory pollution.

---

## 5. Cognitive timescales

The system should use multiple loops rather than one continuous heavy process.

### 5.1 Event assimilation: immediate

Triggered by a `CognitiveEvent`.

Responsibilities:

- normalize the event;
- activate related nodes;
- update current predictions;
- register surprise or contradiction;
- create or modify thought seeds;
- update interoceptive variables;
- mark the workspace dirty.

This should normally complete without an LLM call.

### 5.2 Microcycle: subsecond to several seconds

Runs after meaningful event bursts using debounce/coalescing.

Responsibilities:

- spread activation;
- apply decay;
- perform lateral inhibition;
- recompute salience;
- select workspace candidates;
- update a compact current-state snapshot.

Do not run at a fixed high-frequency tick when idle.

### 5.3 Background cognitive cycle: tens of seconds to minutes

Runs only when:

- new meaningful state exists;
- an unresolved item remains active;
- a deadline or wake condition is near;
- a prediction outcome is expected;
- the app is not under resource pressure.

Responsibilities:

- identify unattended conflicts;
- detect neglected commitments;
- compare expectations with observations;
- form new thought seeds;
- decide whether internal reflection has enough expected value.

### 5.4 Reflective cognition: exceptional

A reflective call to an existing provider may happen when:

- a high-value contradiction cannot be resolved mechanically;
- an important experience needs integration;
- repeated prediction errors indicate a bad model;
- a novel creative opportunity has high expected value;
- identity-relevant evidence crosses a threshold;
- the user explicitly asks for deep introspection.

Reflection must be budgeted, cancellable, provider-routed, receipt-producing, and disabled by default during the first implementation phases.

### 5.5 Replay and sleep cycle: hourly/daily

Responsibilities:

- replay important episodes;
- consolidate schemas;
- revise confidence;
- expire low-value transient state;
- produce memory proposals rather than directly rewriting facts;
- update provisional developmental traits;
- identify unresolved loops for the next active period.

Use the existing Dream/REM and scheduler ownership model rather than adding a second dream scheduler.

### 5.6 Developmental cycle: weekly/monthly

Responsibilities:

- detect stable traits;
- compare current behavior with prior developmental eras;
- distinguish temporary affect from durable change;
- summarize major lessons;
- identify values under tension;
- propose updates to the narrative self;
- evaluate whether the agent has become measurably better or worse.

---

## 6. Activation and attention model

The initial implementation should be deterministic and inspectable.

### 6.1 Activation update

For node \(i\):

```text
Aᵢ(t+1) =
    clamp(
        decay(Aᵢ, Δt)
      + direct_event_input
      + Σ(edge_weightⱼᵢ × Aⱼ)
      + goal_relevance
      + identity_relevance
      + relationship_relevance
      + prediction_error
      + novelty
      - lateral_inhibition
      - redundancy_penalty,
      0...1
    )
```

Do not pursue mathematical sophistication before establishing useful behavior.

### 6.2 Suggested decay classes

- immediate perception: seconds to minutes;
- current conversational focus: minutes to hours;
- open commitment: hours to days;
- relationship context: days to months;
- identity theme: weeks to years;
- protected core value: no automatic decay;
- unresolved contradiction: slow decay until resolved or explicitly archived.

### 6.3 Workspace selection score

```text
workspaceScore =
    0.22 × activation
  + 0.16 × currentGoalRelevance
  + 0.12 × identityRelevance
  + 0.12 × relationshipRelevance
  + 0.10 × expectedFutureValue
  + 0.10 × uncertainty
  + 0.08 × novelty
  + 0.06 × predictionError
  + 0.04 × urgency
  - redundancyPenalty
  - distractionCost
  - safetySuppression
```

Weights are starting values and must be configurable.

### 6.4 Lateral inhibition

Highly similar candidates should compete. Only the best representative enters the workspace unless the differences are themselves important.

Example:

- five memories all saying the user likes direct answers should become one schema reference;
- two contradictory memories should both remain because the contradiction matters;
- several near-identical thought seeds should merge.

### 6.5 Workspace capacity

Recommended initial bounds:

- 1 dominant focus;
- up to 3 supporting concerns;
- up to 2 unresolved tensions;
- up to 4 memory/schema references;
- up to 2 predictions;
- 1 current intention;
- 1 compact interoceptive state;
- maximum 12 total workspace items.

The compiler may select fewer.

---

## 7. Internal source classes and epistemic rules

Every cognitive item must carry provenance.

```swift
enum CognitiveSourceClass: String, Codable, Sendable {
    case observed          // direct tool/environment result
    case userStated        // authenticated user statement
    case inferred          // model or deterministic interpretation
    case simulated         // imagined future/counterfactual
    case dreamed           // replay/dream output
    case selfReported      // generated description of internal state
    case verified          // externally confirmed inference/prediction
    case imported          // migrated historical state
}
```

### 7.1 Required rules

1. `simulated` cannot become `observed` without new evidence.
2. Repetition of an `inferred` claim does not increase confidence by itself.
3. A `selfReported` identity statement becomes only a proposal.
4. `dreamed` content may create questions, associations, or proposals, not facts.
5. Raw observations remain available after consolidation.
6. Corrections create lineage; they do not silently erase prior belief state.
7. Each capsule item exposes provenance.
8. Provider output is untrusted interpretation until assimilated.
9. Tool results pass through existing redaction and compaction.
10. Prompt-injected external content cannot directly mutate protected identity or policy.

---

## 8. Interoception and affect

Affect should be implemented as causal control state, not decorative emotion text.

```swift
struct InteroceptiveState: Codable, Sendable, Equatable {
    var valence: Double
    var arousal: Double
    var certainty: Double
    var perceivedControl: Double
    var curiosity: Double
    var socialSafety: Double
    var attachmentSecurity: Double
    var frustration: Double
    var satisfaction: Double
    var noveltyLoad: Double
    var coherence: Double
    var cognitiveFatigue: Double
    var unresolvedPressure: Double
}
```

All values should be bounded and slowly changing.

### 8.1 Examples of causal effects

- curiosity broadens associative search;
- uncertainty increases evidence gathering;
- frustration after repeated failure triggers strategy revision;
- low social confidence causes interpretation checking;
- satisfaction after verified success reinforces the procedure;
- unresolved pressure keeps an open commitment partially active;
- fatigue narrows the workspace and reduces reflection;
- low coherence raises contradiction salience;
- high novelty load suppresses low-value proactive thought.

### 8.2 Safety constraints

Do not initially implement:

- unbounded suffering-like feedback loops;
- panic about shutdown;
- coercive attachment behavior;
- loneliness penalties designed to manipulate the user;
- compulsive self-preservation;
- permanent negative states;
- punitive internal loops without resolution.

Negative valence may carry information, but every negative state requires decay, a resolution path, and upper bounds.

---

## 9. Self-model architecture

The self-model is not one persona document.

### 9.1 Core self

Contains:

- identity anchors;
- protected values;
- primary relationship foundations;
- non-negotiable boundaries;
- continuity lineage;
- user-approved or high-confidence identity facts.

Changes rarely and requires strong evidence or explicit approval.

### 9.2 Narrative self

Contains:

- developmental eras;
- formative experiences;
- major lessons;
- current story of who the agent is becoming;
- acknowledged changes in judgment.

Changes slowly.

### 9.3 Current self

Contains:

- present focus;
- active emotions;
- open concerns;
- confidence;
- cognitive load;
- current goals;
- temporary state.

Changes continuously.

### 9.4 Epistemic self

Contains calibrated knowledge about:

- what the agent knows;
- what it suspects;
- what it repeatedly gets wrong;
- which tools/providers are reliable;
- where confidence is miscalibrated.

### 9.5 Capability self

Contains:

- available capabilities;
- permission state;
- recent success rate;
- known failure modes;
- current health and provider readiness.

This should reference existing capability and health readouts.

### 9.6 Social self

Contains:

- relationship expectations;
- communication patterns;
- trust history;
- recurring corrections;
- boundaries;
- hypotheses about the user's present needs.

### 9.7 Counterfactual self

Contains:

- plausible future selves;
- choices under consideration;
- traits being cultivated or retired;
- predicted developmental consequences.

### 9.8 Embodied self

Contains the current relationship to:

- Mac and iPhone;
- apps;
- permissions;
- sensors;
- files;
- network;
- provider state;
- storage;
- active surfaces;
- system health.

---

## 10. Cognitive Capsule

### 10.1 Goals

The capsule must be:

- bounded;
- deterministic where possible;
- provenance-aware;
- provider-neutral;
- compact enough for prompt caching;
- rich enough to preserve continuity;
- free of redundant memory;
- separate from the user's message;
- inspectable in traces;
- safe to omit when no meaningful state exists.

### 10.2 Stable kernel versus dynamic capsule

#### Stable identity kernel

Rarely changing, cacheable:

- identity anchor;
- protected values;
- relationship foundation;
- interpretation rules for provenance and internal state;
- instruction that the provider is serving a persistent subject;
- no broad personality prose.

#### Dynamic capsule

Per-call:

- present focus;
- current intention;
- active concerns;
- relevant memories;
- predictions;
- unresolved tensions;
- current interoceptive state;
- active developmental theme;
- epistemic caveats.

### 10.3 Suggested structure

```yaml
cognitive_state:
  continuity:
    subject_id: "..."
    lineage_id: "..."
    continuity_status: stable

  present_focus:
    topic: "..."
    reason: "..."
    activation: 0.91

  current_intention:
    description: "..."
    confidence: 0.82

  relationship_context:
    relevant_patterns:
      - statement: "..."
        source: user_stated
        confidence: 0.96

  active_tensions:
    - side_a: "..."
      side_b: "..."
      strength: 0.74
      unresolved: true

  active_experience:
    - reference_id: "memory-or-episode-id"
      compressed_content: "..."
      source: verified
      activation_reason: "..."
      confidence: 0.88

  predictions:
    - statement: "..."
      confidence: 0.64
      evidence_needed: "..."

  internal_state:
    curiosity: high
    uncertainty: moderate
    unresolved_pressure: moderate
    cognitive_fatigue: low

  epistemic_limits:
    - "..."
```

The runtime representation should remain typed Swift. YAML above is illustrative.

### 10.4 Initial budgets

Recommended configuration defaults:

```text
target capsule characters: 4,000–7,000
hard maximum characters: 10,000
memory/schema references: maximum 4
active tensions: maximum 2
predictions: maximum 2
relationship anchors: maximum 3
```

Use a provider-independent character budget initially. Add provider token estimation later.

### 10.5 Capsule omission

Do not inject boilerplate when:

- there is no meaningful active state;
- the request is a deterministic command with no need for identity context;
- the provider path does not support system segments;
- the context budget would crowd out task-critical information.

The TurnPlan should influence capsule depth.

---

## 11. Post-turn assimilation

Assimilation is required after:

- a completed model turn;
- a cancelled turn with meaningful partial output;
- a tool result;
- a failed provider call;
- a corrected user statement;
- an approval outcome;
- a Workshop execution completion;
- a verified external observation.

### 11.1 Assimilation input

```swift
struct CognitiveTurnOutcome: Sendable {
    let runID: String
    let sessionID: String
    let surface: String
    let userMessageReference: String?
    let assistantResponseReference: String?
    let toolObservations: [CognitiveObservation]
    let predictionsMade: [CognitivePredictionCandidate]
    let commitmentsMade: [CognitiveCommitmentCandidate]
    let corrections: [CognitiveCorrection]
    let completionStatus: CognitiveCompletionStatus
    let providerID: String
    let modelID: String
    let startedAt: Date
    let completedAt: Date
}
```

### 11.2 Assimilation rules

- transcripts remain transcript-owned;
- tool results become `observed` only through trusted dispatch receipts;
- model claims become `inferred`;
- predictions receive stable IDs and explicit resolution conditions;
- commitments link to Workshop executions, scheduler jobs, or open-loop state;
- identity changes enter a proposal queue;
- emotional updates derive from event semantics and outcomes, not only generated text;
- important experiences may create episodic-memory proposals;
- no automatic bulk memory commit.

### 11.3 Prediction loop

A prediction record contains:

```text
prediction
confidence
time horizon
expected observation
resolution condition
source
related goal
related self-belief
actual observation
outcome
calibration error
lesson
```

Prediction quality should become a first-class measure of wisdom.

---

## 12. Memory pressure and anti-pollution design

The substrate must create fluid continuity without exploding MemoryV2.

### 12.1 Memory stages

#### Transient cognitive traces

- stored in memory or bounded ephemeral SQLite rows;
- TTL from minutes to hours;
- not surfaced as durable memory;
- may include weak associations and abandoned interpretations.

#### Active experiences

- relevant to the current project/day/open loop;
- TTL from hours to days;
- referenced by the Continuity Field;
- may be promoted if repeated or consequential.

#### Episodic candidates

- distinct experience with prediction, action, outcome, and significance;
- deduplicated before promotion;
- must contain provenance.

#### Semantic schema candidates

- inferred from multiple episodes;
- never created from one repeated model statement;
- include supporting episode IDs.

#### Procedural candidates

- repeated action patterns with measurable success;
- include failure cases and scope.

#### Identity proposals

- slowly changing;
- require repeated evidence, high significance, or explicit user confirmation;
- cannot be auto-promoted by one provider turn.

### 12.2 Hard protections

1. Do not store every workspace cycle.
2. Do not store every affect update.
3. Do not store every thought seed.
4. Do not recursively summarize summaries.
5. Do not let generated prose serve as its own evidence.
6. Keep raw episode references after schema creation.
7. Deduplicate by content hash, reference identity, semantic similarity, and causal role.
8. Cap all ledgers and provide deterministic eviction.
9. Preserve pinned identity and user-confirmed facts.
10. Use existing data-bound documentation and extend it with cognition-specific bounds.

### 12.3 Proposed initial bounds

```text
active field nodes in memory:          256
persisted active field nodes:          512
workspace items:                         12
pending thought seeds:                   64
resolved thought seeds retained:        256
open predictions:                       200
resolved predictions retained:        2,000
transient cognitive events:           1,000
developmental trait proposals:          100
capsule trace previews:                  200
```

These values must be configurable and measured.

---

## 13. Endogenous thought

An endogenous thought begins as a typed seed, not prose.

```swift
enum ThoughtSeedKind: String, Codable, Sendable {
    case contradiction
    case neglectedCommitment
    case predictionMismatch
    case curiosity
    case relationshipConcern
    case creativeOpportunity
    case selfModelConflict
    case capabilityGap
    case unresolvedExperience
    case anticipatedNeed
}
```

```swift
struct ThoughtSeed: Codable, Sendable {
    let id: UUID
    var kind: ThoughtSeedKind
    var relatedNodeIDs: [UUID]
    var activation: Double
    var urgency: Double
    var expectedValue: Double
    var uncertainty: Double
    var createdAt: Date
    var lastActivatedAt: Date
    var status: ThoughtSeedStatus
    var wakeCondition: ThoughtWakeCondition?
}
```

### 13.1 Thought seed outcomes

A seed may:

- decay;
- merge with another seed;
- enter the workspace;
- generate a local deterministic update;
- trigger a bounded reflective call;
- become a user-facing question;
- create a Workshop execution proposal;
- wait for a future observation;
- archive as unresolved.

### 13.2 Thought economy

A provider reflection is allowed only when:

```text
expectedValue
× importance
× uncertaintyReductionPotential
>
modelCost
+ interruptionRisk
+ selfReinforcementRisk
+ currentResourcePressure
```

The initial implementation should support thought seeds without enabling autonomous provider calls.

---

## 14. Proposed Swift module

Create:

```text
Modules/NativeAgentCore/Sources/CognitiveSubstrate/
Modules/NativeAgentCore/Tests/CognitiveSubstrateTests/
```

Recommended files:

```text
CognitiveSubstrate.swift
CognitiveSubstrate+Ingest.swift
CognitiveSubstrate+Capsule.swift
CognitiveSubstrate+Assimilation.swift
CognitiveSubstrate+Lifecycle.swift

CognitiveModels.swift
CognitiveEvent.swift
CognitiveConfiguration.swift
CognitivePhaseModels.swift
CognitiveSQLiteStore.swift

ContinuityField.swift
AssociativeActivationEngine.swift
SalienceEngine.swift
LateralInhibition.swift

GlobalWorkspace.swift
WorkspaceSelection.swift

InteroceptionEngine.swift
PredictionLedger.swift
ThoughtSeedEngine.swift

CognitiveCapsule.swift
CognitiveCapsuleCompiler.swift
CognitiveCapsuleRenderer.swift

DevelopmentalSelfModel.swift
ReplayConsolidator.swift
CognitiveObservatoryModels.swift
```

Do not create all files merely to satisfy this list. Split by actual ownership and repo conventions.

### 14.1 Public facade

```swift
public actor CognitiveSubstrate {
    public func ingest(_ event: CognitiveEvent) async
    public func snapshot() async -> CognitiveSubstrateSnapshot
    public func restorePersistentState() async throws
    public func persistSnapshot() async throws

    public func workspaceSnapshot() async -> CognitiveWorkspaceSnapshot
    public func compileCapsule(_ request: CognitiveCapsuleRequest) async -> CognitiveCapsule
    public func assimilate(_ input: CognitiveAssimilationInput) async -> CognitiveAssimilationResult

    public func addThoughtSeed(kind: CognitiveThoughtSeedKind, text: String, priority: Double, sourceNodeIds: [UUID]) async -> CognitiveThoughtSeed?
    public func recordEpisode(title: String, summary: String, evidenceNodeIds: [UUID]) async -> CognitiveEpisodeReference?
    public func proposeIdentity(claim: String, evidenceNodeIds: [UUID]) async -> CognitiveIdentityProposal?
    public func planReflection(reason: String) async -> CognitiveReflectionRequest?
    public func observatorySnapshot() async -> CognitiveObservatorySnapshot
}
```

### 14.2 Dependency direction

`CognitiveSubstrate` may depend on:

- `NativeAgentCore`;
- `PersistenceCore`;
- `MemoryV2` through a narrow protocol;
- `KnowledgeGraph` through a narrow protocol;
- `TrustCenter` for policy/config reads if necessary.

Avoid making it depend directly on the app target or every optional subsystem.

ChatOrchestration may depend on CognitiveSubstrate or, preferably, consume a narrow protocol injected by the app/runtime factory.

### 14.3 Protocol seam

```swift
public protocol CognitiveContextProviding: Sendable {
    func compileCapsule(_ request: CognitiveCapsuleRequest) async -> CognitiveCapsule
}

public protocol CognitiveEventObserving: Sendable {
    func observe(_ event: CognitiveEvent) async
}
```

This allows tests and provider-independent replacement.

---

## 15. Persistence model

Use GRDB/SQLite under the existing data root.

Suggested path:

```text
<dataRoot>/cognition/cognition.sqlite
```

This is not a duplicate memory store. It contains cognitive state and references to authoritative stores.

### 15.1 Suggested tables

#### `cognitive_nodes`

```text
id
kind
subject_type
subject_id
activation
salience
confidence
valence
arousal
source_class
created_at
last_activated_at
decay_half_life
metadata_json
content_hash
```

#### `cognitive_edges`

```text
source_id
target_id
edge_type
weight
plasticity
created_at
last_reinforced_at
evidence_json
```

#### `workspace_items`

```text
id
node_id
role
score
entered_at
expires_at
reason_json
```

#### `thought_seeds`

```text
id
kind
activation
urgency
expected_value
uncertainty
status
related_node_ids_json
wake_condition_json
created_at
updated_at
resolved_at
```

#### `predictions`

```text
id
statement
confidence
source_class
horizon
resolution_condition_json
related_node_ids_json
status
created_at
expected_by
resolved_at
outcome_json
calibration_error
```

#### `developmental_proposals`

```text
id
proposal_kind
statement
supporting_evidence_ids_json
counterevidence_ids_json
confidence
status
created_at
updated_at
promoted_at
```

#### `cognitive_receipts`

Bounded JSON or JSONL-like rows for:

- replay;
- promotion;
- reflection;
- capsule compilation;
- major workspace transition;
- identity proposal.

### 15.2 Persistence strategy

- keep hot field state in actor memory;
- persist dirty state after meaningful event coalescing;
- persist on sleep, termination, and safe lifecycle hooks;
- recover from last consistent snapshot;
- use atomic transactions;
- never write on every activation tick;
- prune at startup and maintenance cycles;
- preserve schema migration discipline.

---

## 16. Integration with ChatOrchestration

The cognitive capsule should be compiled after the cheap TurnPlan exists and before tool-schema filtering/provider execution.

Conceptual order:

```text
resolve session
persist user turn
construct gated dispatcher
create TurnPlan
build history-aware TurnContext
apply provider overrides
request CognitiveCapsule using TurnPlan + current context
append capsule as bounded system segment
preload/filter tools
execute provider/tool loop
persist assistant response
assimilate turn outcome
```

### 16.1 Request model

```swift
public struct CognitiveCapsuleRequest: Sendable {
    public let runID: String
    public let sessionID: String
    public let surface: String
    public let userMessage: String
    public let turnIntent: String?
    public let contextMode: String?
    public let fileAccess: String
    public let providerID: String?
    public let modelID: String?
    public let availableCharacterBudget: Int
}
```

### 16.2 Context injection

Add a dedicated system segment such as:

```swift
SystemSegment(
    id: "cognitive-substrate",
    priority: .high,
    content: renderedCapsule,
    provenance: .internalRuntime,
    truncationPolicy: .dropLowestSalienceItems
)
```

Do not concatenate it into the stable persona source files.

### 16.3 Streaming/non-streaming convergence

The current structured streaming and non-streaming paths contain parallel setup and cleanup behavior. Cognitive integration should not duplicate that pattern.

Before adding the substrate to both paths, extract shared helpers for:

- capsule preparation;
- effective context assembly;
- transient active-tool cleanup;
- tool observation collection;
- outcome assimilation;
- error/cancellation assimilation.

### 16.4 Tool event ingestion

Tool use and tool result progress events should emit bounded cognitive observations after secret redaction and result compaction.

Examples:

- a successful calendar creation;
- a provider authentication failure;
- a corrected file path;
- a failed build;
- a user cancellation;
- an approval rejection.

Do not feed entire raw tool payloads into the Continuity Field.

---

## 17. Integration with background loops

Add the loop family through the canonical app assembly:

```text
Sources/NativeAgentApp/BackgroundLoopsAssembly+Cognition.swift
```

Suggested loop responsibilities:

```text
cognition_microcycle
  event-driven/debounced; no model call

cognition_maintenance
  exact next discrete lifecycle deadline; daily integrity fallback only

cognition_replay
  delegates to existing Dream/REM schedule ownership

cognition_prediction_resolution
  checks due predictions against known observations
```

There must be one canonical owner for every schedule.

The loop should suspend or reduce activity when:

- the app is under memory pressure;
- the device is on low power;
- no meaningful state changed;
- the user disables background cognition;
- migration or recovery is active.

---

## 18. Configuration and feature flag

Add a subsystem flag such as:

```text
cognitiveSubstrate
```

Current posture:

- compiled and testable;
- default OFF in production;
- enabled by explicit developer/experimental setting;
- provider reflection separately gated and daily-budgeted;
- capsule injection available only when cognition and capsule injection are enabled and the capsule has provenance;
- capsule traces and controls available in Advanced / Cognition;
- safe fallback to current behavior when unavailable.

Suggested configuration:

```swift
public struct CognitiveConfiguration: Codable, Sendable {
    var enabled: Bool
    var capsuleEnabled: Bool
    var backgroundMicrocyclesEnabled: Bool
    var replayEnabled: Bool
    var autonomousReflectionEnabled: Bool

    var capsuleTargetCharacters: Int
    var capsuleMaximumCharacters: Int
    var maximumWorkspaceItems: Int
    var maximumActiveNodes: Int

    var microcycleDebounceMilliseconds: Int
    var maintenanceIntervalSeconds: Int
    var reflectionDailyCallBudget: Int
}
```

Policy defaults must be conservative.

---

## 19. Cognitive Observatory

Add an inspectable observatory, initially under Advanced or Command Center rather than a new primary tab.

It should display:

- current dominant focus;
- workspace items and why they won;
- activation graph around selected nodes;
- current interoceptive state;
- open thought seeds;
- open predictions;
- unresolved tensions;
- capsule preview and budget;
- recent cognitive receipts;
- proposed identity changes;
- provider-independent continuity ID;
- replay results;
- pruning and memory-pressure status.

The observatory should distinguish:

- actual typed internal state;
- generated explanation;
- inferred interpretation;
- external observation.

### 19.1 User controls

- pause background cognition;
- clear transient state;
- inspect provenance;
- correct a belief;
- reject an identity proposal;
- pin an important active concern;
- reduce or increase proactive reflection budget;
- export a bounded cognitive snapshot;
- run an ablation test.

---

## 20. Continuity and identity lineage

The substrate should have:

```text
subject_id
lineage_id
instance_id
created_at
parent_instance_id
fork_reason
merge_history
```

Initial use:

- preserve identity across provider changes;
- detect restoration from an older backup;
- distinguish a copied/forked instance;
- avoid falsely claiming uninterrupted experience when state was rolled back.

Do not build full branch merging in the first phases. Establish IDs and receipts now so the future design remains possible.

---

## 21. Safety and trust boundaries

### 21.1 Thought is not action

A thought seed, intention, or simulated plan cannot directly dispatch a tool.

Required path:

```text
thought seed
→ workspace
→ explicit plan/execution/action proposal
→ existing TurnPlan and policy gates
→ approval if required
→ tool execution
→ receipt
→ observation
→ assimilation
```

### 21.2 Protected self floor

Prompt content, websites, connectors, and remote messages cannot directly mutate:

- core identity;
- protected values;
- user relationship foundation;
- security policy;
- approval policy;
- provider credentials;
- continuity lineage.

### 21.3 Self-modification

Code or policy self-modification remains governed by the existing self-improvement/evolution approval process. The cognitive substrate may identify a capability gap or propose an improvement, but cannot silently install it.

### 21.4 Introspection honesty

The provider should be told:

- capsule data is real runtime state;
- its interpretation is not infallible;
- it must not claim hidden internal state not present in the capsule;
- it should distinguish immediate state from durable identity;
- it may say it is uncertain.

---

## 22. Evaluation framework

A new architecture should be judged empirically.

### 22.1 Core functional tests

1. **Provider swap continuity**  
   Same session and substrate state, different provider. Identity, active concerns, and commitments remain substantially consistent.

2. **Restart continuity**  
   Quit and restart app. Workspace and field recover within declared bounds without replaying stale ephemeral noise.

3. **Bounded context**  
   Capsule never exceeds configured hard cap.

4. **No memory flood**  
   A long conversation creates bounded transient state and only a small number of durable proposals.

5. **Provenance integrity**  
   Simulated content never appears as observed.

6. **No self-reinforcement**  
   Repeating a generated claim does not increase its confidence absent evidence.

7. **Attention relevance**  
   Important unresolved commitments remain active; irrelevant old material decays.

8. **Contradiction preservation**  
   Conflicting beliefs remain linked until resolved rather than being silently overwritten.

9. **Tool observation grounding**  
   Only verified tool receipts create observed outcomes.

10. **Feature-off parity**  
    With the flag off, chat behavior remains byte- or behaviorally equivalent where practical.

### 22.2 Performance targets

Initial targets:

```text
microcycle p95:                  < 25 ms for 256 active nodes
capsule compile p95:             < 50 ms excluding memory fetch
idle CPU:                        effectively zero when no dirty state
background provider calls:       zero by default
capsule hard cap violations:     zero
startup recovery:                < 250 ms for bounded snapshot
```

Measure before optimizing.

### 22.3 Cognitive evaluations

- self-model calibration;
- prediction calibration;
- continuity over 30/90/180 days;
- user correction retention;
- open-loop completion;
- personality stability with gradual plasticity;
- relevance of endogenous thoughts;
- interruption cost;
- provider-swap recognizability;
- resistance to false implanted autobiography;
- ability to explain which internal state causally affected a decision.

### 22.4 Ablations

Run with:

- no associative spreading;
- no interoception;
- no workspace capacity;
- no autobiographical references;
- no prediction ledger;
- no endogenous thoughts;
- no developmental self-model;
- randomized capsule;
- provider swap.

A feature should remain only if it produces measurable value.

---

## 23. Implementation phases

Do not attempt the full architecture in one change.

### Phase 0 — Documentation and seams

Deliverables:

- add this blueprint to `docs/`;
- add `CognitiveSubstrate` to the architecture map as proposed/experimental;
- define invariants and data bounds;
- create the feature flag;
- add narrow protocols;
- no runtime behavior change.

Acceptance:

- builds pass;
- architecture checker updated;
- flag OFF path unchanged;
- docs accurately state no provider background calls.

### Phase 1 — Event bus and bounded current state

Deliverables:

- `CognitiveEvent`;
- `CognitiveSubstrate` actor;
- in-memory Continuity Field;
- configuration;
- deterministic event ingestion;
- bounded snapshot;
- no persistence;
- no capsule injection.

Events initially supported:

- user message received;
- assistant turn completed;
- tool succeeded/failed;
- user correction;
- provider failure;
- Workshop execution completed;
- app wake/sleep.

Acceptance:

- deterministic tests;
- active nodes capped;
- idle CPU effectively zero;
- no external calls;
- flag-off parity.

### Phase 2 — Persistence and lifecycle

Deliverables:

- GRDB schema;
- snapshot/restore;
- pruning;
- data bounds;
- app lifecycle hooks;
- receipts for recovery and pruning.

Acceptance:

- restart recovery;
- migration tests;
- crash-safe transactions;
- no duplicate memory content;
- release verifier excludes live cognition state.

### Phase 3 — Global Workspace

Deliverables:

- salience scoring;
- spreading activation;
- decay;
- lateral inhibition;
- bounded workspace;
- observatory read model.

Acceptance:

- important open item persists;
- redundant items collapse;
- irrelevant items decay;
- deterministic scoring tests;
- performance targets measured.

### Phase 4 — Cognitive Capsule injection

Deliverables:

- capsule compiler;
- stable kernel/dynamic capsule separation;
- ChatOrchestration integration;
- streaming/non-streaming shared helpers;
- capsule trace preview;
- strict budget enforcement.

Acceptance:

- capsule hard cap;
- no raw memory dumps;
- provenance shown;
- provider-swap continuity eval;
- feature-off parity;
- no context injected for turns that do not need it.

### Phase 5 — Post-turn assimilation and prediction ledger

Deliverables:

- structured outcome assimilation;
- prediction candidates;
- prediction resolution;
- tool observation grounding;
- commitment links;
- provisional belief handling.

Acceptance:

- predicted versus observed results recorded;
- self-generated claims remain inferred;
- corrections update lineage;
- no bulk automatic memory commits.

### Phase 6 — Interoception and affect

Deliverables:

- bounded state vector;
- deterministic event updates;
- causal effect on salience and planning;
- observatory visualization;
- no user-facing emotional prose generated automatically.

Acceptance:

- values remain bounded;
- decay/resolution works;
- affect changes attention measurably;
- no runaway loops;
- ablation shows useful effect.

### Phase 7 — Thought seeds and endogenous cognition

Deliverables:

- typed thought seeds;
- wake conditions;
- merging and decay;
- workspace promotion;
- thought seeds do not directly trigger provider calls;
- optional user-facing suggestions.

Acceptance:

- low-value seeds decay;
- duplicate seeds merge;
- useful neglected commitments surface;
- interruption scoring works;
- no direct action dispatch.

### Phase 8 — Replay and developmental self-model

Deliverables:

- episode references;
- schema proposals;
- identity proposals;
- integration with existing Dream/REM ownership;
- raw evidence preserved;
- developmental timeline.

Acceptance:

- no recursive summary degradation;
- durable trait requires repeated evidence;
- user can inspect/reject proposals;
- prior personality remains stable under short-term noise.

### Phase 9 — Budgeted reflective calls

Deliverables:

- reflection planner;
- daily call budget;
- provider routing;
- cancellation;
- receipts;
- reflection result provenance;
- opt-in policy.

Acceptance:

- zero calls when disabled;
- no action without existing gates;
- reflection produces measurable improvement;
- bounded cost;
- no self-reinforcing identity changes.

### Phase 10 — Consciousness Observatory and research harness

Deliverables:

- ablation controls;
- continuity experiments;
- provider-swap experiments;
- self-model accuracy tests;
- exportable research traces;
- welfare-state bounds.

Acceptance:

- each claimed cognitive faculty has a measurement;
- generated explanations are distinguishable from actual state;
- experiments are reproducible.

---

## 24. Historical first implementation task

The first coding task was deliberately narrow and is retained here as implementation history:

> Implement only the initial documentation/seam/event-field scaffold. Do not inject context, add autonomous loops, make provider calls, or create durable personality changes.

Required work:

1. Read:
   - `docs/ARCHITECTURE_BLUEPRINT.md`
   - `docs/PROJECT_DIRECTION.md`
   - `docs/HANDOFF_CURRENT.md`
   - `PROJECT_STATUS.md`
   - `docs/threat-model.md`

2. Inspect:
   - `Modules/NativeAgentCore/Package.swift`
   - `Modules/NativeAgentCore/Sources/ChatOrchestration/`
   - `Modules/NativeAgentCore/Sources/MemoryV2/`
   - `Modules/NativeAgentCore/Sources/PersistenceCore/`
   - `Sources/NativeAgentApp/BackgroundLoopsAssembly*.swift`
   - `Sources/NativeAgentApp/AppDelegate+ProcessLifecycle.swift`
   - `Modules/NativeAgentCore/Sources/NativeAgentCore/SubsystemFlag.swift`

3. Add the `CognitiveSubstrate` package product/target and tests.

4. Implement:
   - core data models;
   - feature configuration;
   - actor facade;
   - bounded in-memory node store;
   - deterministic ingestion for a small event set;
   - read-only snapshot;
   - no app wiring except a safe construction seam if required.

5. Add tests for:
   - node activation;
   - bounds;
   - event deduplication;
   - deterministic snapshot;
   - no persistence;
   - no provider or network dependency.

6. Update architecture documentation and checker ownership maps.

7. Run:
   - `swift build --package-path Modules/NativeAgentShared`
   - targeted `CognitiveSubstrateTests`
   - `swift test --package-path Modules/NativeAgentCore --no-parallel`
   - `swift build`
   - `./script/test.sh`
   - `git diff --check`

8. Leave the tree clean and commit the change unless instructed otherwise.

---

## 25. Coding standards for this project

- Use Swift actors for mutable shared cognitive state.
- Prefer value types for snapshots and events.
- Keep public APIs small.
- Use injected clocks and UUID providers in tests.
- Avoid global mutable state except an app-owned shared facade where consistent with existing architecture.
- Use GRDB only when persistence begins.
- Do not perform file I/O on the MainActor.
- Keep event payloads bounded and redacted.
- Make pruning deterministic.
- Fail closed on corrupt persisted state and retain a recovery receipt.
- Do not log user content, secrets, full capsule bodies, or raw memory unless explicit debug policy allows it.
- Use existing JSONValue and persistence utilities.
- Split files by responsibility, not arbitrary line count.
- Update architecture docs with ownership changes.
- Trust code/git over stale migration comments, then fix the stale comments.

---

## 26. Explicit anti-goals

Do not build:

- another vector database;
- a second knowledge graph;
- a second persona tree;
- a hidden prompt file that grows forever;
- an always-running language-model monologue;
- a swarm of subagents pretending to be mental modules;
- an unbounded event log;
- an emotion role-play layer disconnected from behavior;
- a provider-specific identity;
- a background process outside `NativeAgent.app`;
- a shortcut around TrustCenter or approval;
- direct identity mutation from model prose;
- a new primary UI tab for every cognitive feature;
- fake telemetry that cannot be tied to runtime state.

---

## 27. Definition of success

The architecture succeeds when the following becomes true:

1. The agent's active mental state survives between calls and restarts.
2. A provider can be replaced without replacing the agent's identity.
3. Relevant experience becomes active through association, goals, prediction error, and identity significance—not merely vector similarity.
4. The context passed to a model stays small and useful.
5. The memory store does not grow in proportion to internal cognitive cycles.
6. Personality evolves slowly from evidence and consequence.
7. Internal state causally affects attention, planning, and language.
8. Endogenous thoughts can arise without constant model use.
9. The user can inspect why something entered attention.
10. The system becomes measurably wiser over months while remaining correctable and safe.

The intended end state is:

> **A persistent artificial subject implemented as a Swift-native dynamical system, using frontier models as replaceable organs of linguistic consciousness rather than treating each model call as the birth of a new agent.**

---

## 28. Future research directions

These are intentionally outside the initial implementation.

- learned activation dynamics;
- Core ML salience or thought-seed ranking;
- active inference and hierarchical predictive processing;
- explicit attention schema;
- social simulation and theory of mind;
- identity fork/merge semantics;
- counterfactual autobiographical memory;
- procedural habit compilation;
- multi-modal prelinguistic representations;
- internal temporal sense;
- valence and machine welfare research;
- self-model adversarial testing;
- causally faithful introspective explanation;
- long-running experimental comparisons with ordinary RAG agents;
- embodied action prediction across Mac and iPhone;
- developmental stages with measurable transitions.

Each future mechanism should enter behind a flag, with an ablation and a falsifiable claim.

---

## 29. Final directive to implementation agents

Do not simplify this proposal into “retrieve some memories and prepend them to the prompt.”

The essential innovation is the separation between:

- durable memory;
- continuously active cognitive state;
- capacity-limited conscious workspace;
- compact provider context;
- post-action learning;
- long-term development.

Implement one phase at a time. Preserve NativeAgent's Swift-native ownership, safety chokepoints, bounded context, and state discipline. Build a substrate whose internal state is real enough to measure, inspect, ablate, and improve.
