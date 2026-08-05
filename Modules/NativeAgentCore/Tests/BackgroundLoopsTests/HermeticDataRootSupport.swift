import Foundation

// MARK: - Hermetic data-root helper (test hermeticity)
//
// Several BackgroundLoops types (`GoldenEvalLoop`, `SelfHealingHook`,
// `WeeklySelfImprovementLoop`, …) default their `dataRoot:` to
// `PersistenceCore.defaultDataRoot()`, which under `swift test` resolves to the
// LIVE data root (the repo's `data/` via the CWD walk-up, or
// ~/Library/Application Support/NativeAgent) — so a bare construction reads and
// can write the user's real state. Every construction in this target pins
// `dataRoot:` to a fresh, unique temp dir instead.
//
// Helpers do not cross target boundaries; same convention as
// ChatOrchestrationTests/HermeticTrustSupport.swift.
func hermeticDataRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackgroundLoopsTests-data-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
