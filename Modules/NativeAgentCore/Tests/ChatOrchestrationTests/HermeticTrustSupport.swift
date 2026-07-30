import Foundation
import TrustCenter

// MARK: - Hermetic trust helper (U5 W-F test hermeticity)
//
// `SwiftNativeTrustCenter()` defaults its `dataRoot:` to
// `PersistenceCore.defaultDataRoot()`, which under `swift test` resolves to
// the LIVE app data root (~/Library/Application Support/NativeAgent). Reading
// trust policy from there — and `updateTrust` WRITING to it — pollutes the
// user's live `data/trust/policy.json` on every test run. Every bare
// `SwiftNativeTrustCenter()` construction in this suite goes through this
// helper instead, pinning the data root to a fresh, unique temp directory so
// the suite is hermetic by construction. Mirrors the makeHermeticClient
// pattern from ResearchTests (commit 988802bb).
func hermeticTrust() -> SwiftNativeTrustCenter {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ChatOrchTests-trust-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return SwiftNativeTrustCenter(dataRoot: root)
}
