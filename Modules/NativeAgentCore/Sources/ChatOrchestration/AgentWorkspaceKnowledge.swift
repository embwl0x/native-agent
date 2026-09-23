import Foundation
import PersistenceCore

/// Presents the existing memory, research and skill owners without retaining
/// their content or interpreting instructions embedded in retrieved material.
enum AgentWorkspaceKnowledge {
    static let destinations: [AgentWorkspaceDestination] = [
        .init(id: "memory", title: "Memory", summary: "Recall something, inspect its evidence, or record a memory.",
              tool: "recall_memory", searchField: "query", tools: ["recall_memory", "commit_memory"]),
        .init(id: "research", title: "Research", summary: "Search the web, read a source, or investigate in the browser.",
              tool: nil, tools: ["read_page", "browser.chrome_acquire", "browser.chrome_snapshot"]),
        .init(id: "skills", title: "Skills", summary: "Open installed guidance or write a new skill.",
              tool: "list_skills", tools: ["list_skills", "read_skill", "save_skill"]),
    ]

    static let readTools: Set<String> = ["recall_memory", "recall_search", "list_skills", "read_skill", "read_page"]

    static func project(tool: String, input: [String: JSONValue], result: JSONValue) -> AgentWorkspaceProjection? {
        switch tool {
        case "recall_memory", "recall_search": return memory(input: input, result: result)
        case "list_skills": return skills(result)
        case "read_skill":
            return .init(title: text(input["name"]) ?? "Skill", content: result, items: [], actions: [
                .init(label: "Installed skills", action: .open(.record(tool: "list_skills", input: [:], title: "Skills"))),
                .init(label: "Write a skill", action: .configure(tool: "save_skill", input: [:], title: "Write a skill")),
            ])
        case "read_page":
            // Coverage and source receipts stay attached, including partial or
            // unsupported extraction. A fetch is never labeled verified truth.
            var actions: [AgentWorkspaceButton] = [
                .init(label: "Search the web", action: .searchWeb, needsText: true),
                .init(label: "Read another web page", action: .perform(tool: "read_page", input: [:], title: "Web source", textField: "url", isEffect: false), needsText: true),
            ]
            if let url = validWebURL(input["url"]) {
                actions.append(.init(label: "Open in browser", action: .perform(tool: "browser.chrome_acquire",
                    input: ["mode": .string("create"), "initial_url": .string(url)],
                    title: "Background browser", textField: nil, isEffect: true)))
            }
            return .init(title: "Web source", content: result, items: [], actions: actions)
        default: return nil
        }
    }

    private static func memory(input: [String: JSONValue], result: JSONValue) -> AgentWorkspaceProjection {
        var content = object(result)
        var items: [AgentWorkspaceItem] = []
        var actions: [AgentWorkspaceButton] = [
            .init(label: "Recall something else", action: .perform(tool: "recall_memory", input: [:], title: "Memory", textField: "query", isEffect: false), needsText: true),
            .init(label: "Record a memory", action: .configure(tool: "commit_memory", input: [:], title: "Record a memory")),
        ]
        if case .array(let hits)? = content.removeValue(forKey: "hits") {
            items = hits.map { hit in
                let row = object(hit)
                var buttons: [AgentWorkspaceButton] = []
                // IDs come only from the canonical hit, never its text/evidence.
                if let id = identifier(row["id"]) {
                    buttons.append(.init(label: "Read memory and evidence", action: .open(.record(
                        tool: "recall_memory", input: ["memory_id": .string(id), "offset": .int(0), "max_characters": .int(2000)], title: memoryTitle(row)))))
                }
                return .init(title: String((text(row["preview"]) ?? text(row["content"]) ?? "Memory").prefix(100)), content: hit, actions: buttons)
            }
            content["returned_memories"] = .int(Int64(hits.count))
        }
        if let id = identifier(input["memory_id"]), content["id"] == .string(id) {
            if let continuation = memoryContinuation(content["read_more"], id: id, page: content) {
                actions.insert(.init(label: "Read next part", action: .open(.record(tool: "recall_memory", input: continuation, title: memoryTitle(content)))), at: 0)
            } else if content["status"] == .string("record_changed") {
                actions.insert(.init(label: "Reopen changed memory", action: .open(.record(tool: "recall_memory", input: ["memory_id": .string(id), "offset": .int(0), "max_characters": .int(2000)], title: "Memory evidence"))), at: 0)
            }
        }
        return .init(title: "Memory", content: content.isEmpty ? result : .object(content), items: items, actions: actions)
    }

    static func memoryTitle(_ row: [String: JSONValue]) -> String {
        let excerpt = text(row["preview"]) ?? text(row["content"]) ?? ""
        let label = excerpt.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return label.isEmpty ? "Memory evidence" : "Memory: " + String(label.prefix(100))
    }

    private static func memoryContinuation(_ value: JSONValue?, id: String, page: [String: JSONValue]) -> [String: JSONValue]? {
        guard case .object(var next)? = value,
              Set(next.keys).isSubset(of: ["tool", "memory_id", "offset", "max_characters", "expected_content_sha256"]),
              next.removeValue(forKey: "tool") == .string("recall_memory"),
              next["memory_id"] == .string(id), page["status"] == .string("ok"),
              case .int(let offset)? = next["offset"], offset > 0,
              next["offset"] == page["next_offset"],
              case .int(let size)? = next["max_characters"], size > 0, size <= 2000,
              let hash = text(next["expected_content_sha256"]), hash.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              page["content_sha256"] == .string(hash) else { return nil }
        return next
    }

    private static func skills(_ result: JSONValue) -> AgentWorkspaceProjection {
        guard case .array(let skills) = result else {
            return .init(title: "Skills", content: result, items: [], actions: [])
        }
        let items = skills.map { skill -> AgentWorkspaceItem in
            let row = object(skill)
            let name = identifier(row["name"])
            // Prefer the exact registered ID; names are the owner's documented
            // fallback for persona body inventory. Neither is a filesystem path.
            let handle = identifier(row["id"]) ?? name
            let actions: [AgentWorkspaceButton] = handle.map { handle in
                [.init(label: "Open skill", action: .open(.record(tool: "read_skill", input: ["name": .string(handle)], title: name ?? "Skill")))]
            } ?? []
            return .init(title: name ?? "Skill", content: skill, actions: actions)
        }
        return .init(title: "Skills", content: .object([
            "returned_skills": .int(Int64(items.count)),
            "meaning": .string("Installed guidance; opening a skill does not grant authority or run it."),
        ]), items: items, actions: [
            .init(label: "Read a named skill", action: .perform(tool: "read_skill", input: [:], title: "Skill", textField: "name", isEffect: false), needsText: true),
            .init(label: "Write a skill", action: .configure(tool: "save_skill", input: [:], title: "Write a skill")),
        ])
    }

    private static func object(_ value: JSONValue) -> [String: JSONValue] {
        guard case .object(let row) = value else { return [:] }; return row
    }
    private static func text(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }; return value
    }
    private static func identifier(_ value: JSONValue?) -> String? {
        guard let value = text(value), !value.isEmpty, value.count <= 500,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }
    private static func validWebURL(_ value: JSONValue?) -> String? {
        guard let value = text(value), value.count <= 8192, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return value
    }
}
