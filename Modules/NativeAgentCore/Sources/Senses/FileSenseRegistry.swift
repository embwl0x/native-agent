import CryptoKit
import Foundation
import NativeAgentCore
import OSLog
import PersistenceCore

/// Registry mutations and code publication share one cross-process sidecar lock.
/// A corrupt existing store is never replaced with an empty one.
public final class FileSenseRegistry: SenseRegistryManaging, Sendable {
    public let root: URL
    private static let logger = Logger(subsystem: "NativeAgent", category: "SenseRegistry")

    struct Version: Codable, Sendable {
        var record: SenseRecord
        var files: [String]
    }

    struct Entry: Codable, Sendable {
        var id: String
        var currentVersion: Int
        var versions: [Version]
    }

    struct Store: Codable, Sendable {
        var format = 1
        var senses: [Entry] = []
    }

    public init(dataRoot: URL) {
        root = dataRoot.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("senses", isDirectory: true)
    }

    /// A tried page and its exact program, scoped to the conversation that made it.
    public struct Trial: Codable, Sendable {
        public let id: String
        public let scope: String
        public let record: SenseRecord
        public let code: String
        public let page: String

        public init(id: String, scope: String, record: SenseRecord, code: String, page: String) {
            self.id = id; self.scope = scope; self.record = record; self.code = code; self.page = page
        }

        public var digest: String {
            get throws { SHA256.hash(data: try FileSenseRegistry.encode(self)).map { String(format: "%02x", $0) }.joined() }
        }
    }

    public func retainTrial(_ trial: Trial) async throws -> String {
        try await withStore { _ in
            try Self.validateID(trial.id)
            try Self.validateCode("sense.js", bytes: Data(trial.code.utf8))
            let bytes = try Self.encode(trial)
            guard bytes.count <= Self.maximumBundleBytes else {
                throw Self.failure("This trial is too large to retain. Call sense.make with the code and keep:true after reviewing its page.")
            }
            let directory = try Self.safeURL(".trials", under: self.root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = try Self.safeURL(".trials/\(trial.id).json", under: self.root)
            guard !FileManager.default.fileExists(atPath: path.path) else { throw Self.failure("Trial id already exists. Run a fresh sense.make trial.") }
            try bytes.write(to: path, options: .atomic)
            // No background owner: bound drafts when another draft is retained.
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "json" && $0 != path }
                .map { url -> (URL, Date) in
                    let safe = try Self.safeURL(".trials/" + url.lastPathComponent, under: self.root)
                    guard let date = try safe.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                        throw Self.failure("A retained trial has no storage timestamp. Repair its draft storage before running a fresh sense.make trial.")
                    }
                    return (safe, date)
                }.sorted { $0.1 > $1.1 }
            for (index, file) in files.enumerated() where index >= 15 || Date().timeIntervalSince(file.1) > 86_400 {
                try FileManager.default.removeItem(at: file.0)
            }
            return (false, try trial.digest)
        }
    }

    public func retainedTrial(id: String, digest: String, scope: String) async throws -> Trial {
        try await withStore { _ in
            try Self.validateID(id)
            let path = try Self.safeURL(".trials/\(id).json", under: self.root)
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw Self.failure("That trial is unavailable. Read the place and run a fresh sense.make trial; nothing was kept.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.intValue, size <= Self.maximumBundleBytes else {
                throw Self.failure("That trial's stored candidate is invalid. Run a fresh sense.make trial; nothing was kept.")
            }
            let trial = try JSONDecoder().decode(Trial.self, from: Data(contentsOf: path))
            guard trial.id == id, trial.scope == scope, try trial.digest == digest,
                  Date().timeIntervalSince(trial.record.createdAt) <= 86_400 else {
                throw Self.failure("That trial changed, expired, or belongs to another conversation. Run a fresh sense.make trial here; nothing was kept.")
            }
            try Self.validateCode("sense.js", bytes: Data(trial.code.utf8))
            return (false, trial)
        }
    }

    public func removeTrial(id: String) async throws {
        try await withStore { _ in
            try Self.validateID(id)
            try FileManager.default.removeItem(at: Self.safeURL(".trials/\(id).json", under: self.root))
            return (false, ())
        }
    }

    public func sense(for corner: SenseCorner) async throws -> SenseRecord? {
        try await allChecked().first { $0.corner.key == corner.key && $0.status == .on }
    }

    public func all() async throws -> [SenseRecord] { try await allChecked() }

    public func allChecked() async throws -> [SenseRecord] {
        try await withStore { store in
            (false, store.senses.map { entry in
                entry.versions.first { $0.record.version == entry.currentVersion }!.record
            }.sorted { $0.id < $1.id })
        }
    }

    /// Compatibility with growers that already wrote the requested version folder.
    /// Only source files are collected; notebooks and other material are excluded.
    public func upsert(_ record: SenseRecord) async throws {
        _ = try await withStore { store in
            try Self.validateID(record.id)
            let source = try Self.safeURL("\(record.id)/v\(record.version)", under: self.root)
            let files = record.language == .native ? [:] : try Self.readSourceFiles(at: source)
            return (true, try self.insert(record, files: files, into: &store, stagedVersion: record.version))
        }
    }

    /// Preferred growth path: publish code and metadata together, returning the assigned version.
    public func upsert(_ record: SenseRecord, codeFiles: [String: Data]) async throws -> SenseRecord {
        try await withStore { store in
            (true, try self.insert(record, files: codeFiles, into: &store))
        }
    }

    /// Publication and the off-switch share the registry lock. A grower must
    /// never turn an archived corner back on after its provider await.
    public func publishIfNotArchived(_ record: SenseRecord, codeFiles: [String: Data]) async throws -> SenseRecord? {
        try await withStore { store in
            let current = store.senses.map { entry in
                entry.versions.first { $0.record.version == entry.currentVersion }!.record
            }
            let switchedOff = current.contains { $0.id == record.id && $0.status == .archived }
                || (!current.contains { $0.corner.key == record.corner.key && $0.status == .on }
                    && current.contains { $0.corner.key == record.corner.key && $0.status == .archived })
            guard !switchedOff else { return (false, nil) }
            return (true, try self.insert(record, files: codeFiles, into: &store, stagedVersion: record.version))
        }
    }

    public func versions(id: String) async throws -> [SenseRecord] {
        try await withStore { store in
            let i = try Self.index(id, in: store)
            return (false, store.senses[i].versions.map(\.record).sorted { $0.version > $1.version })
        }
    }

    public func rollback(id: String) async throws -> SenseRecord {
        let (restored, withdrawn) = try await withStore { store in
            let i = try Self.index(id, in: store)
            let current = store.senses[i].currentVersion
            guard let previous = store.senses[i].versions.filter({ $0.record.version < current })
                .max(by: { $0.record.version < $1.record.version }) else {
                throw Self.failure("No previous version exists for this sense.")
            }
            // CapabilityLifecycle returns a rollback drafted, so old verbs do not
            // silently regain authority. Enabling it is an explicit next step.
            let j = store.senses[i].versions.firstIndex { $0.record.version == previous.record.version }!
            store.senses[i].versions[j].record.status = .draft
            store.senses[i].currentVersion = previous.record.version
            return (true, (store.senses[i].versions[j].record, current))
        }
        SenseDoorViews.shared.forget(senseID: id)
        try await SensesHub.shared.markVersionWrong(senseID: id, version: withdrawn)
        return restored
    }

    public func setStatus(id: String, version: Int, status: SenseStatus) async throws -> SenseRecord {
        let record = try await withStore { store in
            let (i, j) = try Self.current(id, in: store)
            guard store.senses[i].currentVersion == version,
                  store.senses[i].versions[j].record.status != .draft else {
                throw Self.failure("This sense changed. Refresh the page before switching it.")
            }
            store.senses[i].versions[j].record.status = status
            store.senses[i].versions[j].record.unavailableReason = nil
            if status == .on {
                store.senses[i].versions[j].record.enabledAt = Date()
                Self.displace(corner: store.senses[i].versions[j].record.corner, except: id, in: &store)
            }
            return (true, store.senses[i].versions[j].record)
        }
        if status != .on { SenseDoorViews.shared.forget(senseID: id) }
        return record
    }

    public func markUnavailable(id: String, version: Int, reason: String) async throws {
        let changed = try await withStore { store in
            let (i, j) = try Self.current(id, in: store)
            guard store.senses[i].currentVersion == version,
                  store.senses[i].versions[j].record.status == .on else { return (false, false) }
            store.senses[i].versions[j].record.status = .unavailable
            store.senses[i].versions[j].record.unavailableReason = reason
            return (true, true)
        }
        if changed { SenseDoorViews.shared.forget(senseID: id) }
    }

    public func archiveUnused(now: Date = Date()) async throws -> [SenseRecord] {
        let records = try await withStore { store in
            let formatter = ISO8601DateFormatter()
            var archived: [SenseRecord] = []
            for i in store.senses.indices {
                let j = store.senses[i].versions.firstIndex { $0.record.version == store.senses[i].currentVersion }!
                let record = store.senses[i].versions[j].record
                guard record.status == .on, record.origin != .builtIn,
                      CapabilityLifecycle.isUnused(used: formatter.string(from: record.lastUsedAt ?? record.createdAt),
                          enabled: [record.enabledAt.map { formatter.string(from: $0) }], now: now) else { continue }
                store.senses[i].versions[j].record.status = .archived
                archived.append(store.senses[i].versions[j].record)
            }
            return (!archived.isEmpty, archived)
        }
        for record in records { SenseDoorViews.shared.forget(senseID: record.id) }
        return records
    }

    public func recordUse(senseID: String) async {
        do {
            try await withStore { store in
                let (i, j) = try Self.current(senseID, in: store)
                guard store.senses[i].versions[j].record.uses < Int.max else { throw Self.failure("Sense use counter overflow.") }
                // Without a version this can't prove which version ran, so it
                // never unlocks a shared sense's verbs: only the version-aware
                // overload counts that first local run.
                let record = store.senses[i].versions[j].record
                if !(record.origin == .shared && record.uses == 0) { store.senses[i].versions[j].record.uses += 1 }
                store.senses[i].versions[j].record.lastUsedAt = Date()
                return (true, ())
            }
        } catch { Self.report(error) }
    }

    /// Stamp the version that actually ran, even if an upgrade arrived in flight.
    public func recordUse(senseID: String, version: Int) async throws {
        try await withStore { store in
            let i = try Self.index(senseID, in: store)
            guard let j = store.senses[i].versions.firstIndex(where: { $0.record.version == version }) else {
                throw Self.failure("Sense version not found.")
            }
            guard store.senses[i].versions[j].record.uses < Int.max else { throw Self.failure("Sense use counter overflow.") }
            store.senses[i].versions[j].record.uses += 1
            store.senses[i].versions[j].record.lastUsedAt = Date()
            return (true, ())
        }
    }

    func withStore<T: Sendable>(_ body: @escaping @Sendable (inout Store) throws -> (Bool, T)) async throws -> T {
        try Task.checkCancellation()
        _ = try Self.safeURL("registry.json", under: root)
        _ = try Self.safeURL("registry.json.lock", under: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("registry.json")
        return try await SwiftNativePersistenceCore().withFileLock(path) {
            _ = try Self.safeURL("registry.json", under: self.root)
            var store = Store()
            if FileManager.default.fileExists(atPath: path.path) {
                do {
                    store = try JSONDecoder().decode(Store.self, from: Data(contentsOf: path))
                    try Self.validate(store)
                } catch {
                    throw Self.failure("Senses registry unavailable at \(path.path): \(error.localizedDescription) The saved bytes were preserved. Repair or restore registry.json before using senses.")
                }
            }
            let (changed, result) = try body(&store)
            if changed {
                try Self.validate(store)
                try Self.encode(store).write(to: path, options: .atomic)
            }
            return result
        }
    }

    func insert(_ input: SenseRecord, files: [String: Data], into store: inout Store, stagedVersion: Int? = nil) throws -> SenseRecord {
        try Self.validateID(input.id)
        guard !store.senses.contains(where: { $0.id != input.id && $0.id.lowercased() == input.id.lowercased() }) else {
            throw Self.failure("Sense id conflicts with an existing folder's spelling.")
        }
        var record = input
        record.corner = SenseCorner(key: input.corner.key) ?? input.corner
        if let i = store.senses.firstIndex(where: { $0.id == record.id }) {
            guard store.senses[i].versions.map(\.record.version).max()! < Int.max else { throw Self.failure("Sense version overflow.") }
            record.version = max(store.senses[i].versions.map(\.record.version).max()! + 1, stagedVersion ?? 1)
            // Origin cannot be laundered by an upgrade of imported code.
            let j = store.senses[i].versions.firstIndex { $0.record.version == store.senses[i].currentVersion }!
            if store.senses[i].versions[j].record.origin == .shared { record.origin = .shared }
        } else { record.version = max(1, stagedVersion ?? 1) }
        record.uses = 0
        record.corrections = 0
        record.lastUsedAt = nil
        if record.status == .on { record.enabledAt = Date() }
        let version = Version(record: record, files: files.keys.sorted())
        try Self.validate(version)
        for (name, bytes) in files {
            try Self.validateCode(name, bytes: bytes)
        }
        guard files.values.reduce(0, { $0 + $1.count }) <= Self.maximumCodeBytes else {
            throw Self.failure("Sense source exceeds the size limit.")
        }
        let destination = try Self.safeURL("\(record.id)/v\(record.version)", under: root)
        if FileManager.default.fileExists(atPath: destination.path) {
            // A grower may have staged this exact version already. Never replace
            // existing code, including code left by an interrupted publication.
            guard try Self.readSourceFiles(at: destination) == files else {
                throw Self.failure("The next sense version folder already contains different code.")
            }
        } else {
            let parent = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let stage = parent.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            do {
                for (name, bytes) in files {
                    try Task.checkCancellation()
                    let path = stage.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: path, options: .atomic)
                }
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: stage, to: destination)
            } catch {
                do { try FileManager.default.removeItem(at: stage) }
                catch { Self.report(error) }
                throw error
            }
        }
        if record.status == .on { Self.displace(corner: record.corner, except: record.id, in: &store) }
        if let i = store.senses.firstIndex(where: { $0.id == record.id }) {
            store.senses[i].versions.append(version)
            store.senses[i].currentVersion = record.version
        } else {
            store.senses.append(Entry(id: record.id, currentVersion: record.version, versions: [version]))
        }
        return record
    }

    static func current(_ id: String, in store: Store) throws -> (Int, Int) {
        let i = try index(id, in: store)
        return (i, store.senses[i].versions.firstIndex { $0.record.version == store.senses[i].currentVersion }!)
    }

    static func index(_ id: String, in store: Store) throws -> Int {
        guard let i = store.senses.firstIndex(where: { $0.id == id }) else { throw failure("Sense not found: \(id).") }
        return i
    }

    static func displace(corner: SenseCorner, except id: String, in store: inout Store) {
        for i in store.senses.indices where store.senses[i].id != id {
            let j = store.senses[i].versions.firstIndex { $0.record.version == store.senses[i].currentVersion }!
            if store.senses[i].versions[j].record.corner.key == corner.key && store.senses[i].versions[j].record.status == .on {
                store.senses[i].versions[j].record.status = .draft
            }
        }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    static func failure(_ message: String) -> SenseFailure { SenseFailure(code: "registry_failure", message: message) }

    static func report(_ error: Error) {
        logger.error("Sense registry operation failed: \(String(describing: error), privacy: .private)")
    }
}
