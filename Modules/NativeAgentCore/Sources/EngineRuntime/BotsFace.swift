import ChatToolRuntime
import ChatToolParsing
import AuthoredCapabilities
import Foundation
import NativeAgentShared
import PersistenceCore
import StandingBots
// Blueprint: | `BotsFace.swift` | Helpers rows and brief document bodies from the helper owner; Run once and Paused call their owners |

enum BotsFace {
    static func isDocument(_ item: String) -> Bool {
        let parts = item.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let id = parts.first, parts.last == "brief" else { return false }
        return UUID(uuidString: String(id)) != nil
    }

    @MainActor static func body(_ engine: NativeAgentEngine) -> PartFaces.Body {
        { item in
            guard isDocument(item), let raw = item.split(separator: "/").first, let id = UUID(uuidString: String(raw)) else {
                throw PartCallError(code: "helper_document_invalid", message: "Choose a helper's brief document.")
            }
            let owner = engine.contactThreads
            if let failure = owner.helpersRefreshError { throw PartCallError(code: "helpers_unavailable", message: failure) }
            guard owner.helpersLoaded else {
                throw PartCallError(code: "helpers_unread", message: "The helper owner has not returned its definitions.")
            }
            guard let helper = owner.helpers.first(where: { $0.definition.id == id }) else {
                throw PartCallError(code: "helper_not_found", message: "This helper is absent from the owner's checked definitions.")
            }
            return helper.definition.brief
        }
    }

    @MainActor static func reader(_ engine: NativeAgentEngine) -> PartFaces.Read {
        engine.contactThreads.startHelpers(engine: engine)
        return { try await read(engine) }
    }

    @concurrent static func read(_ engine: NativeAgentEngine) async throws -> (face: PartFace, epoch: UInt64) {
        let epoch = UInt64(Date().timeIntervalSince1970 * 1000)
        let state = await MainActor.run {
            let owner = engine.contactThreads, transcripts = engine.transcripts
            return (problem: owner.helpersRefreshError, loaded: owner.helpersLoaded, unattended: owner.helpersUnattended,
                    records: owner.helpers, indexProblem: transcripts.sessionIndexError, indexLoaded: transcripts.hasLoadedSessionIndex,
                    sessions: transcripts.sessions)
        }
        if let problem = state.problem {
            throw PartCallError(code: "helpers_unavailable", message: problem)
        }
        guard state.loaded, let unattended = state.unattended else {
            throw PartCallError(code: "helpers_unread", message: "Helpers are still being read. Their definitions and run history are kept.")
        }
        let records = state.records
        let indexProblem = state.indexProblem ?? (state.indexLoaded ? nil : "The conversation index is still being read.")
        let sessions = indexProblem == nil ? Set(state.sessions.map(\.id)) : []
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
                actions: [.init(id: "bot.run_once", label: "Run once", role: .primary, call: PartFace.Call("bots.check", ["id": .string(id)]))])
        ]
        if bot.cadence != .manual || bot.eventTrigger != nil || bot.paused {
            rows.append(.init(id: id + "/paused", title: "Paused", detail: "Scheduled and event work; Run once remains available.",
                control: .toggle(bot.paused, call: PartFace.Call("bots.paused", ["id": .string(id)]))))
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
                rows: [], block: .init(key: id + "/brief", revision: String(bot.updatedAt.timeIntervalSinceReferenceDate))),
            .init(id: id + "/runs", title: bot.name + " · Latest runs", style: .timeline,
                footer: record.entries.count > 5 ? "Earlier runs are in the helper's conversation." : nil,
                rows: runs.isEmpty ? [.init(id: id + "/no-runs", title: "No runs yet.", tone: .quiet)] : runs)
        ]
    }

    /// A requested check (`bots.check`): the helper runs once and its reply stays in its own conversation.
    @MainActor static func check(_ engine: NativeAgentEngine, _ input: [String: JSONValue]) async throws -> String {
        let id = try await helper(engine, input)
        do {
            let request = try await BotRunConversation.enqueueRequestedCheck(botID: id, dataRoot: engine.dataRoot)
            return "Run request: " + request.uuidString + ". Its reply stays in this helper's conversation."
        } catch { throw PartCallError(code: "helper_action_failed", message: ChatToolOutcome.errorMessage(error)) }
    }

    /// The Paused switch (`bots.paused`): value true pauses the helper's scheduled and event work, false resumes it.
    @MainActor static func paused(_ engine: NativeAgentEngine, _ input: [String: JSONValue]) async throws -> String {
        guard case .bool(let paused)? = input["value"] else {
            throw PartCallError(code: "paused_value", message: "Paused takes value true or false; nothing changed.")
        }
        let id = try await helper(engine, input)
        let store = BotDefinitionStore(dataRoot: engine.dataRoot)
        do { _ = try await Task.detached { try store.pause(id, paused: paused) }.value }
        catch { throw PartCallError(code: "helper_action_failed", message: ChatToolOutcome.errorMessage(error)) }
        return paused ? "Paused." : "Resumed."
    }

    /// The helper `id` names, refused when it is unreadable or deleted.
    @MainActor private static func helper(_ engine: NativeAgentEngine, _ input: [String: JSONValue]) async throws -> UUID {
        guard let id = input["id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            throw PartCallError(code: "helper_row", message: "id is a helper's id from Helpers; nothing changed.")
        }
        let store = BotDefinitionStore(dataRoot: engine.dataRoot)
        let bot: BotDefinition
        do { bot = try await Task.detached { try store.get(id) }.value }
        catch { throw PartCallError(code: "helper_action_failed", message: ChatToolOutcome.errorMessage(error)) }
        guard bot.deleted != true else {
            throw PartCallError(code: "helper_unavailable", message: "This helper was deleted. Read Helpers again; its saved replies are kept.")
        }
        return id
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

    private static func absolute(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
