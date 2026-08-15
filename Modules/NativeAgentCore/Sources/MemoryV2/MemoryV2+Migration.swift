import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - MemoryV2 Path C migration: JSON files → SQLite + re-embed
//
// Reads the legacy on-disk JSON layout
// (<dataRoot>/memory/memory.json + <dataRoot>/memory/*/notes.jsonl +
// <dataRoot>/memory_proposals/*.json + <dataRoot>/.rejected_tombstones)
// and lands eligible entries into the
// SwiftNative SQLite store via a MemoryStorage actor (sister worker m1).
//
// One-way: a sentinel file `<dataRoot>/memory/.migrated_to_sqlite_v2_approved_only`
// records first-run completion. Once present it is authoritative even when
// the canonical store is empty, because an empty store may be the intentional
// result of owner deletion. Before completion, retries remain safe because
// every insert is existence-gated. Original JSON files are preserved for the
// legacy backup window but are never re-imported after completion.

// MARK: - MemoryStorage seam
//
// The migrator depends only on this protocol; production wiring uses
// `RealMemoryStorage` over the GRDB `MemoryStorage` actor, and the
// MemoryV2Tests target pins an in-memory stub (moved out of this module
// 2026-07-21 — it was cutover residue whose own comment said to delete it).

public protocol MemoryV2Storage: Sendable {
    func memoryExists(id: String) async throws -> Bool
    func insertMemory(_ record: MemoryRecord, embedding: [Float]) async throws
    func upsertMemory(_ record: MemoryRecord, embedding: [Float]) async throws -> Bool
    func deleteProposal(id: String) async throws -> Bool
    func tombstoneExists(_ key: String) async throws -> Bool
    func insertTombstone(_ key: String) async throws
}

// MARK: - RealMemoryStorage — MemoryV2Storage backed by the GRDB MemoryStorage actor

/// Wraps the SQLite-backed `MemoryStorage` so the migrator writes into the
/// real on-disk store (`<dataRoot>/memory/memory.sqlite`). Constructed by
/// MemoryV2Migrator's default init; unit tests inject an in-memory stub
/// instead.
public actor RealMemoryStorage: MemoryV2Storage {
    private let storage: MemoryStorage

    public init(storage: MemoryStorage) {
        self.storage = storage
    }

    public func memoryExists(id: String) async throws -> Bool {
        return try await storage.memory(id: id) != nil
    }

    public func insertMemory(_ record: MemoryRecord, embedding: [Float]) async throws {
        let stored = StoredMemory(
            id: record.id,
            content: record.text,
            personaId: Self.personaID(from: record),
            source: record.sourceRunId,
            confidence: record.confidence ?? 1.0,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt ?? record.createdAt,
            embedding: embedding.isEmpty ? nil : embedding,
            status: record.status ?? "active",
            metadata: record.extras
        )
        _ = try await storage.insertMemory(stored)
    }

    public func upsertMemory(_ record: MemoryRecord, embedding: [Float]) async throws -> Bool {
        let stored = StoredMemory(
            id: record.id,
            content: record.text,
            personaId: Self.personaID(from: record),
            source: record.sourceRunId,
            confidence: record.confidence ?? 1.0,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt ?? record.createdAt,
            embedding: embedding.isEmpty ? nil : embedding,
            status: record.status ?? "active",
            metadata: record.extras
        )
        if try await storage.memory(id: stored.id) == nil {
            _ = try await storage.insertMemory(stored)
            return true
        }
        _ = try await storage.updateMemory(
            id: stored.id,
            patch: MemoryPatch(
                content: stored.content,
                source: stored.source,
                confidence: stored.confidence,
                embedding: stored.embedding,
                status: stored.status,
                metadata: stored.metadata
            )
        )
        return false
    }

    public func deleteProposal(id: String) async throws -> Bool {
        try await storage.deleteProposal(id: id)
    }

    public func tombstoneExists(_ key: String) async throws -> Bool {
        return try await storage.isTombstoned(content: key)
    }

    public func insertTombstone(_ key: String) async throws {
        try await storage.addTombstone(content: key, reason: nil)
    }

    private static func personaID(from record: MemoryRecord) -> String {
        if case .object(let obj)? = record.extras,
           case .string(let persona)? = obj["legacy_persona"] {
            let trimmed = persona.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return MemoryV2Defaults.personaID
    }

}

// MARK: - MigrationReport

public struct MigrationReport: Sendable, Equatable {
    public var memoriesImported: Int
    public var proposalsImported: Int
    public var tombstonesImported: Int
    public var errors: [String]
    public var skippedAlreadyMigrated: Bool
    /// Count of per-row embed / insert failures that MUST succeed before the
    /// migration sentinel can be written. When > 0 the migrator refuses to
    /// write `.migrated_to_sqlite_v2_approved_only` so a fail-closed embedding
    /// state (CoreML model missing / load error) doesn't get permanently
    /// sealed — the next launch retries instead.
    public var requiredFailures: Int

    public init(
        memoriesImported: Int = 0,
        proposalsImported: Int = 0,
        tombstonesImported: Int = 0,
        errors: [String] = [],
        skippedAlreadyMigrated: Bool = false,
        requiredFailures: Int = 0
    ) {
        self.memoriesImported = memoriesImported
        self.proposalsImported = proposalsImported
        self.tombstonesImported = tombstonesImported
        self.errors = errors
        self.skippedAlreadyMigrated = skippedAlreadyMigrated
        self.requiredFailures = requiredFailures
    }
}

// MARK: - MemoryV2Migrator

public actor MemoryV2Migrator {
    private let dataRoot: URL
    private let providedStorage: (any MemoryV2Storage)?
    private let embedder: any EmbeddingProvider

    /// Default init opens the REAL GRDB-backed `MemoryStorage` at
    /// `<dataRoot>/memory/memory.sqlite`. If that open throws (disk perms,
    /// schema migration failure), `providedStorage` stays nil and
    /// `migrate()` aborts WITHOUT writing the sentinel — re-running on the
    /// next launch then gets another chance.
    public init(
        dataRoot: URL = defaultDataRoot(),
        storage: (any MemoryV2Storage)? = nil,
        embedder: (any EmbeddingProvider)? = nil
    ) {
        self.dataRoot = dataRoot
        self.providedStorage = storage
        self.embedder = embedder ?? Self.defaultEmbeddingProvider()
    }

    /// Pick the embedding provider for the legacy → SQLite migration pass.
    ///
    /// FAIL-CLOSED: if CoreML isn't usable we return a `FailClosedEmbeddingProvider`
    /// that throws on every `embed()` call. The pre-fix behavior (silent
    /// MockEmbedding fallback with random vectors) wrote the migration sentinel
    /// against garbage embeddings and then never re-tried, so semantic recall
    /// returned noise forever; throwing here at least makes the failure visible
    /// in the migration report. `NATIVE_AGENT_EMBEDDING_MOCK=1` opts a developer
    /// test into mock vectors.
    ///
    /// PAIRED FIX (2026-06-06): `migrate()` below now also refuses to write the
    /// `.migrated_to_sqlite_v2_approved_only` sentinel when any required embed
    /// / insert failed — so a fail-closed migration retries on the next launch
    /// instead of locking in a partial state. See `MigrationReport.requiredFailures`.
    private nonisolated static func defaultEmbeddingProvider() -> any EmbeddingProvider {
        if let coreML = try? CoreMLEmbeddingProvider.bundled() {
            return coreML
        }
        if ProcessInfo.processInfo.environment["NATIVE_AGENT_EMBEDDING_MOCK"] == "1" {
            return MockEmbeddingProvider(dimensions: 384)
        }
        return FailClosedEmbeddingProvider(dimensions: 384)
    }

    private var memoryDir: URL { dataRoot.appendingPathComponent("memory", isDirectory: true) }
    private var proposalsDir: URL { dataRoot.appendingPathComponent("memory_proposals", isDirectory: true) }
    private var tombstoneFile: URL { dataRoot.appendingPathComponent(".rejected_tombstones") }
    private var markerFile: URL { memoryDir.appendingPathComponent(".migrated_to_sqlite_v2_approved_only") }

    public func migrate() async -> MigrationReport {
        var report = MigrationReport()
        let fm = FileManager.default

        // Completion is strictly one-way. Legacy files are retained as cold
        // backups, so consulting canonical row count here would resurrect
        // owner-deleted content whenever the last SQLite row was removed.
        if fm.fileExists(atPath: markerFile.path) {
            print("[MemoryV2Migrator] dataRoot=\(dataRoot.path) sentinel=true; skipping completed migration")
            report.skippedAlreadyMigrated = true
            return report
        }

        // Resolve storage. Default: real SQLite. If the GRDB open throws we
        // refuse to mark migration "done" — sentinel ONLY lands when we have
        // a real store that successfully accepted the rows.
        let storage: any MemoryV2Storage
        if let provided = providedStorage {
            storage = provided
        } else if let real = try? MemoryStorage(dataRoot: dataRoot) {
            storage = RealMemoryStorage(storage: real)
        } else {
            report.errors.append("MemoryV2Migrator: real SQLite storage unavailable; sentinel NOT written")
            return report
        }

        try? fm.createDirectory(at: memoryDir, withIntermediateDirectories: true)

        await migrateMemories(storage: storage, into: &report)
        await migrateLegacyNotes(storage: storage, into: &report)
        await migrateProposals(storage: storage, into: &report)
        await migrateTombstones(storage: storage, into: &report)

        // Refuse the sentinel when ANY required embed / insert failed. A
        // `FailClosedEmbeddingProvider` migration would otherwise lock in an
        // empty/partial state and every later launch would correctly treat that
        // completion marker as authoritative.
        // With this gate the migrator marks "done" ONLY when:
        //   * every per-row embed + insert succeeded, OR
        //   * there was nothing to migrate (a clean fresh install).
        // Re-runs are safe because every insert is existence-gated.
        if report.requiredFailures == 0 {
            if let data = ISO8601DateFormatter().string(from: Date()).data(using: .utf8) {
                try? data.write(to: markerFile, options: .atomic)
            }
        } else {
            report.errors.append(
                "MemoryV2Migrator: \(report.requiredFailures) required embed/insert failure(s); "
                + "sentinel NOT written so migration retries next launch"
            )
        }
        return report
    }

    // MARK: memories

    private func migrateMemories(storage: any MemoryV2Storage, into report: inout MigrationReport) async {
        let memoryFile = memoryDir.appendingPathComponent("memory.json")
        guard FileManager.default.fileExists(atPath: memoryFile.path) else { return }
        // The file EXISTS from here on — any failure to read or decode it
        // must count as required, or the sentinel gets stamped and the
        // legacy memories are silently skipped on every future launch
        // (audit 2026-06-09; same class as the embed-failure gate above).
        guard let data = try? Data(contentsOf: memoryFile) else {
            report.errors.append("memory.json: exists but unreadable")
            report.requiredFailures += 1
            return
        }

        let records: [MemoryRecord]
        do {
            records = try decodeMemoryArray(data)
        } catch {
            report.errors.append("memory.json: decode failed: \(error)")
            report.requiredFailures += 1
            return
        }

        for record in records {
            guard !record.id.isEmpty else {
                report.errors.append("memory: skipped record with empty id")
                continue
            }
            do {
                if try await storage.memoryExists(id: record.id) { continue }
                let vector = (try await embedder.embed([record.text])).first ?? []
                try await storage.insertMemory(record, embedding: vector)
                report.memoriesImported += 1
            } catch {
                report.errors.append("memory \(record.id): \(error)")
                report.requiredFailures += 1
            }
        }
    }

    /// memory.json on disk has historically been EITHER a bare JSON array of
    /// records OR a wrapping object like `{"memories":[...]}`. Accept both
    /// shapes so the migrator survives whichever the daemon last wrote.
    private func decodeMemoryArray(_ data: Data) throws -> [MemoryRecord] {
        let decoder = JSONDecoder()
        if let arr = try? decoder.decode([MemoryRecord].self, from: data) {
            return arr
        }
        let obj = try decoder.decode([String: JSONValue].self, from: data)
        if case .array(let list)? = obj["memories"] {
            return try list.map { v in
                let bytes = try JSONEncoder().encode(v)
                return try decoder.decode(MemoryRecord.self, from: bytes)
            }
        }
        return []
    }

    // MARK: legacy notes.jsonl

    /// Import already-committed legacy note memories. `notes.jsonl` is the
    /// durable output of `commit_memory`; pending/rejected proposal files live
    /// elsewhere and are handled by `migrateProposals`.
    private func migrateLegacyNotes(storage: any MemoryV2Storage, into report: inout MigrationReport) async {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: memoryDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for dir in entries {
            guard ((try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) else {
                continue
            }
            let notesFile = dir.appendingPathComponent("notes.jsonl")
            guard let data = try? Data(contentsOf: notesFile),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }
            for (offset, rawLine) in text.split(whereSeparator: \.isNewline).enumerated() {
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                do {
                    let value = try JSONValue.parse(Data(line.utf8))
                    guard let legacy = LegacyNoteImport(raw: value, notesPath: notesFile.path) else {
                        continue
                    }
                    let vector = (try await embedder.embed([legacy.text])).first ?? []
                    let inserted = try await storage.upsertMemory(legacy.memoryRecord(), embedding: vector)
                    if inserted {
                        report.memoriesImported += 1
                    }
                } catch {
                    report.errors.append("notes.jsonl \(notesFile.lastPathComponent)#\(offset + 1): \(error)")
                    report.requiredFailures += 1
                }
            }
        }
    }

    private struct LegacyNoteImport: Sendable {
        var id: String
        var text: String
        var persona: String?
        var kind: String?
        var createdAt: String
        var sourceRun: String?
        var confidence: Double?
        var importance: Double?
        var tags: [String]?
        var raw: JSONValue
        var notesPath: String

        init?(raw: JSONValue, notesPath: String) {
            guard case .object(let obj) = raw else { return nil }
            if Self.bool(obj, "_test_fixture") == true {
                return nil
            }
            guard let id = Self.string(obj, "id") else { return nil }
            guard let text = Self.string(obj, "text") else { return nil }
            self.id = id
            self.text = text
            self.persona = Self.string(obj, "persona")
            self.kind = Self.string(obj, "kind")
            self.createdAt = Self.string(obj, "ts")
                ?? Self.string(obj, "createdAt")
                ?? Self.string(obj, "created_at")
                ?? MemoryStorage.nowISO8601()
            self.sourceRun = Self.string(obj, "source_run") ?? Self.string(obj, "sourceRunId")
            self.confidence = Self.double(obj, "confidence")
            self.importance = Self.double(obj, "importance")
            self.tags = Self.stringArray(obj, "tags")
            self.raw = raw
            self.notesPath = notesPath
        }

        func memoryRecord() -> MemoryRecord {
            MemoryRecord(
                id: id,
                text: text,
                layer: "semantic",
                memoryKind: kind,
                createdAt: createdAt,
                updatedAt: createdAt,
                sourceRunId: sourceRun,
                status: "active",
                confidence: confidence ?? 0.8,
                importance: importance ?? 0.5,
                tags: tags,
                extras: .object([
                    "legacy_note": raw,
                    "legacy_persona": persona.map(JSONValue.string) ?? .null,
                    "legacy_notes_path": .string(notesPath),
                ])
            )
        }

        private static func string(_ obj: [String: JSONValue], _ key: String) -> String? {
            guard case .string(let s)? = obj[key] else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func bool(_ obj: [String: JSONValue], _ key: String) -> Bool? {
            guard case .bool(let b)? = obj[key] else { return nil }
            return b
        }

        private static func double(_ obj: [String: JSONValue], _ key: String) -> Double? {
            switch obj[key] {
            case .double(let d): return d
            case .int(let i): return Double(i)
            case .string(let s): return Double(s)
            default: return nil
            }
        }

        private static func stringArray(_ obj: [String: JSONValue], _ key: String) -> [String]? {
            guard case .array(let arr)? = obj[key] else { return nil }
            let values = arr.compactMap { value -> String? in
                guard case .string(let s) = value else { return nil }
                return s
            }
            return values.isEmpty ? nil : values
        }
    }

    // MARK: proposals

    private func migrateProposals(storage: any MemoryV2Storage, into report: inout MigrationReport) async {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: proposalsDir, includingPropertiesForKeys: nil) else {
            return
        }
        for url in entries where url.pathExtension == "json" {
            let fileID = url.deletingPathExtension().lastPathComponent
            do {
                let data = try Data(contentsOf: url)
                let value = try JSONDecoder().decode(JSONValue.self, from: data)
                guard let legacy = LegacyProposalImport(fileID: fileID, raw: value) else {
                    for id in legacyProposalIDs(fileID: fileID, raw: value) {
                        _ = try await storage.deleteProposal(id: id)
                    }
                    continue
                }

                switch legacy.status {
                case .approved:
                    guard !legacy.content.isEmpty else {
                        report.errors.append("proposal \(fileID): approved legacy proposal has empty fact_text")
                        for id in legacy.idsToDelete {
                            _ = try await storage.deleteProposal(id: id)
                        }
                        continue
                    }
                    do {
                        let vector = (try await embedder.embed([legacy.content])).first ?? []
                        let inserted = try await storage.upsertMemory(legacy.memoryRecord(), embedding: vector)
                        if inserted {
                            report.memoriesImported += 1
                        }
                    } catch {
                        // Embed/insert is the REQUIRED work for an approved
                        // proposal — bump requiredFailures so the sentinel
                        // refuses to write and migration retries.
                        report.errors.append("proposal \(fileID) approved embed/upsert: \(error)")
                        report.requiredFailures += 1
                    }
                    for id in legacy.idsToDelete {
                        _ = try await storage.deleteProposal(id: id)
                    }
                case .pending, .rejected, .unknown:
                    for id in legacy.idsToDelete {
                        _ = try await storage.deleteProposal(id: id)
                    }
                }
            } catch {
                report.errors.append("proposal \(fileID): \(error)")
                report.requiredFailures += 1
            }
        }
    }

    private enum LegacyProposalStatus: Sendable {
        case approved
        case pending
        case rejected
        case unknown
    }

    private struct LegacyProposalImport: Sendable {
        var fileID: String
        var proposalID: String?
        var status: LegacyProposalStatus
        var content: String
        var source: String?
        var stagedAt: String
        var resolvedAt: String?
        var raw: JSONValue

        var memoryID: String { proposalID ?? fileID }

        var idsToDelete: [String] {
            var ids = [fileID, memoryID]
            if let proposalID {
                ids.append("candidate-\(proposalID)")
            }
            return Array(Set(ids))
        }

        init?(fileID: String, raw: JSONValue) {
            guard case .object(let obj) = raw else { return nil }
            let proposalID = Self.string(obj, "proposal_id")
            let status = Self.normalizeStatus(Self.string(obj, "status"))
            let content = (
                Self.string(obj, "content")
                ?? Self.string(obj, "text")
                ?? Self.string(obj, "fact_text")
                ?? Self.string(obj, "display_text")
                ?? ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let stagedAt = (
                Self.string(obj, "staged_at")
                ?? Self.string(obj, "createdAt")
                ?? Self.string(obj, "created_at")
                ?? Self.string(obj, "first_seen")
                ?? Self.string(obj, "last_seen")
                ?? MemoryStorage.nowISO8601()
            )
            self.fileID = fileID
            self.proposalID = proposalID
            self.status = status
            self.content = content
            self.source = Self.string(obj, "source")
            self.stagedAt = stagedAt
            self.resolvedAt = Self.string(obj, "resolved_at") ?? Self.string(obj, "approved_at")
            self.raw = raw
        }

        func memoryRecord() -> MemoryRecord {
            let created = resolvedAt ?? stagedAt
            return MemoryRecord(
                id: memoryID,
                text: content,
                layer: "semantic",
                memoryKind: "legacy_approved_proposal",
                createdAt: created,
                updatedAt: resolvedAt ?? created,
                sourceRunId: source,
                status: "active",
                confidence: 1.0,
                extras: .object([
                    "legacy_proposal": raw,
                    "legacy_file_id": .string(fileID),
                ])
            )
        }

        private static func string(_ obj: [String: JSONValue], _ key: String) -> String? {
            guard case .string(let s)? = obj[key] else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func normalizeStatus(_ raw: String?) -> LegacyProposalStatus {
            switch raw?.lowercased() {
            case "approved", "accepted":
                return .approved
            case "pending", "staged":
                return .pending
            case "rejected", "denied":
                return .rejected
            default:
                return .unknown
            }
        }
    }

    private func legacyProposalIDs(fileID: String, raw: JSONValue) -> [String] {
        guard case .object(let obj) = raw,
              case .string(let proposalID)? = obj["proposal_id"] else {
            return [fileID]
        }
        return Array(Set([fileID, proposalID, "candidate-\(proposalID)"]))
    }

    // MARK: tombstones

    private func migrateTombstones(storage: any MemoryV2Storage, into report: inout MigrationReport) async {
        guard FileManager.default.fileExists(atPath: tombstoneFile.path) else { return }
        guard let data = try? Data(contentsOf: tombstoneFile),
              let text = String(data: data, encoding: .utf8) else {
            // Tombstones are the rejection denylist — losing them re-admits
            // rejected memories. An existing-but-unreadable file must block
            // the sentinel (audit 2026-06-09).
            report.errors.append("tombstones: file exists but unreadable")
            report.requiredFailures += 1
            return
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let key = raw.trimmingCharacters(in: .whitespaces)
            if key.isEmpty || key.hasPrefix("#") { continue }
            do {
                if try await storage.tombstoneExists(key) { continue }
                try await storage.insertTombstone(key)
                report.tombstonesImported += 1
            } catch {
                report.errors.append("tombstone: \(error)")
                report.requiredFailures += 1
            }
        }
    }
}
