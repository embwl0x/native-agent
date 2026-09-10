import Foundation

public struct BotHistoryImport: Sendable {
    public let id: String
    public let text: String
    public let artifacts: [BotArtifact]
}

extension ShelfStore {
    /// One-time import material. Original shelf, context and document bytes are
    /// never deleted or rewritten. Every revision has its own stable identity.
    public func legacyHistory(bot: UUID, dataRoot: URL) throws -> [BotHistoryImport] {
        var material: [BotHistoryImport] = []
        var cursor: String?
        repeat {
            try Task.checkCancellation()
            let page = try shelfRead(bot: bot, limit: 100, cursor: cursor)
            // Shelf cursors remain valid at the end for future appends. An
            // empty page, not a nil cursor, ends this finite migration read.
            if page.rows.isEmpty { break }
            for row in page.rows {
                let entry = try entry(row.id)
                guard entry.sessionID == nil else { continue }
                let text = [entry.headline, entry.findings, entry.changedSinceLastGood,
                    entry.sourceLinks.map(\.url).joined(separator: "\n"), entry.uncertainties.joined(separator: "\n")]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
                material.append(BotHistoryImport(id: "legacy-shelf-" + entry.id.uuidString,
                    text: "Saved reply (\(entry.runAt))\n\n" + text, artifacts: []))
            }
            cursor = page.nextCursor
        } while cursor != nil
        let disk = StandingBotsDisk(dataRoot: dataRoot)
        try disk.locked {
            let directory = disk.root.appendingPathComponent(bot.uuidString)
            struct Context: Decodable { let notes: String }
            if let context = try disk.read(Context.self, at: directory.appendingPathComponent("context.json")), !context.notes.isEmpty {
                material.append(BotHistoryImport(id: "legacy-context", text: context.notes, artifacts: []))
            }
            struct Reference: Decodable { let name: String; let savedAt: Date }
            struct Revision: Decodable { let reference: Reference; let content: String }
            for path in try disk.files(at: directory.appendingPathComponent("documents"), extension: "json") {
                guard let revision = try disk.read(Revision.self, at: path) else { continue }
                material.append(BotHistoryImport(id: "legacy-document-" + path.deletingPathExtension().lastPathComponent,
                    text: "Saved document: \(revision.reference.name) (\(revision.reference.savedAt))\n\n" + revision.content,
                    artifacts: [BotArtifact(name: revision.reference.name, path: path.path)]))
            }
            // Failed answers are old user work too. Import the retained text;
            // no new sidecars are produced by this runtime.
            struct FailedAnswer: Decodable { let rawOutput: String }
            for path in try disk.files(at: directory.appendingPathComponent("failed-answers"), extension: "json") {
                guard let answer = try disk.read(FailedAnswer.self, at: path), !answer.rawOutput.isEmpty else { continue }
                material.append(BotHistoryImport(id: "legacy-answer-" + path.deletingPathExtension().lastPathComponent,
                    text: answer.rawOutput, artifacts: []))
            }
        }
        return material
    }
}
