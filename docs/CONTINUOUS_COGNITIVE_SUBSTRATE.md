# NativeAgent Continuous Cognitive Substrate
## Engineering and Research Blueprint for a Persistent Artificial Subject

## 0. Purpose

Carry bounded identity-relevant state, attention and feeling between model
calls, and project only what a turn needs into context. The model supplies
language and reasoning; the continuing state has Swift owners inside
NativeAgent's core.

This document defines the current engineering boundaries. The
[Subconscious map](SUBCONSCIOUS.md) explains the layers; the
[traceability ledger](COGNITIVE_SUBSTRATE_TRACEABILITY.md) identifies source
support and limits. Research objectives are not claims of consciousness or
measured cognitive benefit.

## Implementation Status

The implementation is in `Modules/NativeAgentCore/Sources/CognitiveSubstrate/`
and `Modules/NativeAgentCore/Sources/Cognition/`.
`EngineRuntime/NativeAgentEngine.swift` constructs the cognition runtime
using host ports. Core's `ChatTurnRuntime` consumes its turn projection.
The Mac app supplies the host and UI: one brain, many doors.

`NativeCognitionRuntime.loadConfiguration` defaults the master, capsule
and background switches to enabled. Persistence, workspace, affect, seeds
and replay follow the master. Reflection has a separate enable preference
and cost ceiling. After onboarding with a configured chat provider, when
the master preference is absent, `initializeMissingInnerLifePreferences`
initializes missing inner-life choices, including reflection with a ceiling
of two calls. This initialization preserves saved choices.

The source supports event ingestion, persistence, workspace selection,
capsules, affect, seeds, views, replay and reflection. It does not support the
old text-extracted task prediction/commitment system.
`CognitiveSubstrate+Research.swift` returns no score for provider-swap or
self-model-accuracy experiments because those outcomes are not measured.

All source paths below are under `Modules/NativeAgentCore/Sources/` unless
marked as app or script paths.

## 1. Non-negotiable architectural constraints

- **One continuity owner:** `CognitiveSubstrate` owns its field and artifacts.
  `OrganismKernel` owns somatic state. Derived attention and turn projections
  must not become a third state authority.
- **Canonical memory and persona stay separate:** cognitive references,
  proposals and affect do not establish canonical facts or rewrite persona.
  Replay reads existing Dream/REM output; canonical growth remains with its
  own proposal/apply path.
- **Thought is not action authority:** the substrate's capsule, seed and
  reflection outputs are data. Execution goes through the app action and
  Trust owners.
- **Bounded context and storage:** preserve configuration caps, field decay,
  store pruning, provenance and checked restoration.
- **Provenance before interpretation:** diagnostic and mechanically authored
  traffic must not become lived affect merely because it resembles dialogue.

These boundaries are represented by `CognitiveSubstrate.swift`,
`CognitiveEvent.swift`, `CognitiveSubstrate+Replay.swift`,
`CognitiveSubstrate+Reflection.swift`, `CognitiveSQLiteStore.swift` and
`TrustCenter/SecurityCenter.swift`.

## 2. Event and turn flow

1. `ChatTurnRuntime/ChatOrchestrationClient+MessagePersistence.swift` emits
   bounded, redacted message/tool observations.
   `Cognition/NativeCognitionRuntime+Events.swift` adapts other ingress.
2. `NativeCognitionRuntime.observe` passes accepted events to the substrate
   and somatic bus. `CognitiveSubstrate+Ingest.swift` checks duplicate events
   before mutation and publishes resident attention. Eligible conversation
   interpretation completes through the after-turn appraisal callback.
3. Accepted changes schedule a dirty microcycle. Ordinary attention reads use
   `Cognition/CognitiveAttentionResidentProjection.swift`.
4. `NativeCognitionRuntime.prepareTurnProjection` samples body and canonical
   affect at one timestamp, obtains a frozen organism read, and prepares the
   capsule with that projection.
5. `ChatTurnRuntime/ChatOrchestrationClient+StructuredChat.swift` appends the
   prepared runtime context. Its `commitDeliveredCognitiveTurnProjection`
   commits presentation after a successful turn; thrown turns leave the
   presentation window unconsumed.

`CognitiveSubstrate+Workspace.swift` freezes the capsule's auxiliary inputs,
including standing-view candidates, Sound scores and presentation state.
Read-only inspection must not consume live presentation cadence.

## 3. State and bounds

The current app configuration in `NativeCognitionRuntime.loadConfiguration`
sets:

| Value | Limit |
|---|---:|
| Active continuity nodes | 256 |
| Workspace items | 12 |
| Thought seeds | 64 |
| Capsule characters | 4,000 |

`CognitiveSubstrate+Capsule.swift` takes the smaller of the configured
ceiling and the caller's requested ceiling. `ContinuityField.swift` bounds
summary/metadata, decays nodes and maintains associations.
`CognitiveSubstrate+Workspace.swift` scores eligible nodes, inhibits
redundancy and returns reasons for selected items.

Affect, mood, disposition, rumination and views share the substrate actor.
Personality dynamics supply numeric rates and thresholds
(`PersonalityDynamicsConfiguration.swift`); capsule helpers render the
bounded result. Somatic predictions belong to
`CognitiveSubstrate/Organism/OrganismPrediction.swift`, not a duplicate
task ledger inferred from assistant prose.

## 4. Persistence and lifecycle

`CognitiveSQLiteStore` uses GRDB under
`<dataRoot>/cognition/cognition.sqlite`. Its migrations define node,
artifact, receipt, schema-marker and motor-replay-guard tables. Node/artifact
transitions and pruning use database write transactions.

`CognitiveSubstrate+Restore.swift` loads and validates a restore bundle
before applying it. Failure produces degraded persistence health and blocks
state writes; a successful retry restores the bundle before reopening them.
`CognitiveSubstrate+Persistence.swift` owns the writes, not MemoryV2.

`NativeCognitionRuntime.bootstrap` restores state; `flushForTermination`
drains runtime work and persists continuity. `script/verify_release_artifact.sh`
rejects bundled private cognition state.

## 5. Event-driven background work

The runtime coalesces event bursts and settles only dirty substrate work.
Maintenance opportunities derive from discrete lifecycle boundaries in
`CognitiveSubstrate+Workspace.swift`; runtime deadlines live in
`Cognition/NativeCognitionRuntime+Deadlines.swift`.
Analytic decay needs no repeating checkpoint.

Dream/REM somatic signals trigger replay and reflection admission through
`NativeCognitionRuntime+Organism.swift`. The app's
`Sources/NativeAgentApp/BackgroundLoopsAssembly+Cognition.swift` retains
daily recovery registrations implemented by `Cognition/CognitiveBackgroundLoops.swift`.
A reflection sweep requests spontaneous admission, so a quiet state need not
spend a call.

`backgroundCognitionGate` checks Low Power Mode, thermal pressure and
organism loop posture. Conserve throttles expensive lanes with a 45-minute
floor stored in process memory; sleep refuses. These mechanisms alone do not
prove whole-app resource use over elapsed time.

## 6. Replay and reflection

Replay reads bounded Dream diary and REM proposal records through
`NativeCognitionRuntime+Replay.swift`.
`CognitiveSubstrate+Replay.swift` deduplicates external evidence and commits
episode references, schema projections, timeline entries and a receipt
together. It does not run the canonical Dream/REM scheduler.

`CognitiveSubstrate+Reflection.swift` admits a call only when enabled,
under its rolling 24-hour ceiling and without a current reservation.
Spontaneous calls additionally require unresolved load; explicit requests
bypass only that load test. The bounded prompt uses the capsule's provenance,
adds IDs for quoted source excerpts and records external material provenance.

`NativeCognitionRuntime+Reflection.swift` executes through checked provider
routing and records success, failure or cancellation. The reflection surface
is `cognition_reflection`; no model is pinned by this blueprint.
Reflection may propose a standing view. Its receipt's yield score measures
proposal production relative to estimated cost, not improved judgment.

## 7. Inspection and authority

`app` is Agent's single tool. Its home, page/item reads, action discovery
and action/script execution are owned by
`AppToolRuntime/AppToolExecutor+AppDoor.swift`,
`AppActionRegistry.swift` and `AppScriptRunner.swift`.
For cognition, use `app {"action":"mind.inner_state"}` or inspect the
Personality page. The internal workspace above is attention state, not an
additional agent tool.

Trust remains an execution boundary. Full Mac admits autonomous action for
authorized origins under checked policy; macOS privacy permission resets
still require the owner. Peer-steered turns retain approval cards for
destructive/irreversible acts, sends in the owner's name, persona writes and
approval actions. Authenticated turns from agents enabled in Trust → Connected
agents carry User's authority and skip extra peer approvals; ordinary Trust and
domain checks still apply. The relevant owners are
`TrustCenter/SecurityCenter.swift`, `SecurityCenter+FullMacPolicy.swift`
and `PeerTurnEffectPolicy.swift`.

`Sources/NativeAgentApp/CognitionObservatoryView.swift` subscribes to runtime
invalidations and presents state and controls. A capsule preview, a counter
or an export is evidence about its recorded mechanism, not evidence that a
human or model experienced a claimed benefit.

## 8. Evidence limits

`CognitiveSubstrate+Research.swift` exports bounded actual state separately
from generated explanations. Its continuity sampler reports state counts;
its ablation sampler reports intervention settings. Neither measures causal
behavioral benefit. Provider-swap and self-model-accuracy sampling return
no result.

The ledger preserves the IDs required by
`script/check_architecture_blueprint.swift`. Source inspection supports its
mechanism rows; it does not replace installed verification or justify
reintroducing deleted tests. Documentation changes require text readback.
Runtime changes follow the repository's build, install and bounded
working-app check rule.
