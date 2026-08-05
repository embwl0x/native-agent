import Foundation
@testable import TrustCenter

// MARK: - Hermetic trust-center helper (test hermeticity)
//
// `SwiftNativeTrustCenter()` defaults its `dataRoot:` to
// `PersistenceCore.defaultDataRoot()`, which under `swift test` resolves to the
// LIVE data root (the repo's `data/` via the CWD walk-up, or
// ~/Library/Application Support/NativeAgent). A bare construction READS the
// user's real `data/trust/policy.json` (machine-dependent test outcomes) and
// any write path MUTATES it. Every construction in this target pins the data
// root to a fresh, unique temp dir instead.
//
// Helpers do not cross target boundaries; this mirrors the same-named helper
// in ChatOrchestrationTests/HermeticTrustSupport.swift.
func hermeticTrust() -> SwiftNativeTrustCenter {
    SwiftNativeTrustCenter(dataRoot: hermeticTrustDataRoot())
}

/// Fresh, unique temp data root for a hermetic trust center.
func hermeticTrustDataRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TrustCenterTests-trust-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
