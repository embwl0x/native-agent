import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Skill pointer index (2026-07-03)
//
// The skills audit found ZERO list_skills/read_skill invocations in three
// weeks of logs: skills were pull-only, nothing surfaced them, and the
// daemon-era context router that used to pool them into turns was never
// ported. The approved design (User, 2026-07-03) rides the EXISTING librarian:
// every skill body gets a one-line POINTER row in the memory store, embedded
// like any memory, so per-turn hybrid recall surfaces "there is a skill for
// this" exactly when a conversation enters its territory. Bodies stay lazy —
// the pointer tells the model to pull read_skill.
//
// Row contract:
//   id        "skill-pointer:<name>"     (deterministic — idempotent sync)
//   kind      "skill"                    (already in the taxonomy; NOT in
//                                        memoryDecayHalfLifeDays → decay 1.0)
//   lifecycle "confirmed", status "active"
//   removal   status+lifecycle flipped to "deleted" when the skill file goes
//             away. Deliberately NOT deleteMemory(): that path mints
//             embedding tombstones (the rejection denylist) which would block
//             re-adding a similar skill pointer forever.
//
// Sync is called from app start (after memory warmup) and after skill
// enable/disable mutations. Re-embeds only when the pointer text changed.

/// Chains sync executions so no two run concurrently (see doc on
/// `syncSkillPointers`). Each new run awaits the previous one's completion
/// (success OR failure) before starting, so every run reads a snapshot that
/// reflects all prior runs' writes.
actor SkillPointerSyncGate {
    static let shared = SkillPointerSyncGate()
    private var last: Task<SwiftNativeMemoryV2.SkillIndexSyncResult, Error>?

    func run(
        _ op: @escaping @Sendable () async throws -> SwiftNativeMemoryV2.SkillIndexSyncResult
    ) async throws -> SwiftNativeMemoryV2.SkillIndexSyncResult {
        let prev = last
        let task = Task {
            _ = try? await prev?.value
            return try await op()
        }
        last = task
        return try await task.value
    }
}

extension SwiftNativeMemoryV2 {

    public struct SkillIndexSyncResult: Sendable, Equatable {
        public let added: Int
        public let updated: Int
        public let removed: Int
        public let unchanged: Int
        public init(added: Int, updated: Int, removed: Int, unchanged: Int) {
            self.added = added
            self.updated = updated
            self.removed = removed
            self.unchanged = unchanged
        }
    }

    public static let skillPointerIDPrefix = "skill-pointer:"

    /// Scan `bodiesDirs` (first directory wins on name collisions — runtime
    /// bodies override persona bodies, mirroring impl_list_skills precedence)
    /// and reconcile the store's skill-pointer rows against what's on disk.
    ///
    /// Serialized through `SkillPointerSyncGate`: launch sync and the
    /// enable/disable/delete hooks can fire concurrently, and the body
    /// awaits embedding work between its read-snapshot and its writes — an
    /// interleaved pair could resurrect a just-removed pointer from a stale
    /// snapshot (gpt-5.5 review MED, 2026-07-03).
    @discardableResult
    public func syncSkillPointers(
        bodiesDirs: [URL],
        runtimeRegistryURL: URL? = nil
    ) async throws -> SkillIndexSyncResult {
        try await SkillPointerSyncGate.shared.run { [self] in
            try await syncSkillPointersUnserialized(
                bodiesDirs: bodiesDirs,
                runtimeRegistryURL: runtimeRegistryURL
            )
        }
    }

    /// Reconcile pointers and publish the one durable diagnostic receipt used
    /// by launch, UI mutations, and conversational skill writes. Missing body
    /// shelves are valid on a blank install and remain an `ok` result; the
    /// receipt records them as optional-missing diagnostics instead of
    /// inventing a failure.
    @discardableResult
    public func syncSkillPointersRecordingReceipt(
        bodiesDirs: [URL],
        runtimeRegistryURL: URL? = nil,
        receiptURL: URL
    ) async throws -> SkillIndexSyncResult {
        try await SkillPointerSyncGate.shared.run { [self] in
            do {
                let result = try await syncSkillPointersUnserialized(
                    bodiesDirs: bodiesDirs,
                    runtimeRegistryURL: runtimeRegistryURL
                )
                Self.writeSkillPointerSyncReceipt(
                    at: receiptURL,
                    bodiesDirs: bodiesDirs,
                    result: result,
                    error: nil
                )
                return result
            } catch {
                Self.writeSkillPointerSyncReceipt(
                    at: receiptURL,
                    bodiesDirs: bodiesDirs,
                    result: nil,
                    error: error
                )
                throw error
            }
        }
    }

    func syncSkillPointersUnserialized(
        bodiesDirs: [URL],
        runtimeRegistryURL: URL? = nil
    ) async throws -> SkillIndexSyncResult {
        // 1. Current skills on disk → pointer text.
        var current: [String: String] = [:]
        let fm = FileManager.default
        let runtimeAvailability = try Self.runtimeSkillAvailability(
            registryURL: runtimeRegistryURL,
            fileManager: fm
        )
        var explicitlyUnavailableRuntimeNames: Set<String> = []
        for (directoryIndex, dir) in bodiesDirs.enumerated() {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where file.pathExtension.lowercased() == "md" {
                let name = file.deletingPathExtension().lastPathComponent
                let normalizedName = name.lowercased()
                if directoryIndex == 0,
                   runtimeAvailability?[normalizedName] == false {
                    explicitlyUnavailableRuntimeNames.insert(normalizedName)
                    continue
                }
                if directoryIndex > 0,
                   explicitlyUnavailableRuntimeNames.contains(normalizedName) {
                    continue
                }
                guard current[name] == nil else { continue }
                guard let body = try? String(contentsOf: file, encoding: .utf8),
                      !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                // Same hygiene gate the skill tools apply (gpt-5.5 review
                // LOW): a body list_skills/read_skill would hide must not
                // get a recall pointer promising a read that will refuse.
                guard SkillBodyHygiene.violations(in: body).isEmpty else { continue }
                current[name] = Self.skillPointerText(name: name, body: body)
            }
        }

        // 2. Existing pointer rows. listMemory(kind:) includes status-deleted
        // rows (it filters only lifecycle-terminal), so a previously-removed
        // skill that reappears flips back to active under the same id.
        let all = try await listMemory(kind: "skill")
        var existing: [String: MemoryRecord] = [:]
        for row in all where row.id.hasPrefix(Self.skillPointerIDPrefix) {
            existing[String(row.id.dropFirst(Self.skillPointerIDPrefix.count))] = row
        }

        var added = 0, updated = 0, removed = 0, unchanged = 0
        let now = ISO8601DateFormatter().string(from: Date())

        // 3. Upsert every skill on disk. 2026-07-21 audit fix: writes go
        // through the epoch-AWARE overloads (embedOneWithEpoch + the
        // embeddingEpoch-carrying insert/update). The epoch-less overloads
        // forward embeddingEpoch: nil, which requireWritableEpoch rejects
        // with embeddingEpochMismatch the moment any epoch is activated —
        // every skill-pointer sync threw post-activation.
        for (name, text) in current.sorted(by: { $0.key < $1.key }) {
            let id = Self.skillPointerIDPrefix + name
            if let row = existing[name] {
                if row.text == text, row.status == "active" {
                    unchanged += 1
                    continue
                }
                let embedded = try await embedOneWithEpoch(text)
                guard let storage else { throw MemoryV2Error.storageUnavailable }
                _ = try await storage.updateMemory(
                    id: id,
                    patch: .object([
                        "content": .string(text),
                        "status": .string("active"),
                    ]),
                    newEmbedding: embedded.vector,
                    embeddingEpoch: embedded.epoch
                )
                updated += 1
            } else {
                let embedded = try await embedOneWithEpoch(text)
                let record = MemoryRecord(
                    id: id,
                    text: text,
                    layer: "semantic",
                    memoryKind: "skill",
                    createdAt: now,
                    updatedAt: now,
                    sourceRunId: "skill-index",
                    status: "active",
                    extras: Self.skillPointerMetadata(name: name)
                )
                guard let storage else { throw MemoryV2Error.storageUnavailable }
                _ = try await storage.insert(
                    record: record,
                    embedding: embedded.vector,
                    embeddingEpoch: embedded.epoch
                )
                added += 1
            }
        }

        // 4. Retire pointers whose skill file is gone (archived/renamed).
        // Status "deleted" removes them from recall eligibility WITHOUT
        // minting a rejection tombstone (deleteMemory would).
        for (name, row) in existing where current[name] == nil {
            guard row.status == "active" else { continue }
            guard let storage else { throw MemoryV2Error.storageUnavailable }
            _ = try await storage.updateMemory(
                id: row.id,
                patch: .object(["status": .string("deleted")]),
                newEmbedding: nil
            )
            removed += 1
        }

        return SkillIndexSyncResult(
            added: added, updated: updated, removed: removed, unchanged: unchanged
        )
    }

    /// A missing registry means runtime body-only skills are valid legacy
    /// inputs. Once a registry exists, an existing row with a non-active
    /// status explicitly suppresses its body from automatic recall. Malformed
    /// existing bytes fail loud rather than silently exposing or hiding
    /// procedures.
    private static func runtimeSkillAvailability(
        registryURL: URL?,
        fileManager: FileManager
    ) throws -> [String: Bool]? {
        guard let registryURL else { return nil }
        guard fileManager.fileExists(atPath: registryURL.path) else { return nil }
        let data = try Data(contentsOf: registryURL)
        let decoded = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let array = decoded as? [[String: Any]] {
            rows = array
        } else if let object = decoded as? [String: Any],
                  let skills = object["skills"] as? [[String: Any]] {
            rows = skills
        } else {
            throw MemoryV2Error.underlying(
                "skill registry is not an array or {skills:[...]}"
            )
        }

        let availableStatuses: Set<String> = ["active", "installed"]
        var availability: [String: Bool] = [:]
        for row in rows {
            let status = (row["status"] as? String ?? "active").lowercased()
            let available = availableStatuses.contains(status)
            for raw in [row["id"] as? String, row["name"] as? String].compactMap({ $0 }) {
                let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !key.isEmpty {
                    availability[key] = available
                }
            }
        }
        return availability
    }

    private static func writeSkillPointerSyncReceipt(
        at receiptURL: URL,
        bodiesDirs: [URL],
        result: SkillIndexSyncResult?,
        error: Error?
    ) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: receiptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var present: [String] = []
        var missing: [String] = []
        for dir in bodiesDirs {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dir.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                present.append(dir.path)
            } else {
                missing.append(dir.path)
            }
        }
        var object: [String: String] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "bodiesDirs": bodiesDirs.map(\.path).joined(separator: " | "),
            "presentBodiesDirs": present.joined(separator: " | "),
            "missingOptionalBodiesDirs": missing.joined(separator: " | "),
        ]
        if let result {
            object["status"] = "ok"
            object["added"] = String(result.added)
            object["updated"] = String(result.updated)
            object["removed"] = String(result.removed)
            object["unchanged"] = String(result.unchanged)
        } else {
            object["status"] = "failed"
            object["error"] = error.map(String.init(describing:)) ?? "unknown"
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: receiptURL, options: .atomic)
    }

    // MARK: helpers

    /// One-line pointer: name + the skill's own hook line. The hook is the
    /// first non-heading, non-empty line of the body — every body leads with
    /// its "Use when…" sentence. Bounded so a rogue body can't bloat recall.
    static func skillPointerText(name: String, body: String) -> String {
        var hook = ""
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // Bodies open with "Use when…" / "**When to load:** …" hooks in
            // a few decorations; strip the wrapping, keep the sentence.
            line = line
                .replacingOccurrences(of: "**When to load:**", with: "")
                .replacingOccurrences(of: "**When to use:**", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "_* \t"))
            guard !line.isEmpty else { continue }
            hook = line
            break
        }
        if hook.count > 220 {
            hook = String(hook.prefix(220)) + "…"
        }
        let base = "Skill available: \(name)"
        let tail = "Load it with read_skill(\"\(name)\") when this comes up."
        if hook.isEmpty { return "\(base). \(tail)" }
        return "\(base) — \(hook) \(tail)"
    }

    static func skillPointerMetadata(name: String) -> JSONValue {
        .object([
            "kind": .string("skill"),
            "kind_source": .string("skill_index_v1"),
            "skill_name": .string(name),
        ])
    }
}
