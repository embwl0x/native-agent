import Foundation
import PersistenceCore
import ChatToolParsing
// Blueprint: | `AgentWorkspaceKnowledge.swift` | `AgentWorkspaceKnowledge` enum; `project`, `memoryTitle` |

/// Presents the existing memory and research owners without retaining
/// their content or interpreting instructions embedded in retrieved material.
enum AgentWorkspaceKnowledge {
    static let destinations: [AgentWorkspaceDestination] = [
        .init(id: "memory", title: "Memory", summary: "Recall something, inspect its evidence, or record a memory.",
              tool: "recall_memory", searchField: "query", tools: ["recall_memory", "commit_memory"], searchLabel: "Recall something"),
        .init(id: "research", title: "Research", summary: "Search the web, read a source, or investigate in the browser.",
              tool: nil, tools: ["read_page", "browser.chrome_navigate"]),
    ]

    /// Her private web search, never a tab.
    static let webSearchTool = "web_search"

    static let readTools: Set<String> = ["recall_memory", "recall_search", "read_page", webSearchTool]

    static func project(tool: String, input: [String: JSONValue], result: JSONValue) -> WorkspacePage? {
        switch tool {
        case webSearchTool: return webSearch(input: input, result: result)
        case "recall_memory", "recall_search": return memory(input: input, result: result)
        case "read_page":
            // Coverage and source receipts stay attached, including partial or
            // unsupported extraction. A fetch is never labeled verified truth.
            var actions: [AgentWorkspaceButton] = [
                .init(label: "Search the web", action: .searchWeb, needsText: true),
                .init(label: "Read another web page", action: .perform(tool: "read_page", input: [:], title: "Web source", textField: "url", isEffect: false), needsText: true),
            ]
            if let url = validWebURL(input["url"]) {
                actions.append(.init(label: "Open in browser", action: .perform(tool: "browser.chrome_navigate",
                    input: ["url": .string(url)],
                    title: "Background browser", textField: nil, isEffect: true)))
            }
            return .init(title: "Web source", content: result, items: [], actions: actions)
        default: return nil
        }
    }

    /// Search results as rows: each one reads privately (read_page) or,
    /// only when she picks it, opens in her Chrome tab.
    private static func webSearch(input: [String: JSONValue], result: JSONValue) -> WorkspacePage {
        var content = result.objectValue ?? [:]
        var inner = (content.removeValue(forKey: "result") ?? .null).objectValue ?? [:]
        let rows: [JSONValue] = if case .array(let list)? = inner.removeValue(forKey: "results") ?? content.removeValue(forKey: "results") { list } else { [] }
        content.merge(inner) { old, _ in old }
        let items = rows.compactMap { value -> AgentWorkspaceItem? in
            let row = value.objectValue ?? [:]
            guard let url = validWebURL(row["url"]) else { return nil }
            let title = row["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? url
            // A row reads as title · site · snippet; Bing's "…Read more" tail says nothing.
            let site = URL(string: url)?.host?.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression) ?? url
            let snippet = row["snippet"]?.stringValue?.replacingOccurrences(of: #"\s*(…|\.\.\.)?\s*Read more$"#, with: "…", options: .regularExpression)
            return .init(title: String(title.prefix(200)), content: .object(["site": .string(site), "snippet": snippet.map(JSONValue.string) ?? .null]), actions: [
                .init(label: "Read this page", action: .open(.record(tool: "read_page", input: ["url": .string(url)], title: String(title.prefix(100))))),
                // Navigation reuses this conversation's tab or opens one in her group.
                .init(label: "Chrome: open it in my tab", action: .perform(tool: "browser.chrome_navigate",
                    input: ["url": .string(url)], title: "Background browser", textField: nil, isEffect: true)),
            ])
        }
        // A failed search reads as its error, never as "no results".
        let failed = ChatToolOutcome.carriesFailureEvidence(result)
        if !failed, content["status"] == nil || content["status"] == .string("ok") {
            content["status"] = .string("ok")
            if items.isEmpty { content["message"] = .string("No results. Try other words.") }
            if let query = input["query"]?.stringValue { content["about"] = .string("Private search for \"\(query.prefix(80))\"; no browser tab was opened.") }
        }
        return .init(title: "Web search", content: .object(content), items: items, actions: [
            .init(label: "Search again", action: .perform(tool: webSearchTool, input: [:], title: "Web search", textField: "query", isEffect: false), needsText: true),
        ])
    }

    private static func memory(input: [String: JSONValue], result: JSONValue) -> WorkspacePage {
        var content = result.objectValue ?? [:]
        var items: [AgentWorkspaceItem] = []
        var actions: [AgentWorkspaceButton] = [
            .init(label: "Recall something else", action: .perform(tool: "recall_memory", input: [:], title: "Memory", textField: "query", isEffect: false), needsText: true),
            .init(label: "Record a memory", action: .configure(tool: "commit_memory", input: [:], title: "Record a memory")),
        ]
        if case .array(let hits)? = content.removeValue(forKey: "hits") {
            items = hits.map { hit in
                let row = hit.objectValue ?? [:]
                var buttons: [AgentWorkspaceButton] = []
                // IDs come only from the canonical hit, never its text/evidence.
                if let id = identifier(row["id"]) {
                    buttons.append(.init(label: "Read memory and evidence", action: .open(.record(
                        tool: "recall_memory", input: ["memory_id": .string(id), "offset": .int(0), "max_characters": .int(2000)], title: memoryTitle(row)))))
                }
                return .init(title: String((row["preview"]?.stringValue ?? row["content"]?.stringValue ?? "Memory").prefix(100)), content: hit, actions: buttons)
            }
            content["returned_memories"] = .int(Int64(hits.count))
            if content["has_more"] == .bool(true), let query = input["query"]?.stringValue,
               case .int(let offset)? = content["next_offset"], offset > 0 {
                var next = input
                next["query"] = .string(query)
                next["offset"] = .int(offset)
                actions.insert(.init(label: "More memories", action: .open(.record(
                    tool: "recall_memory", input: next, title: "Memory"))), at: 0)
            }
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
        let excerpt = row["preview"]?.stringValue ?? row["content"]?.stringValue ?? ""
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
              let hash = next["expected_content_sha256"]?.stringValue, hash.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              page["content_sha256"] == .string(hash) else { return nil }
        return next
    }


    private static func identifier(_ value: JSONValue?) -> String? {
        guard let value = value?.stringValue, !value.isEmpty, value.count <= 500,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }
    private static func validWebURL(_ value: JSONValue?) -> String? {
        guard let value = value?.stringValue, value.count <= 8192, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return value
    }
}
