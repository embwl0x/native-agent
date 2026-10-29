import ChatSessionWork
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AgentWorkspaceConversations.swift` | `AgentWorkSession`: verified bridge sessions, titles and contact associations; Conversations renders only through `HerScreen.conversationsRoom` |

/// A chat another agent opened with her over the bridge. Only the first
/// user row's bridge metadata qualifies a session, never its title; it joins
/// a person's window only when exactly one contact or built-in id matches.
struct AgentWorkSession {
    let sessionID: String, sender: String, topic: String, latest: String, updatedAt: String
    var createdAt = "", summary = ""

    /// Set by `all()` when two sessions share a title: " · Claude · today 6pm".
    var display = ""
    var agentName: String? = nil

    /// Named by topic; who and when disambiguate matching titles.
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
    /// built-in lanes by their persisted origin agent, contacts by their
    /// verified envelope user id. Titles and message labels are display only.
    private static func bridgeSender(sessionID: String, dataRoot: URL) -> (sender: String, topic: String)? {
        guard NativeAgentChatSessionID.normalizedPathComponent(sessionID) != nil else { return nil }
        let url = dataRoot.appendingPathComponent("chat/messages/\(sessionID).jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Read toward the first user row in 16 KiB steps, capped at 512 KiB.
        let cap = 512 * 1024
        var head = Data(), lineStart = 0, atEnd = false
        while true {
            let line: Data
            if let newline = head[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
                line = head[lineStart..<newline]; lineStart = newline + 1
            } else if !atEnd {
                let more: Data?
                do { more = head.count < cap ? try handle.read(upToCount: min(16 * 1024, cap - head.count)) : nil }
                catch { return nil }
                if let more, !more.isEmpty { head.append(more) } else { atEnd = true }
                continue
            } else if lineStart < head.count {
                line = head[lineStart...]; lineStart = head.count
            } else {
                return nil
            }
            guard case .object(let row)? = try? JSONValue.parse(Data(line)) else { continue }
            let speech = ContactThread.Line(row)
            guard speech.role == "user" else { continue }
            let origin = (speech.metadata["origin"]?.objectValue ?? [:])
            let envelope = (speech.metadata["envelope"]?.objectValue ?? [:])
            guard let surface = origin["surface"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? envelope["surface"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }),
                  surface.hasSuffix("-bridge"), let sender = speech.source else { return nil }
            let topic = String(ContactThread.project([speech], style: .thread).first!.text.prefix(60))
            return (sender, topic)
        }
    }

    /// Newest first, verified independently of display titles or preview consumption.
    static func verified(dataRoot: URL) -> [(id: String, sender: String, topic: String, row: [String: JSONValue])] {
        ((try? HumanConversationIndex.rows(dataRoot: dataRoot)) ?? []).compactMap { row in
            guard let id = row["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }), let sender = bridgeSender(sessionID: id, dataRoot: dataRoot) else { return nil }
            return (id, sender.sender, sender.topic, row)
        }
    }

    static func all(dataRoot: URL) -> [Self] {
        let agentName = ChatCompactionDistiller.configuredAgentName(dataRoot: dataRoot)
        var found: [Self] = verified(dataRoot: dataRoot).map { session in
            let row = session.row
            let preview = HumanConversationIndex.shownPreview(row) ?? ""
            return .init(sessionID: session.id, sender: session.sender, topic: session.topic,
                         latest: String((preview.split(separator: "\n").first ?? "").prefix(160)),
                         updatedAt: row["updatedAt"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? "",
                         createdAt: row["createdAt"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? "",
                         summary: row["summary"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? "", agentName: agentName)
        }
        let titles = HerScreen.disambiguate(found.map(\.about), who: found.map(\.who),
            at: found.map { HerScreen.date($0.createdAt) })
        for index in found.indices where titles[index] != found[index].about { found[index].display = titles[index] }
        return found
    }

    static func people(dataRoot: URL) -> [(agent: String, name: String)] {
        HerScreen.contacts(identity: AgentWorkspacePorts.current.conversations.identity(dataRoot: dataRoot)).map { ($0.id, $0.name) }
    }

    /// The one person this sender is, or nil when none or several match.
    static func owner(_ sender: String, people: [(agent: String, name: String)]) -> (agent: String, name: String)? {
        let who = sender.lowercased()
        let matches = people.filter { who == $0.agent.lowercased() }
        return matches.count == 1 ? matches[0] : nil
    }

    static func sessions(with agent: String, dataRoot: URL) -> [Self] {
        let people = people(dataRoot: dataRoot)
        let identity = AgentWorkspacePorts.current.conversations.identity(dataRoot: dataRoot)
        return all(dataRoot: dataRoot).filter { identity.canonical($0.sender) == identity.canonical(agent)
            && people.contains(where: { identity.canonical($0.agent) == identity.canonical(agent) }) }
    }
}
