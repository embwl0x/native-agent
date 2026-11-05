import ChatSessionWork
import Foundation
import PersonaEngine
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AgentWorkspaceConversations.swift` | `AgentWorkSession`, `AgentScreen.conversationsRoom`: verified sessions; owner-rendered threads |

/// A chat another agent opened with the agent over the bridge. Only the first user row's bridge metadata qualifies a session, never its title; it joins a
/// person's window only when exactly one contact or built-in id matches.
struct AgentWorkSession {
    let sessionID: String, sender: String, topic: String, latest: String, updatedAt: String
    var createdAt = "", summary = ""

    /// Disambiguate duplicate session titles with sender and time.
    var display = ""
    var agentName: String? = nil

    var title: String { display.isEmpty ? about : display }
    var about: String {
        summary.isEmpty ? AgentScreen.humanTitle(topic, agentName: agentName).title : AgentScreen.clip(summary, 60)
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

    /// The sender of the session's first user row when the bridge wrote it: built-in lanes by their persisted origin agent, contacts by their verified envelope
    /// user id. Titles and message labels are display only.
    private static func bridgeSender(sessionID: String, dataRoot: URL) throws -> (sender: String, topic: String)? {
        guard NativeAgentChatSessionID.normalizedPathComponent(sessionID) != nil else { return nil }
        let url = dataRoot.appendingPathComponent("chat/messages/\(sessionID).jsonl")
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch let error as CocoaError where error.isFileAbsent { return nil }
        defer { try? handle.close() }
        // Cap first-user-row discovery at 512 KiB to bound transcript reads.
        let cap = 512 * 1024
        var head = Data(), lineStart = 0, atEnd = false
        while true {
            let line: Data
            if let newline = head[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
                line = head[lineStart..<newline]; lineStart = newline + 1
            } else if !atEnd {
                guard head.count < cap else { throw ToolFailureError("The first speaker was not found within the bounded transcript head.", effects: .none,
                    owner: url.path, instruction: "Inspect the transcript's first complete user row before classifying this conversation.", recovery: .inspect)
                        }
                let more = try handle.read(upToCount: min(16 * 1024, cap - head.count))
                if let more, !more.isEmpty { head.append(more) } else { atEnd = true }
                continue
            } else {
                return nil
            }
            guard case .object(let row) = try JSONValue.parse(Data(line)) else { throw CocoaError(.fileReadCorruptFile) }
            let speech = ContactThread.Line(row)
            guard speech.role == "user" else { continue }
            let origin = (speech.metadata["origin"]?.objectValue ?? [:])
            let envelope = (speech.metadata["envelope"]?.objectValue ?? [:])
            guard let surface = origin["surface"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? envelope["surface"]?.stringValue.flatMap({ $0.isEmpty
                ? nil : $0 }),
                  surface.hasSuffix("-bridge"), let sender = speech.source else { return nil }
            let topic = String(ContactThread.project([speech], style: .thread).first!.text.prefix(60))
            return (sender, topic)
        }
    }

    /// Newest first, verified independently of display titles or preview consumption.
    static func verified(dataRoot: URL) throws -> [(id: String, sender: String, topic: String, row: [String: JSONValue])] {
        try HumanConversationIndex.rows(dataRoot: dataRoot).compactMap { row in
            guard let id = row["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }), let sender = try bridgeSender(sessionID: id, dataRoot: dataRoot) else {
                return nil }
            return (id, sender.sender, sender.topic, row)
        }
    }

    static func all(workspace: WorkspaceOperation, dataRoot: URL) throws -> [Self] {
        let profileName = try PersonaCompiler.compileProfile(dataRoot: dataRoot).name.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentName = profileName.isEmpty ? nil : profileName
        var found: [Self] = try verified(dataRoot: dataRoot).map { session in
            let row = session.row
            let preview = HumanConversationIndex.shownPreview(workspace: workspace, row) ?? ""
            return .init(sessionID: session.id, sender: session.sender, topic: session.topic,
                         latest: String((preview.split(separator: "\n").first ?? "").prefix(160)),
                         updatedAt: row["updatedAt"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? "",
                         createdAt: row["createdAt"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? "",
                         summary: row["summary"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? "", agentName: agentName)
        }
        let titles = AgentScreen.disambiguate(found.map(\.about), who: found.map(\.who),
            at: found.map { AgentScreen.date($0.createdAt) })
        for index in found.indices where titles[index] != found[index].about { found[index].display = titles[index] }
        return found
    }

    static func people(workspace: WorkspaceOperation, dataRoot: URL) throws -> [(agent: String, name: String)] {
        try AgentScreen.contacts(identity: workspace.ports.conversations.identity(dataRoot: dataRoot)).map { ($0.id, $0.name) }
    }

    /// The one person this sender is, or nil when none or several match.
    static func owner(_ sender: String, people: [(agent: String, name: String)]) -> (agent: String, name: String)? {
        let who = sender.lowercased()
        let matches = people.filter { who == $0.agent.lowercased() }
        return matches.count == 1 ? matches[0] : nil
    }

    static func sessions(workspace: WorkspaceOperation, with agent: String, dataRoot: URL) throws -> [Self] {
        let people = try people(workspace: workspace, dataRoot: dataRoot)
        let identity = try workspace.ports.conversations.identity(dataRoot: dataRoot)
        return try all(workspace: workspace, dataRoot: dataRoot).filter { identity.canonical($0.sender) == identity.canonical(agent)
            && people.contains(where: { identity.canonical($0.agent) == identity.canonical(agent) }) }
    }
}
