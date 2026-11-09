import AgentConversations
import AgentWorkspace
import ChatSessionWork
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Privacy
import StandingBots
// Blueprint: | `EngineFaceThreadProjection.swift` | Finished contact rooms, helper history and record-bound Stop/resend commands |

enum EngineFaceThreadProjection {
    struct Input: Sendable {
        var id: String
        var contact: AgentContactPresentation?
        var helper: BotsShelfRecord?
        var agentName: String
        var lines: [AgentContactThreadLine]
        var flight: AgentContactFlight?
        var waiting: Bool
        var delivery: AgentConversationDelivery?
        var sessions: [String]
        var state: FaceReadState
    }

    @MainActor static func input(_ id: String, engine: NativeAgentEngine) -> Input {
        let owner = engine.contactThreads
        _ = owner.partial(for: id)
        let helperID = id.hasPrefix("bot:") ? UUID(uuidString: String(id.dropFirst(4))) : nil
        let helper = helperID.flatMap { id in owner.helpers.first { $0.id == id } }
        let contact = owner.contacts.first { $0.id == id }
        let loaded = owner.loaded && (!id.hasPrefix("bot:") || owner.helpersLoaded)
        let issue = owner.contactRefreshError ?? (id.hasPrefix("bot:") ? owner.helpersRefreshError : nil)
        let state: FaceReadState
        if let issue { state = .unavailable(failure("contact_history_unavailable", issue)) }
        else if !loaded { state = .waiting(on: "contact history") }
        else if contact == nil && helper == nil {
            state = .unavailable(failure("contact_not_found", "This contact is absent from the checked directory. Its saved history is kept."))
        } else if let issue = engine.transcripts.sessionIndexError {
            state = .unavailable(failure("contact_sessions_unavailable", issue))
        } else if !engine.transcripts.hasLoadedSessionIndex { state = .waiting(on: "conversation index") }
        else { state = .ready }
        return Input(id: id, contact: contact, helper: helper, agentName: engine.persona.displayName,
            lines: owner.lines[id] ?? [], flight: owner.flight(for: id), waiting: owner.waiting.contains(id), delivery: owner.status[id],
            sessions: engine.transcripts.sessions.map(\.id), state: state)
    }

    @concurrent static func observe(_ key: FaceKey, engine: NativeAgentEngine) async {
        await engine.contactThreads.start()
        await engine.contactThreads.startHelpers(engine: engine)
        switch key {
        case .contactThread(let id):
            await EngineFaceProjection.watch(read: { input(id, engine: engine) }) { input in
                await engine.face.post(thread(input), at: key)
            }
        case .helperRuns(let raw):
            guard let id = UUID(uuidString: raw) else {
                await engine.face.post(HelperRunsFace(helper: raw, runs: [], detailRequests: [:],
                    state: .unavailable(failure("helper_identity_invalid", "Choose a helper from the checked directory."))), at: key)
                return
            }
            await EngineFaceProjection.watch(read: { runsInput(id, engine: engine) }) { results, state in
                let rows: [PartFace.Row] = results?.history.map { result in
                    row(result.id.uuidString, title: ContactThreadReadouts.firstLine(result.line), detail: result.entry.statusDetail,
                        state: result.entry.runtimeStatus.rawValue, date: result.entry.runAt)
                } ?? []
                guard !Task.isCancelled else { return }
                await engine.face.post(HelperRunsFace(helper: raw, runs: rows, detailRequests: [:], state: state), at: key)
            }
        default: break
        }
    }

    static func thread(_ input: Input) -> ContactThreadFace {
        let id = input.id
        let name = input.contact?.name ?? input.helper?.definition.name
        var value = ContactThreadFace(contact: id, lines: [], linkedSessions: [], partialReply: nil, flight: nil,
            waiting: [], queued: [], state: input.state,
            subtitle: (input.contact?.via ?? input.helper.map { $0.definition.paused ? "Paused" : $0.cadence }).map(safe),
            sendRestriction: input.contact?.sendRestriction.map(safe))
        guard let name else { return value }
        value.label = safe(name)
        if input.agentName.isEmpty && (input.lines.contains(where: { $0.fromAgent && !$0.byPerson })
            || input.flight?.queued.contains(where: { !$0.byPerson }) == true) {
            value.state = .unavailable(failure("contact_identity_unavailable", "The resident agent's profile must be read before naming these messages."))
            return value
        }
        value.lines = input.lines.map { line in
            let speaker = (line.byPerson ? "You" : line.fromAgent ? input.agentName : name) + (line.door.map { " · " + $0 } ?? "")
            return FaceThreadLine(id: line.id, speaker: safe(speaker), text: safe(line.text), date: line.at,
                session: nil, receipt: nil, failure: nil)
        }
        if id.hasPrefix("peer:") {
            let owner = String(id.dropFirst(5))
            value.linkedSessions = input.sessions.filter { $0 != ContactThread.session(owner: owner) && $0.hasPrefix(ContactThread.prefix(owner: owner)) }
        }
        value.receipt = receipt(input.delivery, name: name)
        if value.lines.isEmpty && value.linkedSessions.isEmpty, input.state == .ready {
            value.emptyText = input.contact?.lastActivityAt == nil
                ? "Nothing has passed with \(safe(name)) yet." : "Earlier activity is recorded, but no messages are retained here."
        }
        guard let flight = input.flight else {
            if input.waiting { value.waiting = [row("waiting", title: name, detail: "Waiting for reply", state: "waiting")] }
            return value
        }
        let liveLine = flight.partial != nil ? "Writing…" : flight.working ? "Working…" : "Waiting for \(name)…"
        value.flight = FaceContactFlight(record: flight.recordID, session: flight.scope, isRunning: flight.inFlight, liveLine: safe(liveLine))
        value.partialReply = input.waiting ? flight.partial.map(safe) : nil
        if input.waiting {
            let rowID = "flight:" + flight.recordID
            value.waiting.append(row(rowID, title: name, detail: flight.live?.note.map { liveLine + "\n" + $0 } ?? liveLine,
                state: flight.stop?.state ?? "waiting", date: flight.live?.startedAt))
            if flight.stop == nil { value.commands[rowID] = .stop(contact: id, record: flight.recordID) }
        }
        if let stop = flight.stop {
            if stop.state == "stopped" { value.receipt = "Stopped." }
            if !stop.detail.isEmpty {
                value.waiting.append(row("stop:" + flight.recordID, title: stop.state, detail: stop.detail, state: stop.state))
            }
        }
        value.queued = flight.queued.map { queued in
            let state: String
            let detail: String
            switch queued.state {
            case .queued: state = "queued"; detail = queued.waitingForMac ? "Waiting for the Mac to be free" : "Queued · sends when \(name) answers"
            case .sending: state = "sending"; detail = "Sending…"
            case .held(let reason): state = "held"; detail = reason
            case .notSent(let reason):
                state = "not_sent"; detail = reason
                value.commands[queued.id] = .resend(contact: id, item: queued.id, session: flight.scope)
            }
            return row(queued.id, title: queued.byPerson ? "You" : input.agentName, detail: queued.text + "\n\n" + detail,
                state: state, date: queued.at)
        }
        return value
    }

    @MainActor private static func runsInput(_ id: UUID, engine: NativeAgentEngine) -> (AgentContactThreads.HelperResults?, FaceReadState) {
        let owner = engine.contactThreads
        let helper = owner.helpers.first { $0.id == id }
        let results = owner.helperRuns[id]
        let state: FaceReadState
        if let issue = owner.helpersRefreshError ?? owner.contactRefreshError ?? helper?.runReadIssue {
            state = .unavailable(failure("helper_history_unavailable", issue))
        } else if !owner.helpersLoaded || !owner.loaded { state = .waiting(on: "helper history") }
        else if helper == nil {
            state = .unavailable(failure("helper_not_found", "This helper is absent from the checked directory. Its saved results are kept."))
        } else if results == nil { state = .waiting(on: "helper results") }
        else { state = .ready }
        return (results, state)
    }

    private static func receipt(_ delivery: AgentConversationDelivery?, name: String) -> String? {
        switch delivery {
        case .delivered?: "Delivered to \(safe(name))."
        case .read?: "Read by \(safe(name))."
        case .failed?, .unanswered?: "No reply came back from \(safe(name))."
        case .notDelivered?: "Didn't reach \(safe(name))."
        default: nil
        }
    }

    private static func row(_ id: String, title: String, detail: String?, state: String, date: Date? = nil) -> PartFace.Row {
        PartFace.Row(id: id, title: safe(title), detail: detail.map(safe), value: state, at: date.map { ISO8601DateFormatter().string(from: $0) }, actions: [])
    }
    private static func safe(_ value: String) -> String { NativeAppSecretRedactor.redactText(value) }
    private static func failure(_ code: String, _ message: String) -> WireFailure {
        EngineFaceActs.failure(code, safe(message))
    }
}

extension NativeAgentEngine {
    @concurrent public func contactThreadDocument(_ contact: String) async -> (face: ContactThreadFace, messages: [ChatMessage]) {
        let face = EngineFaceThreadProjection.thread(await EngineFaceThreadProjection.input(contact, engine: self))
        var lines = face.lines
        if let partial = face.partialReply, let speaker = face.label {
            lines.append(FaceThreadLine(id: "live:" + contact, speaker: speaker, text: partial, date: nil,
                session: nil, receipt: nil, failure: nil))
        }
        let messages = lines.map { line in
            ChatMessage(id: line.id, role: "system", content: "**\(line.speaker)**\n\n\(line.text)",
                createdAt: line.date.map(NativeTimestampFormat.plainZulu) ?? "")
        }
        return (face, messages)
    }

    @concurrent public func contactThreadMessage(_ contact: String, id: String) async throws -> ChatMessage {
        let document = await contactThreadDocument(contact)
        switch document.face.state {
        case .unavailable(let issue): throw issue
        case .waiting(let owner):
            throw EngineFaceActs.failure("contact_history_waiting", "Wait for \(owner) to be read before opening this message.")
        case .ready: break
        }
        guard let message = document.messages.first(where: { $0.id == id }) else {
            throw EngineFaceActs.failure("contact_message_not_found", "This message is absent from the checked contact thread.")
        }
        return message
    }
}
