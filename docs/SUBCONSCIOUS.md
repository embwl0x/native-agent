# The Subconscious & Personality System

This is the source map for Agent's carried inner state: attention, affect,
mood, views, reflection and their bounded expression in a turn. It describes
implemented mechanisms, not proof of subjective experience or reply quality.
For the engineering contract see [Continuous Cognitive Substrate](CONTINUOUS_COGNITIVE_SUBSTRATE.md);
for individual implementation claims see the [traceability ledger](COGNITIVE_SUBSTRATE_TRACEABILITY.md).

Core paths below are relative to `Modules/NativeAgentCore/Sources/`.
Unqualified substrate files live in `CognitiveSubstrate/`; runtime extensions
live in `Cognition/`. App paths start with `Sources/NativeAgentApp/`.

## The one-page mental model

`EngineRuntime/NativeAgentEngine.swift` assembles `NativeCognitionRuntime`
from Core's `Cognition` module with the app's host ports. The runtime joins
two state owners:

| Owner | What it carries |
|---|---|
| `CognitiveSubstrate/CognitiveSubstrate.swift` | Continuity field, affect, thought seeds, standing views, disposition, replay references and reflection receipts |
| `CognitiveSubstrate/Organism/OrganismKernel.swift` | Somatic state and the body projection used in a turn |

`NativeCognitionRuntime.observe` feeds a cognitive event into the substrate
and somatic adapter. Accepted changes schedule coalesced settlement and publish
a runtime invalidation. Exact duplicate events return without new settlement.
Body-only signals enter through `NativeCognitionRuntime+Organism.swift`.

Before an ordinary provider call, `prepareTurnProjection` samples the body
and canonical affect at one fixed time, freezes the organism projection, and
prepares a capsule from that state. Core's
`ChatTurnRuntime/ChatOrchestrationClient+StructuredChat.swift` appends the
projection and commits its presentation bookkeeping after a successful turn.
Thrown turns leave that presentation window unconsumed. Preparing a preview
does not itself mean the model received it.

## Inputs and interpretation

`ChatTurnRuntime/ChatOrchestrationClient+MessagePersistence.swift` supplies
message and tool-result observations; `Cognition/NativeCognitionRuntime+Events.swift`
adapts remote actions, motor outcomes and provider lifecycle evidence.
`CognitiveSubstrate/CognitiveEvent.swift` defines their types and provenance.

The `CognitiveTurnKind.contributesToLivedState` switch admits live and system
events; debug, verification and mechanical kinds do not contribute to lived
affect. Mechanical row metadata identifies generated card copy, system notices
and compaction summaries without treating their
wording as Agent's own experience.

Interpretation is not all a lexical scan at ingress. In
`CognitiveSubstrate+Ingest.swift`, eligible conversational user events defer
interpretation to the after-turn path. `NativeCognitionRuntime.refreshConfiguration`
connects that path to `AdaptiveMemoryPromoter`, then applies the returned
appraisal through `finishAfterTurn`. Caring verdicts reach the organism
through a separate admission callback. The implementation lives in
`CognitiveSubstrate+CaringAppraisal.swift`, `+CaringEvent.swift` and
`Organism/OrganismCaringEvent.swift`.

## What persists and what is derived

| Layer | Current mechanism and source |
|---|---|
| Working attention | `ContinuityField.swift` bounds nodes, decays activation and spreads associations. `CognitiveSubstrate+Workspace.swift` selects a bounded set, inhibits redundant candidates and records selection reasons. This internal cognitive workspace is a read model. |
| Affect | `CognitiveSubstrate+Affect.swift` updates and analytically decays arousal, uncertainty, task pressure and social warmth. |
| Mood and disposition | `CognitiveSubstrate+Mood.swift` derives mood from tagged nodes and current affect; a persisted disposition adds a slower undertone. |
| Personality dynamics | `PersonalityDynamicsConfiguration.swift` holds numeric rates, thresholds and cadence; selected trait dials adjust earned warmth, delivery brevity and play weight. It does not supply persona prose. |
| Thought seeds and rumination | `CognitiveSubstrate+ThoughtSeeds.swift` merges, decays and ranks seeds. `+Rumination.swift` carries unresolved pressure and release bookkeeping. |
| Standing views | `CognitiveSubstrate+StandingViews.swift` owns proposed, held, active and retired states. It caps held and active views at five each; proposed views at twelve. |
| Replay | `Cognition/NativeCognitionRuntime+Replay.swift` reads Dream diary and REM proposal records. `CognitiveSubstrate+Replay.swift` integrates bounded references and developmental lineage with deduplication and checked persistence. |
| Reflection | `CognitiveSubstrate+Reflection.swift` plans and records bounded reflection; `Cognition/NativeCognitionRuntime+Reflection.swift` owns provider execution and its result. |

The runtime's configured limits are 256 active nodes, 12 workspace items,
64 thought seeds and a 4,000-character capsule ceiling
(`NativeCognitionRuntime.loadConfiguration`). A caller can request a smaller
capsule.

Cognitive persistence is `<dataRoot>/cognition/cognition.sqlite`, owned by
`CognitiveSQLiteStore.swift`. `CognitiveSubstrate+Restore.swift` validates
the restore bundle before applying it and blocks state writes when restoration
fails. This is continuity state, not another canonical fact or persona store.

## What reaches the model

`CognitiveSubstrate+Capsule.swift` fits a selected expression of current
state into the requested budget. Its helpers own distinct projections:

- `+FeltFingerprint.swift` and `+CapsuleFeltSignals.swift`: feeling words
  and their aboutness; unavailable dimensions remain optional.
- `+CapsuleCadence.swift`: Inner-line selection, repetition limits and
  session continuity.
- `+CapsuleSoundEcho.swift`: bounded self-exemplar selection and verbal
  repetition cues.

These are projections of the same state, not additional persona owners.
`Cognition/CognitiveAttentionResidentProjection.swift` separately publishes
a lock-backed attention read for context selection, without fetching the
whole substrate during that read.

## Between turns

`NativeCognitionRuntime` coalesces dirty event bursts with a 0.25-second
delay. `NativeCognitionRuntime+Deadlines.swift` owns maintenance and residual
repair deadlines; continuous decay is projected at read time. App assembly
retains daily maintenance, replay and reflection registrations as recovery
sweeps (`Sources/NativeAgentApp/BackgroundLoopsAssembly+Cognition.swift`).

Reflection has an enable switch, an in-flight reservation and a rolling
24-hour call ceiling. Spontaneous reflection also requires unresolved load;
requested reflection bypasses that load threshold, not the cost ceiling.
Its model/provider comes from checked `cognition_reflection` routing, not
a fixed model name.

Low Power Mode, serious/critical thermal pressure and a sleeping organism
posture can defer background cognition. Conserve posture throttles expensive
lanes with a 45-minute starvation floor. These are admission rules, not a
measurement of idle CPU or long-term usefulness.

### Reach notification privacy

`Cognition/NativeCognitionRuntime+Reach.swift` owns the notification after
Agent posts an authored reply to User's conversation. Its neutral push body is
“Left you something in chat. No reply needed.” It points to chat without
including the reply or conversation-derived seed text. If the conversation
is User's Telegram DM, Reach instead sends the authored reply there, with no
additional push. Telegram delivery therefore carries their reply text; the
neutral lock-screen/APNS body does not.

### Their hour

Enable the hour switch in Setup (`Sources/NativeAgentApp/SetupView.swift`);
`studioWanderEnabled` defaults off and requires Subconscious. Configure its
provider/model under **Providers → Memory and mind**, which owns **Creative
exploration**. `BackgroundLoops/StudioWanderLane.swift`
enforces explicit enablement, the Subconscious master, and onboarding clearance
for public-safe builds in `resolveInstallation`.

## Reading and acting on them state

Agent reaches this through them one `app` tool:

```json
{"action":"mind.inner_state","args":{"detail":"compact"}}
```

`app {}` is home; `app {"page":"personality"}` reads that page, and
`find` discovers actions. `AppToolRuntime/AppActionRegistry.swift` declares
the inner-state action and `ToolRegistry/ToolNameAliases.swift` maps its
internal implementation name. `CognitiveSubstrate+InnerState.swift` bounds
the returned record; it is an inspection, not a fresh model interpretation.

Standing-view transitions use `mind.hold_view`, `mind.release_view` and
`mind.approve_view` through the same door. Holding/releasing has its own
live-turn provenance check in
`ChatToolRuntime/SwiftToolDispatcher+StandingViewTools.swift`.
Approval authority comes from the current action and Trust policy; do not
infer it from a view's strength or the capsule's wording.

Bridge clients use `GET /standing_views` and `POST /standing_views/resolve`,
implemented in `Sources/NativeAgentApp/ClaudeBridge+StandingViews.swift`.
GET returns a `standingViews` array of `{id,status,body}` records, ordered
active, held, proposed, with body previews capped at 80 characters; retired
views are omitted. POST accepts `{id,action}`, where action is
`approve | reject | retire`. Approve/reject require proposed status; retire
requires active/held. Invalid status transitions return 409 with
`not_awaiting_review` for approve/reject or `not_leaning` for retire.

The human-facing Observatory is
`Sources/NativeAgentApp/CognitionObservatoryView.swift`. It subscribes to
owner changes and exposes the runtime's last committed live capsule separately
from inspection reads. Its counters and research exports describe state;
they do not establish consciousness, behavioral benefit or provider agreement.

## Where to verify

These diagnostic and recovery paths are relative to `<dataRoot>`:

| Path | Contents |
|---|---|
| `cognition/organism_state.json` | Persisted body state and organism continuity |
| `cognition/caring_appraisals.jsonl` | Caring appraisal receipts and the body's dosing response |
| `memory/moment_receipts.jsonl` | Moment-lane outcome receipts, including abstention and extraction failures |
| `studio/wander/wander.json` | Hour/wander refractory state and trace history |
