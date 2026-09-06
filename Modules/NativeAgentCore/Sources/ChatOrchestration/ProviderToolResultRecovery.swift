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
    }

    private struct Entry: Sendable {
        let handle: String
        let toolName: String
        let scope: Scope
        let url: URL
        let characters: Int
        let bytes: Int
        let pageByteOffsets: [Int]
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

    init(root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgent", isDirectory: true)
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

    func store(
        content: String,
        toolName: String,
        sessionId: String?,
        turnId: String?
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
            pageByteOffsets: pageByteOffsets,
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
            bytes: entry.bytes
        )
    }

    func page(
        handle: String,
        page: Int,
        sessionId: String?,
        turnId: String?
    ) -> JSONValue {
        cleanupExpired(now: Date())
        guard let scope = Scope(sessionId: sessionId, turnId: turnId),
              let entry = entries[handle],
              entry.scope == scope else {
            return .object([
                "status": .string("failed"),
                "reason": .string("result_handle_unavailable"),
                "detail": .string("The result handle is expired, invalid, or belongs to a different turn."),
            ])
        }
        let pageCount = max(1, entry.pageByteOffsets.count - 1)
        guard page >= 0, page < pageCount else {
            return .object([
                "status": .string("failed"),
                "reason": .string("page_out_of_range"),
                "page_count": .int(Int64(pageCount)),
            ])
        }
        let startByte = entry.pageByteOffsets[page]
        let endByte = entry.pageByteOffsets[page + 1]
        guard let file = try? FileHandle(forReadingFrom: entry.url) else {
            remove(handle: handle)
            return .object([
                "status": .string("failed"),
                "reason": .string("result_spill_unreadable"),
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
            ])
        }
        // Reading renews the handle: a result the model is still working
        // through is in use, whatever the clock says.
        entries[handle]?.lastReadAt = Date()
        let hasMore = page + 1 < pageCount
        let nextPage: JSONValue = hasMore ? .int(Int64(page + 1)) : .null
        return .object([
            "status": .string("completed"),
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

    func resetForTests() {
        liveScopes.removeAll()
        for handle in Array(entries.keys) { remove(handle: handle) }
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
        guard let entry = entries.removeValue(forKey: handle) else { return }
        totalBytes = max(0, totalBytes - entry.bytes)
        try? FileManager.default.removeItem(at: entry.url)
    }
}

extension SwiftToolDispatcher {
    func impl_tool_result_page(input: [String: JSONValue]) async -> JSONValue {
        guard case .string(let handle)? = input["result_handle"], !handle.isEmpty else {
            return .object([
                "status": .string("failed"),
                "reason": .string("missing_result_handle"),
            ])
        }
        let page: Int = {
            if case .int(let value)? = input["page"] { return Int(value) }
            return 0
        }()
        return await ProviderToolResultRecoveryStore.shared.page(
            handle: handle,
            page: page,
            sessionId: Self.extractSessionId(from: input),
            turnId: TurnTraceContext.turnId
        )
    }
}
