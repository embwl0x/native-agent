import ChatToolRuntime
import ChatToolParsing
import AuthoredCapabilities
import Foundation
import NativeAgentShared
import StandingBots
// Blueprint: | `BotsFace.swift` | Helpers face over the helper owner's published memory; Run once and Paused return to the canonical owners |

@MainActor enum BotsFace {
    private static let timestamp = ISO8601DateFormatter()
    @MainActor static func reader(_ engine: NativeAgentEngine) -> PartFaces.Read {
        engine.contactThreads.startHelpers(engine: engine)
        return { try read(engine) }
    }

    @MainActor static func read(_ engine: NativeAgentEngine) throws -> (face: PartFace, epoch: UInt64) {
        let epoch = UInt64(Date().timeIntervalSince1970 * 1000)
        let owner = engine.contactThreads
        if let problem = owner.helpersRefreshError {
            throw PartCallError(code: "helpers_unavailable", message: problem)
        }
        guard owner.helpersLoaded, let unattended = owner.helpersUnattended else {
            throw PartCallError(code: "helpers_unread", message: "Helpers are still being read. Their definitions and run history are kept.")
        }
        let records = owner.helpers
        let transcripts = engine.transcripts
        let indexProblem = transcripts.sessionIndexError
            ?? (transcripts.hasLoadedSessionIndex ? nil : "The conversation index is still being read.")
        let sessions = indexProblem == nil ? Set(transcripts.sessions.map(\.id)) : []
        var sections: [PartFace.Section] = []
        for record in records {
            sections += helper(record, sessions: sessions, indexProblem: indexProblem)
        }
        let count = records.count
        var line = count == 0 ? "No helpers yet." : "\(count) \(count == 1 ? "helper" : "helpers")."
        if !unattended { line += " Scheduled and event runs are off." }
        let missed = records.filter { $0.missed != nil }.count
        if missed > 0 { line += " \(missed) \(missed == 1 ? "helper has" : "helpers have") a missed run." }
        var notes: [PartFace.Row] = []
        if !unattended { notes.append(.init(id: "unattended", title: BotsShelfUnattended.pageLine, tone: .attention)) }
        notes.append(.init(id: "make-or-change", title: "To make a helper or change one, tell me in chat."))
        sections.append(.init(id: "helpers-note", style: .note, rows: notes))
        return (.init(title: "Helpers", line: line, sections: sections), epoch)
    }

    private static func helper(_ record: BotsShelfRecord, sessions: Set<String>, indexProblem: String?) -> [PartFace.Section] {
        let bot = record.definition, id = bot.id.uuidString
        let issue = record.modelChoiceIssue ?? bot.modelChoiceProblem
        let conversation = sessions.contains(bot.sessionID)
        var detail: [String] = []
        if let issue { detail.append(issue + " Tell me in chat to change this helper.") }
        if let issue = record.runReadIssue { detail.append(issue) }
        // The schedule line carries the cadence and the next run in words, so the model choice is named on its own.
        detail += [record.statusWord, bot.modelSelection(currentModel: record.followingModel), record.scheduleLine]
        if let indexProblem { detail.append(indexProblem) }
        else if !conversation { detail.append("No conversation yet — Run once, or tell me in chat.") }
        var rows: [PartFace.Row] = [
            .init(id: id, title: bot.name, detail: detail.joined(separator: " · "), value: timingKind(bot),
                at: record.running ? record.startedAt.map(absolute) : nil,
                symbol: bot.eventTrigger != nil ? "bolt" : bot.cadence == .manual ? "wrench.and.screwdriver" : "clock",
                tone: record.running ? .live : issue != nil || indexProblem != nil ? .attention : tone(record.status),
                open: issue == nil && conversation ? "chat:" + bot.sessionID : nil,
                actions: [.init(id: "bot.run_once", label: "Run once", role: .primary)])
        ]
        if bot.cadence != .manual || bot.eventTrigger != nil || bot.paused {
            rows.append(.init(id: id + "/paused", title: "Paused", detail: "Scheduled and event work; Run once remains available.",
                control: .toggle(bot.paused)))
        }
        if let wake = record.wakeLine { rows.append(.init(id: id + "/wake", title: "Wake", detail: wake)) }
        if let missed = record.missed {
            rows.append(.init(id: id + "/missed", title: "Missed run", detail: missed.words, at: absolute(missed.dueAt), tone: .attention))
        }
        let runs = record.sortedEntries.prefix(5).map { entry -> PartFace.Row in
            var words = [entry.runtimeStatus.rawValue, String(format: "%.1fs", entry.spend.seconds), entry.model ?? "Model not recorded"]
            if let cause = entry.statusDetail { words.append(cause) }
            else if entry.runtimeStatus != .completed {
                words.append(entry.uncertainties.isEmpty ? "Cause not recorded." : entry.uncertainties.joined(separator: " · "))
            }
            let session = entry.sessionID
            if let indexProblem { words.append(indexProblem) }
            else if session == nil { words.append("Conversation not recorded.") }
            return .init(id: entry.id.uuidString, title: headline(entry), detail: words.joined(separator: " · "),
                at: absolute(entry.runAt), tone: runTone(entry.runtimeStatus),
                open: session.flatMap { sessions.contains($0) ? "chat:" + $0 : nil })
        }
        return [
            .init(id: id, title: bot.name, style: .list, rows: rows),
            .init(id: id + "/brief", title: bot.name + " · Brief", style: .note,
                rows: [.init(id: id + "/job", title: bot.brief)]),
            .init(id: id + "/runs", title: bot.name + " · Latest runs", style: .timeline,
                footer: record.entries.count > 5 ? "Earlier runs are in the helper's conversation." : nil,
                rows: runs.isEmpty ? [.init(id: id + "/no-runs", title: "No runs yet.", tone: .quiet)] : runs)
        ]
    }

    @MainActor static func act(_ engine: NativeAgentEngine, row: String, action: String, value: String?) async throws -> String? {
        do { return try await perform(engine, row: row, action: action, value: value) }
        catch let error as PartCallError { throw error }
        catch { throw PartCallError(code: "helper_action_failed", message: ChatToolOutcome.errorMessage(error)) }
    }

    @MainActor private static func perform(_ engine: NativeAgentEngine, row: String, action: String, value: String?) async throws -> String? {
        let pieces = row.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = pieces.first, let id = UUID(uuidString: String(first)), pieces.count <= 2 else {
            throw PartCallError(code: "helper_row", message: "Choose a helper's Run once or Paused row on Helpers.")
        }
        let store = BotDefinitionStore(dataRoot: engine.dataRoot)
        let bot = try await Task.detached { try store.get(id) }.value
        guard bot.deleted != true else {
            throw PartCallError(code: "helper_unavailable", message: "This helper was deleted. Read Helpers again; its saved replies are kept.")
        }
        switch action {
        case "bot.run_once" where pieces.count == 1:
            let request = try await BotRunConversation.enqueueRequestedCheck(botID: id, dataRoot: engine.dataRoot)
            return "Run request: " + request.uuidString + ". Its reply stays in this helper's conversation."
        case "set" where pieces.count == 2 && pieces[1] == "paused":
            guard value == "on" || value == "off" else {
                throw PartCallError(code: "paused_value", message: "Set Paused to on or off.")
            }
            _ = try await Task.detached { try store.pause(id, paused: value == "on") }.value
            return nil
        default:
            throw PartCallError(code: "helper_action", message: "Use Run once or the Paused switch. To change this helper, tell me in chat.")
        }
    }

    private static func timingKind(_ bot: BotDefinition) -> String {
        if bot.paused { return "Paused" }
        if bot.eventTrigger != nil { return "On event" }
        return bot.cadence == .manual ? "Manual" : "Scheduled"
    }

    private static func tone(_ status: BotsShelfRecord.Status) -> PartFace.Tone {
        switch status {
        case .running: .live
        case .failed, .interrupted: .failed
        case .needsModelChoice, .waitingForApproval, .waitingOnPerson: .attention
        case .ready: .done
        case .queued, .new, .paused, .stopped: .quiet
        }
    }

    private static func runTone(_ status: BotRunStatus) -> PartFace.Tone {
        switch status {
        case .completed: .done
        case .failed, .interrupted: .failed
        case .waitingForApproval, .waitingOnPerson: .attention
        case .stopped: .quiet
        }
    }

    private static func headline(_ entry: ShelfEntry) -> String {
        guard !entry.actualReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if entry.runtimeStatus == .completed { return entry.runHealth == .nothingNew ? "Checked, nothing new" : "No reply saved" }
            return entry.runtimeStatus.rawValue.capitalized + " — no reply saved"
        }
        return BotHeadline.make(from: entry.headline.isEmpty ? entry.actualReply : entry.headline)
    }

    private static func absolute(_ date: Date) -> String { timestamp.string(from: date) }
}
