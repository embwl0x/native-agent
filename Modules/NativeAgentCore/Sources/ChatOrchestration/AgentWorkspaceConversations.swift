import Foundation
import CryptoKit
import PersistenceCore

/// The conversation owner's bookmarks, presented as recognizable windows.
/// This is not another inbox or transcript: opening a window still enters
/// agent_read and its current owner/gates before any reply can be shown.
enum AgentWorkspaceConversations {
    private struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func project(scope: String, dataRoot: URL, page: Int = 0,
                        observations: [AgentWorkspaceChanges.Stamp] = [],
                        perform: AgentWorkspace.Perform) async throws -> AgentWorkspaceProjection {
        guard !scope.isEmpty else {
            throw Failure(message: "A conversation workspace needs its verified chat session.")
        }
        let contactsResult = try await perform("agent_contacts", [:])
        guard case .object(let contactsRoot) = contactsResult,
              contactsRoot["status"] == .string("ok"),
              case .array(let contacts)? = contactsRoot["contacts"] else {
            return .init(title: "Conversations", content: contactsResult, items: [], actions: [])
        }
        // Admission to the contact catalog is not authority to reveal any
        // retained reply. Only routing metadata from this exact chat follows.
        let readable = Set(contacts.compactMap { contact -> String? in
            guard case .object(let row) = contact,
                  case .string(let agent)? = row["agent"],
                  case .array(let capabilities)? = row["capabilities"],
                  capabilities.contains(.string("read")) else { return nil }
            return agent
        })
        // Every conversation she has, whichever chat it began in: one desktop.
        // Newest per contact and thread name; bots keep one continuous row.
        var seen: Set<String> = []
        let records = try AgentConversationStore(dataRoot: dataRoot).records()
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
            .filter { seen.insert($0.agent.hasPrefix("bot:") ? $0.agent : $0.agent + "\u{0}" + $0.label.lowercased()).inserted }
        let currentPage = min(31, max(0, page))
        var botReads: [String: JSONValue] = [:]
        // Bot transcripts belong to the continuous-session owner, not the
        // most recent ask stored in this chat's routing bookmark. Refresh only
        // this visible page, through the ordinary read gate, never a send.
        for record in records.dropFirst(currentPage * 8).prefix(8)
            where record.agent.hasPrefix("bot:") && exactAgent(record.agent) && readable.contains(record.agent) {
            do { botReads[record.agent] = try await perform("agent_read", ["agent": .string(record.agent)]) }
            catch { botReads[record.agent] = .object(["status": .string("unavailable")]) }
        }
        let items = records.map {
            item($0, readable: exactAgent($0.agent) && readable.contains($0.agent),
                 observations: observations, botRead: botReads[$0.agent])
        }
        let actions: [AgentWorkspaceButton] = [
            .init(label: "Find someone", action: .open(.people(page: 0))),
            .init(label: "Your conversations", action: .open(.record(tool: "chat_conversations", input: [:], title: "Conversations with you"))),
            .init(label: "My helpers", action: .open(.area("helpers")))
        ]
        let visible = Array(items.dropFirst(currentPage * 8).prefix(8))
        func count(_ group: String) -> JSONValue {
            .int(Int64(visible.filter { item in
                guard case .object(let row) = item.content else { return false }
                return row["group"] == .string(group)
            }.count))
        }
        var result = AgentWorkspaceProjection(title: "Conversations", content: .object([
            "status": .string("ok"), "count": .int(Int64(items.count)),
            "this_page": .object(["needs_attention": count("Needs attention"),
                "changed": count("Changed since last opened"), "in_progress": count("In progress")]),
            "meaning": .string("Most recently active conversations first. Cues describe recorded evidence, not live presence or unread counts. Open for the current reply; My helpers also keeps continuous helper conversations.")
        ]), items: items, actions: actions)
        result.page = currentPage
        return result
    }

    private static func item(_ record: AgentConversationRecord, readable: Bool,
                             observations: [AgentWorkspaceChanges.Stamp], botRead: JSONValue?) -> AgentWorkspaceItem {
        let isBot = record.agent.hasPrefix("bot:")
        let title = isBot ? record.name + " — Continuous conversation" : record.name + " — " + record.label
        let recordedState = state(record)
        let state = isBot ? botState(botRead) : recordedState
        var input: [String: JSONValue] = ["agent": .string(record.agent)]
        if !isBot { input["conversation"] = .string(record.label) }
        let location = AgentWorkspaceLocation.record(tool: "agent_read",
            input: input, title: title)
        func evaluate(_ previous: AgentWorkspaceChanges.Stamp?) -> AgentWorkspaceChanges.Observation? {
            guard readable else { return nil }
            if isBot {
                guard let botRead else { return nil }
                return AgentWorkspaceChanges.evaluate(location: location, result: botRead, previous: previous)
            }
            return AgentConversationSession.workspaceChangeObservation(record, location: location, previous: previous)
        }
        let candidate = evaluate(nil)
        let previous = candidate?.nextStamp.flatMap { next in observations.first { $0.identity == next.identity } }
        let change = evaluate(previous)
        let currentState = isBot && change?.state == .unavailable
            ? (phase: "attention", detail: "A current comparable helper read is unavailable. Open the conversation to check it; its previous view is preserved.")
            : state
        var content: [String: JSONValue] = [
            "source_key": .string(record.id),
            "agent": .string(record.agent), "conversation": .string(isBot ? "Continuous conversation" : record.label),
            "state": .string(readable ? currentState.phase : "attention"),
            "recorded_state": .string(recordedState.phase),
            "detail": .string(readable ? currentState.detail : "This contact is not currently available in the contact list. Its saved conversation is preserved; a saved-result read will check the owner's current access."),
            "as_of": .string(ISO8601DateFormatter().string(from: isBot && botRead != nil ? Date() : record.updatedAt)),
            "state_basis": .string(isBot && botRead != nil ? "current continuous conversation owner read" : readable ? "last recorded owner outcome" : "last recorded owner outcome; contact availability checked now"),
            "change_token": .string(isBot ? (candidate?.nextStamp?.fingerprint ?? "unavailable") : changeToken(record)),
            "available": .bool(readable)
        ]
        // A delivery problem is not evidence that the peer's work failed.
        if !isBot, let delivery = record.deliveryState { content["delivery_state"] = .string(delivery) }
        if let change {
            content["change"] = change.metadata
            // This says only that owner evidence differs. A changed status is
            // not necessarily a new reply, and listing never acknowledges it.
            if change.state == .changed {
                switch change.kind {
                case "reply_changed":
                    content["detail"] = .string("The recorded reply changed since you last opened this conversation. Open to read it.")
                case "state_changed":
                    content["detail"] = .string("The recorded progress changed; the retained reply is the same. Open to see the current state.")
                default:
                    content["detail"] = .string("The recorded exchange changed since you last opened it. Open to read what changed.")
                }
            }
        }
        // Recognition cues use already-read owner metadata. They do not
        // acknowledge a reply or add transcript reads for off-page helpers.
        let needsAttention = !readable || currentState.phase == "attention"
        content["group"] = .string(needsAttention ? "Needs attention"
            : change?.state == .changed ? "Changed since last opened"
            : currentState.phase == "waiting" ? "In progress" : "Recent conversations")
        content["kind"] = .string(isBot ? "Helper conversation" : "Agent conversation")
        let actions: [AgentWorkspaceButton] = exactAgent(record.agent) ? [
            .init(label: !readable ? "Read saved result" : change?.state == .changed
                  ? (change?.kind == "state_changed" ? "See updated progress" : "Read what’s new")
                  : "Open conversation", action: .open(location))
        ] : []
        return .init(title: title, content: .object(content), actions: actions)
    }

    private static func exactAgent(_ agent: String) -> Bool {
        if ["codex", "claude", "omp"].contains(agent) { return true }
        if agent.hasPrefix("bot:") { return UUID(uuidString: String(agent.dropFirst(4))) != nil }
        if agent.hasPrefix("peer:") {
            let id = agent.dropFirst(5)
            return !id.isEmpty && id.count <= 480 && !id.contains(where: { $0.isWhitespace })
        }
        return false
    }

    private static func botState(_ read: JSONValue?) -> (phase: String, detail: String) {
        guard case .object(let root)? = read,
              case .array(let exchanges)? = root["exchanges"],
              case .object(let latest)? = exchanges.first else {
            return ("attention", "The continuous conversation could not establish a current exchange. Open it to check its owner.")
        }
        if latest["needs_input"] == .bool(true) || latest["needs_authentication"] == .bool(true) {
            return ("attention", "The helper's current exchange needs your attention. Open it to see what is needed.")
        }
        switch latest["execution_state"] {
        case .string("queued"), .string("running"), .string("working"), .string("pending"), .string("accepted"):
            return ("waiting", "The helper's current exchange is still in progress.")
        case .string("completed"), .string("succeeded"), .string("done"), .string("replied"), .string("answered"):
            return ("ready", "The helper's current exchange settled. Open the conversation to read it and continue.")
        default:
            return ("attention", "Open the helper's current exchange to check its recorded outcome.")
        }
    }

    private static func state(_ record: AgentConversationRecord) -> (phase: String, detail: String) {
        var receipt: [String: JSONValue] = [:]
        if case .object(let root)? = record.receipt {
            receipt = root
            if case .array(let jobs)? = root["jobs"], jobs.count == 1,
               case .object(let job) = jobs[0] { receipt = job }
        }
        if receipt["needs_input"] == .bool(true) {
            return ("attention", "The last result asked for a reply or decision. Open the conversation to see it.")
        }
        switch record.phase {
        case "sending":
            return ("waiting", "A send was recorded as in progress. Open to check its outcome; do not repeat it.")
        case "waiting":
            return ("waiting", "Waiting at the last owner update. Open for the current result; no resend is needed.")
        case "ready":
            return ("ready", "The last exchange settled. Open its result and continue the same conversation.")
        case "attention":
            return ("attention", "The last exchange needs attention. Open the retained result before deciding what to do.")
        default:
            return ("attention", "The saved outcome is not recognized. Open the conversation to check its actual state.")
        }
    }

    /// Stable across mere opens/selection changes. The caller can compare this
    /// opaque observation without exposing retained private text in the list.
    private static func changeToken(_ record: AgentConversationRecord) -> String {
        let value: JSONValue = .object([
            "operation": .string(record.operationID), "phase": .string(record.phase),
            "receipt": record.receipt ?? .null,
            "delivery": record.deliveryState.map(JSONValue.string) ?? .null
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// A chat another agent opened with her over the bridge. 2026-09-22, Agent's
/// ask (User agreed): one window per person, both directions. Only the first
/// user row's bridge metadata qualifies a session, never its title; it joins
/// a person's window only when exactly one contact or built-in id matches.
struct AgentWorkSession {
    let sessionID: String, sender: String, topic: String, latest: String, updatedAt: String
    var createdAt = "", summary = ""

    /// Set by `all()` when two sessions share a title: " · Claude · today 6pm".
    var display = ""
    var agentName: String? = nil

    /// 2026-09-22, Agent's ask: every session read "Work session with Claude".
    /// 2026-09-23 (her screen): named by what it is about; who and when are
    /// added only where two would otherwise read the same.
    var title: String { display.isEmpty ? about : display }
    var about: String {
        summary.isEmpty ? HerScreen.humanTitle(topic, agentName: agentName).title : HerScreen.clip(summary, 60)
    }
    var who: String { sender == "agent" ? "Another agent" : sender.prefix(1).uppercased() + sender.dropFirst() }

    var location: AgentWorkspaceLocation {
        .record(tool: "chat_conversations", input: ["conversation_session_id": .string(sessionID)], title: title)
    }
    var item: AgentWorkspaceItem {
        .init(title: title, content: .object(["kind": .string("Work session"), "about": .string(topic),
            "latest": .string(latest), "updated_at": .string(updatedAt)]),
              actions: [.init(label: "Open work session", action: .open(location))])
    }

    /// The sender of the session's first user row when the bridge wrote it:
    /// built-in lanes by their verified origin agent, contacts by the label the
    /// bridge itself prefixed ("[from: Hermes, via bridge] …").
    static func bridgeSender(sessionID: String, dataRoot: URL) -> (sender: String, topic: String)? {
        let url = dataRoot.appendingPathComponent("chat/messages/\(sessionID).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 512 * 1024) else { return nil }
        for line in head.split(separator: UInt8(ascii: "\n")) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  row["role"] as? String == "user" else { continue }
            let origin = (row["metadata"] as? [String: Any])?["origin"] as? [String: Any]
            guard let agent = origin?["agent"] as? String, !agent.isEmpty,
                  let surface = origin?["surface"] as? String, surface.hasSuffix("-bridge"),
                  let content = row["content"] as? String, content.hasPrefix("[from: "),
                  let end = content.range(of: ", via bridge]") else { return nil }
            let label = String(content[content.index(content.startIndex, offsetBy: 7)..<end.lowerBound])
            let topic = String(content[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
            return (["claude", "codex", "omp"].contains(agent) ? agent : label, topic)
        }
        return nil
    }

    /// Newest first; names and latest line only. The title is a cheap
    /// prefilter; the transcript metadata decides.
    static func all(dataRoot: URL) -> [Self] {
        let agentName = ChatCompactionDistiller.configuredAgentName(dataRoot: dataRoot)
        var found: [Self] = ((try? HumanConversationReader.rows(dataRoot: dataRoot)) ?? []).compactMap { row in
            guard let id = HumanConversationReader.string(row["id"]),
                  HumanConversationReader.string(row["title"])?.hasPrefix("[from: ") == true,
                  let parsed = bridgeSender(sessionID: id, dataRoot: dataRoot) else { return nil }
            let preview = HumanConversationReader.string(row["lastMessagePreview"]) ?? ""
            return .init(sessionID: id, sender: parsed.sender, topic: parsed.topic,
                         latest: String((preview.split(separator: "\n").first ?? "").prefix(160)),
                         updatedAt: HumanConversationReader.string(row["updatedAt"]) ?? "",
                         createdAt: HumanConversationReader.string(row["createdAt"]) ?? "",
                         summary: HumanConversationReader.string(row["summary"]) ?? "", agentName: agentName)
        }
        let titles = HerScreen.disambiguate(found.map(\.about), who: found.map(\.who),
            at: found.map { HerScreen.date($0.createdAt) })
        for index in found.indices where titles[index] != found[index].about { found[index].display = titles[index] }
        return found
    }

    static func people(dataRoot: URL) -> [(agent: String, name: String)] {
        [("claude", "Claude"), ("codex", "Codex"), ("omp", "Omp")]
            + ((try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []).map { ("peer:" + $0.id, $0.name) }
    }

    /// The one person this sender is, or nil when none or several match.
    static func owner(_ sender: String, people: [(agent: String, name: String)]) -> (agent: String, name: String)? {
        let who = sender.lowercased()
        let matches = people.filter { who == $0.agent || who == $0.name.lowercased() }
        return matches.count == 1 ? matches[0] : nil
    }

    static func sessions(with agent: String, dataRoot: URL) -> [Self] {
        let people = people(dataRoot: dataRoot)
        return all(dataRoot: dataRoot).filter { owner($0.sender, people: people)?.agent == agent }
    }
}
