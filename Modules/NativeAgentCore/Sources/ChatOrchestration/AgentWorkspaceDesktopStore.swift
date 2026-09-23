import Foundation
import CryptoKit
import Darwin
import PersistenceCore

struct AgentWorkspaceSavedDesktop: Sendable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var current: AgentWorkspaceLocation = .home
    var places: [AgentWorkspaceLocation] = []
    var workAnchor: AgentWorkspaceLocation?
    var workTopic: String?
    var path: [AgentWorkspaceLocation] = []
    var workNote: String?
    var keptPlaces: [AgentWorkspaceLocation] = []
    var focusedWork: Bool = false
    var lastWorkAction: AgentWorkspaceWorkReceipt?
    var placeActions: [String: AgentWorkspaceWorkReceipt] = [:]
}

struct AgentWorkspaceDesktopState: Sendable, Equatable {
    var current: AgentWorkspaceLocation = .home
    var places: [AgentWorkspaceLocation] = []
    var workAnchor: AgentWorkspaceLocation?
    var workTopic: String?
    var saved: [AgentWorkspaceSavedDesktop] = []
    var selectedWorkspaceID: String?
    var observations: [AgentWorkspaceChanges.Stamp] = []
    var path: [AgentWorkspaceLocation] = []
    var drafts: [AgentWorkspaceForm] = []
    var workNote: String?
    var keptPlaces: [AgentWorkspaceLocation] = []
    var focusedWork: Bool = false
    var lastWorkAction: AgentWorkspaceWorkReceipt?
    var placeActions: [String: AgentWorkspaceWorkReceipt] = [:]
}

/// Durable navigation references and allowlisted draft inputs, never authority,
/// loaded evidence or executable actions. Reopening obtains fresh owner state.
struct AgentWorkspaceDesktopStore: Sendable {
    private let directory: URL
    private let scopeHash: String
    private static let byteLimit = 512 * 1024
    var fileURL: URL { directory.appendingPathComponent(scopeHash + ".json") }

    init(dataRoot: URL, scope: String) {
        directory = dataRoot.appendingPathComponent("workspace_desktops", isDirectory: true)
        scopeHash = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func load() throws -> AgentWorkspaceDesktopState? {
        try withDirectory(create: false) { fd in
            guard fd >= 0 else { return nil }
            return try read(fd)
        }
    }

    func save(_ state: AgentWorkspaceDesktopState) throws {
        let normalized = try Self.normalized(state)
        let wire = WireState(version: 2, scope: scopeHash, current: WireLocation(normalized.current),
            places: normalized.places.map(WireLocation.init), workAnchor: normalized.workAnchor.map(WireLocation.init),
            workTopic: normalized.workTopic, saved: normalized.saved.map(WireSaved.init), selectedWorkspaceID: normalized.selectedWorkspaceID,
            observations: normalized.observations, path: normalized.path.map(WireLocation.init),
            drafts: normalized.drafts.map(AgentWorkspaceForm.Stored.init), workNote: normalized.workNote,
            keptPlaces: normalized.keptPlaces.map(WireLocation.init), focusedWork: normalized.focusedWork,
            lastWorkAction: normalized.lastWorkAction, placeActions: normalized.placeActions)
        let data = try JSONEncoder().encode(wire)
        guard data.count <= Self.byteLimit else { throw Failure.capacity }
        try withDirectory(create: true) { fd in
            // Refuse to replace an unreadable/corrupt existing desktop. Its
            // evidence remains available for recovery rather than being erased.
            _ = try read(fd)
            let temporary = "." + scopeHash + "." + UUID().uuidString + ".tmp"
            let output = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw Failure.io }
            var closed = false
            defer { if !closed { close(output) }; unlinkat(fd, temporary, 0) }
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { throw Failure.invalid }
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(output, base.advanced(by: written), bytes.count - written)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw Failure.io }
                    written += count
                }
            }
            guard fsync(output) == 0 else { throw Failure.io }
            let result = close(output); closed = true
            guard result == 0, renameat(fd, temporary, fd, scopeHash + ".json") == 0, fsync(fd) == 0 else { throw Failure.io }
        }
    }

    /// Whitelist stable references, dropping transient cursors and display
    /// content. Unknown tools are deliberately not serialized as future actions.
    static func durable(_ location: AgentWorkspaceLocation) -> AgentWorkspaceLocation? {
        switch location {
        case .home: return .home
        case .openPlaces: return .openPlaces
        case .savedWorkspaces: return .savedWorkspaces
        case .workOverview: return .workOverview
        case .arrivals: return nil
        case .find(let value): return clean(value, limit: 400).map(AgentWorkspaceLocation.find)
        case .work(let value): return clean(value, limit: 400).map(AgentWorkspaceLocation.work)
        case .documents(let value): return clean(value, limit: 400).map(AgentWorkspaceLocation.documents)
        case .people(let page): return .people(page: max(0, min(page, 4096)))
        case .conversations(let page): return .conversations(page: max(0, min(page, 4096)))
        case .area(let id):
            return AgentWorkspaceEnvironment.destinations.contains { $0.id == id } ? .area(id) : nil
        case .capabilities: return .home
        case .page(let source, let page):
            // View offsets carry no content or executable authority. Nested
            // paging is flattened so malicious stored recursion cannot grow.
            if case .page = source { return nil }
            guard let saved = durable(source), page >= 0, page <= 4096 else { return nil }
            return .page(saved, page)
        case .form(let form): return form.canPersist ? location : nil
        case .receipt(_, _, _, let readback): return readback.flatMap(durable)
        case .browserBookmark(let url, let title, let tabID):
            guard validURL(url), title.count <= 8192, let label = clean(title, limit: 8192) else { return nil }
            if let tabID, !(0...9_007_199_254_740_991).contains(tabID) { return nil }
            return .browserBookmark(url: url, title: label, tabID: tabID)
        case .record(let tool, let input, let title):
            if tool.hasPrefix("browser.") { return .area("browser") }
            guard let label = clean(title, limit: 120) else { return nil }
            let keys: Set<String>
            let required: Set<String>
            switch tool {
            case "read_file", "list_dir": keys = ["path"]; required = keys
            case "agent_read": keys = ["agent", "conversation", "history_before", "history_exchange"]; required = ["agent"]
            case "chat_conversations": keys = ["conversation_session_id"]; required = []
            case "desk_read": keys = ["handle", "query"]; required = []
            case "work_context": keys = ["query", "session_id"]; required = ["query"]
            case "read_skill": keys = ["name"]; required = keys
            case "read_page": keys = ["url"]; required = keys
            case "read_chat_message": keys = ["message_id", "session_id"]; required = keys
            case "recall_memory", "recall_search": keys = ["memory_id", "query"]; required = []
            case "shelf_entry": keys = ["id", "bot_id"]; required = keys
            case "shelf_read": keys = ["bot_id", "include_read", "newest_first"]; required = []
            case "task_ledger_list": keys = ["task_id"]; required = []
            case "delegation_status": keys = ["task_id"]; required = []
            case "mail_search": keys = ["query"]; required = keys
            case "mail_list_recent": keys = ["expected_message_id"]; required = []
            case "messages_recent_threads": keys = ["thread_id"]; required = []
            case "screen": keys = ["app", "part"]; required = []
            case "bot_list": keys = ["id"]; required = []
            case "mac_calendar_list_upcoming": keys = ["day", "calendar_name"]; required = []
            case "list_skills", "agent_contacts",
                 "mac_reminders_list_due_today",
                 "inner_state", "agent_introspect": keys = []; required = []
            default: return nil
            }
            var arguments: [String: JSONValue] = [:]
            for key in keys {
                guard let value = input[key], value != .null else { continue }
                if tool == "shelf_read", ["include_read", "newest_first"].contains(key) {
                    guard case .bool = value else { return nil }
                    arguments[key] = value
                    continue
                }
                guard case .string(let original) = value,
                      let text = clean(original, limit: key == "path" || key == "url" ? 8192 : 400), text == original else { return nil }
                arguments[key] = .string(text)
            }
            guard required.allSatisfy({ arguments[$0] != nil }) else { return nil }
            if tool == "agent_read" {
                guard arguments["history_before"] == nil || arguments["history_exchange"] == nil else { return nil }
                for key in ["history_before", "history_exchange"] {
                    if case .string(let id)? = arguments[key], UUID(uuidString: id) == nil { return nil }
                }
            }
            if tool == "read_file" || tool == "list_dir" {
                guard case .string(let path)? = arguments["path"], path.hasPrefix("/"),
                      !path.split(separator: "/").contains("..") else { return nil }
            }
            if tool == "read_page" {
                guard case .string(let url)? = arguments["url"], validURL(url) else { return nil }
            }
            if tool == "recall_memory" || tool == "recall_search" {
                guard arguments["query"] != nil || arguments["memory_id"] != nil else { return nil }
            }
            // Preserve validated reading positions. Owners recheck versions
            // after restart; no loaded evidence or action token is serialized.
            let numericKeys: Set<String>
            switch tool {
            case "read_file": numericKeys = ["offset", "max_bytes"]
            case "read_chat_message": numericKeys = ["offset", "limit"]
            case "recall_memory": numericKeys = arguments["memory_id"] != nil ? ["offset", "max_characters"] : []
            case "desk_read": numericKeys = ["offset", "notes_offset", "refs_offset", "detail_offset", "limit"]
            case "work_context": numericKeys = ["desk_offset", "history_offset", "limit"]
            case "mail_list_recent": numericKeys = ["body_offset", "offset"]
            case "mail_search": numericKeys = ["offset"]
            case "messages_recent_threads": numericKeys = ["before_message_id", "limit"]
            case "mac_calendar_list_upcoming": numericKeys = ["hours_ahead", "limit"]
            default: numericKeys = []
            }
            for key in numericKeys {
                guard let value = input[key] else { continue }
                guard case .int(let number) = value, number >= 0,
                      number <= (key == "before_message_id" ? Int64.max : 16_777_216) else { return nil }
                if key != "offset" && !key.hasSuffix("_offset"), number == 0 { return nil }
                arguments[key] = value
            }
            if tool == "read_file", let version = input["version"] {
                guard case .string(let text) = version, text.count <= 400, clean(text, limit: 400) == text else { return nil }
                arguments["version"] = version
            }
            if tool == "recall_memory", let hash = input["expected_content_sha256"] {
                guard case .string(let text) = hash, text.count == 64,
                      text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
                arguments["expected_content_sha256"] = hash
            }
            if case .int(let offset)? = arguments["offset"], offset > 0,
               (tool == "read_file" && arguments["version"] == nil) || (tool == "recall_memory" && arguments["expected_content_sha256"] == nil) {
                arguments.removeValue(forKey: "offset")
            }
            if tool == "screen" { arguments["structured"] = .bool(true) }
            if tool == "desk_read", input["structured"] != nil {
                guard case .bool = input["structured"] else { return nil }
                arguments["structured"] = input["structured"]
            }
            if tool == "desk_read", let version = input["detail_version"] {
                guard case .string(let text) = version, text.count == 64,
                      text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
                arguments["detail_version"] = version
            }
            if tool == "desk_read", case .int(let offset)? = arguments["detail_offset"], offset > 0, arguments["detail_version"] == nil {
                arguments["detail_offset"] = .int(0)
            }
            if tool == "mail_list_recent", let messageID = input["message_id"] {
                guard case .int(let id) = messageID, id > 0, arguments["expected_message_id"] != nil else { return nil }
                arguments["message_id"] = messageID
            } else if tool == "mail_list_recent", arguments["expected_message_id"] != nil { return nil }
            return .record(tool: tool, input: arguments, title: label)
        }
    }

    private static func clean(_ text: String, limit: Int) -> String? {
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return String(text.prefix(limit))
    }

    private static func validURL(_ text: String) -> Bool {
        guard text.count <= 8192, clean(text, limit: 8192) != nil, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return false }
        return true
    }

    private static func normalized(_ value: AgentWorkspaceDesktopState) throws -> AgentWorkspaceDesktopState {
        func receipts(_ input: [String: AgentWorkspaceWorkReceipt]) throws -> [String: AgentWorkspaceWorkReceipt] {
            guard input.count <= 24, input.allSatisfy({ key, value in
                key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } && value.isValid
            }) else { throw Failure.invalid }
            return input
        }
        func note(_ input: String?) throws -> String? {
            guard let input else { return nil }
            guard !input.isEmpty, input.utf8.count <= 4096,
                  !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else { throw Failure.invalid }
            return input
        }
        func kept(_ input: [AgentWorkspaceLocation]) throws -> [AgentWorkspaceLocation] {
            guard input.count <= 12 else { throw Failure.invalid }
            var identities = Set<String>()
            for place in input {
                guard durable(place) == place, let identity = AgentWorkspaceNavigation.placeIdentity(place),
                      identities.insert(identity).inserted else { throw Failure.invalid }
                switch place {
                case .form, .receipt: throw Failure.invalid
                default: break
                }
            }
            return input
        }
        func places(_ input: [AgentWorkspaceLocation]) -> [AgentWorkspaceLocation] {
            var result: [AgentWorkspaceLocation] = []
            for place in input.suffix(24).compactMap(durable) where !result.contains(place) { result.append(place) }
            return result
        }
        guard value.saved.count <= 12, Set(value.saved.map(\.id)).count == value.saved.count,
              value.drafts.count <= 4, Set(value.drafts.map(\.draftID)).count == value.drafts.count,
              value.observations.count <= 64, value.observations.allSatisfy(\.isValid),
              Set(value.observations.map(\.identity)).count == value.observations.count else { throw Failure.invalid }
        if let selected = value.selectedWorkspaceID, !value.saved.contains(where: { $0.id == selected }) { throw Failure.invalid }
        let saved = try value.saved.map { entry -> AgentWorkspaceSavedDesktop in
            guard UUID(uuidString: entry.id) != nil, let name = clean(entry.name, limit: 120) else { throw Failure.invalid }
            return .init(id: entry.id, name: name, current: durable(entry.current) ?? .home, places: places(entry.places),
                workAnchor: entry.workAnchor.flatMap(durable), workTopic: entry.workTopic.flatMap { clean($0, limit: 400) },
                path: Array(entry.path.suffix(8).compactMap(durable)), workNote: try note(entry.workNote), keptPlaces: try kept(entry.keptPlaces),
                focusedWork: entry.focusedWork, lastWorkAction: entry.lastWorkAction, placeActions: try receipts(entry.placeActions))
        }
        guard ([value.lastWorkAction] + saved.map(\.lastWorkAction)).compactMap({ $0 }).allSatisfy(\.isValid) else { throw Failure.invalid }
        return .init(current: durable(value.current) ?? .home, places: places(value.places),
            workAnchor: value.workAnchor.flatMap(durable), workTopic: value.workTopic.flatMap { clean($0, limit: 400) }, saved: saved,
            selectedWorkspaceID: value.selectedWorkspaceID, observations: value.observations,
            path: Array(value.path.suffix(8).compactMap(durable)), drafts: value.drafts.filter(\.canPersist),
            workNote: try note(value.workNote), keptPlaces: try kept(value.keptPlaces), focusedWork: value.focusedWork,
            lastWorkAction: value.lastWorkAction, placeActions: try receipts(value.placeActions))
    }

    private func read(_ directoryFD: Int32) throws -> AgentWorkspaceDesktopState? {
        let fd = openat(directoryFD, scopeHash + ".json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw Failure.invalid }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= Self.byteLimit else { throw Failure.invalid }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var count = 0
            while count < bytes.count {
                let read = Darwin.read(fd, bytes.baseAddress!.advanced(by: count), bytes.count - count)
                if read < 0, errno == EINTR { continue }
                guard read > 0 else { throw Failure.invalid }; count += read
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw Failure.invalid }
        let wire = try JSONDecoder().decode(WireState.self, from: data)
        guard [1, 2].contains(wire.version), wire.scope == scopeHash, wire.places.count <= 24, wire.saved.count <= 12,
              (wire.drafts?.count ?? 0) <= 4, (wire.path?.count ?? 0) <= 8 else { throw Failure.invalid }
        let drafts = try (wire.drafts ?? []).map { try $0.restored() }
        guard Set(drafts.map(\.draftID)).count == drafts.count else { throw Failure.invalid }
        let state = try AgentWorkspaceDesktopState(current: wire.current.location(drafts: drafts), places: wire.places.map { try $0.location(drafts: drafts) },
            workAnchor: wire.workAnchor?.location(drafts: drafts), workTopic: wire.workTopic, saved: wire.saved.map { try $0.desktop(drafts: drafts) },
            selectedWorkspaceID: wire.selectedWorkspaceID, observations: wire.observations ?? [],
            path: (wire.path ?? []).map { try $0.location(drafts: drafts) }, drafts: drafts,
            workNote: wire.workNote, keptPlaces: (wire.keptPlaces ?? []).map { try $0.location(drafts: drafts) },
            focusedWork: wire.focusedWork ?? false, lastWorkAction: wire.lastWorkAction, placeActions: wire.placeActions ?? [:])
        guard try Self.normalized(state) == state else { throw Failure.invalid }
        return state
    }

    private func withDirectory<T>(create: Bool, body: (Int32) throws -> T) throws -> T {
        if create {
            if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw Failure.io }
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, !create, errno == ENOENT { return try body(-1) }
        guard fd >= 0 else { throw Failure.invalid }; defer { close(fd) }
        var directoryInfo = stat()
        guard fstat(fd, &directoryInfo) == 0, directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & 0o077 == 0 else { throw Failure.invalid }
        // Cooperating instances serialize the validation-and-replace boundary.
        let lock = openat(fd, "." + scopeHash + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw Failure.invalid }; defer { close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              flock(lock, LOCK_EX) == 0 else { throw Failure.invalid }
        defer { flock(lock, LOCK_UN) }
        return try body(fd)
    }

    private enum Failure: Error, LocalizedError {
        case invalid, io, capacity
        var errorDescription: String? {
            switch self {
            case .invalid: return "The saved workspace could not be read safely. It was preserved without replacement."
            case .io: return "The workspace could not be saved reliably. Existing owner data was not changed."
            case .capacity: return "This chat's saved desktop would exceed 512 KiB. Existing saved bytes and resident drafts were preserved; finish or discard a draft to make room."
            }
        }
    }

    private struct WireState: Codable {
        var version: Int
        var scope: String
        var current: WireLocation
        var places: [WireLocation]
        var workAnchor: WireLocation?
        var workTopic: String?
        var saved: [WireSaved]
        var selectedWorkspaceID: String?
        var observations: [AgentWorkspaceChanges.Stamp]?
        var path: [WireLocation]?
        var drafts: [AgentWorkspaceForm.Stored]?
        var workNote: String?
        var keptPlaces: [WireLocation]?
        var focusedWork: Bool?
        var lastWorkAction: AgentWorkspaceWorkReceipt?
        var placeActions: [String: AgentWorkspaceWorkReceipt]?
    }

    private struct WireSaved: Codable {
        var id: String; var name: String; var current: WireLocation; var places: [WireLocation]
        var workAnchor: WireLocation?; var workTopic: String?
        var path: [WireLocation]?
        var workNote: String?
        var keptPlaces: [WireLocation]?
        var focusedWork: Bool?
        var lastWorkAction: AgentWorkspaceWorkReceipt?
        var placeActions: [String: AgentWorkspaceWorkReceipt]?
        init(_ value: AgentWorkspaceSavedDesktop) {
            id = value.id; name = value.name; current = .init(value.current); places = value.places.map(WireLocation.init)
            workAnchor = value.workAnchor.map(WireLocation.init); workTopic = value.workTopic
            path = value.path.map(WireLocation.init)
            workNote = value.workNote; keptPlaces = value.keptPlaces.map(WireLocation.init)
            focusedWork = value.focusedWork; lastWorkAction = value.lastWorkAction
            placeActions = value.placeActions
        }
        func desktop(drafts: [AgentWorkspaceForm]) throws -> AgentWorkspaceSavedDesktop {
            guard places.count <= 24, (path?.count ?? 0) <= 8 else { throw Failure.invalid }
            return try .init(id: id, name: name, current: current.location(drafts: drafts), places: places.map { try $0.location(drafts: drafts) },
                workAnchor: workAnchor?.location(drafts: drafts), workTopic: workTopic,
                path: (path ?? []).map { try $0.location(drafts: drafts) }, workNote: workNote,
                keptPlaces: (keptPlaces ?? []).map { try $0.location(drafts: drafts) },
                focusedWork: focusedWork ?? false, lastWorkAction: lastWorkAction, placeActions: placeActions ?? [:])
        }
    }

    private struct WireLocation: Codable {
        var kind: String; var value: String?; var title: String?; var input: [String: JSONValue]?
        var page: Int?
        init(_ location: AgentWorkspaceLocation) {
            switch location {
            case .home: kind = "home"
            case .openPlaces: kind = "openPlaces"
            case .savedWorkspaces: kind = "savedWorkspaces"
            case .workOverview: kind = "workOverview"
            case .find(let text): kind = "find"; value = text
            case .work(let text): kind = "work"; value = text
            case .documents(let text): kind = "documents"; value = text
            case .people(let index): kind = "people"; page = index
            case .conversations(let index): kind = "conversations"; page = index
            case .page(let source, let index):
                self = WireLocation(source); page = index
            case .area(let id): kind = "area"; value = id
            case .record(let tool, let arguments, let name): kind = "record"; value = tool; input = arguments; title = name
            case .browserBookmark(let url, let name, let tabID):
                kind = "browserBookmark"; value = url; title = name
                if let tabID { input = ["tab_id": .int(tabID)] }
            case .form(let form): kind = "draft"; value = form.draftID.uuidString
            default: kind = "home"
            }
        }
        func location(drafts: [AgentWorkspaceForm] = []) throws -> AgentWorkspaceLocation {
            let location: AgentWorkspaceLocation
            switch kind {
            case "home": location = .home
            case "openPlaces": location = .openPlaces
            case "savedWorkspaces": location = .savedWorkspaces
            case "workOverview": location = .workOverview
            case "find": guard let value else { throw Failure.invalid }; location = .find(value)
            case "people": location = .people(page: page ?? 0)
            case "conversations": location = .conversations(page: page ?? 0)
            case "work": guard let value else { throw Failure.invalid }; location = .work(value)
            case "documents": guard let value else { throw Failure.invalid }; location = .documents(value)
            case "area": guard let value else { throw Failure.invalid }; location = .area(value)
            case "record":
                guard let value, let input, let title else { throw Failure.invalid }
                location = .record(tool: value, input: input, title: title)
            case "browserBookmark":
                guard let value, let title else { throw Failure.invalid }
                let tabID: Int64?
                if let raw = input?["tab_id"] {
                    guard case .int(let id) = raw else { throw Failure.invalid }; tabID = id
                } else { tabID = nil }
                location = .browserBookmark(url: value, title: title, tabID: tabID)
            case "draft":
                guard let value, let id = UUID(uuidString: value), let form = drafts.first(where: { $0.draftID == id }) else { throw Failure.invalid }
                location = .form(form)
            default: throw Failure.invalid
            }
            let restored: AgentWorkspaceLocation
            if let page, kind != "people", kind != "conversations" { restored = .page(location, page) }
            else { restored = location }
            guard AgentWorkspaceDesktopStore.durable(restored) == restored else { throw Failure.invalid }
            return restored
        }
    }
}
