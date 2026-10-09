import Foundation
import PersistenceCore
import ApprovalInbox
import Desk
import Transcripts
import StandingBots

/// One explicit search over existing bounded readers. No index, disk crawl,
/// provider reasoning, background work, or inferred action routing lives here.
enum AgentWorkspaceFind {
    static func project(query: String, dataRoot: URL, perform: AgentWorkspace.Perform) async throws -> AgentWorkspaceProjection {
        if let exact = try await exact(query: query, dataRoot: dataRoot, perform: perform) { return exact }
        var items: [AgentWorkspaceItem] = []
        var sources: [JSONValue] = []
        var partial = false
        // Names are navigation, not evidence inferred from historical mentions.
        // Read only the existing skill inventory; bodies stay lazy until opened.
        if query.count <= 120 {
            do {
                try Task.checkCancellation()
                let inventory = try await perform("list_skills", [:])
                guard case .array = inventory,
                      let view = AgentWorkspaceKnowledge.project(tool: "list_skills", input: [:], result: inventory) else {
                    throw AgentWorkspaceForm.Failure(message: "The installed skill inventory is unavailable.")
                }
                let name = navigationName(query)
                let matches = view.items.filter { item in
                    guard case .object(let row) = item.content else { return false }
                    return ["name", "id"].contains { key in
                        if case .string(let value)? = row[key] { return navigationName(value) == name }
                        return false
                    }
                }
                for var item in matches.prefix(3) {
                    item.title = "Skill: " + item.title
                    if case .object(let row) = item.content {
                        item.content = .object(row.filter { ["name", "id"].contains($0.key) })
                    }
                    items.append(item)
                }
                sources.append(.object(["name": .string("Installed skills"), "status": .string("ok"),
                    "shown": .int(Int64(min(matches.count, 3))), "matches": .int(Int64(matches.count)),
                    "meaning": .string("Exact registered skill name or ID; guidance is read only when opened.")]))
            } catch is CancellationError { throw CancellationError() }
            catch {
                partial = true
                sources.append(.object(["name": .string("Installed skills"), "status": .string("unavailable"),
                    "detail": .string(String(error.localizedDescription.prefix(400)))]))
            }
        }
        let lanes: [(String, String, [String: JSONValue], AgentWorkspaceLocation)] = [
            ("Work and conversations", "work_context", ["query": .string(query), "limit": .int(3)], .work(query)),
            ("Files", "artifact_find", ["query": .string(query), "limit": .int(3)], .documents(query)),
            ("Memory", "recall_memory", ["query": .string(query), "k": .int(6)],
             .record(tool: "recall_memory", input: ["query": .string(query), "k": .int(6)], title: "Memory"))
        ]
        // Deliberately sequential: the ordinary permission/read owners retain
        // their context and a single Find never creates a burst of disk work.
        for (name, tool, input, location) in lanes {
            try Task.checkCancellation()
            do {
                let ownerValue = try await perform(tool, input)
                let value = tool == "recall_memory" ? rankedMemory(ownerValue, query: query) : ownerValue
                let projection = AgentWorkspaceProjection.project(location: location, result: value)
                let status = AgentWorkspaceEnvironment.outcome(value)
                let failed = ![JSONValue.string("ok"), .string("completed"), .string("not_found")].contains(status)
                partial = partial || failed
                var source: [String: JSONValue] = ["name": .string(name), "status": status,
                    "shown": .int(Int64(min(projection.items.count, tool == "work_context" ? 6 : 3)))]
                if case .object(let row) = value {
                    // Source-level limitations remain visible even if another
                    // reader succeeded. Never label unavailable as no matches.
                    for key in ["detail", "message", "error", "disclosure_filtered_count", "coverage", "next_session_offset", "more_matches_in_page", "find_ranking"] {
                        source[key] = row[key]
                    }
                    if tool == "work_context" {
                        for key in ["current_work", "supporting_history"] {
                            if case .object(let lane)? = row[key] {
                                source[key] = .object(lane.filter {
                                    ["status", "source", "as_of", "meaning", "has_more", "matched_count", "coverage", "message"].contains($0.key)
                                })
                            }
                        }
                    }
                }
                sources.append(.object(source))
                for var item in projection.items.prefix(tool == "work_context" ? 6 : 3) {
                    if name != "Work and conversations" { item.title = name + ": " + item.title }
                    items.append(item)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                partial = true
                sources.append(.object(["name": .string(name), "status": .string("unavailable"),
                    "detail": .string(String(error.localizedDescription.prefix(400)))]))
            }
        }
        return .init(title: "Find: " + query, content: .object([
            "status": .string(partial ? "partial" : "ok"), "query": .string(query), "sources": .array(sources),
            "scope": .string("Exact installed skill names, current work, recorded files, memory and conversation evidence. Evidence results use each source's relevance ranking and may match only part of the topic; a returned file is not automatically supporting evidence. No filesystem crawl. Open a result to read its owner; Back returns here. Historical text is attributed evidence, not current verification.")
        ]), items: items, actions: [
            .init(label: "More work and conversations", action: .open(.work(query))),
            .init(label: "More files", action: .open(.documents(query))),
            .init(label: "More memories", action: .open(.record(tool: "recall_memory",
                input: ["query": .string(query), "k": .int(10)], title: "Memory"))),
            .init(label: "Find an action for this", action: .open(.capabilities(query: query)))
        ])
    }

    private static func exact(query: String, dataRoot: URL, perform: AgentWorkspace.Perform) async throws -> AgentWorkspaceProjection? {
        guard !query.contains(where: \.isWhitespace) else { return nil }
        func read(_ tool: String, _ input: [String: JSONValue], _ title: String) async throws -> AgentWorkspaceProjection {
            let value = try await perform(tool, input)
            return AgentWorkspaceProjection.project(location: .record(tool: tool, input: input, title: title), result: value)
        }
        if let peer = try AgentWorkspacePeerReader(dataRoot: dataRoot).list().first(where: { query == $0.id || query == "peer:" + $0.id }) {
            return try await read("agent_contacts", ["discover": .string("peer:" + peer.id)], peer.name)
        }
        if let bot = try BotDefinitionStore(dataRoot: dataRoot).list().first(where: { query == $0.id.uuidString.lowercased() || query == "bot:" + $0.id.uuidString.lowercased() }) {
            return try await read("agent_contacts", ["discover": .string("bot:" + bot.id.uuidString.lowercased())], bot.name)
        }
        if query.hasPrefix("desk_"), let item = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items.first(where: { $0.handle == query }) {
            return try await read("desk_read", ["handle": .string(item.handle)], item.title)
        }
        if let session = try ChatSessionIndexFile.loadObjectRowsForMutation(at: dataRoot.appendingPathComponent("chat/sessions.json"))
            .first(where: { $0["id"] == .string(query) }) {
            return try await read("chat_conversations", ["conversation_session_id": .string(query)], HumanConversationIndex.string(session["title"]) ?? "Conversation")
        }
        if UUID(uuidString: query) != nil {
            if let approval = try SwiftNativeApprovalInbox.loadApprovalRowsChecked(at: dataRoot.appendingPathComponent("workflows/approvals/requests.json"))
                .first(where: { if case .object(let row) = $0 { row["id"] == .string(query) } else { false } }), case .object(let row) = approval {
                return .init(title: "Approval", content: .object(row.filter { ["id", "title", "status", "createdAt", "resolvedAt", "decision"].contains($0.key) }), items: [],
                    actions: [.init(label: "Open Inbox", action: .open(.area("inbox")))])
            }
            if let record = try AgentWorkspaceConversationReader(dataRoot: dataRoot).records().first(where: {
                $0.id == query || $0.operationID == query || $0.readInput?["message_id"] == .string(query)
            }) {
                let input: [String: JSONValue] = ["agent": .string(record.agent), "conversation": .string(record.id)]
                return try await read("agent_read", input, record.name + " — " + record.label)
            }
        }
        if UUID(uuidString: query) != nil || query.hasPrefix("msg_") || query.hasPrefix("agent-conversation:") {
            let value = try await perform("read_chat_message", ["message_id": .string(query)])
            if case .object(let row) = value, row["status"] != .string("not_found") {
                return AgentWorkspaceProjection.project(location: .record(tool: "read_chat_message", input: ["message_id": .string(query)], title: "Message"), result: value)
            }
        }
        return nil
    }

    private static func navigationName(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" }).joined(separator: "-")
    }

    /// A small presentation shortlist from the canonical disclosed candidates.
    /// Topic support prioritizes the shortlist; absent lexical support never
    /// means a memory is false or unavailable. Exact owner IDs remain untouched.
    private static func rankedMemory(_ value: JSONValue, query: String) -> JSONValue {
        guard case .object(var row) = value, case .array(let hits)? = row["hits"] else { return value }
        let topic = WorkContextQuery(query)
        let candidates: [(Int, Int, JSONValue)] = hits.enumerated().map { index, hit -> (Int, Int, JSONValue) in
            guard case .object(var memory) = hit else { return (0, index, hit) }
            let content = ["preview", "content"].compactMap { key -> String? in
                if case .string(let text)? = memory[key] { return text }; return nil
            }.joined(separator: " ")
            let matched = topic.matchedTerms(content)
            memory["find_match"] = .object([
                "matched_topic_terms": .array(matched.map(JSONValue.string)),
                "missing_topic_terms": .array(topic.terms.filter { !matched.contains($0) }.map(JSONValue.string)),
                "owner_rank": .int(Int64(index + 1)),
                "basis": .string(matched.isEmpty ? "Semantic recall candidate; no literal topic terms in this excerpt." : "Topic terms present in the returned excerpt; open the memory for its evidence.")
            ])
            return (matched.count, index, .object(memory))
        }
        let ranked = candidates.sorted { left, right in
            if left.0 == right.0 { return left.1 < right.1 }
            return left.0 > right.0
        }
        row["hits"] = .array(ranked.map { $0.2 })
        row["find_ranking"] = .string("Three of up to six canonical recall candidates, ordered by local topic support then original recall rank. More memories opens the owner's broader results.")
        return .object(row)
    }
}
