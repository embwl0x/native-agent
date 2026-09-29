import Foundation
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2

extension NativeClient {
    func consolidateMemory() async throws -> [String: Any] {
        // Use the same MemoryConsolidator as the background loop.
        return try await triggerMemoryConsolidation(dryRun: false)
    }

    // PATCH-2026-05-08: wave2-chat-ux slash /remember support
    //
    // The resolved canonical owner embeds + inserts through MemoryStorage
    // with the same tombstone gate for both default and alternate roots.
    @discardableResult
    func addMemory(
        text: String,
        source: String = "mac.slash-remember",
        metadata: JSONValue? = nil,
        memory: SwiftNativeMemoryV2? = nil
    ) async throws -> MemoryV2.MemoryRecord {
        let owner = memory ?? SwiftNativeMemoryV2.resolvedOwner(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
        return try await owner.store(content: text, source: source, metadata: metadata)
    }

    func postNote(
        text: String,
        kind: String = "user_note",
        tags: [String] = [],
        memory: SwiftNativeMemoryV2? = nil
    ) async throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "NativeAgentNotes", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "text is required"])
        }

        let resolvedKind = kind.isEmpty ? "note" : kind.trimmingCharacters(in: .whitespacesAndNewlines)
        // 2026-09-06: notes follow the same root-aware owner as other memory writes.
        let owner = memory ?? SwiftNativeMemoryV2.resolvedOwner(
            dataRoot: dataRootOverride ?? PersistenceCore.defaultDataRoot()
        )
        let record = try await owner.store(
            content: trimmed,
            source: "mac.note",
            metadata: .object([
                "note_kind": .string(resolvedKind),
                "tags": .array(tags.map { .string($0) }),
                "confidence": .double(0.8),
                "importance": .double(0.5),
                "surface": .string("mac"),
                "command": .string("/note"),
            ])
        )
        return ["ok": true, "id": record.id]
    }

    // Persist per-session scratch directly under the shared file lock.
    // A missing session refuses the write rather than creating a throwaway namespace.
    func postScratch(key: String, value: String, sessionId: String? = nil) async throws -> [String: Any] {
        guard let sid = sessionId, !sid.isEmpty else {
            return ["ok": false, "error": "scratch requires a session"]
        }
        // Use the same normalized session directory as the other session writers.
        guard let safeSid = NativeAgentChatSessionID.normalizedPathComponent(sid) else {
            return ["ok": false, "error": "invalid session id for scratch"]
        }
        let path = (dataRootOverride ?? PersistenceCore.defaultDataRoot())
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(safeSid, isDirectory: true)
            .appendingPathComponent("scratch.json")
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let current = try await persistence.readJSON(path, ifMissing: .object([:]))
            var root: [String: JSONValue]
            if case .object(let obj) = current { root = obj } else { root = [:] }
            root[key] = .string(value)
            try await persistence.writeJSON(.object(root), to: path)
        }
        return ["ok": true, "key": key, "namespace": safeSid, "full_key": "\(safeSid):\(key)"]
    }

}
