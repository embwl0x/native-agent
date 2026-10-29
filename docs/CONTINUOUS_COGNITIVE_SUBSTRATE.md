# NativeAgent Continuous Cognitive Substrate

## Engineering and Research Blueprint for a Persistent Artificial Subject

## 0. Purpose

Carry bounded identity-relevant state, attention and feeling between model
calls, and project only what a turn needs into context. The model supplies
language and reasoning; the continuing state has Swift owners inside
NativeAgent's core.

This document defines the current engineering boundaries. The
[Subconscious map](SUBCONSCIOUS.md) explains mechanisms and evidence limits;
[Cognition Wiring](COGNITION_WIRING.md) connects their owners.
Research objectives are not claims of consciousness or
measured cognitive benefit.

## Implementation Status

The implementation is in `Modules/NativeAgentCore/Sources/CognitiveSubstrate/`
and `Modules/NativeAgentCore/Sources/Cognition/`.
`EngineRuntime/NativeAgentEngine.swift` constructs the cognition runtime
using host ports. Core's `ChatTurnRuntime` consumes its turn projection.
The Mac app supplies the host and UI: one brain, many doors.

`NativeCognitionRuntime.loadConfiguration` defaults the master, capsule
and background switches to enabled. Persistence, workspace, affect, cares
and replay follow the master. Reflection has a separate enable preference
and cost ceiling. After onboarding with a configured chat provider, when
the master preference is absent, `initializeMissingInnerLifePreferences`
initializes missing inner-life choices, including reflection with a ceiling
of two calls. This initialization preserves saved choices.

The source supports event ingestion, persistence, workspace selection,
capsules, affect, cares, replay and reflection. It does not support the
old text-extracted task prediction/commitment system.
The live Observatory remains available at **Diagnostics → Cognition**, including
its workspace inclusion controls. The count-based experiment lifecycle, faculty
ratings, research checks panel and research-export controls are retired. SQLite migration
`v6_retire_cognitive_experiments` removes only their `experiment` artifacts;
living cognition, canonical memory/persona and other receipts retain their format.

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
- **Thought is not action authority:** the substrate's capsule, care and
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

## 2. Mechanism owners

[SUBCONSCIOUS](SUBCONSCIOUS.md) owns event admission, state bounds, checked
restore, frozen capsules, reflection and inspection. [COGNITION_WIRING](COGNITION_WIRING.md)
owns turn connections, background admission and authority boundaries.
`CognitiveSubstrate.frozenRead` and `NativeCognitionRuntime.prepareTurnProjection`
are the fixed-time read owners; the loop's confirmed-delivery boundary commits presentation.

## 3. Evidence limits

Inner-state and diagnostic readings expose the mechanisms they read. They
do not establish consciousness, causal behavioral benefit or provider agreement.
The removed experiment ratings had no measured before/after outcome.

Source inspection does not replace installed verification.
Documentation changes require text readback.
Runtime changes follow the repository's build, install and bounded
working-app check rule.
