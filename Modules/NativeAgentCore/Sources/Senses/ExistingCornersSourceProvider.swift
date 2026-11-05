import Foundation
import Darwin
import PersistenceCore
import NativeAgentCore
// Blueprint: | `ExistingCornersSourceProvider.swift` | `ExistingCornersSourceProvider`, `SenseNativePages`: gated material, watches and bounded pages |

/// These ports avoid a dependency from Senses back into the door that consults it.
public protocol SenseNativePageSource: SenseSourceProvider {
    func page(for corner: SenseCorner, address: String?, operation: SenseReadOperation) async throws -> NativePage
}

public struct ExistingCornersSourceProvider: SenseNativePageSource, SenseSourceWatchingProvider, SenseWatchReporting {
    private let readMaterial: @Sendable (SenseCorner, String?, SenseReadOperation) async throws -> SenseMaterial
    private let readPage: @Sendable (SenseCorner, String?, SenseReadOperation) async throws -> NativePage
    private let readChanges: (@Sendable (SenseCorner, String?, SenseReadOperation) async throws -> AsyncStream<SenseSourceChange>)?
    private let reportWatches: (@Sendable () async -> [SenseLiveWatch])?

    public init(
        readMaterial: @escaping @Sendable (SenseCorner, String?, SenseReadOperation) async throws -> SenseMaterial,
        readPage: @escaping @Sendable (SenseCorner, String?, SenseReadOperation) async throws -> NativePage,
        readChanges: (@Sendable (SenseCorner, String?, SenseReadOperation) async throws -> AsyncStream<SenseSourceChange>)? = nil,
        reportWatches: (@Sendable () async -> [SenseLiveWatch])? = nil
    ) {
        self.readMaterial = readMaterial
        self.readPage = readPage
        self.readChanges = readChanges
        self.reportWatches = reportWatches
    }

    public func liveWatches() async -> [SenseLiveWatch] { await reportWatches?() ?? [] }

    public func material(for corner: SenseCorner, address: String?, operation: SenseReadOperation) async throws -> SenseMaterial {
        try await readMaterial(corner, address, operation)
    }

    public func page(for corner: SenseCorner, address: String?, operation: SenseReadOperation) async throws -> NativePage {
        try await readPage(corner, address, operation)
    }

    public func changes(for corner: SenseCorner, address: String?, operation: SenseReadOperation) async throws -> AsyncStream<SenseSourceChange> {
        if case .site = corner, let readChanges { return try await readChanges(corner, address, operation) }
        if case .app = corner {
            guard let readChanges else {
                throw SenseFailure(code: "source_unavailable", message: "This app corner has no accessibility event source.")
            }
            return try await readChanges(corner, address, operation)
        }
        guard case .fileKind = corner, let address else {
            throw SenseFailure(code: "unsupported", message: "This corner has no event-backed source watch.")
        }
        // JSON read addresses and wake paths resolve to one identity; membership still requires material's read gates.
        let path: String
        if address.hasPrefix("{") {
            guard case .object(let fields) = try JSONValue.parse(Data(address.utf8)),
                  case .string(let value)? = fields["path"] else {
                throw SenseFailure(code: "source_unavailable", message: "A file watch needs its requested path.")
            }
            path = value
        } else if let url = URL(string: address), url.isFileURL { path = url.path }
        else { path = NSString(string: address).expandingTildeInPath }
        guard path.hasPrefix("/") else {
            throw SenseFailure(code: "source_unavailable", message: "A file watch needs an absolute path.")
        }
        let root = URL(fileURLWithPath: path)
        // Keep the root/parent subscription alive through absence and unreadable membership.
        let paths = [root, root.deletingLastPathComponent()]
        let initial = FileChangeEvents(paths: paths, emitInitial: false)
        let pair = AsyncStream<SenseSourceChange>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Observation outlives the turn, so it must inherit none of its session, approvals, file grants or action callback.
        let task = Task.detached(priority: .utility) {
            var events = initial
            var watched = Set(paths)
            defer { events.cancel(); pair.continuation.finish() }
            func unavailable(_ error: Error) async {
                let failure = (error as? SenseFailure) ?? SenseFailure(code: "source_unavailable", message: error.localizedDescription)
                pair.continuation.yield(.unavailable(failure))
            }
            guard await events.waitUntilArmed() else {
                if !Task.isCancelled {
                    await unavailable(SenseFailure(code: "source_unavailable", message: "File observation could not be armed for \(path)."))
                }
                return
            }
            guard !Task.isCancelled else { return }
            while !Task.isCancelled {
                do {
                    let material = try await self.material(for: corner, address: address, operation: operation)
                    guard case .file(let admittedPath, _, _) = material,
                          URL(fileURLWithPath: admittedPath).standardizedFileURL.path == root.standardizedFileURL.path else {
                        throw SenseFailure(code: "source_unavailable", message: "File observation must retain its requested path.")
                    }
                    let nextPaths = try Self.watchPaths(root)
                    if Set(nextPaths) != watched {
                        let next = FileChangeEvents(paths: nextPaths, emitInitial: false)
                        guard await next.waitUntilArmed() else {
                            next.cancel()
                            throw SenseFailure(code: "source_unavailable", message: "File membership observation could not be armed for \(path).")
                        }
                        guard !Task.isCancelled else { next.cancel(); return }
                        events.cancel(); events = next; watched = Set(nextPaths)
                    }
                    // Check identity only after read admission; a failed read cannot prove deletion.
                    let identity = try Self.fileIdentity(root)
                    pair.continuation.yield(.changed(material, files: identity))
                } catch {
                    guard !Task.isCancelled else { return }
                    if let failure = error as? SenseFailure, failure.code == "source_absent" {
                        pair.continuation.yield(.absent)
                    } else {
                        await unavailable(error)
                    }
                }
                // Only a source edge admits repair after failure; without one, the unavailable watch waits without a timer or reread.
                var iterator = events.stream.makeAsyncIterator()
                guard await iterator.next() != nil else {
                    if !Task.isCancelled {
                        await unavailable(SenseFailure(
                            code: "source_unavailable",
                            message: "File observation ended for \(path); a part/catalog change can register it again."
                        ))
                    }
                    return
                }
            }
        }
        pair.continuation.onTermination = { _ in task.cancel(); initial.cancel() }
        return pair.stream
    }

    /// Report failure in the news before ending the event stream.
    public static func postWatchFailure(_ error: Error, corner: SenseCorner, address: String, observationID: String?, what: String) async {
        do {
            guard let record = try await SensesHub.shared.registry?.sense(for: corner), record.status == .on else { return }
            await SenseNewsBoard.shared.post(SenseNews(senseID: record.id, version: record.version, address: address,
                summary: "\(what) news unavailable: \(ContextSecretContentPolicy.redactedFragment(error.localizedDescription))",
                at: Date(), observationID: observationID))
        } catch {
            await SenseNewsBoard.shared.post(SenseNews(senseID: "sense-registry", version: 1,
                address: corner.key, summary: error.localizedDescription, at: Date()))
        }
    }

    private static func watchPaths(_ root: URL) throws -> [URL] {
        let directory = try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        return [root, root.deletingLastPathComponent()] + (directory ? try packageManifest(root,
            symlinkMessage: "A watched document package cannot contain symbolic links.",
            memberFailure: SenseFailure(code: "material_too_large", message: "The document package has too many watched members.")).map(\.url) : [])
    }

    private static func fileIdentity(_ root: URL) throws -> [String: [Int64]] {
        func stamp(_ url: URL, directory: Bool) throws -> [Int64] {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw SenseFailure(code: "source_unavailable", message: "File identity is unreadable at \(url.path) (errno \(errno)).")
            }
            if directory { return [Int64(info.st_ino)] }
            return [Int64(info.st_ino), Int64(info.st_size), Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec)]
        }
        let directory = try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        var result = [root.path: try stamp(root, directory: directory)]
        if directory {
            for member in try packageManifest(root) { result[member.url.path] = try stamp(member.url, directory: !member.isFile) }
        }
        return result
    }

    /// Watching and delivery share the 8,000-member bound, including watched directories; only regular files may be archived.
    public static func packageManifest(_ root: URL, symlinkMessage: String = "Sense document packages cannot contain symbolic links.",
                                memberFailure: SenseFailure = SenseFailure(
                                    code: "input_limit",
                                    message: "Sense document package exceeds its member limit."
                                )) throws -> [(url: URL, isFile: Bool)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var traversalFailed = false
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, _ in traversalFailed = true; return false }) else {
            throw SenseFailure(code: "source_unavailable", message: "Sense document package is unavailable.")
        }
        var members: [(url: URL, isFile: Bool)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else {
                throw SenseFailure(code: "source_denied", message: symlinkMessage)
            }
            guard values.isRegularFile == true || values.isDirectory == true else {
                throw SenseFailure(code: "source_denied", message: "Sense document package contains unsupported members.")
            }
            guard members.count < 8_000 else { throw memberFailure }
            members.append((url, values.isRegularFile == true))
        }
        guard !traversalFailed else {
            throw SenseFailure(code: "source_unavailable", message: "Sense document package could not be read completely.")
        }
        return members
    }

}

public enum SenseNativePages {
    /// Keep structural paths private in captured material; agent addresses carry only readable fragments.
    public static func chromeAddress(host: String, url: String, fragment: String? = nil) -> String {
        guard let parts = URLComponents(string: url) else { return "site:" + host.lowercased() }
        let base = "site:" + host.lowercased() + (parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath)
            + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        return fragment.map { base + "#" + $0 } ?? base
    }

    private final class ChromePlaces: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: (arguments: [String: JSONValue], url: String)] = [:]
        var order: [String] = []
    }
    private static let chromePlaces = ChromePlaces()

    /// Bind reading positions to the served conversation and tab so recycled elements cannot delete them.
    public static func chromeContinuation(_ page: [String: JSONValue], cursor: JSONValue, scope: String, alias: String? = nil) -> String? {
        guard case .object(let fields) = cursor, case .string(let url)? = page["url"],
              let host = URL(string: url)?.host, case .int(let tab)? = page["tabId"], tab >= 0,
              case .int(let frame)? = fields["frameId"], frame >= 0,
              let encoded = try? cursor.serialize(pretty: false) else { return nil }
        let fragment: String
        if case .object(let place)? = fields["position"] {
            let coordinates = ["scrollX", "scrollY", "distance", "y", "x", "ordinal"].compactMap { key -> String? in
                switch place[key] {
                case .int(let value)?: return String(value)
                case .double(let value)? where value.isFinite: return String(value)
                default: return nil
                }
            }
            guard coordinates.count == 6 else { return nil }
            fragment = "view-\(frame)-" + coordinates.joined(separator: "_")
        } else {
            guard fields["textOffset"] == nil, fields["optionOffset"] == nil else { return nil }
            fragment = "view-\(frame)"
        }
        var position: [String] = []
        for key in ["textOffset", "optionOffset"] {
            if case .int(let offset)? = fields[key], offset > 0 { position.append("\(key)=\(offset)") }
        }
        let canonical = chromeAddress(host: host, url: url, fragment: fragment)
            + "?read=more" + (position.isEmpty ? "" : "&" + position.joined(separator: "&"))
        // Bind redirects by captured tab and page position because grown views may retain the requested URL spelling.
        if let alias {
            guard alias.hasPrefix("site:" + host.lowercased() + "/"),
                  alias.split(separator: "#", maxSplits: 1).last == canonical.split(separator: "#", maxSplits: 1).last else { return nil }
        }
        let address = alias ?? canonical
        var arguments: [String: JSONValue] = ["tab_id": .int(tab), "more": .string(encoded)]
        if case .object(let reading)? = page["reading"] { arguments["scope"] = reading["scope"] }
        let key = scope + "\u{0}" + String(tab) + "\u{0}" + address
        chromePlaces.lock.lock(); defer { chromePlaces.lock.unlock() }
        chromePlaces.order.removeAll { $0 == key }
        chromePlaces.order.append(key)
        chromePlaces.entries[key] = (arguments, url)
        while chromePlaces.order.count > 1024 {
            chromePlaces.entries.removeValue(forKey: chromePlaces.order.removeFirst())
        }
        return address
    }

    public static func chromeContinuationArguments(_ address: String, scope: String, tab: Int64? = nil) throws -> [String: JSONValue] {
        chromePlaces.lock.lock(); defer { chromePlaces.lock.unlock() }
        let prefix = scope + "\u{0}"
        let matches = chromePlaces.entries.filter { key, value in
            key.hasPrefix(prefix) && key.hasSuffix("\u{0}" + address)
                && (tab == nil || value.arguments["tab_id"] == tab.map(JSONValue.int))
        }
        guard matches.count == 1, let match = matches.first else {
            throw SenseFailure(code: "invalid_address", message: matches.isEmpty
                ? "This reading place is no longer available; read the page again. raw view · private Chrome reading-place bindings; no page was read."
                : """
                    This reading place belongs to more than one held tab; supply its tab_id. raw view · private Chrome reading-place bindings; no page was \
                    read.
                    """)
        }
        return match.value.arguments
    }

    /// Retain structural sense addresses under the compact display without duplicating a path catalog in the envelope.
    public static func chromeThings(_ snapshot: JSONValue) throws -> [NativeThing] {
        func text(_ value: JSONValue?) -> String? { if case .string(let text)? = value { return text }; return nil }
        guard case .object(let page) = snapshot, let url = text(page["url"]),
              let host = URL(string: url)?.host, case .array(let nodes)? = page["nodes"] else { return [] }
        guard nodes.allSatisfy({ value in
            guard case .object(let node) = value, let fragment = text(node["addressFragment"]) else { return false }
            return !fragment.isEmpty
        }) else {
            throw SenseFailure(code: "reader_update_required", message: """
                Chrome's reader has no readable places; extension 0.4.20 is required. raw view · the captured Chrome reader did not supply element places; \
                no native page was served.
                """)
        }
        return nodes.compactMap { value in
            guard case .object(let node) = value, let fragment = text(node["addressFragment"]) else { return nil }
            var verbs: [String] = []
            if case .array(let actions)? = node["actions"] { verbs = actions.compactMap { text($0) }.filter { ["click", "fill", "select"].contains($0) } }
            if case .object(let states)? = node["states"], states["disabled"] == .bool(true) || states["blockedByModal"] == .bool(true) { verbs = [] }
            let name = [text(node["name"]), text(node["text"]), text(node["url"])].compactMap { $0 }.first { !$0.isEmpty } ?? "element"
            return NativeThing(name: name, kind: text(node["role"]) ?? text(node["kind"]) ?? "element",
                address: chromeAddress(host: host, url: url, fragment: fragment), verbs: verbs)
        }
    }

    public static func window(_ page: NativePage, arguments: [String: JSONValue]) throws -> NativePage {
        if SenseScreenThings.isNativeScreenPage(page) {
            guard page.things.allSatisfy({ page.text.contains("[" + SenseScreenThings.printed($0.address) + "]") }) else {
                throw SenseFailure(code: "bad_output", message: "The native screen action index does not match its page.")
            }
            return try screenWindow(page, arguments: arguments)
        }
        let bytes = Array(page.text.utf8)
        let offset: Int = if case .int(let n)? = arguments["__sense_text_offset"] { Int(exactly: n) ?? -1 } else { 0 }
        guard offset >= 0, offset <= bytes.count,
              offset == bytes.count || bytes[offset] & 0xc0 != 0x80 else {
            throw SenseFailure(code: "invalid_address", message: "The native page cursor is invalid.")
        }
        var end = min(bytes.count, offset + NativePage.maximumTextBytes)
        while end < bytes.count, bytes[end] & 0xc0 == 0x80 { end -= 1 }
        var result = page
        result.text = String(decoding: bytes[offset..<end], as: UTF8.self)
        let thingOffset: Int = if case .int(let n)? = arguments["__sense_thing_offset"] { Int(exactly: n) ?? -1 } else { 0 }
        guard thingOffset >= 0, thingOffset <= page.things.count else {
            throw SenseFailure(code: "invalid_address", message: "The native page thing cursor is invalid.")
        }
        let thingEnd = min(page.things.count, thingOffset + 80)
        result.things = Array(page.things[thingOffset..<thingEnd])
        if end < bytes.count || thingEnd < page.things.count {
            var next = arguments
            next["__sense_text_offset"] = .int(Int64(end))
            next["__sense_thing_offset"] = .int(Int64(thingEnd))
            result.more = try JSONValue.object(next).serialize(pretty: false)
            result.folded.append(thingEnd < page.things.count ? "Remaining raw view and things" : "Remaining raw view")
        }
        return result
    }

    /// Page text and things with one frozen cursor so neither budget can lose or repeat a control.
    private static func screenWindow(_ page: NativePage, arguments: [String: JSONValue]) throws -> NativePage {
        let bytes = Array(page.text.utf8)
        let offset: Int = if case .int(let n)? = arguments["__sense_text_offset"] { Int(exactly: n) ?? -1 } else { 0 }
        guard offset >= 0, offset <= bytes.count,
              offset == bytes.count || bytes[offset] & 0xc0 != 0x80 else {
            throw SenseFailure(code: "invalid_address", message: "The native page cursor is invalid.")
        }
        let preceding = String(decoding: bytes[..<offset], as: UTF8.self).split(separator: "\n")
        let currentSection = preceding.last { $0.hasPrefix("## ") || $0.hasPrefix("### ") }
            .map { String($0.drop(while: { $0 == "#" || $0 == " " })) }
        let startsSection = String(decoding: bytes[offset...], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("##")
        var prefix = ""
        if offset > 0 {
            prefix = SenseScreenThings.accessibilityReadLine + "\n"
            if let currentSection, !startsSection { prefix += "## \(currentSection) (continued)\n" }
        }
        guard prefix.utf8.count < NativePage.maximumTextBytes else {
            throw SenseFailure(code: "bad_output", message: "The screen section heading exceeds the native page budget.")
        }
        let positions = page.things.compactMap { thing -> (thing: NativeThing, start: Int, end: Int, line: Int)? in
            guard let range = page.text.range(of: "[" + SenseScreenThings.printed(thing.address) + "]") else { return nil }
            let start = page.text.utf8.distance(from: page.text.utf8.startIndex, to: range.lowerBound)
            let end = page.text.utf8.distance(from: page.text.utf8.startIndex, to: range.upperBound)
            let line = bytes[..<start].lastIndex(of: 10).map { $0 + 1 } ?? 0
            return (thing, start, end, line)
        }.sorted { $0.start < $1.start }
        var end = min(bytes.count, offset + NativePage.maximumTextBytes - prefix.utf8.count)
        while end < bytes.count, bytes[end] & 0xc0 == 0x80 { end -= 1 }
        let pending = positions.filter { $0.start >= offset }
        if pending.count > 80 { end = min(end, max(offset, pending[80].line)) }
        // Prefer whole lines but permit progress through paragraphs longer than the page budget.
        if end < bytes.count, let newline = bytes[offset..<end].lastIndex(of: 10), newline > offset {
            end = newline + 1
        }
        if let splitAddress = positions.first(where: { $0.start < end && $0.end > end }) { end = splitAddress.start }
        guard end > offset || offset == bytes.count else {
            throw SenseFailure(code: "bad_output", message: "A screen address exceeds the native page budget.")
        }
        var result = page
        result.text = prefix + String(decoding: bytes[offset..<end], as: UTF8.self)
        result.things = positions.filter { $0.start >= offset && $0.end <= end }.map(\.thing)
        result.folded = []
        result.more = nil
        if end < bytes.count {
            let remaining = String(decoding: bytes[end...], as: UTF8.self)
            let sections = remaining.split(separator: "\n").filter { $0.hasPrefix("## ") || $0.hasPrefix("### ") }
                .map { String($0.drop(while: { $0 == "#" || $0 == " " })) }
            result.folded = Array(NSOrderedSet(array: sections).array.compactMap { $0 as? String })
            let servedSection = String(decoding: bytes[..<end], as: UTF8.self).split(separator: "\n")
                .last { $0.hasPrefix("## ") || $0.hasPrefix("### ") }
                .map { String($0.drop(while: { $0 == "#" || $0 == " " })) }
            if let servedSection, !remaining.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("##") {
                result.folded.insert(servedSection + " (continued)", at: 0)
            }
            if result.folded.isEmpty { result.folded = ["Page content continued"] }
            // Only frozen identity and reading position belong to continuation args; session, transport and display metadata do not.
            var next: [String: JSONValue] = [:]
            guard case .object(let identity) = try JSONValue.parse(Data(page.address.utf8)),
                  case .string(let frame)? = identity["__sense_screen_frame"] else {
                throw SenseFailure(code: "bad_output", message: "The native screen snapshot has no continuation identity.")
            }
            next["__sense_screen_frame"] = .string(frame)
            next["app"] = if case .app(let bundle) = page.corner { .string(bundle) } else { nil }
            next["__sense_text_offset"] = .int(Int64(end))
            next.removeValue(forKey: "__sense_thing_offset")
            result.more = try JSONValue.object(next).serialize(pretty: false)
        }
        return result
    }
}
