import Foundation
import NativeAgentCore
import PersistenceCore

/// Lossless, turn-scoped spill storage for provider results that are too large
/// to inject in one model message. Files live under the user's private temp
/// directory with owner-only permissions, are addressed by random handles,
/// and can only be read from the same chat session and turn.
actor ProviderToolResultRecoveryStore {
    static let shared = ProviderToolResultRecoveryStore()

    static let pageUTF8Bytes = 8_000

    /// User, 2026-09-06: a page is embedded as a JSON STRING in the
    /// `tool_result_page` envelope, and this codebase serializes with
    /// `ensure_ascii=True` — every non-ASCII scalar becomes `\uXXXX` (6 bytes,
    /// 12 for a surrogate pair) and every quote/backslash/newline doubles. So
    /// 8 000 RAW bytes of CJK or escape-heavy JSON serialized past the 12 000
    /// byte `tool_result_page` projection ceiling, and the page spilled into
    /// ANOTHER handle: paging a large result could never return the result.
    /// Pages are now bounded by BOTH the raw cap above and this serialized
    /// cap, which leaves the envelope's own fields room under that ceiling.
    /// Pure ASCII is unaffected — the raw cap still binds first.
    static let pageSerializedUTF8Bytes = 10_000

    /// Bytes one scalar costs INSIDE a serialized JSON string, matching
    /// `JSONValue.encodeString` exactly.
    static func jsonEscapedByteCount(_ v: UInt32) -> Int {
        switch v {
        case 0x22, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D: return 2
        default:
            if v < 0x20 { return 6 }
            if v < 0x7F { return 1 }
            if v <= 0xFFFF { return 6 }
            return 12
        }
    }
    static let maxEntryBytes = 64 * 1024 * 1024
    static let maxTotalBytes = 128 * 1024 * 1024
    static let maxEntries = 32
    static let ttl: TimeInterval = 30 * 60

    /// User, 2026-09-06: the 30-minute TTL ran from CREATION and nothing renewed
    /// it, so a long permitted turn (Telegram and the agent bridges get 180
    /// iterations and a 6 h ceiling) watched its own spill handles expire under
    /// it and `tool_result_page` answered "expired, invalid, or belongs to a
    /// different turn" for a handle it had just been handed. A handle whose turn
    /// is still live is never expired; the idle TTL applies once the turn ends,
    /// and this is the ceiling that stops a leaked scope from pinning bytes
    /// forever. Matches the turn wall-clock ceiling.
    static let liveTurnMaxLifetime: TimeInterval = 6 * 60 * 60

    struct Scope: Hashable, Sendable {
        let sessionId: String
        let turnId: String

        init?(sessionId: String?, turnId: String?) {
            let session = (sessionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let turn = (turnId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !session.isEmpty, !turn.isEmpty, turn != "unknown" else { return nil }
            self.sessionId = session
            self.turnId = turn
        }
    }

    struct Receipt: Sendable {
        let handle: String
        let pageCount: Int
        let characters: Int
        let bytes: Int
        let resultClass: ChatToolOutcome.ExactResultClass
    }

    private struct Entry: Sendable {
        let handle: String
        let toolName: String
        let scope: Scope
        let url: URL
        let characters: Int
        let bytes: Int
        let resultClass: ChatToolOutcome.ExactResultClass
        let pageByteOffsets: [Int]
        let sectionBudget: Int
        let createdAt: Date
        /// Last time the model actually read a page. The idle clock runs from
        /// here, not from creation.
        var lastReadAt: Date
    }

    private let root: URL
    private var entries: [String: Entry] = [:]
    private var totalBytes = 0
    /// Scopes whose turn has not ended yet. A turn seeds this the first time it
    /// spills; `remove(scope:)` — which every loop calls in its `defer` — clears
    /// it. Handles in a live scope survive the idle TTL.
    private var liveScopes: Set<Scope> = []
    private struct ReadCursor {
        let handle: String
        let nextPage: Int?
        let query: String?
    }
    private var readCursors: [Scope: ReadCursor] = [:]

    init(root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent(InstallPaths.current.name("NativeAgent"), isDirectory: true)
        .appendingPathComponent("provider_tool_results", isDirectory: true)) {
        self.root = root
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        // Crash leftovers have no in-memory authorization record and are never
        // readable. Remove old ones eagerly; newer ones remain protected by the
        // 0700 directory until a later cleanup pass.
        if let urls = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let cutoff = Date().addingTimeInterval(-Self.ttl)
            for url in urls {
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if modified.map({ $0 < cutoff }) ?? true { try? fm.removeItem(at: url) }
            }
        }
    }

    /// Classify the exact redacted envelope, not a head/tail excerpt. A page
    /// being readable is separate evidence from the original action outcome.
    nonisolated static func resultClass(content: String) -> ChatToolOutcome.ExactResultClass {
        guard content.utf8.count <= maxEntryBytes,
              let value = try? JSONValue.parse(Data(content.utf8)) else { return .unknown }
        return ChatToolOutcome.exactResultClass(value)
    }

    func store(
        content: String,
        toolName: String,
        sessionId: String?,
        turnId: String?,
        originalResultClass: ChatToolOutcome.ExactResultClass? = nil,
        sectionBudget: Int = ToolResultSections.pageBudget
    ) -> Receipt? {
        guard let scope = Scope(sessionId: sessionId, turnId: turnId) else { return nil }
        cleanupExpired(now: Date())

        let data = Data(content.utf8)
        guard data.count <= Self.maxEntryBytes else { return nil }
        guard entries.count < Self.maxEntries,
              totalBytes + data.count <= Self.maxTotalBytes else { return nil }

        // Build valid Unicode-scalar byte boundaries once. Bounding bytes (not
        // grapheme count) prevents a pathological combining sequence from
        // becoming an unexpectedly huge provider page.
        var pageByteOffsets = [0]
        var byteOffset = 0
        var pageStartByte = 0
        var pageSerializedBytes = 0
        for scalar in content.unicodeScalars {
            let value = scalar.value
            let scalarBytes = value <= 0x7F ? 1 : value <= 0x7FF ? 2 : value <= 0xFFFF ? 3 : 4
            let escapedBytes = Self.jsonEscapedByteCount(value)
            let overRaw = byteOffset - pageStartByte + scalarBytes > Self.pageUTF8Bytes
            let overSerialized = pageSerializedBytes + escapedBytes > Self.pageSerializedUTF8Bytes
            if byteOffset > pageStartByte, overRaw || overSerialized {
                pageByteOffsets.append(byteOffset)
                pageStartByte = byteOffset
                pageSerializedBytes = 0
            }
            byteOffset += scalarBytes
            pageSerializedBytes += escapedBytes
        }
        if pageByteOffsets.last != byteOffset {
            pageByteOffsets.append(byteOffset)
        }

        let handle = UUID().uuidString.lowercased()
        let url = root.appendingPathComponent(handle, isDirectory: false)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        let now = Date()
        let entry = Entry(
            handle: handle,
            toolName: toolName,
            scope: scope,
            url: url,
            characters: content.count,
            bytes: data.count,
            resultClass: originalResultClass ?? Self.resultClass(content: content),
            pageByteOffsets: pageByteOffsets,
            sectionBudget: sectionBudget,
            createdAt: now,
            lastReadAt: now
        )
        entries[handle] = entry
        liveScopes.insert(scope)
        totalBytes += data.count
        return Receipt(
            handle: handle,
            pageCount: max(1, entry.pageByteOffsets.count - 1),
            characters: entry.characters,
            bytes: entry.bytes,
            resultClass: entry.resultClass
        )
    }

    func page(
        handle: String,
        page: Int,
        sessionId: String?,
        turnId: String?,
        query: String? = nil
    ) -> JSONValue {
        let result = readPage(handle: handle, page: page, sessionId: sessionId, turnId: turnId, query: query)
        if let scope = Scope(sessionId: sessionId, turnId: turnId),
           case .object(let object) = result, object["status"] == .string("completed") {
            let next: Int?
            if case .int(let value)? = object["next_page"] { next = Int(exactly: value) }
            else { next = nil }
            readCursors[scope] = ReadCursor(handle: handle, nextPage: next, query: query)
        }
        return result
    }

    /// Continue the exact last read in this turn, preserving its query/mode.
    /// Before the first read only an unambiguous retained result is selected.
    func continueReading(handle: String?, sessionId: String?, turnId: String?) -> JSONValue {
        cleanupExpired(now: Date())
        guard let scope = Scope(sessionId: sessionId, turnId: turnId) else {
            return .object(["status": .string("failed"), "reason": .string("missing_result_scope")])
        }
        if let cursor = readCursors[scope], handle == nil || handle == cursor.handle {
            guard let next = cursor.nextPage else {
                return .object(["status": .string("completed"), "result_handle": .string(cursor.handle),
                    "has_more": .bool(false), "reading_complete": .bool(true),
                    "recovery_only": .bool(true),
                    "verification_scope": .string("retained_tool_response_not_external_outcome"),
                    "original_result_class": .string(entries[cursor.handle]?.resultClass.rawValue ?? "unknown"),
                    "detail": .string("You reached the end of this retained result. No operation was repeated.")])
            }
            return page(handle: cursor.handle, page: next, sessionId: sessionId, turnId: turnId, query: cursor.query)
        }
        let candidates = entries.values.filter { $0.scope == scope && (handle == nil || $0.handle == handle) }
            .sorted { $0.createdAt < $1.createdAt }
        guard candidates.count == 1, let entry = candidates.first else {
            return .object([
                "status": .string("failed"),
                "reason": .string(candidates.isEmpty ? "result_handle_unavailable" : "choose_result"),
                "results": .array(candidates.map { .object(["result_handle": .string($0.handle), "tool": .string($0.toolName)]) }),
                "recovery_hint": .string(candidates.isEmpty
                    ? "No matching retained result is readable in this turn. Inspect its durable receipt or original status; never repeat a write to recover output."
                    : "Several results are retained. Choose result_handle once; subsequent continue reads keep its position."),
            ])
        }
        return page(handle: entry.handle, page: 0, sessionId: sessionId, turnId: turnId, query: "")
    }

    private func readPage(
        handle: String, page: Int, sessionId: String?, turnId: String?, query: String?
    ) -> JSONValue {
        cleanupExpired(now: Date())
        guard let scope = Scope(sessionId: sessionId, turnId: turnId),
              let entry = entries[handle],
              entry.scope == scope else {
            return .object([
                "status": .string("failed"),
                "reason": .string("result_handle_unavailable"),
                "detail": .string("The result handle is expired, invalid, or belongs to a different turn."),
                "recovery_hint": .string("Inspect the original operation's status or durable receipt. Missing output does not establish failure; do not repeat a write or external action merely to recover its output."),
            ])
        }
        if let query, let data = try? Data(contentsOf: entry.url),
           let content = String(data: data, encoding: .utf8) {
            let pages = ToolResultSections.pages(content: content, query: query, budget: entry.sectionBudget)
            guard pages.indices.contains(page) else {
                return .object(["status": .string("failed"), "reason": .string("page_out_of_range"),
                    "page_count": .int(Int64(pages.count)),
                    "recovery_hint": .string("Read the same retained result with a page from 0 through \(pages.count - 1), keeping query and raw unchanged; do not rerun the original operation.")])
            }
            entries[handle]?.lastReadAt = Date()
            let remaining = pages.dropFirst(page + 1).reduce(0) { $0 + $1.count }
            let sections = pages[page].map { section -> JSONValue in
                guard case .object(var row) = section,
                      case .int(let start)? = row["raw_byte_start"],
                      case .int(let end)? = row["raw_byte_end"] else { return section }
                row["raw_first_page"] = .int(Int64(max(0, entry.pageByteOffsets.lastIndex(where: { $0 <= start }) ?? 0)))
                row["raw_last_page"] = .int(Int64(max(0, entry.pageByteOffsets.lastIndex(where: { $0 < end }) ?? 0)))
                return .object(row)
            }
            return .object([
                "status": .string("completed"),
                "original_result_class": .string(entry.resultClass.rawValue),
                "recovery_only": .bool(true),
                "verification_scope": .string("retained_tool_response_not_external_outcome"),
                "result_handle": .string(handle), "query": .string(query),
                "page": .int(Int64(page)), "page_count": .int(Int64(pages.count)),
                "sections": .array(sections),
                "remaining_sections": .int(Int64(remaining)),
                "has_more": .bool(page + 1 < pages.count),
                "next_page": page + 1 < pages.count ? .int(Int64(page + 1)) : .null,
                "raw_page_count": .int(Int64(max(1, entry.pageByteOffsets.count - 1))),
                "detail": .string("Page \(page + 1) of \(pages.count). \(remaining) whole sections follow. Read tool_result_page with this result_handle, the same query and next_page as page. Paths and paragraph numbers identify the original positions. raw=true returns the original byte stream in separate pages."),
            ])
        }
        let pageCount = max(1, entry.pageByteOffsets.count - 1)
        guard page >= 0, page < pageCount else {
            return .object([
                "status": .string("failed"),
                "reason": .string("page_out_of_range"),
                "page_count": .int(Int64(pageCount)),
                "recovery_hint": .string("Read the same retained result with a page from 0 through \(pageCount - 1); do not rerun the original operation."),
            ])
        }
        let startByte = entry.pageByteOffsets[page]
        let endByte = entry.pageByteOffsets[page + 1]
        guard let file = try? FileHandle(forReadingFrom: entry.url) else {
            remove(handle: handle)
            return .object([
                "status": .string("failed"),
                "reason": .string("result_spill_unreadable"),
                "recovery_hint": .string("Inspect the original operation's durable receipt before deciding whether another action is safe. Output recovery failed; the original action outcome is not changed."),
            ])
        }
        defer { try? file.close() }
        guard (try? file.seek(toOffset: UInt64(startByte))) != nil,
              let data = try? file.read(upToCount: endByte - startByte),
              let content = String(data: data, encoding: .utf8) else {
            remove(handle: handle)
            return .object([
                "status": .string("failed"),
                "reason": .string("result_spill_unreadable"),
                "recovery_hint": .string("Inspect the original operation's durable receipt before deciding whether another action is safe. Output recovery failed; the original action outcome is not changed."),
            ])
        }
        // Reading renews the handle: a result the model is still working
        // through is in use, whatever the clock says.
        entries[handle]?.lastReadAt = Date()
        let hasMore = page + 1 < pageCount
        let nextPage: JSONValue = hasMore ? .int(Int64(page + 1)) : .null
        return .object([
            "status": .string("completed"),
            "original_result_class": .string(entry.resultClass.rawValue),
            "recovery_only": .bool(true),
            "verification_scope": .string("retained_tool_response_not_external_outcome"),
            "tool": .string(entry.toolName),
            "result_handle": .string(handle),
            "page": .int(Int64(page)),
            "page_count": .int(Int64(pageCount)),
            "page_bytes": .int(Int64(endByte - startByte)),
            "original_characters": .int(Int64(entry.characters)),
            "original_bytes": .int(Int64(entry.bytes)),
            "content": .string(content),
            "has_more": .bool(hasMore),
            "next_page": nextPage,
        ])
    }

    func remove(scope: Scope) {
        liveScopes.remove(scope)
        for handle in entries.values.filter({ $0.scope == scope }).map(\.handle) {
            remove(handle: handle)
        }
    }

    private func cleanupExpired(now: Date) {
        for entry in Array(entries.values) {
            // The absolute ceiling binds even on a live turn — it is the only
            // thing that frees a scope whose `remove(scope:)` never arrived.
            if now.timeIntervalSince(entry.createdAt) >= Self.liveTurnMaxLifetime {
                remove(handle: entry.handle)
                continue
            }
            // A live turn keeps its handles: the turn's own `defer` is what ends
            // them, not the clock.
            guard !liveScopes.contains(entry.scope) else { continue }
            if now.timeIntervalSince(entry.lastReadAt) >= Self.ttl {
                remove(handle: entry.handle)
            }
        }
        // A scope with nothing left to protect stops being tracked, so a turn
        // that ended without its `defer` cannot pin the set forever.
        liveScopes.formIntersection(Set(entries.values.map(\.scope)))
        let liveNames = Set(entries.values.map { $0.url.lastPathComponent })
        let cutoff = now.addingTimeInterval(-Self.ttl)
        let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for url in urls ?? [] where !liveNames.contains(url.lastPathComponent) {
            let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            if modified.map({ $0 < cutoff }) ?? true {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func remove(handle: String) {
        for scope in readCursors.keys.filter({ readCursors[$0]?.handle == handle }) { readCursors.removeValue(forKey: scope) }
        guard let entry = entries.removeValue(forKey: handle) else { return }
        totalBytes = max(0, totalBytes - entry.bytes)
        try? FileManager.default.removeItem(at: entry.url)
    }
}

extension SwiftToolDispatcher {
    func impl_tool_result_page(input: [String: JSONValue]) async -> JSONValue {
        if input["continue"] == .bool(true) {
            guard ["page", "query", "raw"].allSatisfy({ input[$0] == nil || input[$0] == .null }) else {
                return .object(["status": .string("failed"), "reason": .string("conflicting_read_selection"),
                    "recovery_hint": .string("Use continue:true alone (optional result_handle), or select an explicit page/query/raw mode. Continue retains the previous mode and position.")])
            }
            let handle = jsonString(input["result_handle"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            return await ProviderToolResultRecoveryStore.shared.continueReading(
                handle: handle?.isEmpty == false ? handle : nil,
                sessionId: Self.extractSessionId(from: input), turnId: TurnTraceContext.turnId)
        }
        guard case .string(let handle)? = input["result_handle"], !handle.isEmpty else {
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_result_handle"),
                "recovery_hint": .string("Copy result_handle from the earlier bounded_tool_result response in this turn."),
            ])
        }
        let page: Int?
        switch input["page"] ?? .null {
        case .null, .bool(false): page = 0
        case .int(let value): page = Int(exactly: value)
        case .double(let value): page = Int(exactly: value)
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            page = trimmed.isEmpty ? 0 : Int(trimmed)
        default: page = nil
        }
        guard let page, page >= 0 else {
            return .object([
                "status": .string("failed"),
                "reason": .string("invalid_page"),
                "recovery_hint": .string("Set page to a whole number starting at 0, or copy next_page from the previous response. Keep result_handle, query and raw unchanged; do not rerun the original operation."),
            ])
        }
        return await ProviderToolResultRecoveryStore.shared.page(
            handle: handle,
            page: page,
            sessionId: Self.extractSessionId(from: input),
            turnId: TurnTraceContext.turnId,
            query: input["raw"] == .bool(true) ? nil : (jsonString(input["query"]) ?? "")
        )
    }
}
