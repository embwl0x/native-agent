import Foundation
import PersistenceCore

/// Views of the file, Mac and browser owners. This adapter performs no I/O,
/// scans no prose for instructions and never interprets a page as a tool plan.
enum AgentWorkspaceApps {
    static let destinations: [AgentWorkspaceDestination] = [
        .init(id: "computer", title: "Computer", summary: "Look at the Mac, select a current control, and act on it.", tool: "screen", input: ["structured": .bool(true)], tools: ["screen", "go", "act", "wait"]),
        .init(id: "browser", title: "Browser", summary: "Your conversation's browser tab, with page controls ready to select.", tool: "browser.chrome_status", tools: ["browser.chrome_snapshot", "browser.chrome_acquire", "browser.chrome_navigate"]),
        // The environment resolves this destination to the canonical workspace
        // root. A relative dot can mean a source checkout on developer installs.
        .init(id: "files", title: "Files", summary: "Browse the workspace and open its documents.", tool: "list_dir", input: ["path": .string("$workspace"), "max_entries": .int(12)], tools: ["list_dir", "read_file", "write_file"]),
        .init(id: "create", title: "Create", summary: "Make a document, image or other artifact using available capabilities.", tool: nil, tools: ["write_file", "image_generate", "save_skill"]),
    ]

    static let readTools: Set<String> = ["list_dir", "screen", "menu", "read", "browser.chrome_status", "browser.chrome_snapshot", "browser.read_text", "browser.read_links"]

    /// Small, explicit controls for common actions. The underlying owner still
    /// validates the supplied website and applies the normal conversation gates.
    static func quickAction(tool: String) -> AgentWorkspaceButton? {
        if tool == "browser.chrome_snapshot" {
            return readButton("Read my current tab", tool: tool,
                input: ["max_nodes": .int(80), "max_text_chars": .int(10000)])
        }
        switch tool {
        case "app_page_read":
            return .init(label: "Read a page (chat, today, memories, desk, bots, personality, providers, trust, connectors, capabilities, diagnostics, settings)",
                action: .perform(tool: tool, input: [:], title: "Read a page", textField: "page", isEffect: false), needsText: true)
        case "app_page_screenshot":
            return .init(label: "Look at a page", action: .perform(tool: tool, input: [:], title: "Look at a page", textField: "page", isEffect: false), needsText: true)
        default: break
        }
        if tool == "browser.chrome_navigate" {
            return .init(label: "Go to a website address in my tab",
                action: .perform(tool: tool, input: [:], title: "Go to a website address", textField: "url", isEffect: true), needsText: true)
        }
        guard tool == "browser.chrome_acquire" else { return nil }
        return .init(
            label: "Open a website in a new tab",
            action: .perform(tool: tool, input: ["mode": .string("create")], title: "Open a website in a new tab", textField: "initial_url", isEffect: true),
            needsText: true
        )
    }

    static func project(tool: String, input: [String: JSONValue], result: JSONValue) -> AgentWorkspaceProjection? {
        switch tool {
        case "list_dir": return directory(input: input, result: result)
        case "browser.chrome_status":
            let row = object(result)
            var actions = quickAction(tool: "browser.chrome_acquire").map { [$0] } ?? []
            return .init(title: "Browser", content: result, items: [], actions: actions)
        case "browser.chrome_snapshot": return browser(input: input, result: result)
        case "screen": return computer(input: input, result: result)
        case "menu": return menu(result: result)
        default: return nil
        }
    }

    static func computerLocation(input: [String: JSONValue] = [:], result: JSONValue) -> AgentWorkspaceLocation? {
        let row = object(result), controls = object(object(row["detail"] ?? .null)["controls"] ?? .null)
        let app = object(controls["app"] ?? .null)
        guard row["ok"] == .bool(true), let identity = string(app["bundle_id"]) ?? string(app["name"]) else { return nil }
        var arguments: [String: JSONValue] = ["app": .string(identity), "structured": .bool(true)]
        if let part = input["part"] { arguments["part"] = part }
        return .record(tool: "screen", input: arguments, title: string(app["name"]) ?? identity)
    }

    private static func computer(input: [String: JSONValue], result: JSONValue) -> AgentWorkspaceProjection {
        var row = object(result)
        var detail = object(row["detail"] ?? .null)
        var controls = object(detail["controls"] ?? .null)
        var items: [AgentWorkspaceItem] = []
        if row["ok"] == .bool(true), let frame = string(controls["frame_id"]),
           case .array(let affordances)? = controls["affordances"] {
            for value in affordances.prefix(60) {
                let control = object(value)
                guard control["enabled"] == .bool(true), control["handle_ambiguous"] != .bool(true),
                      let handle = string(control["handle"]), let role = string(control["role"]) else { continue }
                let name = string(control["label"]) ?? "Unnamed " + role
                let bound: [String: JSONValue] = ["handle": .string(handle), "frame_id": .string(frame), "target": .string(name)]
                func button(_ label: String, verb: String, text: Bool = false) -> AgentWorkspaceButton {
                    .init(label: label, action: .perform(tool: "act", input: bound.merging(["verb": .string(verb)]) { _, new in new },
                        title: name, textField: text ? "text" : nil, isEffect: true), needsText: text)
                }
                var actions: [AgentWorkspaceButton] = []
                switch role {
                case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField":
                    actions = [button("Type here", verb: "type", text: true)]
                case "AXCheckBox", "AXRadioButton", "AXSwitch":
                    actions = [button("Toggle", verb: "toggle")]
                case "AXRow", "AXCell":
                    actions = [button("Select", verb: "select"), button("Open", verb: "open")]
                default:
                    actions = [button("Click", verb: "click")]
                }
                if controls["front"] != .bool(true) { actions = [] }
                items.append(.init(title: name, content: value, actions: actions))
            }
            // Do not repeat all control records in both metadata and items.
            let projected = Set(items.compactMap { string(object($0.content)["handle"]) })
            controls["affordances"] = .array(affordances.filter { !projected.contains(string(object($0)["handle"]) ?? "") })
            detail["controls"] = .object(controls)
            row["detail"] = .object(detail)
        }
        row["workspace_actionable_count"] = .int(Int64(items.count))
        if controls["front"] != .bool(true), !items.isEmpty {
            row["workspace_actionable_count"] = .int(0)
            row["window_state"] = .string("This app is in the background. Bring it forward to receive fresh actionable controls; reading did not steal focus.")
        }
        row["workspace_detail"] = .string(items.isEmpty
            ? "No selectable accessibility controls were available in this observation. Use the natural screen or pixels for content the app does not publish as controls."
            : "Select a control and its action. NativeAgent carries the exact observation binding; a changed target is refused and refreshed rather than guessed or clicked again.")
        let app = object(controls["app"] ?? .null)
        let appName = string(app["bundle_id"]) ?? string(app["name"]) ?? string(input["app"])
        var readInput: [String: JSONValue] = ["structured": .bool(true)]
        if let appName { readInput["app"] = .string(appName) }
        if let part = input["part"] { readInput["part"] = part }
        var actions: [AgentWorkspaceButton] = [
            readButton("Look again", tool: "screen", input: readInput),
            .init(label: "Go to an app or location", action: .perform(tool: "go", input: [:], title: "Go to an app or location", textField: "name", isEffect: true), needsText: true),
            readButton("Read app menu", tool: "menu", input: appName.map { ["app": .string($0)] } ?? [:]),
            .init(label: "Act by name or on a visual region", action: .configure(tool: "act", input: [:], title: "Act on the screen")),
            readButton("Look at desktop pixels", tool: "screen", input: ["pixels": .bool(true)]),
        ]
        if let appName {
            actions.insert(.init(label: "Bring this app forward", action: .perform(tool: "go",
                input: ["name": .string(appName)], title: "Open " + (string(app["name"]) ?? appName), textField: nil, isEffect: true)), at: 1)
            actions.append(readButton("Look at frontmost app", tool: "screen", input: ["structured": .bool(true)]))
        }
        return .init(title: string(app["name"]) ?? string(input["app"]) ?? "Computer", content: .object(row), items: items, actions: actions)
    }

    private static func menu(result: JSONValue) -> AgentWorkspaceProjection {
        let envelope = object(result)
        var output = object(envelope["output"] ?? .null)
        let app = object(output["app"] ?? .null)
        guard envelope["ok"] == .bool(true), output["available"] == .bool(true),
              let appName = string(app["bundle_id"]) ?? string(app["name"]),
              case .array(let paths)? = output["paths"] else {
            return .init(title: "Computer menu", content: result, items: [], actions: [readButton("Look again", tool: "screen", input: ["structured": .bool(true)])])
        }
        let items: [AgentWorkspaceItem] = paths.prefix(80).compactMap { value in
            let item = object(value)
            guard item["enabled"] == .bool(true), item["opens_submenu"] != .bool(true), let path = string(item["path"]) else { return nil }
            return .init(title: path, content: value, actions: [.init(label: "Choose", action: .perform(tool: "menu_press",
                input: ["app": .string(appName), "path": .string(path)], title: path, textField: nil, isEffect: true))])
        }
        let projected = Set(items.map(\.title))
        output["paths"] = .array(paths.filter { !projected.contains(string(object($0)["path"]) ?? "") })
        var content = envelope; content["output"] = .object(output)
        return .init(title: "Computer menu", content: .object(content), items: items, actions: [
            readButton("Read this app menu again", tool: "menu", input: ["app": .string(appName)]),
            readButton("Return to screen", tool: "screen", input: ["structured": .bool(true)]),
        ])
    }

    private static func directory(input: [String: JSONValue], result: JSONValue) -> AgentWorkspaceProjection {
        let row = object(result)
        guard row["ok"] == .bool(true), row["status"] == .string("ok"),
              let path = string(row["path"]), path.hasPrefix("/"),
              case .array(let entries)? = row["entries"] else {
            return .init(title: "Files", content: result, items: [], actions: [])
        }
        var items: [AgentWorkspaceItem] = []
        for value in entries {
            guard case .string(let entry) = value else { continue }
            let isDirectory = entry.hasSuffix("/")
            let name = isDirectory ? String(entry.dropLast()) : entry
            // Immediate children only; never turn a display entry into an
            // absolute path, traversal, or an injected subpath.
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { continue }
            let child = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name).path
            let tool = isDirectory ? "list_dir" : "read_file"
            let arguments: [String: JSONValue] = isDirectory
                ? ["path": .string(child), "max_entries": .int(12)]
                : ["path": .string(child), "max_bytes": .int(12000)]
            items.append(.init(title: name, content: .object(["path": .string(child), "kind": .string(isDirectory ? "folder" : "file")]), actions: [readButton(isDirectory ? "Open folder" : "Open file", tool: tool, input: arguments, title: (isDirectory ? "Folder: " : "File: ") + name)]))
        }
        var actions: [AgentWorkspaceButton] = [
            .init(label: "Find a filename in this folder", action: .perform(tool: "list_dir", input: ["path": .string(path), "max_entries": .int(12)], title: "Find a filename", textField: "name_contains", isEffect: false), needsText: true),
            .init(label: "Create a file named…", action: .createFile(directory: path), needsText: true),
        ]
        if row["has_more"] == .bool(true), case .object(let next)? = row["next"],
           Set(next.keys).isSubset(of: ["path", "name_contains", "case_sensitive", "max_entries", "offset", "snapshot"]),
           next["path"] == input["path"], next["name_contains"] == row["name_contains"],
           next["case_sensitive"] == row["case_sensitive"], next["snapshot"] == row["snapshot"],
           string(next["snapshot"]) != nil,
           let offset = integer(next["offset"]), let current = integer(row["offset"]), offset > current,
           let count = integer(next["max_entries"]), count > 0, count <= 200 {
            actions.insert(readButton("Next files", tool: "list_dir", input: next), at: 0)
        }
        var metadata = row
        metadata.removeValue(forKey: "entries")
        return .init(title: "Files: " + path, content: .object(metadata), items: items, actions: actions)
    }

    private static func browser(input: [String: JSONValue], result: JSONValue) -> AgentWorkspaceProjection {
        let row = object(result)
        guard row["ok"] != .bool(false), row["error"] == nil,
              let snapshot = string(row["snapshotId"]), let lease = string(row["leaseId"]),
              let sequence = integer(row["userSequence"]), sequence >= 0,
              let tab = integer(row["tabId"]), tab >= 0,
              case .array(let nodes)? = row["nodes"] else {
            // Recovery stays with the exact selected lease. Never fall back to
            // whichever tab happens to be current after a refused/stale read.
            let retry: [AgentWorkspaceButton] = string(input["lease_id"]).map { lease in
                var arguments: [String: JSONValue] = ["lease_id": .string(lease), "max_nodes": .int(80), "max_text_chars": .int(10000)]
                if input["scope"] == .string("main_content") { arguments["scope"] = .string("main_content") }
                return [readButton("Read this page again", tool: "browser.chrome_snapshot", input: arguments)]
            } ?? []
            return .init(title: "Browser page", content: result, items: [], actions: retry)
        }
        var items: [AgentWorkspaceItem] = []
        for value in nodes {
            guard case .object(let node) = value, let id = string(node["nodeId"]),
                  node["visible"] == .bool(true), case .object(let states)? = node["states"],
                  states["disabled"] == .bool(false), states["blockedByModal"] != .bool(true),
                  case .array(let available)? = node["actions"] else { continue }
            let bound: [String: JSONValue] = ["lease_id": .string(lease), "expected_user_sequence": .int(sequence), "snapshot_id": .string(snapshot), "node_id": .string(id)]
            let name = string(node["name"]) ?? string(node["text"]) ?? "Page control"
            var buttons: [AgentWorkspaceButton] = []
            if available.contains(.string("click")) {
                buttons.append(.init(label: "Click", action: .perform(tool: "browser.chrome_click", input: bound, title: name, textField: nil, isEffect: true)))
            }
            if available.contains(.string("fill")), states["editable"] == .bool(true) {
                buttons.append(.init(label: "Fill", action: .perform(tool: "browser.chrome_fill", input: bound, title: name, textField: "value", isEffect: true), needsText: true))
            }
            if available.contains(.string("select")) {
                buttons.append(.init(label: "Choose an option", action: .configure(tool: "browser.chrome_select", input: bound, title: name)))
            }
            if !buttons.isEmpty { items.append(.init(title: name, content: value, actions: buttons)) }
        }
        var metadata = row
        // Keep reading content/ancestry without sending every actionable node
        // twice. The full control record is already in its item; non-actionable
        // text, containers and disabled controls remain reading evidence.
        let projectedIDs = Set(items.compactMap { string(object($0.content)["nodeId"]) })
        metadata["nodes"] = .array(nodes.filter { value in
            guard let id = string(object(value)["nodeId"]) else { return true }
            return !projectedIDs.contains(id)
        })
        metadata["workspace_actionable_count"] = .int(Int64(items.count))
        if object(row["rendering"] ?? .null)["readyState"] == .string("loading") {
            metadata["workspace_state"] = .string("loading")
            metadata["workspace_detail"] = .string("This is the page observed while it is still loading. Read page again for more; opening the tab is not proof that search results or replies have finished loading.")
        }
        var current: [String: JSONValue] = ["lease_id": .string(lease), "max_nodes": .int(80), "max_text_chars": .int(10000)]
        let reading = object(row["reading"] ?? .null)
        let mainContent = reading["scope"] == .string("main_content")
        if mainContent { current["scope"] = .string("main_content") }
        var readingActions: [AgentWorkspaceButton] = []
        if mainContent {
            var whole = current; whole["scope"] = .string("page")
            readingActions.append(readButton("Read whole page", tool: "browser.chrome_snapshot", input: whole))
            metadata["workspace_reading"] = .string(reading["mainContentAvailable"] == .bool(true)
                ? "Reading the visible main content. Page down continues through the rendered article; this is not a claim that offscreen content was read."
                : "No semantic main/article region was found. Read whole page to see the current controls and content.")
        } else if reading["mainContentAvailable"] == .bool(true) {
            var main = current; main["scope"] = .string("main_content")
            readingActions.append(readButton("Read main content", tool: "browser.chrome_snapshot", input: main))
        }
        let navigation: [String: JSONValue] = ["lease_id": .string(lease), "expected_user_sequence": .int(sequence)]
        // Page scrolling deliberately omits node/snapshot IDs; the owner binds
        // the exact lease and refuses a changed user sequence. These are effects
        // even though they only move the viewport, so Back never scrolls again.
        let pageDown = navigation.merging(["delta_x": .int(0), "delta_y": .int(700)]) { _, new in new }
        let pageUp = navigation.merging(["delta_x": .int(0), "delta_y": .int(-700)]) { _, new in new }
        return .init(title: string(row["title"]) ?? "Browser page", content: .object(metadata), items: items, actions: readingActions + [
            readButton("Read page again", tool: "browser.chrome_snapshot", input: current),
            .init(label: "Go to a website", action: .perform(tool: "browser.chrome_navigate", input: navigation, title: "Go to a website", textField: "url", isEffect: true), needsText: true),
            .init(label: "Page down", action: .perform(tool: "browser.chrome_scroll", input: pageDown, title: "Page down", textField: nil, isEffect: true)),
            .init(label: "Page up", action: .perform(tool: "browser.chrome_scroll", input: pageUp, title: "Page up", textField: nil, isEffect: true)),
            .init(label: "Scroll a precise amount or container", action: .configure(tool: "browser.chrome_scroll", input: navigation, title: "Scroll a precise amount or container")),
        ])
    }

    private static func readButton(_ label: String, tool: String, input: [String: JSONValue], title: String? = nil) -> AgentWorkspaceButton {
        .init(label: label, action: .open(.record(tool: tool, input: input, title: title ?? label)))
    }
    private static func object(_ value: JSONValue) -> [String: JSONValue] { if case .object(let row) = value { return row }; return [:] }
    private static func string(_ value: JSONValue?) -> String? { guard case .string(let text)? = value, !text.isEmpty, text.count <= 8192 else { return nil }; return text }
    private static func integer(_ value: JSONValue?) -> Int64? { guard case .int(let number)? = value else { return nil }; return number }
}
