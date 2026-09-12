# Cognitive Substrate Traceability Ledger

Last ownership review: 2026-09-07, source baseline `13006f73`. Rows touched by the
2026-09-11/12 audit follow-through (reflection provenance, the conserve gate,
REM proposal catch-up) were re-read against `086055a4e` on 2026-09-12; the rest
retain their 2026-09-07 evidence.

This file is the implementation contract for `docs/CONTINUOUS_COGNITIVE_SUBSTRATE.md`.
It exists so implementation agents cannot compress the blueprint into a vague
"mostly done" statement and silently skip acceptance criteria.

## Status Rules

Status values:

- `Done`: implemented, code-referenced, and covered by a focused check or test.
- `Partial`: some infrastructure exists, but the blueprint behavior or acceptance proof is incomplete.
- `Not started`: no meaningful implementation exists yet.
- `Intentional boundary`: deliberately not implemented because another NativeAgent
  safety chokepoint owns it.

A phase is not complete until every deliverable and acceptance row is `Done` or
`Intentional boundary` with a named owner. When code changes any row below, update
this ledger in the same commit.

Current implementation anchors:

- Core substrate: `Modules/NativeAgentCore/Sources/CognitiveSubstrate/`
- App assembly gate: `Sources/NativeAgentApp/NativeCognitionRuntime.swift`
- Background loops: `Sources/NativeAgentApp/BackgroundLoopsAssembly+Cognition.swift`
- Observatory UI: `Sources/NativeAgentApp/CognitionObservatoryView.swift`
- Focused tests: `Modules/NativeAgentCore/Tests/CognitiveSubstrateTests/CognitiveSubstrateTests.swift`, `Modules/NativeAgentCore/Tests/ChatOrchestrationTests/ChatOrchestrationClientTests.swift`, `tests/NativeAgentAppTests/NativeCognitiveEventFactoryTests.swift`

## Source ownership after the splits

The phase statuses below retain their existing implementation/test evidence;
this documentation pass did not rerun cognition tests or certify a release.
Files below are in Core `Sources/CognitiveSubstrate/` unless marked app.
All `CognitiveSubstrate+…` extensions share the actor state declared in
`CognitiveSubstrate.swift`: field, affect, seeds, proposals, replay evidence,
presentation bookkeeping and persistence health. They are not independent minds.

| Ledger seam | Current implementation owner and handoff |
| --- | --- |
| P0/P1 contracts and event ingestion | `CognitiveSubstrateContracts.swift` defines injected clock/UUID/dynamics, moment recall, attention sink and typed receipt reads. `CognitiveSubstrate+Ingest.swift` rejects duplicates before state mutation, calls relational appraisal backed by `+ConversationalAppraisal.swift`, and updates field/affect/semantic tags. Resident ingress publishes attention and defers durability to the dirty microcycle; direct ingress keeps its persistence path. |
| P2 persistence and restoration | `CognitiveSubstrate+Persistence.swift` coordinates store writes; `+Restore.swift` validates the complete bundle before applying it and blocks writes on failed restore. `CognitiveSQLiteStore` is the persistence boundary, not MemoryV2. |
| P3/P4 workspace to capsule | `+Workspace.swift` supplies bounded workspace reads; `+Capsule.swift` compiles/fits live or frozen capsules and prepares presentation commits. Frozen rendering uses the supplied epoch; only accepted context commits surfaced bookkeeping. |
| P4/P6 felt, Sound and cadence | `+CapsuleFeltSignals.swift` selects felt aboutness/ambivalence; `+CapsuleSoundEcho.swift` scores Sound echo/rut wording; `+CapsuleCadence.swift` selects Inner lines, bounds repetition/rest and renders session continuity. These return projections/presentation changes to capsule assembly, not new affect or memory state. |
| Shared helpers | `+Values.swift` owns coercion, IDs/digests, text filters and bounds used by those extensions. Despite its name it is not the authority for personal values. |
| P8 Dream/REM integration | App `NativeCognitionRuntime+Replay.swift` reads existing Dream/REM output; `CognitiveSubstrate+Replay.swift` integrates deduplicated episode/proposal/timeline evidence with checked persistence. Dream scheduling and approval-gated canonical identity remain outside this owner. |
| P10 research | `CognitiveSubstrate+Research.swift` reads faculty/welfare measurements, records reproducible no-provider experiments and exports bounded state. A proposal-yield or continuity score is a measurement of that harness, not independent evidence of cognitive improvement or lived experience. |
| X10–X15 organism | `Organism/OrganismPredictionModels.swift` defines ledger/outcome/horizon values; `OrganismPrediction.swift` applies somatic transitions and settles/expires predictions; `OrganismPrediction+Horizon.swift` refreshes horizon sources using the same ledger/settlement helpers. `OrganismCapabilitySelfModel.swift` derives advisory beliefs. `OrganismGeneratedSleepRecalibration.swift` returns generated-evidence calibration artifacts; live state/deadlines stay with `OrganismKernel` and `OrganismLivingDynamics`. |
| X17/X19 app projection | `NativeCognitionRuntime.swift` remains the app coordinator. `NativeCognitionRuntimeModels.swift` carries detail-read, capsule-preview, invalidation and runtime status values. The existing runtime projection path prepares one fixed-time cognition/organism value; model extraction adds no actor or observer. |
| Review and bridge evidence | App `ClaudeBridge+StandingViews.swift` calls the same `CognitionProposalActions` used by UI review. `ClaudeBridge+StateProjection.swift` exposes runtime snapshots/read errors. Its general `activeProvider` inference and constant `chatReady` are not checked execution-readiness proof. |

For canonical memory/KG writes and their extracted codecs, migrations and
consolidation transaction see [Memory ownership](MEMORY_SYSTEM_MAP.md#ownership-after-the-september-splits).
For the full surface → turn → dispatch → assimilation flow see the
[architecture families](ARCHITECTURE_BLUEPRINT.md#ownership-after-the-splits).

## Phase 0 - Documentation And Seams

| ID | Blueprint item | Status | Evidence / gap |
|---|---|---|---|
| CCS-P0-D1 | Add blueprint to `docs/` | Done | `docs/CONTINUOUS_COGNITIVE_SUBSTRATE.md` |
| CCS-P0-D2 | Add `CognitiveSubstrate` to architecture map as proposed/experimental | Done | `docs/ARCHITECTURE_BLUEPRINT.md` |
| CCS-P0-D3 | Define invariants and data bounds | Done | Blueprint constraints plus `docs/data-bounds.md` |
| CCS-P0-D4 | Create feature flag | Done | `.cognitiveSubstrate`; default-off tests exist |
| CCS-P0-D5 | Add narrow protocols | Done | `CognitiveEventObserving`, `CognitiveContextProviding`, `CognitiveTurnAssimilating` |
| CCS-P0-D6 | No runtime behavior change for the scaffold | Done | Superseded by later gated runtime; flag-off path remains the invariant |
| CCS-P0-A1 | Builds pass | Done | Last known baseline in `docs/HANDOFF_CURRENT.md` |
| CCS-P0-A2 | Architecture checker updated | Done | `script/check_architecture_blueprint.swift` |
| CCS-P0-A3 | Flag-off path unchanged | Done | Default-off tests and runtime gating |
| CCS-P0-A4 | Docs accurately state no provider background calls | Done | Reflection remains separately opt-in and budgeted |

## Phase 1 - Event Bus And Bounded Current State

| ID | Blueprint item | Status | Evidence / gap |
|---|---|---|---|
| CCS-P1-D1 | `CognitiveEvent` | Done | `CognitiveEvent.swift` |
| CCS-P1-D2 | `CognitiveSubstrate` actor | Done | `CognitiveSubstrate.swift` |
| CCS-P1-D3 | In-memory Continuity Field | Done | `ContinuityField.swift` |
| CCS-P1-D4 | Configuration | Done | `CognitiveConfiguration.swift` |
| CCS-P1-D5 | Deterministic event ingestion | Done | Injected clock/UUID tests |
| CCS-P1-D6 | Bounded snapshot | Done | Node caps and summary/metadata bounds tests |
| CCS-P1-D7 | No persistence in Phase 1 | Done | Superseded by Phase 2; persistence stays optional/gated |
| CCS-P1-D8 | No capsule injection in Phase 1 | Done | Superseded by Phase 4; injection stays optional/gated |
| CCS-P1-D9 | User message event ingress | Done | `NativeCognitiveEventFactory.turnMessage` and runtime `observeUserMessage` provide bounded redacted ingress for non-chat surfaces. CognitiveSubstrate is the sole semantic appraisal owner; organism ingress receives topology without a second lexical valence pass. |
| CCS-P1-D10 | Assistant turn completed event ingress | Done | `NativeCognitiveEventFactory.turnMessage` and runtime `observeAssistantTurnCompleted` provide bounded redacted completion ingress for non-chat surfaces. Speaking alone carries no organism reward; only exact resolution/outcome evidence may change success chemistry. |
| CCS-P1-D11 | Tool succeeded/failed event ingress | Done | Structured chat and text-compat/Telegram tool progress emit bounded redacted cognitive tool-start/result events; focused chat tests cover both paths |
| CCS-P1-D12 | User correction event ingress | Done | iOS/iCloud reject/cancel/delete/dismiss actions are classified as `userCorrection` through `MacSyncActionRouter` and `NativeCognitiveEventFactory`; focused app test covers remote rejection |
| CCS-P1-D13 | Provider failure event ingress | Done | iOS/iCloud provider action failures are classified as `providerFailure` with redacted metadata; focused app test covers provider failure redaction |
| CCS-P1-D14 | Workshop execution completed event ingress | Done | `WorkshopExecutorLoop` emits terminal execution records through an injected sink and app assembly forwards to cognition; focused app test covers execution terminal event construction |
| CCS-P1-D15 | App wake/sleep event ingress | Done | `NativeCognitionRuntime.bootstrap()` and termination hooks |
| CCS-P1-A1 | Deterministic tests | Done | Focused substrate tests |
| CCS-P1-A2 | Active nodes capped | Done | Capacity eviction tests |
| CCS-P1-A3 | Idle cognition creates no periodic owner work | Mechanism done; installed resource claim pending elapsed evidence | Dirty-state microcycles return nil when no work is pending. Maintenance now projects one exact discrete lifecycle deadline; the old five-minute full checkpoint is absent and the registered daily pass is crash/integrity recovery. Residual organism repair no longer schedules an unrelated cognition microcycle. Deterministic tests prove no write at the old five-minute point, exact boundary execution, and no repair cross-poke. The v3 installed gate separately requires 24 quiescent hours, quiet CPU below 0.5%, and process wakes below 18,000/hour; those whole-process multi-day values remain installed measurements, not conclusions from mechanism tests. The three registered `cognition_*` loops all sit at 24 h and exist only as crash/integrity recovery for deadlines a process missed (`BackgroundLoopsAssembly+Cognition.swift:11/:20/:38`); `cognition_reflection` fires `demand: .spontaneous` so a quiet day spends nothing. |
| CCS-P1-A6 | Resource pressure throttles rather than starves | Done (2026-09-11) | `backgroundCognitionGate(reason:)` (`NativeCognitionRuntime.swift:2054`) refuses in order: Low Power Mode (`:2055-2065`), thermal `serious`/`critical` (`:2066-2082`), then `loopBudget` (`:2083`). Thermal precedes the conserve bookkeeping deliberately (`:2066-2069`) so a thermal refusal does not spend a lane's pass. `.sleep` refuses outright; `.conserve` is a **per-lane** throttle keyed on the reason's `<lane>:` prefix (`expensiveLaneKey`, `:2049-2052`) over reasons containing `reflection`/`replay`/`cue` (`:2096-2098`), with a guaranteed pass after `conserveExpensiveStarvationFloor = 45 min` (`:194`, enforced `:2104-2135`). Receipts `cognition.organism_loop_deferred` / `cognition.organism_loop_starvation_pass` carry `lane`, `secondsSinceLanePass`, `starvationFloorSeconds`. Measured defect named in-code (`:186-193`): one conserve evening, 90 deferrals, zero reflections. **Honest limit:** `conserveExpensivePassAt` is process memory (`:195-198`), so a relaunch grants every lane one immediate pass. |
| CCS-P1-A4 | No external calls | Done | Reflection has separate Phase 9 gate |
| CCS-P1-A5 | Flag-off parity | Done | Disabled-state tests and default-off runtime |

## Phase 2 - Persistence And Lifecycle

| ID | Blueprint item | Status | Evidence / gap |
|---|---|---|---|
| CCS-P2-D1 | GRDB schema | Done | SQLite schema now has typed node, artifact, receipt, and schema-marker tables; bounded associations remain in-memory/exported read model |
| CCS-P2-D2 | Snapshot/restore | Done | `CognitiveSQLiteStore.loadRestoreBundle` performs strict all-or-nothing node/artifact decoding. A malformed row moves `CognitiveSubstrate` into typed degraded health with writes blocked, preserves the prior in-memory state and canonical SQLite rows, records `lifecycle.restore_degraded`, and permits persistence again only after a clean retry restores the complete bundle. |
| CCS-P2-D3 | Pruning | Done | Store pruning for nodes/artifacts; artifact pruning protects bounded per-family quotas before generic age eviction, and exact thought-seed family replacement makes decay/cap removals durable across restart |
| CCS-P2-D4 | Data bounds | Done | `docs/data-bounds.md` and configuration caps |
| CCS-P2-D5 | App lifecycle hooks | Done | `NativeCognitionRuntime` bootstrap/persist hooks |
| CCS-P2-D6 | Receipts for recovery and pruning | Done | Restore receipts plus typed prune receipts in `cognitive_receipts`; focused prune receipt test |
| CCS-P2-A1 | Restart recovery | Done | `CognitivePersistenceHealthTests.partialRestoreDegradesWithoutClobberAndCleanRetryRecovers`, `sqliteReadsRejectMalformedRowsInsteadOfDroppingThem`, and `StoreBoundsTests.failedRestoreFreezesDestructivePersist` prove corrupt/partial restore fails closed, cannot overwrite source rows, and recovers only after a clean complete restore. |
| CCS-P2-A2 | Migration tests | Done | `sqliteSchemaMarkersAndPruneReceiptsAreTypedAndBounded` verifies v2 schema marker after migrator runs |
| CCS-P2-A3 | Crash-safe transactions | Done | Store writes/prunes are single GRDB write transactions with restore/prune tests over real SQLite files; thought-seed replacement, decay/cap eviction, protected-family pruning, and lifecycle receipts commit together |
| CCS-P2-A4 | No duplicate memory content | Done | Cognitive state cannot write MemoryV2 facts |
| CCS-P2-A5 | Release verifier excludes live cognition state | Done | `script/verify_release_artifact.sh` explicitly rejects `Contents/Resources/cognition` and nested cognition state dirs |

## Phase 3 - Global Workspace

| ID | Blueprint item | Status | Evidence / gap |
|---|---|---|---|
| CCS-P3-D1 | Salience scoring | Done | `workspaceScore(for:)` |
| CCS-P3-D2 | Spreading activation | Done | `ContinuityField` maintains bounded association weights and spreads activation on related event ingress |
| CCS-P3-D3 | Decay | Done | Continuity decay tests |
| CCS-P3-D4 | Lateral inhibition | Done | Duplicate-subject inhibition test |
| CCS-P3-D5 | Bounded workspace | Done | `maximumWorkspaceItems` tests |
| CCS-P3-D6 | Observatory read model | Done | Observatory displays workspace reasons plus association graph edges and rereads through payload-free `NativeCognitionRuntime` owner invalidations rather than a periodic view poll. |
| CCS-P3-A1 | Important open item persists | Done | `importantOpenConcernPersistsAcrossRestore` proves an open concern restores into workspace |
| CCS-P3-A2 | Redundant items collapse | Done | Duplicate-subject test |
| CCS-P3-A3 | Irrelevant items decay | Done | Decay tests |
| CCS-P3-A4 | Deterministic scoring tests | Done | Workspace ordering/cap tests |
| CCS-P3-A5 | Performance targets measured | Done | Focused 300-node spreading activation timing guard in `CognitiveSubstrateTests` |

## Phase 4 - Cognitive Capsule Injection

| ID | Blueprint item | Status | Evidence / gap |
|---|---|---|---|
| CCS-P4-D1 | Capsule compiler | Done | `compileCapsule` |
| CCS-P4-D2 | Stable kernel/dynamic capsule separation | Done | `CognitiveCapsule` carries stable kernel, dynamic context, provenance IDs, and combined view with cap tests |
| CCS-P4-D3 | ChatOrchestration integration | Done | Runtime context capsule injection; 2026-07-09 hardening preserves the full organism projection when only a repeated Body line is suppressed and marks a line surfaced only after budget fitting retained it. |
| CCS-P4-D4 | Streaming/non-streaming shared helpers | Done | Streaming and text-compat paths converge through `CognitiveContextProviding.prepareCapsule` and central need classifier |
| CCS-P4-D5 | Capsule trace preview | Done | Observatory capsule preview |
| CCS-P4-D6 | Strict budget enforcement | Done | Capsule cap tests |
| CCS-P4-A1 | Capsule hard cap | Done | Focused test |
| CCS-P4-A2 | No raw memory dumps | Done | Capsule only uses bounded workspace summaries |
| CCS-P4-A3 | Provenance shown | Done | Provenance node IDs and UI preview |
| CCS-P4-A4 | Provider-swap continuity eval | Done | `runResearchExperiment(.providerSwap)` compares provider variants without provider calls and records reproducible state digest |
| CCS-P4-A5 | Feature-off parity | Done | Default-off gating |
| CCS-P4-A6 | No context injected for turns that do not need it | Done | `prepareCapsuleOnlyReturnsInjectableNonEmptyCapsule` proves low-signal turns skip injection while relevant turns inject |

## Phase 5 - Post-Turn Assimilation And Prediction Ledger

| ID | Blueprint item | Status | Evidence / gap |
|---|---|---|---|
| CCS-P5-D1 | Structured outcome assimilation | Done | `CognitiveAssimilationInput/Result` produce bounded predictions, commitments, resolutions, and notes with focused tests |
| CCS-P5-D2 | Prediction candidates | Done | Statement extraction creates bounded pending predictions with due-time inference and evidence IDs |
| CCS-P5-D3 | Prediction resolution | Done | Corrections/tool observations resolve by token overlap; due pending predictions expire through `runPredictionResolution` |
| CCS-P5-D4 | Tool observation grounding | Done | Tool observations resolve matched predictions/commitments; predictions/commitments now carry source hashes and lineage IDs |
| CCS-P5-D5 | Commitment links | Done | `CognitiveCommitment` ledger links pending commitments and predictions bidirectionally |
| CCS-P5-D6 | Provisional belief handling | Done | Predictions/commitments remain provisional with no-memory-commit notes, evidence IDs, source hashes, and lineage IDs |
| CCS-P5-A1 | Predicted versus observed results recorded | Done | Focused tests cover observed, completed, expired, and overdue statuses |
| CCS-P5-A2 | Self-generated claims remain inferred | Done | Assimilated predictions/commitments default to `.inferred` with source hashes and tests |
| CCS-P5-A3 | Corrections update lineage | Done | Corrections contradict/cancel matched predictions and commitments while preserving lineage/source hashes |
| CCS-P5-A4 | No bulk automatic memory commits | Done | Memory writes are intentionally blocked |

## Phase 6 - Interoception And Affect

| ID | Blueprint item | Status | Evidence / gap |
|---|---|---|---|
| CCS-P6-D1 | Bounded state vector | Done | `CognitiveAffectState` |
| CCS-P6-D2 | Deterministic event updates | Done | Affect test with injected clock |
| CCS-P6-D3 | Causal effect on salience and planning | Done | Affect boosts workspace scoring and feeds thought-suggestion interruption scoring/capsule relevance |
| CCS-P6-D4 | Observatory visualization | Done | Observatory affect panel |
| CCS-P6-D5 | No user-facing emotional prose generated automatically | Done | Affect remains internal state |
| CCS-P6-A1 | Values remain bounded | Done | Tests |
| CCS-P6-A2 | Decay/resolution works | Done | `affectMaintenanceDecaysWithoutNewEvent` proves standalone maintenance decay |
| CCS-P6-A3 | Affect changes attention measurably | Done | Faculty measurement/export harness includes affect-bound and workspace-focus measurements |
| CCS-P6-A4 | No runaway loops | Done | Background work gated by dirty state and flags |
| CCS-P6-A5 | Ablation shows useful effect | Done | `runResearchExperiment(.ablation)` and Observatory ablation controls expose measurable ablation state |

## Phase 7 - Thought Seeds And Endogenous Cognition

| ID | Blueprint item | Status | Evidence / gap |
|---|---|---|---|
| CCS-P7-D1 | Typed thought seeds | Done | `CognitiveThoughtSeedKind` |
| CCS-P7-D2 | Wake conditions | Done | Dirty-state/affect microcycle plus prediction-resolution loop can wake neglected commitment seeds |
| CCS-P7-D3 | Merging and decay | Done | Merge/decay/cap test |
| CCS-P7-D4 | Workspace promotion | Done | `thoughtSuggestionSnapshot` promotes seeds with active workspace evidence and preserves `workspaceNodeIds` |
| CCS-P7-D5 | No autonomous provider calls yet | Done | Reflection remains separately gated |
| CCS-P7-D6 | Optional user-facing suggestions | Done | Observatory shows bounded `CognitiveThoughtSuggestion` rows when seeds clear the interruption threshold |
| CCS-P7-A1 | Low-value seeds decay | Done | Tests |
| CCS-P7-A2 | Duplicate seeds merge | Done | Tests |
| CCS-P7-A3 | Useful neglected commitments surface | Done | Overdue commitments create bounded `.neglectedCommitment` thought seeds |
| CCS-P7-A4 | Interruption scoring works | Done | `thoughtSuggestionsScoreInterruptionsAndPromoteWorkspaceSeeds` covers thresholding, workspace boost, and low-value suppression |
| CCS-P7-A5 | No direct action dispatch | Done | Actions remain outside cognitive substrate |

## Phase 8 - Replay And Developmental Self-Model

| ID | Blueprint item | Status | Evidence / gap |
|---|---|---|---|
| CCS-P8-D1 | Episode references | Done | `recordEpisode` |
| CCS-P8-D2 | Schema proposals | Done | `CognitiveSchemaProposal` ingests REM proposal rows with inspect/approve/reject controls |
| CCS-P8-D3 | Identity proposals | Done | Proposal/approve/reject flow now records developmental timeline lineage |
| CCS-P8-D4 | Integration with existing Dream/REM ownership | Done | `NativeCognitionRuntime+Replay` reads dream diary/REM proposal output without owning the scheduler or starting cycles. The `rem_cycle` background loop is retired (2026-08-31) — weekly REM has one owner, the `nativeagent-weekly-rem` TriggerScheduler job (`BackgroundLoopsAssembly+DreamsMemory.swift:23-39`). A pending REM proposal that never became an approval card gets a bounded launch catch-up, `remStagingCatchUpLimit = 10` (`:58-90`, budget actor `:493-506`): no REM batch is generated, staging stamps `approvalId` so it is idempotent, and overflow waits for the next launch or the weekly job, which runs the same uncapped pass even when it skips as `.alreadyReserved` (`REMConsolidator.swift:264`, `:629-655`). A missed dream/REM **cycle** remains a single due-now job stamp, not a replayed queue (`SchedulerDueJobRunner+Selection.swift:259-274`) |
| CCS-P8-D5 | Raw evidence preserved | Done | Replay episodes/schema proposals keep bounded external evidence IDs and lineage IDs |
| CCS-P8-D6 | Developmental timeline | Done | `CognitiveDevelopmentalTimelineEvent` plus Observatory timeline panel |
| CCS-P8-A1 | No recursive summary degradation | Done | `replayIntegrationCreatesTimelineAndDoesNotDegradeRepeatedDreams` proves repeated replay dedupes raw evidence |
| CCS-P8-A2 | Durable trait requires repeated evidence | Done | Proposal requires at least two evidence IDs |
| CCS-P8-A3 | User can inspect/reject proposals | Done | Observatory resolve controls |
| CCS-P8-A4 | Prior personality remains stable under short-term noise | Done | `replaySelfModelStaysStableUnderShortTermNoise` proves one noisy evidence item cannot create identity proposal |

## Phase 9 - Budgeted Reflective Calls

| ID | Blueprint item | Status | Evidence / gap |
|---|---|---|---|
| CCS-P9-D1 | Reflection planner | Done | `planReflection` builds bounded Opus 4.8 requests behind budget/opt-in gates |
| CCS-P9-D2 | Daily call budget | Done | Budget gate and tests |
| CCS-P9-D3 | Provider routing | Done | `cognition_reflection` pinned to `claude-opus-4-8` / `anthropic_oauth_direct` |
| CCS-P9-D4 | Cancellation | Done | `reflectionCancellationRecordsReceiptWithoutProposalsAndConsumesBudget` proves cancelled calls write receipts, create no proposals, and consume budget |
| CCS-P9-D5 | Receipts | Done | Reflection receipts |
| CCS-P9-D6 | Reflection result provenance | Done | Receipts carry provider/model/token estimates/proposal IDs; parsed proposals link to `reflection:<receipt>` lineage. **The evidence is the provenance of the capsule that built the prompt**, frozen when the prompt was built: `capsule.provenanceNodeIds` → `CognitiveReflectionRequest.sourceNodeIds` (`CognitiveSubstrate+Reflection.swift:77-83`, `:106`, `:128`; field doc `CognitivePhaseModels.swift:674-678`). A second `workspaceSnapshot()` read was a *different* snapshot across actor reentrancy, so a takeaway cited evidence that never fed it (Astra audit 2026-09-11 finding 7, rationale in-code `:98-105`). Out-of-substrate material quoted in the prompt — today the dream diary entry a `dreamCompleted` reflection reflects ON — rides `materialProvenance`, bounded to 200 chars (`CognitivePhaseModels.swift:682`, `+Reflection.swift:107-111`, `:129`); both flow into the minted takeaway's evidence (`:225-233`) |
| CCS-P9-D7 | Opt-in policy | Done | Explicit UserDefaults/env toggles |
| CCS-P9-A1 | Zero calls when disabled | Done | Gating tests |
| CCS-P9-A2 | No action without existing gates | Done | Reflections do not dispatch actions |
| CCS-P9-A3 | Reflection produces measurable improvement | Done | `proposalYieldScore` measures proposal yield per bounded cost unit and is tested |
| CCS-P9-A4 | Bounded cost | Done | Prompt/result caps, daily call budget, token estimates, cost units, and Observatory receipt display |
| CCS-P9-A5 | No self-reinforcing identity changes | Done | Reflection parser routes identity-looking output to review-only schema proposals; identity proposal snapshot remains empty in tests |

## Phase 10 - Consciousness Observatory And Research Harness

| ID | Blueprint item | Status | Evidence / gap |
|---|---|---|---|
| CCS-P10-D1 | Ablation controls | Done | Observatory has ablate/restore controls and `runResearchExperiment(.ablation)` |
| CCS-P10-D2 | Continuity experiments | Done | `runResearchExperiment(.continuity)` records reproducible continuity metrics |
| CCS-P10-D3 | Provider-swap experiments | Done | `runResearchExperiment(.providerSwap)` records no-call provider-variant continuity metrics |
| CCS-P10-D4 | Self-model accuracy tests | Done | `runResearchExperiment(.selfModelAccuracy)` and short-term-noise tests measure proposal-only identity stability |
| CCS-P10-D5 | Exportable research traces | Done | `exportResearchTrace` returns bounded state/measurement/experiment/timeline JSON and runtime writes it under `data/cognition/exports` |
| CCS-P10-D6 | Welfare-state bounds | Done | `CognitiveWelfareBounds` clamps affect/resource pressure and labels telemetry as non-consciousness claim |
| CCS-P10-A1 | Each claimed cognitive faculty has a measurement | Done | `facultyMeasurementSnapshot` covers event continuity, workspace, capsule, predictions, affect, seeds, replay, reflection, export |
| CCS-P10-A2 | Generated explanations are distinguishable from actual state | Done | Research export separates `actualState` from empty `generatedExplanations` with explicit policy |
| CCS-P10-A3 | Experiments are reproducible | Done | `researchHarnessExportsMeasurementsAndReproducibleExperiments` proves same seed/metrics yield same key |

## Cross-Cutting Integration Gates

| ID | Blueprint item | Status | Evidence / gap |
|---|---|---|---|
| CCS-X1 | Capsule compiled after TurnPlan and before provider execution | Done | Chat runtime context hook |
| CCS-X2 | Tool event ingestion after secret redaction/result compaction | Done | `redactedProgressEvent`, text-compat redacted tool events, and tool persistence feed cognitive events only after redaction/compaction; focused tests cover raw-secret exclusion |
| CCS-X3 | Canonical loop owner for microcycle, maintenance, replay, prediction resolution | Done | `NativeCognitionRuntime` owns event-coalesced microcycle settlement, one exact cognition-maintenance deadline, and one exact residual-repair deadline. `BackgroundLoopsAssembly+Cognition` retains daily maintenance/replay crash-integrity fallbacks and the separate reflection budget cadence. There is no production cognition heartbeat. |
| CCS-X4 | Suspend/reduce under low power, memory pressure, no state change, disabled flag, migration/recovery | Done | Background runtime skips cognition work under low-power mode or serious/critical thermal pressure; core still gates disabled/no-dirty states |
| CCS-X5 | Observatory displays focus, why items won, graph, affect, seeds, predictions, tensions, capsule, receipts, identity, lineage, replay, pruning | Done | Observatory includes focus/reasons, graph edges, affect, seeds/suggestions, predictions, tensions/pruning caps, capsule, receipts, identity/schema, replay timeline/lineage |
| CCS-X6 | Observatory controls pause, clear, provenance, correct belief, reject identity, pin concern, budget, export, ablation | Done | Controls include toggles/pause, clear, budget, schema/identity reject, pin concern, export, ablate/restore, and provenance/lineage panels |
| CCS-X7 | Continuity identity lineage (`subject_id`, `lineage_id`, `instance_id`, fork metadata) | Done | Developmental timeline events carry `lineageId`, `subjectId`, `instanceId`, fork metadata, and external evidence IDs |
| CCS-X8 | MemoryV2/KG narrow protocol integration | Done | `CognitiveMemoryReading`/`CognitiveKnowledgeGraphReading` protocols, app adapters over MemoryV2/KG, and explicit MemoryV2 proposal-candidate staging preserve no automatic durable writes |
| CCS-X9 | No cognitive-state direct tool dispatch | Intentional boundary | Tool dispatch remains owned by Trust/Security/Mac/tool chokepoints |
| CCS-X10 | Organism reflex review uses the app-owned runtime and durable audit receipts | Done | Lazy `reflex_review` routes approve/hold/reject through transactional `NativeCognitionRuntime.applyOrganismReflexReview`; bounded who/when/what receipts persist with organism continuity and mirror into `organism.reflex_review` cognitive receipts. `OrganismReflexTests`, `OrganismPersistenceTests`, and `AppChatToolDispatcherTests` cover transitions, permanent rejection, backward decode, receipt round-trip, schema, and dispatch. |
| CCS-X11 | Organism residual repair is analytic, local, and authority-free | Done | `OrganismLivingDynamics` derives exact sleep pressure and one next meaningful deadline from prediction, surprise, contradiction, field, and calibration residuals. Local repair touches only named organism field tissue; operational calibration is generated/frozen advisory evidence; identity/Dream lanes retain their existing approval and provider-budget gates. No lane can write prompts, MemoryV2, actions, notifications, identity, provider selection, or permission. Restart refractory, resource inhibition, neutral-zero-work, bounded-target, and delayed-clock regressions pass. |
| CCS-X12 | Capability and procedure learning remain evidence-shaped and review-bound | Done | Capability belief is Beta-smoothed over exact prediction outcomes; expiry adds uncertainty rather than failure. Procedure candidates aggregate bounded reflex evidence. `ProcedureCompilation` may admit invariant repeated GitHub/Workshop trajectories into an immutable declarative replay policy, but emits no code, owns no activation, rechecks current reducer/TrustCenter/approval preconditions, and falls back deterministically. |
| CCS-X13 | Provider-path belief remains transient and cannot become provider reality | Done | Exact provider lifecycle evidence feeds one bounded freshness/uncertainty belief with hashed IDs, hostile-decode rederivation, future/nonfinite rejection, and duplicate bounds. Persistence intentionally omits it; lifecycle changes clear it; no provider-selection consumer exists. |
| CCS-X14 | Body beliefs distinguish reality, evidence, freshness, uncertainty, and expiry | Done | `OrganismTypedBodyBeliefs` projects peer presence, notification delivery, memory/dream integrity, tool capability, approval path, and resource state from typed bounded evidence. APNS acceptance never becomes delivery/seen proof; configured tools are not live success; hostile/future/nonfinite/duplicate evidence fails closed; injected-root isolation and domain ablations pass. |
| CCS-X15 | Causal self-model accepts interventions, not correlations | Done | `CausalOperationalSelfModel` fits bounded conditional effects only from immutable controlled assignments and complete outcomes, abstains under weak/novel/drift evidence, and has no prompt/tool/provider/action/permission/identity consumer. Observational rows remain association-only. |
| CCS-X16 | Automatic reasoning-effort modulation does not enter production | Rejected/removed | The experiment store, ApprovalInbox activation seam, pre-provider resolver, bootstrap, and terminal reconciliation were removed. Manual provider/model/effort selection remains authoritative. Historical comparison receipts may be inspected, but no dormant controller, assignment store, or activation path ships. |
| CCS-X17 | Turn attention stays resident, bounded, cancellation-aware, and observable | Done | `CognitiveAttentionResidentProjection` receives bounded substrate, organism predicted-tool-group, and pursuit snapshots at their existing mutation boundaries. The turn path performs one lock-backed read with no actor hop, bootstrap, Desk I/O, model work, or task creation; focused bootstrap/replay timing coverage holds the read below 50 ms. Existing `context.summary` receipts remain payload-free, and timeout cancellation is checked across each live owner boundary. |
| CCS-X18 | Canonical resident work state re-enters context only on relevant evidence | Done | `NativeResidentWorkContextProjection` rebuilds bounded advisory Fluid Context from canonical Desk and linked Workshop records. `NativeContextFlowRuntime` uses exact-path filesystem events rather than polling; projection identifiers and namespaces prevent Workshop evidence from replaying MemoryV2 or unrelated sources. Deterministic tests cover relevance omission, event-driven settlement, zero provider planning calls, and restart recovery. Workshop completion may close Desk only after recorded verification; otherwise canonical work remains review-bound. |
| CCS-X19 | Ordinary turns consume one fixed-time cognition/organism projection | Done | `CognitiveTurnProjection` is an immutable turn-scoped value, not a state owner. `NativeCognitionRuntime` samples body state once, projects canonical warmth/pressure at the same injected time, refreshes and freezes OrganismKernel in one admission, and compiles the capsule from that frozen organism projection. Structured and Anthropic text-compatible paths consume the same capsule/posture value once and commit presentation-only surfaced bookkeeping only after runtime context was appended. Focused tests prove one preparation/one commit on both paths, exact timestamp parity, and no prepare-time surfacing. Trust, tools, provider routing, memory, and effect-time authority remain unchanged. |

## Next Execution Order

All tracked cognitive-substrate blueprint rows in this ledger are complete as of
the current implementation. Future work should add new row IDs before claiming
new substrate behavior.
