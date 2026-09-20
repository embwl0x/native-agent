# ActivityWatch ground truth

Run the existing ActivityWatch regression suite from the repository root:

```bash
swift test --disable-keychain --package-path Modules/NativeAgentCore --filter ActivityWatchTests
```

`groundTruthTimelineExecutesExactly` in
`Modules/NativeAgentCore/Tests/ActivityWatchTests/ActivityProductionBoundaryTests.swift`
replays `ground_truth_script.json` through the real `ActivitySimulator` and
`ActivitySpanStore` in a temporary directory. It checks seven spans, exact
timestamps, close reasons, title redaction, capture exclusions, and positive
durations. The last span remains open after the simulated crash.

`reconcileClosesAtLastSeen` in `ActivitySpanStoreTests.swift` separately checks
that startup reconciliation closes an abandoned span at `last_seen_at`, rather
than at the next launch time, and that repeated reconciliation is idempotent.

These are deterministic simulation and persistence tests. They do not prove
live Accessibility capture or a human's real activity rate.
