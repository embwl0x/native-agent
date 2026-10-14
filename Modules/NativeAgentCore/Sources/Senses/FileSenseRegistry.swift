import CryptoKit
import Foundation
import NativeAgentCore
import OSLog
import PersistenceCore

/// Sense records are a projection of ability files and the bundled defaults.
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
        root = CapabilityLifecycle.Store.senses.directory(in: dataRoot.standardizedFileURL.resolvingSymlinksInPath())
    }

    public var programs: OwnedProgramStore { OwnedProgramStore(root: root) }
    var abilities: AbilityStore { AbilityStore(dataRoot: root.deletingLastPathComponent()) }

    public func candidate(_ input: SenseRecord, codeFiles: [String: Data], scope: String = "") async throws -> OwnedProgramStore.Candidate {
        try await withStore { store in
            guard input.language == .javascript, let entry = input.entry,
                  let bytes = codeFiles[entry], let code = String(data: bytes, encoding: .utf8) else {
                throw Self.failure("Authored senses require a JavaScript entry.")
            }
            var record = input
            let previous = store.senses.first { $0.id == record.id }
            if input.origin == .shared, let previous {
                let current = previous.versions.first { $0.record.version == previous.currentVersion }!.record
                guard current.origin == .shared, current.corner == input.corner else { throw Self.failure("Import would replace a locally owned sense or a different corner.") }
            }
            record.version = try CapabilityLifecycle.nextVersion(previous?.versions.map(\.record.version) ?? [], requested: input.version)
            if previous?.versions.first(where: { $0.record.version == previous?.currentVersion })?.record.origin == .shared {
                record.origin = .shared
            }
            record.candidateDigest = nil
            record.uses = 0; record.corrections = 0; record.lastUsedAt = nil
            let files = codeFiles.keys.sorted()
            try Self.validate(Version(record: record, files: files))
            for (name, bytes) in codeFiles { try Self.validateCode(name, bytes: bytes) }
            guard codeFiles.values.reduce(0, { $0 + $1.count }) <= Self.maximumCodeBytes else { throw Self.failure("Sense source exceeds the size limit.") }
            let candidate = try OwnedProgramStore.Candidate(program: OwnedProgram(kind: .sense, id: record.id,
                version: String(record.version), source: code, entry: .sense, reach: record.reach),
                manifest: .object(["record": try .fromEncodable(record), "scope": .string(scope),
                                   "files": try .fromEncodable(codeFiles.filter { $0.key != entry })]),
                fixtures: .array([]), dependencyShapes: .object([:]), prior: try Self.selection(store, corner: record.corner))
            try self.programs.stage(candidate)
            return (false, candidate)
        }
    }

    public static func record(_ candidate: OwnedProgramStore.Candidate) throws -> SenseRecord {
        guard case .object(let fields) = candidate.manifest, let value = fields["record"], candidate.program.kind == .sense else {
            throw failure("Sense candidate metadata is missing.")
        }
        var record = try JSONDecoder().decode(SenseRecord.self, from: value.serializedData(pretty: false))
        record.candidateDigest = candidate.digest
        return record
    }

    public func keep(_ candidate: OwnedProgramStore.Candidate, key: Data, scope: String) async throws -> (SenseRecord, String) {
        guard case .object(let manifest) = candidate.manifest, manifest["scope"] == .string(scope),
              case .object(let proof) = try programs.proof(candidate, key: key),
              case .array(let receipts)? = proof["receipts"], case .object(let receipt)? = receipts.first,
              let page = receipt["page"] else { throw Self.failure("Try this exact sense in this conversation before keeping it.") }
        let shown = try JSONDecoder().decode(NativePage.self, from: page.serializedData(pretty: false))
        var record = try Self.record(candidate)
        record.verbs = Array(Set(shown.things.flatMap(\.verbs))).sorted()
        record.status = .on; record.enabledAt = Date()
        let published = record
        try await withStore { store in
            _ = try self.programs.proof(candidate, key: key)
            guard try Self.selection(store, corner: published.corner) == candidate.prior else {
                throw Self.failure("The place's sense changed or is switched off. Read it and try again after restoring it.")
            }
            try Self.insert(published, files: self.sourceFiles(published).keys.sorted(), into: &store)
            return (true, ())
        }
        return (record, SenseDoor.render(shown, provenance: SenseProvenance(record: record)))
    }

    static func selection(_ store: Store, corner: SenseCorner) throws -> JSONValue {
        try .fromEncodable(store.senses.filter { $0.versions.contains { $0.record.corner == corner } }.map { entry in
            let record = entry.versions.first { $0.record.version == entry.currentVersion }!.record
            return ["id": JSONValue.string(entry.id), "version": .int(Int64(entry.currentVersion)),
                    "status": .string(record.status.rawValue),
                    "enabled": try JSONValue.fromEncodable(record.enabledAt), "disabledBy": try JSONValue.fromEncodable(record.disabledBy)]
        })
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

    public func upsert(_ record: SenseRecord) async throws {
        let files = record.language == .native ? [:] : try sourceFiles(record)
        _ = try await upsert(record, codeFiles: files)
    }

    /// Preferred growth path: publish code and metadata together, returning the assigned version.
    public func upsert(_ record: SenseRecord, codeFiles: [String: Data]) async throws -> SenseRecord {
        if record.language == .native {
            return try await withStore { store in
                var native = record
                native.version = try CapabilityLifecycle.nextVersion(store.senses.first { $0.id == record.id }?.versions.map(\.record.version) ?? [], requested: record.version)
                native = try Self.insert(native, files: [], into: &store)
                return (true, native)
            }
        }
        let candidate = try await candidate(record, codeFiles: codeFiles)
        let published = try Self.record(candidate)
        try await withStore { store in
            _ = try self.programs.load(id: candidate.program.id, digest: candidate.digest)
            guard try Self.selection(store, corner: published.corner) == candidate.prior else { throw Self.failure("Sense changed before publication.") }
            try Self.insert(published, files: codeFiles.keys.sorted(), into: &store)
            return (true, ())
        }
        return published
    }

    public func versions(id: String) async throws -> [SenseRecord] {
        try await withStore { store in
            let i = try Self.index(id, in: store)
            return (false, store.senses[i].versions.map(\.record).sorted { $0.version > $1.version })
        }
    }

    /// Lifecycle identity excludes all read bookkeeping and captured views.
    public func lifecycleRead(id: String) async throws -> JSONValue {
        try await withStore { store in
            let entry = store.senses[try Self.index(id, in: store)]
            let versions = entry.versions.map(\.record).sorted { $0.version > $1.version }
            let identity = JSONValue.object(["selected": .int(Int64(entry.currentVersion)), "versions": .array(versions.map {
                .object(["version": .int(Int64($0.version)), "digest": $0.candidateDigest.map(JSONValue.string) ?? .null,
                         "status": .string($0.status.rawValue),
                         "disabledBy": $0.disabledBy.map(JSONValue.string) ?? .null])
            })])
            let digest = SHA256.hash(data: try identity.serializedData(pretty: false)).prefix(6)
                .map { String(format: "%02x", $0) }.joined()
            return (false, .object(["status": .string("ok"),
                "current": try .fromEncodable(versions.first { $0.version == entry.currentVersion }!),
                "version": .string("senses/" + id + "@" + digest), "versions": try .fromEncodable(versions)]))
        }
    }

    public func rollback(id: String, version: Int, preview: Bool = false) async throws -> SenseRecord {
        let (restored, withdrawn) = try await withStore { store in
            let i = try Self.index(id, in: store)
            let current = store.senses[i].currentVersion
            let selected = store.senses[i].versions.first { $0.record.version == current }!.record
            guard version != current,
                  let j = store.senses[i].versions.firstIndex(where: { $0.record.version == version }) else {
                throw Self.failure("Choose the previous version from sense.versions.")
            }
            // An on sense keeps reading through the selected retained version;
            // rollback cannot turn an off sense back on.
            store.senses[i].versions[j].record.status = selected.status == .on ? .on : .off
            store.senses[i].versions[j].record = try CapabilityLifecycle.preservingOwnerOff(store.senses[i].versions[j].record, before: selected, preview: preview)
            store.senses[i].currentVersion = version
            if store.senses[i].versions[j].record.language != .native { _ = try self.sourceFiles(store.senses[i].versions[j].record) }
            if !preview { try self.abilities.swap(id: id) }
            return (!preview, (store.senses[i].versions[j].record, current))
        }
        if !preview {
            SenseDoorViews.shared.forget(senseID: id)
            if restored.version != withdrawn { try await SensesHub.shared.markVersionWrong(senseID: id, version: withdrawn) }
        }
        return restored
    }

    public func drop(id: String, version: Int, preview: Bool = false, ownerAuthorized: Bool = false) async throws -> SenseRecord {
        let record = try await withStore(ownerAuthorized: ownerAuthorized) { store in
            let (i, j) = try Self.current(id, in: store)
            guard store.senses[i].currentVersion == version else { throw Self.failure("Sense changed; read its current version before dropping it.") }
            if store.senses[i].versions[j].record.language != .native { _ = try self.sourceFiles(store.senses[i].versions[j].record) }
            let record = store.senses[i].versions[j].record
            let override = try self.abilities.read(id: id, slot: .current)
            guard record.origin != .builtIn || override != nil else {
                throw Self.failure("This sense is bundled with the app. Switch it off to stop using it.")
            }
            if !ownerAuthorized, CapabilityLifecycle.requiresOwnerToEnable(isOff: record.status == .off, disabledBy: record.disabledBy) {
                throw SenseFailure(code: "owners_call", message: "The owner turned \(id) off; they turn it back on. Ask them.")
            }
            store.senses.remove(at: i)
            return (!preview, record)
        }
        if !preview { SenseDoorViews.shared.forget(senseID: id) }
        return record
    }

    public func setStatus(id: String, version: Int, status: SenseStatus, preview: Bool = false,
                          ownerAuthorized: Bool = false) async throws -> SenseRecord {
        let record = try await withStore(ownerAuthorized: ownerAuthorized) { store in
            let (i, j) = try Self.current(id, in: store)
            let current = store.senses[i].versions[j].record
            guard status != .on || store.senses[i].versions[j].record.language != .swift else {
                throw Self.failure("Convert the historical Swift sense to JavaScript before enabling it.")
            }
            guard store.senses[i].currentVersion == version else {
                throw Self.failure("This sense changed. Refresh the page before switching it.")
            }
            if status == .on, store.senses[i].versions[j].record.language != .native {
                var resumed = store.senses[i].versions[j].record
                resumed.status = .on
                _ = try self.sourceFiles(resumed)
            }
            store.senses[i].versions[j].record.status = status
            store.senses[i].versions[j].record.unavailableReason = nil
            if status == .on {
                store.senses[i].versions[j].record.enabledAt = Date()
                Self.displace(corner: store.senses[i].versions[j].record.corner, except: id, in: &store)
            }
            do {
                store.senses[i].versions[j].record = try CapabilityLifecycle.preservingOwnerOff(store.senses[i].versions[j].record,
                    before: current, ownerAuthorized: ownerAuthorized, enabling: status == .on, preview: preview)
            } catch let error as NSError where error.domain == "CapabilityLifecycle" {
                throw SenseFailure(code: "owners_call", message: error.localizedDescription)
            }
            return (!preview, store.senses[i].versions[j].record)
        }
        if !preview, status != .on { SenseDoorViews.shared.forget(senseID: id) }
        return record
    }

    public func markUnavailable(id: String, version: Int, reason: String) async throws {
        let changed = try await withStore { store in
            let (i, j) = try Self.current(id, in: store)
            guard store.senses[i].currentVersion == version,
                  store.senses[i].versions[j].record.status == .on else { return (false, false) }
            var fields = try self.abilities.states()[id]?.objectValue ?? [:]
            fields["unavailableReason"] = .string(reason)
            try self.abilities.saveState(id: id, fields: fields)
            return (false, true)
        }
        if changed { SenseDoorViews.shared.forget(senseID: id) }
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

    func withStore<T: Sendable>(ownerAuthorized: Bool = false, _ body: @escaping @Sendable (inout Store) throws -> (Bool, T)) async throws -> T {
        try Task.checkCancellation()
        return try AbilityStore.withLock {
            var store = try Self.decode(self.abilities.registry(kind: .sense))
            let defaults = try BuiltInSenses.defaults()
            let defaultIDs = Set(defaults.map { $0.record.id.lowercased() })
            for file in try self.abilities.files() where defaultIDs.contains(file.id.lowercased()) && file.kind != .sense {
                throw Self.failure("Ability id collision: \(file.id) is also a bundled sense.")
            }
            let states = try self.abilities.states()
            for version in defaults where !store.senses.contains(where: { $0.id == version.record.id }) {
                var fields = try JSONValue.fromEncodable(version.record).objectValue!
                for (key, value) in states[version.record.id]?.objectValue ?? [:] { fields[key] = value }
                if fields["status"] == .string("on"), case .string = fields["unavailableReason"] ?? .null {
                    fields["status"] = .string("unavailable")
                }
                let record = try JSONDecoder().decode(SenseRecord.self, from: JSONValue.object(fields).serializedData(pretty: false))
                store.senses.append(Entry(id: record.id, currentVersion: record.version, versions: [Version(record: record, files: version.files)]))
            }
            let before = store
            let (changed, result) = try body(&store)
            if changed {
                store = try Self.decode(CapabilityLifecycle.preservingOwnerOff(JSONValue.fromEncodable(store),
                    before: JSONValue.fromEncodable(before), ownerAuthorized: ownerAuthorized))
                var value = try JSONValue.fromEncodable(store).objectValue!
                value["senses"] = .array(try store.senses.map { entry in
                    var fields = try JSONValue.fromEncodable(entry).objectValue!
                    fields["versions"] = .array(try entry.versions.map { version in
                        var fields = try JSONValue.fromEncodable(version).objectValue!
                        if let bundled = defaults.first(where: { $0.record.id == entry.id }),
                           try Self.metadata(version.record) == Self.metadata(bundled.record) {
                            var record = fields["record"]!.objectValue!
                            record["bundledDefault"] = .bool(true); fields["record"] = .object(record)
                        } else if version.record.version == entry.currentVersion,
                                  try self.abilities.read(id: entry.id, slot: .current) == nil,
                                  try self.abilities.read(id: entry.id, slot: .next) == nil,
                                  defaults.contains(where: { $0.record.id == entry.id }) {
                            let body = try version.record.entry.map { try String(contentsOf: BuiltInSenses.resourceRoot().appendingPathComponent($0), encoding: .utf8) } ?? ""
                            try self.abilities.write(AbilityStore.File(id: entry.id, kind: .sense,
                                metadata: ["record": try JSONValue.fromEncodable(version.record)], body: body, pathExtension: "js"))
                        }
                        return .object(fields)
                    })
                    return .object(fields)
                })
                try self.abilities.saveRegistry(.object(value), kind: .sense, ownerAuthorized: ownerAuthorized)
            }
            return result
        }
    }

    static func metadata(_ record: SenseRecord) throws -> JSONValue {
        var fields = try JSONValue.fromEncodable(record).objectValue!
        if record.status == .unavailable, record.disabledBy != "owner" { fields["status"] = .string("on") }
        for key in ["uses", "corrections", "lastUsedAt", "unavailableReason"] { fields.removeValue(forKey: key) }
        return .object(fields)
    }

    @discardableResult
    static func insert(_ input: SenseRecord, files: [String], into store: inout Store) throws -> SenseRecord {
        let previous = store.senses.first { $0.id == input.id }
        let current = previous?.versions.first { $0.record.version == previous?.currentVersion }?.record
        let record = try CapabilityLifecycle.preservingOwnerOff(input, before: current, enabling: input.status == .on)
        guard !store.senses.contains(where: { $0.id != record.id && $0.id.lowercased() == record.id.lowercased() }) else {
            throw failure("Sense id conflicts with an existing folder's spelling.")
        }
        let version = Version(record: record, files: files)
        try validate(version)
        if record.status == .on { displace(corner: record.corner, except: record.id, in: &store) }
        if let i = store.senses.firstIndex(where: { $0.id == record.id }) {
            guard !store.senses[i].versions.contains(where: { $0.record.version == record.version }) else { throw failure("Sense version changed before publication.") }
            store.senses[i].versions.append(version)
            store.senses[i].versions = Array(store.senses[i].versions.suffix(2))
            store.senses[i].currentVersion = record.version
        } else {
            store.senses.append(Entry(id: record.id, currentVersion: record.version, versions: [version]))
        }
        try validate(store)
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
                store.senses[i].versions[j].record.status = .off
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

private extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let fields) = self { fields } else { nil } }
}
