import SwiftUI
import Foundation
import CryptoKit
import NativeAgentShared
// Blueprint: | `TurnInspectorView.swift` | Device-local summary faces, bounded continuations and demanded count evidence |

enum TurnInspectorPresentation {
    static func truncationNotice(visibleCount: Int, totalCount: Int) -> String {
        "Showing \(visibleCount) of \(totalCount) turns (oldest dropped for sync size)."
    }

    static func plainDuration(wallMs: Int) -> String? {
        guard wallMs >= 0 else { return nil }
        let seconds = Int((Double(wallMs) / 1000).rounded())
        if wallMs < 1000 { return "under a second" }
        if seconds < 90 { return AliveWords.count(seconds, "second") }
        return AliveWords.count(Int((Double(seconds) / 60).rounded()), "minute")
    }
}

@MainActor private struct PhoneTurnsFaceOwner: MobileLocalFaceOwner {
    var waitingOn: String { "this iPhone's received turn summaries" }

    func readFace(_ request: FaceReadRequest) async throws -> PartFace {
        guard let file = iCloudSyncEngine.shared.turnSummaries else {
            throw PartCallError(code: "turns_not_received", message: "Waiting for a published turn summary on this iPhone.")
        }
        return try await Self.project(file, request: request)
    }

    @concurrent private static func project(_ file: TurnSummaryFile, request: FaceReadRequest) async throws -> PartFace {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(file)
        let revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let expected = request.revision, expected != revision {
            throw PartCallError(code: "collection_changed", message: "The received summaries changed; read from the current turn.")
        }
        let cursor: Int
        if let supplied = request.cursor {
            guard let value = Int(supplied), value >= 0 else {
                throw PartCallError(code: "turn_cursor_invalid", message: "The summary cursor must be a nonnegative row offset.")
            }
            cursor = value
        } else { cursor = 0 }
        if request.key == "turns" {
            guard request.expectedCall?.action == "phone.turns.read", request.expectedCall?.args["id"] == nil else {
                throw PartCallError(code: "turn_read_changed", message: "The turn collection does not match the held read.")
            }
            let anchor = request.anchor.flatMap { id in file.summaries.firstIndex { $0.id == id } }
            let start = request.cursor == nil ? anchor ?? 0 : cursor
            guard start <= file.summaries.count else {
                throw PartCallError(code: "turn_cursor_invalid", message: "The cursor is beyond the received turn summaries.")
            }
            let summaries = file.summaries.dropFirst(start).prefix(256)
            let rows = summaries.map { summary in
                PartFace.Row(id: summary.id, title: summary.surface.flatMap { $0.isEmpty ? nil : $0 } ?? "Turn",
                    detail: plainLine(summary), value: summary.llmTokens.map { $0 >= 0 ? AliveWords.count($0, "token") : "Tokens unknown" },
                    at: summary.startedAt.ISO8601Format(), expands: true,
                    read: .init("phone.turns.read", ["id": .string(summary.id)]))
            }
            let next = start.addingReportingOverflow(rows.count)
            guard !next.overflow else { throw PartCallError(code: "turn_cursor_invalid", message: "The summary cursor exceeds its range.") }
            let more: PartFace.More? = next.partialValue < file.summaries.count
                ? .init(next: String(next.partialValue), total: file.summaries.count, revision: revision,
                        read: .init("phone.turns.read")) : nil
            var footer: String?
            if file.truncated || file.totalTurnsSeen > file.summaries.count {
                footer = TurnInspectorPresentation.truncationNotice(visibleCount: file.summaries.count, totalCount: file.totalTurnsSeen)
            }
            let drawn = file.summaries.isEmpty
                ? [PartFace.Row(id: "empty", title: "The latest received summary has no turns in it.", tone: .quiet)] : rows
            return PartFace(sections: [.init(id: "turns", title: "Newest first", style: .list,
                footer: footer, rows: drawn, more: more, filter: "Filter received turns", revision: revision)])
        }
        let id: String
        let readingKinds = request.expectedCall?.action == "phone.turns.kinds"
        if readingKinds {
            guard case .string(let supplied)? = request.expectedCall?.args["id"], request.key == "turn-kinds/" + supplied else {
                throw PartCallError(code: "turn_identity_missing", message: "This summary evidence request has no turn identity.")
            }
            id = supplied
        } else {
            guard request.expectedCall?.action == "phone.turns.read",
                  case .string(let supplied)? = request.expectedCall?.args["id"], supplied == request.key else {
                throw PartCallError(code: "turn_read_changed", message: "The turn identity does not match the held read.")
            }
            id = supplied
        }
        guard let summary = file.summaries.first(where: { $0.id == id }) else {
            return .init(sections: [.init(id: "unavailable", style: .note,
                rows: [.init(id: "unavailable", title: "This turn is not in the received bounded summary.", tone: .quiet)])])
        }
        let kinds = summary.kinds.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        guard cursor <= kinds.count else {
            throw PartCallError(code: "turn_cursor_invalid", message: "The cursor is beyond this turn's received event kinds.")
        }
        let visible = kinds.dropFirst(cursor).prefix(256)
        let next = cursor.addingReportingOverflow(visible.count)
        guard !next.overflow else { throw PartCallError(code: "turn_cursor_invalid", message: "The event-kind cursor exceeds its range.") }
        let more: PartFace.More? = next.partialValue < kinds.count
            ? .init(next: String(next.partialValue), total: kinds.count, revision: revision,
                    read: .init("phone.turns.kinds", ["id": .string(id)])) : nil
        var sections = [PartFace.Section(id: "turn-kinds/" + id, title: "Event counts", style: .values,
            rows: visible.map { .init(id: $0.key, title: AliveWords.humanized($0.key),
                                     value: $0.value >= 0 ? String($0.value) : "Invalid count: \($0.value)") },
            more: more, revision: revision)]
        if !readingKinds {
            var measures = [PartFace.Row(id: "events", title: "Events", value: summary.eventCount >= 0 ? String(summary.eventCount) : "Unknown"),
                .init(id: "duration", title: "Duration", value: TurnInspectorPresentation.plainDuration(wallMs: summary.wallMs)),
                .init(id: "last", title: "Last event", at: summary.lastAt.ISO8601Format())]
            if let tokens = summary.llmTokens {
                measures.append(.init(id: "tokens", title: "Tokens", value: tokens >= 0 ? String(tokens) : "Unknown"))
            }
            if let ttft = summary.ttftMs {
                measures.append(.init(id: "first-word", title: "First word", value: ttft >= 0 ? "\(ttft) ms" : "Unknown"))
            }
            sections.insert(.init(id: "turn-measures/" + id, style: .values, rows: measures, revision: revision), at: 0)
        }
        return .init(sections: sections)
    }

    private nonisolated static func plainLine(_ summary: TurnSummaryRecord) -> String {
        let took = TurnInspectorPresentation.plainDuration(wallMs: summary.wallMs)
        let tools = summary.kinds["tool.dispatch"]
        var line = took.map { "Took \($0)" } ?? "Duration unavailable"
        if let tools, tools > 0 { line += ", with \(AliveWords.count(tools, "tool event", spelled: true))" }
        else if let tools, tools < 0 { line += ", with an invalid tool event count" }
        return line + "."
    }
}

private struct PhoneTurnsReading {
    let file: TurnSummaryFile
    let result: Result<PartFace, PartCallError>
}

struct TurnInspectorView: View {
    @State private var session = FacePageSession()
    @State private var reading: PhoneTurnsReading?
    @State private var latest = LatestRead()
    private let sync = iCloudSyncEngine.shared
    private let owner = PhoneTurnsFaceOwner()

    var body: some View {
        AlivePage(title: "Turns", line: "How my recent replies went.", freshnessGroup: "turn_summaries") {
            MobileLocalFaceRows(face: shownFace, owner: owner, session: session)
        }
        .task(id: sync.turnSummaries) { await read() }
        .task { await sync.refreshTurnSummariesSnapshot() }
        .refreshable { await sync.refreshTurnSummariesSnapshot() }
        .macSyncErrorBanner()
    }

    private var shownFace: PartFace {
        guard let reading, reading.file == sync.turnSummaries else {
            return .init(sections: [.init(id: "waiting", style: .waiting,
                rows: [.init(id: "waiting", title: sync.turnSummaries == nil
                    ? "Waiting for a published turn summary on this iPhone." : "Reading this iPhone's turn summaries…", tone: .quiet)])])
        }
        switch reading.result {
        case .success(let face): return face
        case .failure(let failure): return .init(sections: [.init(id: "failure", style: .note,
            rows: [.init(id: "failure", title: failure.message, tone: .failed)])])
        }
    }

    private func read() async {
        guard let file = sync.turnSummaries else { return }
        _ = await latest.read({
            let result: Result<PartFace, PartCallError>
            do {
                result = .success(try await owner.readFace(.init(id: UUID(), key: "turns", expectedCall: .init("phone.turns.read"))))
            } catch is CancellationError { return nil as PhoneTurnsReading? }
            catch { result = .failure(.init(code: "turns_read_failed", message: error.localizedDescription)) }
            return PhoneTurnsReading(file: file, result: result)
        }, publish: { if let value = $0 { reading = value } })
    }
}
