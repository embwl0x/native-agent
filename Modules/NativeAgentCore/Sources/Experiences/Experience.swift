import Foundation
import GRDB
import NativeAgentCore
@_exported import NativeAgentShared
import os
// Blueprint: | `Experience.swift` | `ExperienceStore`, the append-only owner per data root over `experiences/experiences.sqlite`; `begin`, `append`, `experience`, `open`, indexed open/recent `projection` and commit-fed `changes`. Shared `Experience`/`ObligationPhase` live in NativeAgentShared. Recording stays off reply paths; projection drains queued writes and reports persistence gaps; a write the law refuses is logged and never poisons reads. Turn owners record answer lifetimes and recover saved-answer settlements; conversation and shelf owners publish peer obligations and completed run identities |


/// The experience owner for one data root: `experiences/experiences.sqlite`.
/// `experience` holds each birth (its id, kind, time, born form and whether it
/// still owes anything); `event` holds each `Change` appended after, in order,
/// as itself. A birth and each append are one transaction, checked against the
/// law inside it. A read is a primary-key lookup and its events; the open
/// projection is `WHERE open`. E0's records sit beside the real ones and are
/// advisory until a lane makes them authoritative.
public actor ExperienceStore {
    public enum Change: Codable, Sendable, Equatable {
        case cause(String)
        case evidence(Experience.Ref)
        case face(Experience.Face)
        case claim(Experience.Claim)
        /// Recorded once; a different second outcome is refused.
        case outcome(Experience.Outcome)
        case progress(String)
        case obligation(key: String, phase: ObligationPhase, attempt: String? = nil, evidence: Experience.Ref? = nil)
        /// Its owner gives up what is still owed; a settled obligation stays as it settled.
        case letGo(key: String, reason: ObligationPhase.LetGo)
    }

    public enum LawError: Error, LocalizedError {
        case reused(String)
        case unknown(String)
        case secondOutcome(String)
        case unknownObligation(String, String)
        case refusedStep(String, String, ObligationPhase, ObligationPhase)
        case otherAttempt(String, String)
        case unreadable(String, Int64)

        public var errorDescription: String? {
            switch self {
            case .reused(let id): "Experience \(id) was already written with different content; mint a new id."
            case .unknown(let id): "No experience \(id); its owner must write it before anything appends to it."
            case .secondOutcome(let id): "Experience \(id) already has a different outcome; an experience has one."
            case .unknownObligation(let id, let key): "Experience \(id) owes nothing named \(key); obligations are declared by its owner."
            case .refusedStep(let id, let key, let from, let to):
                "Experience \(id)'s \(key) cannot move from \(from.rawValue) to \(to.rawValue)."
            case .otherAttempt(let id, let key): "Experience \(id)'s \(key) belongs to another attempt."
            case .unreadable(let id, let seq): "Experience \(id)'s event \(seq) is not a change this build reads."
            }
        }
    }

    private static let owners = OSAllocatedUnfairLock(initialState: [URL: ExperienceStore]())
    /// Each experience's last queued write: writes to one experience land in the
    /// order its owner asked for them, and never wait on another experience's.
    private static let pending = OSAllocatedUnfairLock(initialState: [String: (token: UUID, task: Task<Void, Never>)]())
    private static let log = ModuleLog(category: "Experiences")

    public static func at(_ dataRoot: URL) -> ExperienceStore {
        let path = dataRoot.appendingPathComponent("experiences/experiences.sqlite").standardizedFileURL
        return owners.withLock { owners in
            if let owner = owners[path] { return owner }
            let owner = ExperienceStore(path: path)
            owners[path] = owner
            return owner
        }
    }

    /// Writes are records beside the real ones: queued per experience `id` in
    /// the order asked, never retried. A write that fails to persist is a gap;
    /// one the law refuses is only logged — the record stayed exact, so no read
    /// is poisoned by it (10-24: one refused late answer froze every contact
    /// read until relaunch). Delivery and failure accounting join their own
    /// writes before retiring the caller's work; recording never throws.
    @discardableResult
    public static func record(_ dataRoot: URL, _ id: String,
                              _ write: @escaping @Sendable (ExperienceStore) async throws -> Void) -> Task<Void, Never> {
        let store = at(dataRoot)
        let key = store.path.path + "#" + id, token = UUID()
        return pending.withLock { tails in
            let previous = tails[key]?.task
            let task = Task.detached {
                await previous?.value
                do { try await write(store) } catch let refused as LawError {
                    log("experience write refused: %@", refused.localizedDescription)
                } catch {
                    log("experience gap: %@", error.localizedDescription)
                    await store.failed(error)
                }
                pending.withLock { if $0[key]?.token == token { $0[key] = nil } }
            }
            tails[key] = (token, task)
            return task
        }
    }

    private let path: URL
    private var opened: DatabasePool?
    private var gap: String?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    public nonisolated static let processID = UUID().uuidString

    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(())
            continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func changed() { for observer in observers.values { observer.yield(()) } }
    private func failed(_ error: Error) {
        guard gap != error.localizedDescription else { return }
        gap = error.localizedDescription
        changed()
    }

    private init(path: URL) {
        self.path = path
    }

    /// Its owner writes it once. False when this exact experience already exists.
    @discardableResult
    public func begin(_ new: Experience) throws -> Bool {
        let inserted = try database().write { db in
            if let born = try String.fetchOne(db, sql: "SELECT born FROM experience WHERE id = ?", arguments: [new.id]) {
                var existing = try Self.decoder.decode(Experience.self, from: Data(born.utf8))
                var proposed = new
                (existing.at, proposed.at) = ("", "")
                guard existing == proposed else { throw LawError.reused(new.id) }
                return false
            }
            var born = new
            born.at = NativeTimestampFormat.fractionalZulu(Date())
            try db.execute(sql: "INSERT INTO experience (id, kind, at, born, open, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [born.id, born.kind.rawValue, born.at, try Self.json(born), born.isOpen, born.at])
            return true
        }
        if inserted { changed() }
        return inserted
    }

    /// Everything after birth is one of these, checked against the law.
    public func append(_ changes: [Change], to id: String) throws {
        let moved = try database().write { db in
            guard var current = try Self.fold(db, id) else { throw LawError.unknown(id) }
            let at = NativeTimestampFormat.fractionalZulu(Date())
            var moved = false
            for change in changes {
                if case .progress(let progress) = change, current.progress == progress {
                    moved = true
                    continue
                }
                guard try Self.apply(change, to: &current) else { continue }
                try db.execute(sql: "INSERT INTO event (experience_id, at, event) VALUES (?, ?, ?)",
                               arguments: [id, at, try Self.json(change)])
                moved = true
            }
            if moved {
                try db.execute(sql: "UPDATE experience SET open = ?, updated_at = ? WHERE id = ?", arguments: [current.isOpen, at, id])
            }
            return moved
        }
        if moved { changed() }
    }

    /// Read by id.
    public func experience(_ id: String) throws -> Experience? {
        try database().read { try Self.fold($0, id) }
    }

    /// The experiences that still owe something, oldest first.
    public func open() throws -> [Experience] {
        try database().read { db in
            try String.fetchAll(db, sql: "SELECT id FROM experience WHERE open ORDER BY at").compactMap { try Self.fold(db, $0) }
        }
    }

    /// Every write queued for this store so far has landed or been logged as a
    /// gap: an id an owner just handed out reads as its owner wrote it.
    public func drained() async {
        let queued = Self.pending.withLock { tails in tails.filter { $0.key.hasPrefix(path.path + "#") }.map(\.value.task) }
        for write in queued { await write.value }
    }

    /// A reader crosses every write queued for this store before publishing. Gaps
    /// invalidate the projection, never the reply that produced the record.
    public func projection() async throws -> [Experience] {
        await drained()
        if let gap { throw NSError(domain: "Experiences", code: 1, userInfo: [NSLocalizedDescriptionKey: gap]) }
        return try await database().read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT id FROM experience WHERE open
                UNION SELECT id FROM (
                    SELECT id FROM experience ORDER BY updated_at DESC LIMIT 64
                )
                """)
            return try ids.compactMap { try Self.fold(db, $0) }
                .sorted { ($0.updatedAt ?? $0.at) > ($1.updatedAt ?? $1.at) }
        }
    }

    /// Replays through the same law that admitted each change; a row it cannot read is reported.
    private static func fold(_ db: Database, _ id: String) throws -> Experience? {
        guard let record = try Row.fetchOne(db, sql: "SELECT born, updated_at FROM experience WHERE id = ?", arguments: [id]) else { return nil }
        var experience = try decoder.decode(Experience.self, from: Data((record["born"] as String).utf8))
        for row in try Row.fetchAll(db, sql: "SELECT seq, at, event FROM event WHERE experience_id = ? ORDER BY seq", arguments: [id]) {
            guard let change = try? decoder.decode(Change.self, from: Data((row["event"] as String).utf8)) else {
                throw LawError.unreadable(id, row["seq"])
            }
            _ = try apply(change, to: &experience)
        }
        experience.updatedAt = record["updated_at"]
        return experience
    }

    /// The law, in one place: applies a change and says whether it moved
    /// anything, or refuses what the law forbids.
    private static func apply(_ change: Change, to experience: inout Experience) throws -> Bool {
        let id = experience.id
        switch change {
        case .cause(let cause):
            guard !experience.cause.contains(cause) else { return false }
            experience.cause.append(cause)
        case .face(let face):
            guard experience.face != face else { return false }
            experience.face = face
        case .evidence(let ref):
            guard !experience.evidence.contains(ref) else { return false }
            experience.evidence.append(ref)
        case .claim(let claim):
            guard !experience.claims.contains(claim) else { return false }
            experience.claims.append(claim)
        case .outcome(let outcome):
            guard experience.outcome != outcome else { return false }
            guard experience.outcome == nil else { throw LawError.secondOutcome(id) }
            experience.outcome = outcome
        case .progress(let progress):
            experience.progress = progress
        case .obligation(let key, let phase, let attempt, let evidence):
            guard var obligation = experience.owes[key] else { throw LawError.unknownObligation(id, key) }
            switch obligation.phase.step(to: phase) {
            case .already: return false
            case .refused: throw LawError.refusedStep(id, key, obligation.phase, phase)
            case .allowed: break
            }
            guard phase == .reserved || obligation.attempt == attempt else { throw LawError.otherAttempt(id, key) }
            (obligation.phase, obligation.attempt, obligation.evidence) = (phase, attempt, evidence)
            experience.owes[key] = obligation
        case .letGo(let key, let reason):
            guard var obligation = experience.owes[key] else { throw LawError.unknownObligation(id, key) }
            guard !obligation.phase.isSettled else { return false }
            (obligation.phase, obligation.reason) = (.letGo, reason)
            experience.owes[key] = obligation
        }
        return true
    }

    /// Opened on first use, the way MemoryV2 opens its store (WAL, a bounded
    /// journal), in an owner-only folder so its sidecars are private from the first byte.
    private func database() throws -> DatabasePool {
        if let opened { return opened }
        let folder = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: folder.path)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(2)
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA journal_size_limit = 4194304") }
        let pool = try DatabasePool(path: path.path, configuration: config)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE experience (id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, at TEXT NOT NULL,
                                         born TEXT NOT NULL, open INTEGER NOT NULL);
                CREATE INDEX experience_open ON experience(at) WHERE open;
                CREATE TABLE event (seq INTEGER PRIMARY KEY AUTOINCREMENT,
                                    experience_id TEXT NOT NULL REFERENCES experience(id),
                                    at TEXT NOT NULL, event TEXT NOT NULL);
                CREATE INDEX event_experience ON event(experience_id, seq);
                """)
        }
        migrator.registerMigration("projection") { db in
            try db.execute(sql: """
                ALTER TABLE experience ADD COLUMN updated_at TEXT NOT NULL DEFAULT '';
                UPDATE experience SET updated_at = COALESCE(
                    (SELECT MAX(at) FROM event WHERE experience_id = experience.id), at);
                CREATE INDEX experience_recent ON experience(updated_at DESC);
                """)
        }
        try migrator.migrate(pool)
        opened = pool
        return pool
    }

    private static let decoder = JSONDecoder()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
