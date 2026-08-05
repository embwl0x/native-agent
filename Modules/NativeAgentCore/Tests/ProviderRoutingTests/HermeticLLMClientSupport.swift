import Foundation

// MARK: - Hermetic LLM-client catalog root helper (test hermeticity)
//
// `SwiftNativeLLMClient(...)` defaults `moonshotCatalogDataRoot:` to
// `PersistenceCore.defaultDataRoot()`, which under `swift test` resolves to the
// LIVE data root (the repo's `data/` via the CWD walk-up, or
// ~/Library/Application Support/NativeAgent). A bare construction therefore
// reads the user's real Moonshot model catalog, making outcomes depend on the
// machine. Every construction in this target pins it to a fresh temp dir.
//
// Helpers do not cross target boundaries; same convention as
// ChatOrchestrationTests/HermeticTrustSupport.swift.
func hermeticMoonshotCatalogDataRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProviderRoutingTests-moonshotCatalog-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
