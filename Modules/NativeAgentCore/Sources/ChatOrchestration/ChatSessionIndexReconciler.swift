import Foundation
import NativeAgentCore
import PersistenceCore

/// Bounded launch repair for the one unavoidable two-file chat commit window:
/// a transcript row is durable before `sessions.json` is synchronized. This
/// reconciler never rewrites transcript bytes and refuses to operate when the
/// shared index itself is damaged.
public struct ChatSessionIndexReconciliationReport: Sendable, Equatable {
    public var transcriptsExamined = 0
    public var sessionsRecovered = 0
    public var corruptTranscripts = 0
    public var skippedForBounds = 0

    public init() {}
}

public actor ChatSessionIndexReconciler {
    private let dataRoot: URL
    private let persistence: SwiftNativePersistenceCore

    public init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()
    ) {
        self.dataRoot = dataRoot
        self.persistence = persistence
    }

    public func reconcile(
        maximumFiles: Int = 256,
        maximumBytes: Int64 = 32 * 1_024 * 1_024
    ) async throws -> ChatSessionIndexReconciliationReport {
        let sessionsPath = dataRoot.appendingPathComponent("chat/sessions.json")
        let messagesDirectory = dataRoot.appendingPathComponent("chat/messages", isDirectory: true)
        guard FileManager.default.fileExists(atPath: messagesDirectory.path) else { return .init() }

        return try await persistence.withFileLock(sessionsPath) {
            var report = ChatSessionIndexReconciliationReport()
            var rows = try ChatSessionIndexFile.loadObjectRowsForMutation(at: sessionsPath)
            var knownIDs = Set(rows.compactMap { row -> String? in
                guard case .string(let raw)? = row["id"],
                      NativeAgentChatSessionID.normalizedPathComponent(raw) == raw else { return nil }
                return raw
            })

            let candidates = try FileManager.default.contentsOfDirectory(
                at: messagesDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "jsonl" }
                .sorted { lhs, rhs in
                    // Missing index rows are the repair target, so examine
                    // them before already-indexed transcripts. Otherwise the
                    // first 256 healthy historical files can permanently
                    // starve a newer orphan whose filename sorts later.
                    func priority(_ url: URL) -> Int {
                        let raw = url.deletingPathExtension().lastPathComponent
                        guard NativeAgentChatSessionID.normalizedPathComponent(raw) == raw else { return 1 }
                        return knownIDs.contains(raw) ? 2 : 0
                    }
                    let lhsPriority = priority(lhs)
                    let rhsPriority = priority(rhs)
                    if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                    return lhs.lastPathComponent < rhs.lastPathComponent
                }

            let fileLimit = max(0, maximumFiles)
            let boundedCandidates = candidates.prefix(fileLimit)
            report.skippedForBounds += max(0, candidates.count - boundedCandidates.count)

            var consumedBytes: Int64 = 0
            var recovered: [[String: JSONValue]] = []
            for transcript in boundedCandidates {
                report.transcriptsExamined += 1
                let values = try transcript.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    report.corruptTranscripts += 1
                    continue
                }
                let fileBytes = Int64(values.fileSize ?? 0)
                guard maximumBytes >= 0, fileBytes >= 0,
                      consumedBytes <= maximumBytes,
                      fileBytes <= maximumBytes - consumedBytes else {
                    report.skippedForBounds += 1
                    continue
                }
                let rawID = transcript.deletingPathExtension().lastPathComponent
                guard let sessionID = NativeAgentChatSessionID.normalizedPathComponent(rawID),
                      sessionID == rawID else {
                    report.corruptTranscripts += 1
                    continue
                }
                consumedBytes += fileBytes

                let scan = try await persistence.withFileLock(transcript) {
                    try await persistence.readJSONLReporting(transcript)
                }
                let objectRows: [[String: JSONValue]] = scan.rows.compactMap {
                    guard case .object(let object) = $0 else { return nil }
                    return object
                }
                let invalidShape = objectRows.count != scan.rows.count || objectRows.contains { object in
                    guard case .string(_)? = object["role"],
                          case .string(_)? = object["content"] else { return true }
                    if case .string(let storedSession)? = object["sessionId"] {
                        return storedSession != sessionID
                    }
                    return false
                }
                if scan.report.malformedLineCount > 0
                    || scan.report.trailingPartialLine
                    || invalidShape {
                    report.corruptTranscripts += 1
                    continue
                }
                guard !knownIDs.contains(sessionID), !objectRows.isEmpty else { continue }

                guard let createdAt = Self.string(objectRows.first?["createdAt"])
                        ?? Self.string(objectRows.first?["timestamp"]) else {
                    report.corruptTranscripts += 1
                    continue
                }
                let updatedAt = Self.string(objectRows.last?["createdAt"])
                    ?? Self.string(objectRows.last?["timestamp"])
                    ?? createdAt
                let firstUserContent = objectRows.first(where: {
                    Self.string($0["role"])?.lowercased() == "user"
                }).flatMap { Self.string($0["content"]) }
                let lastContent = objectRows.last.flatMap { Self.string($0["content"]) } ?? ""
                let source = objectRows.reversed().compactMap { Self.string($0["source"]) }.first ?? "app"
                var recoveredRow: [String: JSONValue] = [
                    "id": .string(sessionID),
                    "title": .string(Self.bounded(firstUserContent ?? "Recovered Chat", to: 80)),
                    "source": .string(source),
                    "createdAt": .string(createdAt),
                    "updatedAt": .string(updatedAt),
                    "archived": .bool(false),
                    "messageCount": .int(Int64(objectRows.count)),
                    "summary": .string(""),
                ]
                let preview = Self.bounded(lastContent, to: 160)
                if !preview.isEmpty { recoveredRow["lastMessagePreview"] = .string(preview) }
                recovered.append(recoveredRow)
                knownIDs.insert(sessionID)
                report.sessionsRecovered += 1
            }

            if !recovered.isEmpty {
                recovered.sort {
                    (Self.string($0["updatedAt"]) ?? "") > (Self.string($1["updatedAt"]) ?? "")
                }
                rows.insert(contentsOf: recovered, at: 0)
                let data = try ChatSessionIndexFile.serializedData(for: rows)
                try await persistence.writeDataAtomicDurable(data, to: sessionsPath)
            }
            return report
        }
    }

    private nonisolated static func string(_ value: JSONValue?) -> String? {
        guard case .string(let raw)? = value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func bounded(_ raw: String, to limit: Int) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count <= limit ? clean : String(clean.prefix(limit)) + "…"
    }
}
