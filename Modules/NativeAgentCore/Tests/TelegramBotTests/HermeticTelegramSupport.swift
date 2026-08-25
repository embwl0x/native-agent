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

// MARK: - Feed readers for the coverage-ledger evals
//
// The Telegram fence's silent failures are almost all "a row that should have
// been written wasn't" (dropped row) or "a row that should NOT have been
// written was" (dead control). Both are read back off the temp dataRoot, never
// off the live tree — same hermeticity contract as `hermeticTelegramDataRoot`.

import PersistenceCore

/// Rows of `<dataRoot>/telegram/<name>.jsonl`, or `[]` when the feed was never
/// written. Missing-file MUST read as empty, not as a failure: "no row" is the
/// exact outcome several of these evals assert.
func telegramFeedRows(root: URL, _ name: String) async -> [[String: JSONValue]] {
    let path = root
        .appendingPathComponent("telegram", isDirectory: true)
        .appendingPathComponent("\(name).jsonl")
    let rows = (try? await SwiftNativePersistenceCore().readJSONL(path)) ?? []
    return rows.compactMap { row in
        guard case .object(let obj) = row else { return nil }
        return obj
    }
}

func telegramFeedStrings(_ rows: [[String: JSONValue]], _ key: String) -> [String] {
    rows.compactMap { row in
        guard case .string(let value)? = row[key] else { return nil }
        return value
    }
}
