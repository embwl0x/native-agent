# Changelog

Public releases of NativeAgent. Download: the latest notarized DMG is on
the [releases page](https://github.com/embwl0x/native-agent/releases);
installed apps update in place via Sparkle (Check for Updates…).

## 0.3.8 — 2026-08-06

Reliability and polish release.

**Fixes**
- The agent's USER.md identity document now contains only facts about the
  user — the agent's own work journal and operational notes no longer
  crowd it out (they remain in memory, just not in the doc that rides
  every prompt).
- ⌘K opens the Workshop command palette even when the bench has keyboard
  focus.
- Chat: history compaction is budget-capped and tool activity summaries
  are bounded, keeping long sessions responsive.
- Sync: completion markers can no longer be evicted from the
  processed-message cap, eliminating a rare repeat-command path on
  Mac↔iPhone sync.
- Approvals: remote approval actions are strictly validated and fail
  closed.
- Background loops: event-listener liveness is now tracked; failure
  streaks page instead of staying silent.

**Improvements**
- Trust Center copy describes what each setting actually permits, and
  only ever understates permissiveness.
- Desk quick actions route through the same gated tool dispatch as chat,
  with a real approval record per click.
- iOS: sync errors and Mac status surface directly in the app.
- Context assembly budgets derive from the model's real window with
  provably bounded ceilings.
- Internal wire vocabulary unified (execution.json; legacy state migrates
  automatically).

## 0.3.7 — 2026-08-03

- First widely-announced public build: notarized DMG, Sparkle update
  feed, scrubbed public source snapshot.

## 0.3.3 — 2026-08-03

- Early public iteration: packaging and update-feed fixes.

## 0.3.2 — 2026-08-01

- Initial public release lane: Developer ID signing, notarization, DMG
  builder, appcast.
