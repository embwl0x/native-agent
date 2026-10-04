# Cognitive Substrate Traceability Ledger

Source-backed implementation map for
[Continuous Cognitive Substrate](CONTINUOUS_COGNITIVE_SUBSTRATE.md).
This ledger records mechanisms and evidence limits, not release certification.

## Status Rules

- **Source:** implementation found in the named owner; no installed result implied.
- **Boundary:** another owner controls the effect.
- **Retired:** no longer part of the contract; ID retained for script compatibility.
- **Unverified:** the claimed outcome is not established by this source review.

`script/check_architecture_blueprint.swift` requires the P0–P10 deliverable
and acceptance IDs, X1–X9, this heading and **Next Execution Order**.
Keep those markers stable. Historical suite results are not current proof.
Runtime changes follow the repository's build, install and bounded working-app
check rule; docs-only changes require readback.

## Source ownership after the splits

Paths are relative to `Modules/NativeAgentCore/Sources/`.

| Shorthand | Owner |
|---|---|
| S | `CognitiveSubstrate/`; `+Name` means `CognitiveSubstrate+Name.swift` |
| R | `Cognition/NativeCognitionRuntime.swift`; `R+Name` means its extension in `Cognition/` |
| T | `ChatTurnRuntime/ChatOrchestrationClient+MessagePersistence.swift` and `ChatOrchestrationClient+StructuredChat.swift` |
| Store | `CognitiveSubstrate/CognitiveSQLiteStore.swift` and `CognitiveSQLiteStore+Reads.swift` |
| Engine | `EngineRuntime/NativeAgentEngine.swift` |
| UI | `Sources/NativeAgentApp/CognitionObservatoryView.swift` and its extensions, relative to repository root |
| Loops | App `Sources/NativeAgentApp/BackgroundLoopsAssembly+Cognition.swift` and Core `Cognition/CognitiveBackgroundLoops.swift` |

Engine assembles R with host ports. R coordinates the substrate and organism;
S's extensions share one actor. T consumes the same turn projection for chat.
The UI reads these owners and subscribes to runtime invalidations.

## Phase 0 - Documentation And Seams

| ID | Item | Status | Source / limit |
|---|---|---|---|
| CCS-P0-D1 | Blueprint | Source | `CONTINUOUS_COGNITIVE_SUBSTRATE.md` |
| CCS-P0-D2 | Architecture ownership | Source | `ARCHITECTURE_BLUEPRINT.md`; Engine constructs R |
| CCS-P0-D3 | Bounds | Source | `S/CognitiveConfiguration.swift`; R `loadConfiguration` |
| CCS-P0-D4 | Configuration switches | Source | R preference loading and setters |
| CCS-P0-D5 | Narrow dependencies | Source | `S/CognitiveSubstrateContracts.swift` and `CognitivePhaseModels.swift` |
| CCS-P0-D6 | Scaffold has no runtime effect | Retired | This is integrated runtime code, not a scaffold |
| CCS-P0-A1 | Build passes | Unverified | No build performed for this docs-only change |
| CCS-P0-A2 | Ledger checker | Source | `script/check_architecture_blueprint.swift`, `appendCognitiveTraceabilityErrors` |
| CCS-P0-A3 | Default-off premise | Retired | R enables cognition when its saved master preference is absent |
| CCS-P0-A4 | Background provider calls | Source | Reflection has separate admission in S `+Reflection` and execution in R `+Reflection` |

## Phase 1 - Event Bus And Bounded Current State

| ID | Item | Status | Source / limit |
|---|---|---|---|
| CCS-P1-D1 | Typed events | Source | `S/CognitiveEvent.swift` |
| CCS-P1-D2 | State actor | Source | `S/CognitiveSubstrate.swift` |
| CCS-P1-D3 | Continuity field | Source | `S/ContinuityField.swift` |
| CCS-P1-D4 | Configuration | Source | `S/CognitiveConfiguration.swift`; R `loadConfiguration` |
| CCS-P1-D5 | Injected clock/UUID | Source | `S/CognitiveSubstrateContracts.swift`; S `+Ingest` |
| CCS-P1-D6 | Bounded nodes and metadata | Source | `ContinuityField.ingest` and `enforceCapacity` |
| CCS-P1-D7 | Persistence gating | Source | S `+Persistence` and `+Restore` |
| CCS-P1-D8 | Capsule gating | Source | S `+Capsule` |
| CCS-P1-D9 | User-message ingress | Source | T `observeCognitiveMessage`; R `+Events` |
| CCS-P1-D10 | Assistant completion ingress | Source | Same message boundary |
| CCS-P1-D11 | Tool outcomes | Source | T `observeCognitiveTool` and `observeCognitiveProgressEvent` |
| CCS-P1-D12 | Remote corrections | Source | R `+Events`, `remoteAction` |
| CCS-P1-D13 | Provider failure evidence | Source | R `+Events`; T provider-error observations |
| CCS-P1-D14 | Motor outcome ingress | Source | Engine forwards motor projections to R `observeMotorActionState` |
| CCS-P1-D15 | Wake/sleep | Source | R `bootstrap` and `flushForTermination` |
| CCS-P1-A1 | Deterministic execution proof | Unverified | Dependency injection is a mechanism, not a current execution result |
| CCS-P1-A2 | Node cap | Source | `ContinuityField.enforceCapacity`; app limit 256 |
| CCS-P1-A3 | Quiet work admission | Source | S `+Workspace` rejects clean microcycles; R deadlines and daily recovery Loops |
| CCS-P1-A4 | Provider-free ingress | Source | S `+Ingest` defers eligible interpretation; after-turn appraisal and reflection are separate paths |
| CCS-P1-A5 | Disabled-path parity | Unverified | Enabled guards exist; no installed parity claim |
| CCS-P1-A6 | Resource-pressure handling | Source | R `backgroundCognitionGate`: power/thermal/sleep refusal, conserve throttle |

## Phase 2 - Persistence And Lifecycle

| ID | Item | Status | Source / limit |
|---|---|---|---|
| CCS-P2-D1 | GRDB schema | Source | Store migrations: nodes, artifacts, receipts, schema markers and motor replay admission |
| CCS-P2-D2 | Checked restore | Source | S `+Restore` validates a complete bundle before applying it; failure blocks state writes |
| CCS-P2-D3 | Pruning | Source | Store node, artifact and receipt pruning; protected family quotas |
| CCS-P2-D4 | Data bounds | Source | Configuration caps and Store limits |
| CCS-P2-D5 | Lifecycle | Source | R `bootstrap`, `flushForTermination` |
| CCS-P2-D6 | Recovery/prune receipts | Source | Store; S `+Restore` |
| CCS-P2-A1 | Installed restart recovery | Unverified | Restore implementation exists; no current restart result claimed |
| CCS-P2-A2 | Migration execution | Unverified | Migrations read, not executed |
| CCS-P2-A3 | Transaction boundary | Source | Store uses GRDB write transactions |
| CCS-P2-A4 | Canonical memory | Boundary | S persists cognitive state; replay consumes references, not canonical MemoryV2 writes |
| CCS-P2-A5 | Release exclusion | Source | `script/verify_release_artifact.sh` rejects private cognition directories |

## Phase 3 - Global Workspace

This is the substrate's internal attention selection, not an agent tool.

| ID | Item | Status | Source / limit |
|---|---|---|---|
| CCS-P3-D1 | Salience | Source | S `+Workspace.workspaceScore` |
| CCS-P3-D2 | Spreading activation | Source | `ContinuityField.spreadActivation` |
| CCS-P3-D3 | Decay | Source | `ContinuityField.snapshot` projects at the supplied time |
| CCS-P3-D4 | Redundancy inhibition | Source | S `+Workspace.makeWorkspaceSnapshot` |
| CCS-P3-D5 | Bounded selection | Source | `maximumWorkspaceItems`; app limit 12 |
| CCS-P3-D6 | Inspection | Source | UI and R owner invalidations |
| CCS-P3-A1 | Important concern survives restart | Unverified | No installed relevance/restart result claimed |
| CCS-P3-A2 | Redundancy rule | Source | Same inhibition path as D4 |
| CCS-P3-A3 | Decay rule | Source | Same projection as D3 |
| CCS-P3-A4 | Deterministic ordering proof | Unverified | No current execution result claimed |
| CCS-P3-A5 | Performance target | Unverified | Source inspection supplies no timing measurement |

## Phase 4 - Cognitive Capsule Injection

| ID | Item | Status | Source / limit |
|---|---|---|---|
| CCS-P4-D1 | Compiler | Source | S `+Capsule` |
| CCS-P4-D2 | Kernel/dynamic separation | Source | `CognitiveCapsule`; S `+Capsule` |
| CCS-P4-D3 | Turn integration | Source | R `prepareTurnProjection`; T prepares/appends/commits |
| CCS-P4-D4 | Shared projection | Source | T `prepareCognitiveTurnProjection` and `commitDeliveredCognitiveTurnProjection` |
| CCS-P4-D5 | Preview | Source | R `lastInjectedCapsuleBridgeSummary`; UI capsule panel |
| CCS-P4-D6 | Budget fitting | Source | S `+Capsule.fitCapsuleLines` |
| CCS-P4-A1 | Hard ceiling | Source | Minimum of configured and caller-requested character limits |
| CCS-P4-A2 | Bounded content | Source | S `+Capsule.innerStateCapsuleLines` selects projections |
| CCS-P4-A3 | Provenance | Source | Capsule node IDs; frozen workspace inputs |
| CCS-P4-A4 | Provider-swap continuity proof | Unverified | S `+Research` declines provider-swap scores |
| CCS-P4-A5 | Disabled-path parity | Unverified | No current installed comparison |
| CCS-P4-A6 | Omission and presentation | Source | S `prepareFrozenCapsulePresentation`; T commits live presentation after a successful turn |

## Phase 5 - Post-Turn Assimilation And Prediction Ledger

| ID | Item | Status | Source / limit |
|---|---|---|---|
| CCS-P5-D1, CCS-P5-D2, CCS-P5-D3, CCS-P5-D4, CCS-P5-D5, CCS-P5-D6 | Text-extracted outcomes, predictions, resolutions, grounding, commitments and provisional beliefs | Retired | S `+Replay` documents removal of the assimilation seam; no such task ledger remains in S |
| CCS-P5-A1, CCS-P5-A2, CCS-P5-A3 | Extracted prediction outcomes, inference status and correction lineage | Retired | Acceptance rows for the removed mechanism |
| CCS-P5-A4 | Automatic canonical memory writes | Boundary | MemoryV2 owns canonical memory; cognition's after-turn appraisal is separate |

Current after-turn interpretation is wired in R `refreshConfiguration`
through `AdaptiveMemoryPromoter` to S `finishAfterTurn`. Body predictions
remain in `S/Organism/OrganismPrediction.swift`; they do not restore the
removed assistant-prose task ledger.

## Phase 6 - Interoception And Affect

| ID | Item | Status | Source / limit |
|---|---|---|---|
| CCS-P6-D1 | Affect vector | Source | `CognitiveAffectState` in `S/CognitivePhaseModels.swift` |
| CCS-P6-D2 | Event updates | Source | S `+Affect`, `+Ingest`, `+CaringAppraisal` |
| CCS-P6-D3 | Attention influence | Source | S `+Workspace.workspaceScore` and `+ThoughtSeeds.interruptionScore` |
| CCS-P6-D4 | Affect display | Source | UI `CognitionObservatoryView+Affect.swift` |
| CCS-P6-D5 | Expression | Source | S `+Capsule` renders internal context; affect itself sends no user message |
| CCS-P6-A1 | Bounds | Source | Affect values clamped; S `+Research.welfareBoundsSnapshot` reports bounds |
| CCS-P6-A2 | Decay | Source | S `+Affect.decayedAffect` |
| CCS-P6-A3 | Useful attention change | Unverified | Scoring influence exists; behavioral benefit is not measured here |
| CCS-P6-A4 | Work admission | Source | S dirty/configuration guards; R event coalescing and deadlines |
| CCS-P6-A5 | Useful ablation effect | Unverified | S `+Research` reports ablation settings, not causal benefit |

## Phase 7 - Thought Seeds And Endogenous Cognition

| ID | Item | Status | Source / limit |
|---|---|---|---|
| CCS-P7-D1 | Typed seeds | Source | `CognitiveThoughtSeedKind` in `S/CognitivePhaseModels.swift` |
| CCS-P7-D2 | Seed creation during settlement | Source | S `+Workspace.runMicrocycleChecked` |
| CCS-P7-D3 | Merge, decay and cap | Source | S `+ThoughtSeeds` |
| CCS-P7-D4 | Workspace-linked suggestions | Source | `thoughtSuggestionSnapshot` |
| CCS-P7-D5 | Provider-call authority | Boundary | Reflection admission/execution belongs to S/R `+Reflection` |
| CCS-P7-D6 | Inspection | Source | UI `CognitionObservatoryView+ThoughtSeeds.swift` |
| CCS-P7-A1 | Low-priority expiry | Source | S `+ThoughtSeeds.decayThoughtSeedsInMemory` |
| CCS-P7-A2 | Duplicate merge | Source | S `+ThoughtSeeds.addThoughtSeed` |
| CCS-P7-A3 | Extracted overdue commitments | Retired | The Phase 5 task ledger is absent |
| CCS-P7-A4 | Interruption score | Source | S `+ThoughtSeeds.interruptionScore`; usefulness unmeasured here |
| CCS-P7-A5 | Direct action dispatch | Boundary | Seed suggestions carry data; app/Trust owners execute actions |

## Phase 8 - Replay And Developmental Self-Model

| ID | Item | Status | Source / limit |
|---|---|---|---|
| CCS-P8-D1 | Episode references | Source | S `+Replay.recordEpisode` and `integrateReplayChecked` |
| CCS-P8-D2 | REM proposal projection | Source | R `+Replay`; S `+Replay` |
| CCS-P8-D3 | Canonical identity proposals | Boundary | `DreamREMCycle/REMConsolidator.swift`; substrate projects existing proposal evidence |
| CCS-P8-D4 | Dream/REM integration | Source | R `+Replay.makeReplayIntegrationInput`; R `+Organism` commit-signal handling |
| CCS-P8-D5 | External evidence references | Source | S `+Replay` stores bounded evidence IDs and lineage |
| CCS-P8-D6 | Timeline | Source | S `+Replay.developmentalTimelineSnapshot` |
| CCS-P8-A1 | Replay deduplication | Source | `integrateReplayChecked` checks external evidence IDs |
| CCS-P8-A2 | Repeated evidence establishes a trait | Unverified | No general trait-validity threshold claimed |
| CCS-P8-A3 | Inspect/resolve proposals | Source | UI `Sources/NativeAgentApp/CognitionProposalsView.swift` and `Sources/NativeAgentApp/CognitionSurfaceActions.swift`; R schema/view methods |
| CCS-P8-A4 | Personality stability under noise | Unverified | A proposal boundary alone does not measure personality stability |

## Phase 9 - Budgeted Reflective Calls

| ID | Item | Status | Source / limit |
|---|---|---|---|
| CCS-P9-D1 | Planner | Source | S `+Reflection.planReflectionChecked` |
| CCS-P9-D2 | Cost ceiling | Source | Rolling 24-hour receipt count and in-flight reservation |
| CCS-P9-D3 | Provider route | Source | R checked `cognition_reflection` routing; no fixed model |
| CCS-P9-D4 | Cancellation | Source | R `+Reflection` records cancellation results |
| CCS-P9-D5 | Receipts | Source | S `+Reflection.recordReflectionResult` |
| CCS-P9-D6 | Provenance | Source | Capsule IDs plus quoted-excerpt IDs and external material provenance |
| CCS-P9-D7 | Enable policy | Source | R preference/onboarding initialization; S admission gate |
| CCS-P9-A1 | Disabled-call gate | Source | S `reflectionCostRefusal` |
| CCS-P9-A2 | Action authority | Boundary | Reflection can propose a view; app/Trust own effects |
| CCS-P9-A3 | Measurable improvement | Unverified | Proposal yield is not a judgment-quality measurement |
| CCS-P9-A4 | Bounded cost mechanism | Source | Prompt/result bounds, receipt cost estimates and call ceiling |
| CCS-P9-A5 | Identity write boundary | Boundary | Reflection parser proposes standing views; canonical growth has its own owner |

## Phase 10 - Consciousness Observatory And Research Harness

| ID | Item | Status | Source / limit |
|---|---|---|---|
| CCS-P10-D1 | Ablation controls | Source | S `+Research.setAblation`; UI |
| CCS-P10-D2 | Continuity sampler | Source | S `+Research` samples counts, not longitudinal continuity |
| CCS-P10-D3 | Provider-swap score | Retired | `experimentScore` returns nil |
| CCS-P10-D4 | Self-model accuracy score | Retired | `experimentScore` returns nil |
| CCS-P10-D5 | Export | Source | S `exportResearchTrace`; R writes bounded exports |
| CCS-P10-D6 | Welfare readout | Source | `welfareBoundsSnapshot`: operational telemetry, no consciousness claim |
| CCS-P10-A1 | Faculty measurements | Source | `facultyMeasurementSnapshot` reports counters/flags/bounds, not faculty validation |
| CCS-P10-A2 | State/explanation distinction | Source | Export separates `actualState` and `generatedExplanations` |
| CCS-P10-A3 | Reproducibility mechanism | Source | Key derives from experiment kind, seed and sorted metrics; no execution result claimed |

## Cross-Cutting Integration Gates

| ID | Item | Status | Source / limit |
|---|---|---|---|
| CCS-X1 | Provider-context placement | Source | T prepares and appends the runtime projection before provider dispatch |
| CCS-X2 | Redacted ingress | Source | T message/tool observation methods redact and bound content |
| CCS-X3 | Background ownership | Source | R event/deadline ownership; Loops recovery registrations |
| CCS-X4 | Pressure/dirty/disabled gates | Source | R `backgroundCognitionGate`; S `runMicrocycleChecked` |
| CCS-X5 | Observable state | Source | UI reads R detail and runtime invalidations |
| CCS-X6 | Controls | Source | R configuration, clear, schema/view, export and ablation methods |
| CCS-X7 | Lineage | Source | S `+Replay` timeline includes subject, instance, lineage and external evidence |
| CCS-X8 | Memory integration | Source | `S/CognitiveSubstrateContracts.swift`; R MemoryV2 adapters |
| CCS-X9 | Dispatch authority | Boundary | `AppToolRuntime/AppActionRegistry.swift` and `TrustCenter/SecurityCenter.swift` |

## Next Execution Order

There is no implementation queue implied by this ledger. Unverified rows
identify evidence limits, not authorized work. Select changes from User's
current request and recheck the owning code before changing a row.
