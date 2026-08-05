import Foundation

// MARK: - Hermetic Telegram data-root helper (test hermeticity)
//
// `SwiftNativeTelegramBot()` defaults its `dataRoot:` to
// `PersistenceCore.defaultDataRoot()`, which under `swift test` resolves to the
// LIVE data root (the repo's `data/` via the CWD walk-up, or
// ~/Library/Application Support/NativeAgent). The bot reads AND writes
// `<dataRoot>/telegram/{config,state}.json` from there, so a bare construction
// makes the suite depend on — and mutate — the user's real Telegram wiring.
// Every construction in this target pins `dataRoot:` to a fresh temp dir.
//
// Helpers do not cross target boundaries; same convention as
// ChatOrchestrationTests/HermeticTrustSupport.swift.
func hermeticTelegramDataRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TelegramBotTests-data-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
