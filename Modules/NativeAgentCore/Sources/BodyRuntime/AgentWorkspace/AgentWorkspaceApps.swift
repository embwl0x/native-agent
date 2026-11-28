import Foundation
import PersistenceCore
// Blueprint: | `AgentWorkspaceApps.swift` | `AgentWorkspaceApps`: file/Mac/browser projections, app action discovery, and bounded workspace text fields |

enum AgentWorkspaceApps {
    static let destinations: [AgentWorkspaceDestination] = [
        .init(id: "computer", title: "Computer", summary: "Look at the Mac, select a current control, and act on it.", tool: "screen", input: ["structured"
            : .bool(true)], tools: ["screen", "go", "act", "wait"]),
        .init(id: "browser", title: "Browser", summary: "Your conversation's browser tab, with page controls ready to select.", tool: "browser.chrome_status",
            tools: ["browser.chrome_snapshot", "browser.chrome_navigate"]),
        .init(id: "files", title: "Files", summary: "Browse the workspace and open its documents.", tool: "list_dir", input: ["path": .string("$workspace"),
            "max_entries": .int(12)], tools: ["list_dir", "read_file", "write_file"]),
        .init(id: "create", title: "Create", summary: "Make a document, image or other artifact using available capabilities.", tool: nil,
            tools: ["write_file", "image_generate"]),
    ]

    static let readTools: Set<String> = ["list_dir", "screen", "menu", "read", "browser.chrome_status", "browser.chrome_snapshot", "browser.read_text",
        "browser.read_links"]

    static func quickAction(tool: String) -> AgentWorkspaceButton? {
        if tool == "browser.chrome_snapshot" {
            return AgentWorkspaceActivity.read("Read my current tab", tool: tool, input: [:])
        }
        switch tool {
        case "commit_memory":
            return .init(label: "Record a memory", action: .open(.record(tool: "app", input: ["find": .string(tool), "args": .object([:])], title: "Record a memory")))
        case "contacts_create_or_update":
            return .init(label: "New contact", action: .open(.record(tool: "app", input: ["find": .string(tool), "args": .object([:])], title: "New contact")))
        case "read_page":
            return .init(label: "Read a web page privately, no tab", action: .perform(tool: tool, input: [:], title: "Web source",
                                                                                      textField: "url", isEffect: false), needsText: true)
        default: break
        }
        if tool == "browser.chrome_navigate" {
            return .init(label: "Go to a website address in my tab",
                action: .perform(tool: tool, input: [:], title: "Go to a website address", textField: "url", isEffect: true), needsText: true)
        }
        return nil
    }

    static func project(tool: String, input: [String: JSONValue], result: JSONValue) -> WorkspacePage? {
        switch tool {
        case "list_dir": return directory(input: input, result: result)
        case "browser.chrome_status":
            let actions = quickAction(tool: "browser.chrome_navigate").map { [$0] } ?? []
            return .init(title: "Browser", content: result, items: [], actions: actions)
        case "browser.chrome_snapshot": return browser(input: input, result: result)
        case "screen": return computer(input: input, result: result)
        case "menu": return menu(result: result)
        default: return nil
        }
    }

    static func computerLocation(input: [String: JSONValue] = [:], result: JSONValue) -> AgentWorkspaceLocation? {
        let row = JSONValue.objectOrEmpty(result), controls = JSONValue.objectOrEmpty(JSONValue.objectOrEmpty(row["detail"])["controls"] ?? .null)
        let app = JSONValue.objectOrEmpty(controls["app"])
        guard row["ok"] == .bool(true), let identity = boundedString(app["bundle_id"]) ?? boundedString(app["name"]) else { return nil }
        var arguments: [String: JSONValue] = ["app": .string(identity), "structured": .bool(true)]
        if let part = input["part"] { arguments["part"] = part }
        return .record(tool: "screen", input: arguments, title: boundedString(app["name"]) ?? identity)
    }

    private static func computer(input: [String: JSONValue], result: JSONValue) -> WorkspacePage {
        var row = JSONValue.objectOrEmpty(result)
        var detail = JSONValue.objectOrEmpty(row["detail"])
        var controls = JSONValue.objectOrEmpty(detail["controls"])
        var items: [AgentWorkspaceItem] = []
        if row["ok"] == .bool(true), let frame = boundedString(controls["frame_id"]),
           case .array(let affordances)? = controls["affordances"] {
            for value in affordances.prefix(60) {
                let control = JSONValue.objectOrEmpty(value)
                guard control["enabled"] == .bool(true), control["handle_ambiguous"] != .bool(true),
                      let handle = boundedString(control["handle"]), let role = boundedString(control["role"]) else { continue }
                let name = boundedString(control["label"]) ?? "Unnamed " + role
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
            let projected = Set(items.compactMap { boundedString(JSONValue.objectOrEmpty($0.content)["handle"]) })
            controls["affordances"] = .array(affordances.filter { !projected.contains(boundedString(JSONValue.objectOrEmpty($0)["handle"]) ?? "") })
            detail["controls"] = .object(controls)
            row["detail"] = .object(detail)
        }
        row["workspace_actionable_count"] = .int(Int64(items.count))
        if controls["front"] != .bool(true), !items.isEmpty {
            row["workspace_actionable_count"] = .int(0)
            row["window_state"] = .string("This app is in the background. Bring it forward to receive fresh actionable controls; reading did not steal focus.")
        }
        row["workspace_detail"] = .string(items.isEmpty
            ? """
                No selectable accessibility controls were available in this observation. Use the natural screen or pixels for content the app does not \
                publish as controls.
                """
            : """
                Select a control and its action. NativeAgent carries the exact observation binding; a changed target is refused and refreshed rather than \
                guessed or clicked again.
                """)
        let app = JSONValue.objectOrEmpty(controls["app"])
        let appName = boundedString(app["bundle_id"]) ?? boundedString(app["name"]) ?? boundedString(input["app"])
        var readInput: [String: JSONValue] = ["structured": .bool(true)]
        if let appName { readInput["app"] = .string(appName) }
        if let part = input["part"] { readInput["part"] = part }
        var actions: [AgentWorkspaceButton] = [
            AgentWorkspaceActivity.read("Look again", tool: "screen", input: readInput),
            .init(label: "Go to an app or location", action: .perform(tool: "go", input: [:], title: "Go to an app or location", textField: "name",
                isEffect: true), needsText: true),
            AgentWorkspaceActivity.read("Read app menu", tool: "menu", input: appName.map { ["app": .string($0)] } ?? [:]),
            .init(label: "Act by name or on a visual region", action: .open(.record(tool: "app", input: ["find": .string("act"), "args": .object([:])], title: "Act on the screen"))),
            AgentWorkspaceActivity.read("Look at desktop pixels", tool: "screen", input: ["pixels": .bool(true)]),
        ]
        if let appName {
            actions.insert(.init(label: "Bring this app forward", action: .perform(tool: "go",
                input: ["name": .string(appName)], title: "Open " + (boundedString(app["name"]) ?? appName), textField: nil, isEffect: true)), at: 1)
            actions.append(AgentWorkspaceActivity.read("Look at frontmost app", tool: "screen", input: ["structured": .bool(true)]))
        }
        return .init(title: boundedString(app["name"]) ?? boundedString(input["app"]) ?? "Computer", content: .object(row), items: items, actions: actions)
    }

    private static func menu(result: JSONValue) -> WorkspacePage {
        let envelope = JSONValue.objectOrEmpty(result)
        var output = JSONValue.objectOrEmpty(envelope["output"])
        let app = JSONValue.objectOrEmpty(output["app"])
        guard envelope["ok"] == .bool(true), output["available"] == .bool(true),
              let appName = boundedString(app["bundle_id"]) ?? boundedString(app["name"]),
              case .array(let paths)? = output["paths"] else {
            return .init(title: "Computer menu", content: result, items: [], actions: [AgentWorkspaceActivity.read("Look again", tool: "screen", input: ["structured": .bool(
                true)])])
        }
        let items: [AgentWorkspaceItem] = paths.prefix(80).compactMap { value in
            let item = JSONValue.objectOrEmpty(value)
            guard item["enabled"] == .bool(true), item["opens_submenu"] != .bool(true), let path = boundedString(item["path"]) else { return nil }
            return .init(title: path, content: value, actions: [.init(label: "Choose", action: .perform(tool: "menu_press",
                input: ["app": .string(appName), "path": .string(path)], title: path, textField: nil, isEffect: true))])
        }
        let projected = Set(items.map(\.title))
        output["paths"] = .array(paths.filter { !projected.contains(boundedString(JSONValue.objectOrEmpty($0)["path"]) ?? "") })
        var content = envelope; content["output"] = .object(output)
        return .init(title: "Computer menu", content: .object(content), items: items, actions: [
            AgentWorkspaceActivity.read("Read this app menu again", tool: "menu", input: ["app": .string(appName)]),
            AgentWorkspaceActivity.read("Return to screen", tool: "screen", input: ["structured": .bool(true)]),
        ])
    }

    private static func directory(input: [String: JSONValue], result: JSONValue) -> WorkspacePage {
        let row = JSONValue.objectOrEmpty(result)
        guard row["ok"] == .bool(true), row["status"] == .string("ok"),
              let path = boundedString(row["path"]), path.hasPrefix("/"),
              case .array(let entries)? = row["entries"] else {
            return .init(title: "Files", content: result, items: [], actions: [])
        }
        var items: [AgentWorkspaceItem] = []
        for value in entries {
            guard case .string(let entry) = value else { continue }
            let isDirectory = entry.hasSuffix("/")
            let name = isDirectory ? String(entry.dropLast()) : entry
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { continue }
            let child = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name).path
            let tool = isDirectory ? "list_dir" : "read_file"
            let arguments: [String: JSONValue] = isDirectory
                ? ["path": .string(child), "max_entries": .int(12)]
                : ["path": .string(child), "max_bytes": .int(12000)]
            items.append(.init(title: name, content: .object(["path": .string(child), "kind": .string(isDirectory ? "folder" : "file")]), actions: [AgentWorkspaceActivity.read(
                isDirectory ? "Open folder" : "Open file", tool: tool, input: arguments, title: (isDirectory ? "Folder: " : "File: ") + name)]))
        }
        var actions: [AgentWorkspaceButton] = [
            .init(label: "Find a filename in this folder", action: .perform(tool: "list_dir", input: ["path": .string(path), "max_entries": .int(12)],
                title: "Find a filename", textField: "name_contains", isEffect: false), needsText: true),
            .init(label: "Create a file", action: .open(.record(tool: "app",
                input: ["find": .string("files.write")], title: "Create a file"))),
        ]
        if row["has_more"] == .bool(true), case .object(let next)? = row["next"],
           Set(next.keys).isSubset(of: ["path", "name_contains", "case_sensitive", "max_entries", "offset", "snapshot"]),
           next["path"] == input["path"], next["name_contains"] == row["name_contains"],
           next["case_sensitive"] == row["case_sensitive"], next["snapshot"] == row["snapshot"],
           boundedString(next["snapshot"]) != nil,
           let offset = next["offset"]?.strictInt64, let current = row["offset"]?.strictInt64, offset > current,
           let count = next["max_entries"]?.strictInt64, count > 0, count <= 200 {
            actions.insert(AgentWorkspaceActivity.read("Next files", tool: "list_dir", input: next), at: 0)
        }
        var metadata = row
        metadata.removeValue(forKey: "entries")
        return .init(title: "Files: " + path, content: .object(metadata), items: items, actions: actions)
    }

    private static func browser(input: [String: JSONValue], result: JSONValue) -> WorkspacePage {
        let row = JSONValue.objectOrEmpty(result)
        guard row["ok"] != .bool(false), row["error"] == nil,
              let snapshot = boundedString(row["snapshotId"]),
              let sequence = row["userSequence"]?.strictInt64, sequence >= 0,
              let tab = row["tabId"]?.strictInt64, tab >= 0,
              case .array(let nodes)? = row["nodes"] else {
            let retry: [AgentWorkspaceButton] = input["tab_id"]?.strictInt64.map { tab in
                var arguments: [String: JSONValue] = ["tab_id": .int(tab)]
                if input["scope"] == .string("main_content") { arguments["scope"] = .string("main_content") }
                return [AgentWorkspaceActivity.read("Read this page again", tool: "browser.chrome_snapshot", input: arguments)]
            } ?? []
            return .init(title: "Browser page", content: result, items: [], actions: retry)
        }
        var items: [AgentWorkspaceItem] = []
        for value in nodes {
            guard case .object(let node) = value, let id = boundedString(node["nodeId"]),
                  node["visible"] == .bool(true), case .object(let states)? = node["states"],
                  states["disabled"] == .bool(false), states["blockedByModal"] != .bool(true),
                  case .array(let available)? = node["actions"] else { continue }
            let number = id.hasPrefix("n") ? String(id.dropFirst()) : id
            let bound: [String: JSONValue] = ["tab_id": .int(tab), "expected_user_sequence": .int(sequence), "snapshot_id": .string(snapshot), "node_id"
                : .string(number)]
            let name = boundedString(node["name"]) ?? boundedString(node["text"]) ?? "Page control"
            var buttons: [AgentWorkspaceButton] = []
            if available.contains(.string("click")) {
                buttons.append(.init(label: "Click", action: .perform(tool: "browser.chrome_click", input: bound, title: name, textField: nil, isEffect: true)))
            }
            if available.contains(.string("fill")), states["editable"] == .bool(true) {
                buttons.append(.init(label: "Fill", action: .perform(tool: "browser.chrome_fill", input: bound, title: name, textField: "value",
                    isEffect: true), needsText: true))
            }
            if available.contains(.string("select")) {
                buttons.append(.init(label: "Choose an option", action: .open(.record(tool: "app", input: ["find": .string("browser.chrome_select"), "args": .object(bound)], title: name))))
            }
            if !buttons.isEmpty { items.append(.init(title: name, content: value, actions: buttons)) }
        }
        var metadata = row
        let projectedIDs = Set(items.compactMap { boundedString(JSONValue.objectOrEmpty($0.content)["nodeId"]) })
        metadata["nodes"] = .array(nodes.filter { value in
            guard let id = boundedString(JSONValue.objectOrEmpty(value)["nodeId"]) else { return true }
            return !projectedIDs.contains(id)
        })
        metadata["workspace_actionable_count"] = .int(Int64(items.count))
        var current: [String: JSONValue] = ["tab_id": .int(tab)]
        let reading = JSONValue.objectOrEmpty(row["reading"])
        let mainContent = reading["scope"] == .string("main_content")
        if mainContent { current["scope"] = .string("main_content") }
        var readingActions: [AgentWorkspaceButton] = []
        if mainContent {
            var whole = current; whole["scope"] = .string("page")
            readingActions.append(AgentWorkspaceActivity.read("Read whole page", tool: "browser.chrome_snapshot", input: whole))
            metadata["workspace_reading"] = .string(reading["mainContentAvailable"] == .bool(true)
                ? "Reading the visible main content. Page down continues through the rendered article; this is not a claim that offscreen content was read."
                : "No main region declared: reading the page without its navigation (Read whole page adds it).")
        } else if reading["mainContentAvailable"] == .bool(true) {
            var main = current; main["scope"] = .string("main_content")
            readingActions.append(AgentWorkspaceActivity.read("Read main content", tool: "browser.chrome_snapshot", input: main))
        }
        let navigation: [String: JSONValue] = ["tab_id": .int(tab), "expected_user_sequence": .int(sequence)]
        let pageDown = navigation.merging(["delta_x": .int(0), "delta_y": .int(700)]) { _, new in new }
        let pageUp = navigation.merging(["delta_x": .int(0), "delta_y": .int(-700)]) { _, new in new }
        return .init(title: boundedString(row["title"]) ?? "Browser page", content: .object(metadata), items: items, actions: readingActions + [
            AgentWorkspaceActivity.read("Read page again", tool: "browser.chrome_snapshot", input: current),
            .init(label: "Go to a website", action: .perform(tool: "browser.chrome_navigate", input: navigation, title: "Go to a website", textField: "url",
                isEffect: true), needsText: true),
            .init(label: "Page down", action: .perform(tool: "browser.chrome_scroll", input: pageDown, title: "Page down", textField: nil, isEffect: true)),
            .init(label: "Page up", action: .perform(tool: "browser.chrome_scroll", input: pageUp, title: "Page up", textField: nil, isEffect: true)),
            .init(label: "Scroll a precise amount or container", action: .open(.record(tool: "app", input: ["find": .string("browser.chrome_scroll"), "args": .object(navigation)], title: "Scroll a precise amount or container"))),
        ])
    }

    static func boundedString(_ value: JSONValue?) -> String? {
        guard let text = value?.nonemptyString, text.count <= 8192 else { return nil }
        return text
    }
}
