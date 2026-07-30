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
    static let maxEntryBytes = 64 * 1024 * 1024
    static let maxTotalBytes = 128 * 1024 * 1024
    static let maxEntries = 32
    static let ttl: TimeInterval = 30 * 60

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
    }

    private let root: URL
    private var entries: [String: Entry] = [:]
    private var totalBytes = 0

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
        for scalar in content.unicodeScalars {
            let value = scalar.value
            let scalarBytes = value <= 0x7F ? 1 : value <= 0x7FF ? 2 : value <= 0xFFFF ? 3 : 4
            if byteOffset > pageStartByte,
               byteOffset - pageStartByte + scalarBytes > Self.pageUTF8Bytes {
                pageByteOffsets.append(byteOffset)
                pageStartByte = byteOffset
            }
            byteOffset += scalarBytes
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

        let entry = Entry(
            handle: handle,
            toolName: toolName,
            scope: scope,
            url: url,
            characters: content.count,
            bytes: data.count,
            pageByteOffsets: pageByteOffsets,
            createdAt: Date()
        )
        entries[handle] = entry
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
        let hasMore = page + 1 < pageCount
        let nextPage: JSONValue = hasMore ? .int(Int64(page + 1)) : .null
        return .object([
            "status": .string("completed"),
            "tool": .string(entry.toolName),
            "result_handle": .string(handle),
            "page": .int(Int64(page)),
            "page_count": .int(Int64(pageCount)),
            "page_bytes": .int(Int64(Self.pageUTF8Bytes)),
            "original_characters": .int(Int64(entry.characters)),
            "original_bytes": .int(Int64(entry.bytes)),
            "content": .string(content),
            "has_more": .bool(hasMore),
            "next_page": nextPage,
        ])
    }

    func remove(scope: Scope) {
        for handle in entries.values.filter({ $0.scope == scope }).map(\.handle) {
            remove(handle: handle)
        }
    }

    func resetForTests() {
        for handle in Array(entries.keys) { remove(handle: handle) }
    }

    private func cleanupExpired(now: Date) {
        for entry in entries.values where now.timeIntervalSince(entry.createdAt) >= Self.ttl {
            remove(handle: entry.handle)
        }
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
