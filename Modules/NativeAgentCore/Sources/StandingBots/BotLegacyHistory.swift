import Foundation
// Blueprint: | `BotLegacyHistory.swift` | `ShelfStore`: `legacyHistory` |

public struct BotHistoryImport: Sendable {
    public let id: String
    public let text: String
    public let artifacts: [BotArtifact]
}

extension ShelfStore {
    /// Retained pre-chat shelf rows still require conversion on User's data.
    /// Original bytes are never deleted or rewritten by this reader.
    public func legacyHistory(bot: UUID, dataRoot: URL) throws -> [BotHistoryImport] {
        var material: [BotHistoryImport] = []
        for entry in try entriesByBot()[bot] ?? [] {
            try Task.checkCancellation()
            guard entry.sessionID == nil else { continue }
            let text = [entry.headline, entry.findings, entry.changedSinceLastGood,
                entry.sourceLinks.map(\.url).joined(separator: "\n"), entry.uncertainties.joined(separator: "\n")]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
            material.append(BotHistoryImport(id: "legacy-shelf-" + entry.id.uuidString,
                text: "Saved reply (\(entry.runAt))\n\n" + text, artifacts: []))
        }
        return material
    }
}
