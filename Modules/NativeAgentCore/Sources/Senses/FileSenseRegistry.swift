import AuthoredCapabilities
import CryptoKit
import Foundation
import NativeAgentCore
import OSLog
import PersistenceCore
// Blueprint: | `FileSenseRegistry.swift` | AbilityStore projections and publication; locked helper lifetimes exclude read bookkeeping |

/// Project records from ability files and bundle defaults to keep a single lifecycle owner.
public final class FileSenseRegistry: Sendable {
    public let root: URL
    private static let logger = Logger(subsystem: "NativeAgent", category: "SenseRegistry")
    private struct HelperSelection {
        let metadata: JSONValue
        let identity = UUID().uuidString
    }
    // Access only under AbilityStore.withLock; reselecting the same version begins a new lifetime.
    nonisolated(unsafe) private static var helperSelections: [String: [String: HelperSelection]] = [:]

    struct Version: Sendable {
        var record: SenseRecord
        /// Nil means source could not be checked, never an empty manifest.
        var files: [String]?
        var sourceFailure: String? = nil

        var presentationRecord: SenseRecord {
            var shown = record
            if let sourceFailure {
                if shown.status == .on { shown.status = .unavailable }
                shown.unavailableReason = sourceFailure
            }
            return shown
        }
    }

    struct Entry: Sendable {
        var id: String
        var current: Version
        var previous: Version?
        var versions: [Version] { [previous, current].compactMap { $0 } }

        var presentationRecord: SenseRecord {
            var shown = current.presentationRecord
            if let failure = previous?.sourceFailure {
                // A broken retained version must remain visible without disabling the selected one.
                shown.unavailableReason = [shown.unavailableReason, failure].compactMap { $0 }.joined(separator: "\n")
            }
            return shown
        }
    }

    struct Store: Sendable {
        var senses: [Entry] = []
    }

    public init(dataRoot: URL) {
        root = CapabilityLifecycle.Store.senses.directory(in: dataRoot.standardizedFileURL.resolvingSymlinksInPath())
    }

    public var programs: OwnedProgramStore { OwnedProgramStore(root: root) }
    var abilities: AbilityStore { AbilityStore(dataRoot: root.deletingLastPathComponent()) }

    public func candidate(
        _ input: SenseRecord,
        codeFiles: [String: Data],
        scope: String = "",
        header: [String: JSONValue] = [:], turn: Turn?
    ) async throws -> OwnedProgramStore.Candidate {
        let part = try AbilityStore.partHeader(header.merging(["reach": try .fromEncodable(input.reach)]) { first, _ in first })
        return try await withStore { store in
            guard input.language == .javascript, let entry = input.entry,
                  let bytes = codeFiles[entry], let code = String(data: bytes, encoding: .utf8) else {
                throw Self.failure("Authored senses require a JavaScript entry.")
            }
            var record = input
            record.reach = try JSONDecoder().decode(SenseReach.self, from: part["reach"]!.serializedData(pretty: false))
            let previous = store.senses.first { $0.id == record.id }
            if input.origin == .shared, let previous {
                let current = previous.current.record
                guard current.origin == .shared, current.corner == input.corner else {
                    throw Self.failure("Import would replace a locally owned sense or a different corner.")
                }
            }
            record.version = try CapabilityLifecycle.nextVersion(previous?.versions.map(\.record.version) ?? [], requested: input.version)
            if previous?.current.record.origin == .shared {
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
                                   "files": try .fromEncodable(codeFiles.filter { $0.key != entry })].merging(part) { _, value in value }),
                fixtures: .array([]), dependencyShapes: .object([:]), prior: try Self.selection(store, corner: record.corner))
            try self.programs.stage(candidate, turn: turn)
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

    public func keep(_ candidate: OwnedProgramStore.Candidate, key: Data, scope: String, turn: Turn?) async throws -> (SenseRecord, String) {
        guard case .object(let manifest) = candidate.manifest, manifest["scope"] == .string(scope),
              case .object(let proof) = try programs.proof(candidate, key: key),
              case .array(let receipts)? = proof["receipts"], case .object(let receipt)? = receipts.first,
              let page = receipt["page"] else { throw Self.failure("Try this exact sense in this conversation before keeping it.") }
        let shown = try JSONDecoder().decode(NativePage.self, from: page.serializedData(pretty: false))
        var record = try Self.record(candidate)
        record.verbs = Array(Set(shown.things.flatMap(\.verbs))).sorted()
        record.status = .on; record.enabledAt = Date()
        let published = record
        try await withStore(enabling: true, turn: turn) { store in
            _ = try self.programs.proof(candidate, key: key)
            guard try Self.selection(store, corner: published.corner) == candidate.prior else {
                throw Self.failure("The place's sense changed or is switched off. Read it and try again after restoring it.")
            }
            try Self.insert(published, files: self.sourceFiles(published).keys.sorted(), into: &store, turn: turn)
            return (true, ())
        }
        return (record, SenseDoor.render(shown, provenance: SenseProvenance(record: record)))
    }

    static func selection(_ store: Store, corner: SenseCorner) throws -> JSONValue {
        try .fromEncodable(store.senses.filter { $0.versions.contains { $0.record.corner == corner } }.map { entry in
            let record = entry.current.record
            return ["id": JSONValue.string(entry.id), "version": .int(Int64(entry.current.record.version)),
                    "status": .string(record.status.rawValue),
                    "enabled": try JSONValue.fromEncodable(record.enabledAt), "disabledBy": try JSONValue.fromEncodable(record.disabledBy)]
        })
    }

    public func sense(for corner: SenseCorner) async throws -> SenseRecord? {
        try await allChecked().first { $0.corner.key == corner.key && $0.status == .on }
    }

    public func all() async throws -> [SenseRecord] { try await allChecked() }

    /// Surface reads must not reconcile helper lifetimes.
    public func presentationRecords() throws -> [SenseRecord] {
        try AbilityStore.withLock {
            try readStore(defaults: BuiltInSenses.defaults()).senses.map { entry in
                entry.presentationRecord
            }
        }
    }

    public func allChecked() async throws -> [SenseRecord] {
        try await withStore { store in
            (false, store.senses.map { entry in
                entry.presentationRecord
            }.sorted { $0.id < $1.id })
        }
    }

    public func upsert(_ record: SenseRecord, turn: Turn?) async throws {
        let files = record.language == .native ? [:] : try sourceFiles(record)
        _ = try await upsert(record, codeFiles: files, turn: turn)
    }

    public func upsert(_ record: SenseRecord, codeFiles: [String: Data], turn: Turn?) async throws -> SenseRecord {
        if record.language == .native {
            return try await withStore(turn: turn) { store in
                var native = record
                native.version = try CapabilityLifecycle.nextVersion(
                    store.senses.first { $0.id == record.id }?.versions.map(\.record.version) ?? [],
                    requested: record.version
                )
                native = try Self.insert(native, files: [], into: &store, turn: turn)
                return (true, native)
            }
        }
        let candidate = try await candidate(record, codeFiles: codeFiles, turn: turn)
        let published = try Self.record(candidate)
        try await withStore(turn: turn) { store in
            _ = try self.programs.load(id: candidate.program.id, digest: candidate.digest)
            guard try Self.selection(store, corner: published.corner) == candidate.prior else { throw Self.failure("Sense changed before publication.") }
            try Self.insert(published, files: codeFiles.keys.sorted(), into: &store, turn: turn)
            return (true, ())
        }
        return published
    }

    public func versions(id: String) async throws -> [SenseRecord] {
        try await withStore { store in
            let i = try Self.index(id, in: store)
            return (false, store.senses[i].versions.map(\.presentationRecord).sorted { $0.version > $1.version })
        }
    }

    /// Exclude read bookkeeping and captured views so reads cannot change helper lifetimes.
    public func lifecycleRead(id: String) async throws -> JSONValue {
        try await withStore { store in
            let entry = store.senses[try Self.index(id, in: store)]
            let versions = entry.versions.map(\.presentationRecord).sorted { $0.version > $1.version }
            let identity = JSONValue.object(["selected": .int(Int64(entry.current.record.version)), "versions": .array(versions.map {
                .object(["version": .int(Int64($0.version)), "digest": $0.candidateDigest.map(JSONValue.string) ?? .null,
                         "status": .string($0.status.rawValue),
                         "disabledBy": $0.disabledBy.map(JSONValue.string) ?? .null])
            })])
            let digest = SHA256.hash(data: try identity.serializedData(pretty: false)).prefix(6)
                .map { String(format: "%02x", $0) }.joined()
            func shown(_ record: SenseRecord) throws -> JSONValue {
                var row = try JSONValue.fromEncodable(record).objectValue ?? [:]
                row["corner_name"] = .string(record.corner.surfaceName)
                return .object(row)
            }
            return (false, .object(["status": .string("ok"),
                "current": try shown(entry.presentationRecord),
                "version": .string("senses/" + id + "@" + digest), "versions": .array(try versions.map(shown))]))
        }
    }

    public func drop(id: String, version: Int, preview: Bool = false, ownerAuthorized: Bool = false, turn: Turn?) async throws -> SenseRecord {
        let record = try await withStore(ownerAuthorized: ownerAuthorized, turn: turn) { store in
            let i = try Self.index(id, in: store)
            guard store.senses[i].current.record.version == version else { throw Self.failure("Sense changed; read its current version before dropping it.") }
            if store.senses[i].current.record.language != .native { _ = try self.sourceFiles(store.senses[i].current.record) }
            let record = store.senses[i].current.record
            let override = try self.abilities.read(id: id, slot: .current)
            guard record.origin != .builtIn || override != nil else {
                throw Self.failure("This sense is bundled with the app. Switch it off to stop using it.")
            }
            if !ownerAuthorized, CapabilityLifecycle.requiresOwnerToEnable(isOff: record.status == .off, disabledBy: record.disabledBy) {
                throw SenseFailure(code: "owners_call", message: "The owner switched \(id) off, so dropping it is theirs: ask them. Nothing changed.")
            }
            store.senses.remove(at: i)
            return (!preview, record)
        }
        if !preview { SenseDoorViews.shared.forget(senseID: id) }
        return record
    }

    public func setStatus(id: String, version: Int, status: SenseStatus, preview: Bool = false,
                          ownerAuthorized: Bool = false, turn: Turn?) async throws -> SenseRecord {
        let record = try await withStore(ownerAuthorized: ownerAuthorized, enabling: status == .on, turn: turn) { store in
            let i = try Self.index(id, in: store)
            let current = store.senses[i].current.record
            guard store.senses[i].current.record.version == version else {
                throw Self.failure("This sense changed. Refresh the page before switching it.")
            }
            if status == .on, store.senses[i].current.record.language != .native {
                var resumed = store.senses[i].current.record
                resumed.status = .on
                _ = try self.sourceFiles(resumed)
            }
            store.senses[i].current.record.status = status
            // An owner's off-switch belongs to the owner; the agent's off-switch belongs to the agent.
            store.senses[i].current.record.disabledBy = status == .off ? (ownerAuthorized ? "owner" : "hers") : nil
            store.senses[i].current.record.unavailableReason = nil
            if status == .on {
                store.senses[i].current.record.enabledAt = Date()
                Self.displace(corner: store.senses[i].current.record.corner, except: id, in: &store)
            }
            do {
                store.senses[i].current.record = try CapabilityLifecycle.preservingOwnerOff(store.senses[i].current.record,
                    before: current, ownerAuthorized: ownerAuthorized, enabling: status == .on, preview: preview, turn: turn)
            } catch let error as NSError where error.domain == "CapabilityLifecycle" {
                throw SenseFailure(code: "owners_call", message: error.localizedDescription)
            }
            return (!preview, store.senses[i].current.record)
        }
        if !preview, status != .on { SenseDoorViews.shared.forget(senseID: id) }
        return record
    }

    public func markUnavailable(id: String, selection: String, reason: String) async throws -> Bool {
        let changed = try await withStore { store in
            // Reconcile under the publication lock so reports from replaced selections cannot mark their successors unavailable.
            if try self.selectHelpers(in: store)[id]?.identity != selection { return (false, false) }
            var fields = try self.abilities.states()[id]?.objectValue ?? [:]
            fields["unavailableReason"] = .string(reason)
            try self.abilities.saveState(id: id, fields: fields)
            return (false, true)
        }
        if changed { SenseDoorViews.shared.forget(senseID: id) }
        return changed
    }

    /// Record the read against the retained version that actually ran.
    public func recordUse(senseID: String, version: Int, turn: Turn?) async throws {
        try await withStore(turn: turn) { store in
            let i = try Self.index(senseID, in: store)
            guard let record = store.senses[i].versions.first(where: { $0.record.version == version })?.record else {
                throw Self.failure("Sense version not found.")
            }
            let current = store.senses[i].current.record
            try self.abilities.recordRun(id: senseID, version: record.candidateDigest ?? String(version),
                receipt: .object(["status": .string("ok"), "read": .bool(true)]), nativeSense: JSONValue.fromEncodable(current), turn: turn)
            return (false, ())
        }
    }

    func withStore<T: Sendable>(
        ownerAuthorized: Bool = false,
        enabling: Bool = false,
        turn: Turn? = nil,
        _ body: @escaping @Sendable (inout Store) throws -> (Bool, T)
    ) async throws -> T {
        try Task.checkCancellation()
        let (result, retired) = try AbilityStore.withLock {
            let defaults = try BuiltInSenses.defaults()
            var store = try self.readStore(defaults: defaults)
            let before = store
            let previousSelections = Self.helperSelections[self.root.path] ?? [:]
            let (changed, result) = try body(&store)
            if changed {
                try Self.validate(store)
                let checked = try CapabilityLifecycle.preservingOwnerOff(
                    .array(try store.senses.map { entry in try .fromEncodable(entry.current.record) }),
                    before: .array(try before.senses.map { entry in try .fromEncodable(entry.current.record) }),
                    ownerAuthorized: ownerAuthorized, senseRecords: true, turn: turn)
                let rows: [JSONValue] = try checked.arrayValue!.map { value in
                    let record = try JSONDecoder().decode(SenseRecord.self, from: value.serializedData(pretty: false))
                    var fields = value.objectValue!
                    if let bundled = defaults.first(where: { $0.record.id == record.id }),
                       try Self.metadata(record) == Self.metadata(bundled.record) {
                        fields["bundledDefault"] = .bool(true)
                    } else if try self.abilities.read(id: record.id, slot: .current) == nil,
                              try self.abilities.read(id: record.id, slot: .next) == nil,
                              defaults.contains(where: { $0.record.id == record.id }) {
                        fields["body"] = .string(try record.entry.map {
                            try String(contentsOf: BuiltInSenses.resourceRoot().appendingPathComponent($0), encoding: .utf8)
                        } ?? "")
                    }
                    return .object(fields)
                }
                try self.abilities.saveRegistry(.array(rows), kind: .sense, ownerAuthorized: ownerAuthorized, enabling: enabling, turn: turn)
            }
            // Read committed state: previews cannot publish, availability changes only state, and removing an override exposes its default.
            let selected = try self.selectHelpers(in: self.readStore(defaults: defaults))
            let retired = previousSelections.compactMap { id, previous in
                selected[id]?.identity == previous.identity ? nil : previous.identity
            }
            return (result, retired)
        }
        for selection in retired { await SensesHub.shared.runner?.retire(selection: selection) }
        return result
    }

    private func readStore(defaults: [Version]) throws -> Store {
        let catalog = try abilities.catalog()
        var store = Store()
        let states = catalog.states
        for file in catalog.files where file.kind == .sense && file.metadata["record"]?.objectValue != nil {
            func version(_ retained: AbilityStore.File, slot: AbilityStore.Slot) throws -> Version {
                let fields = try abilities.record(retained, statistics: retained == file ? states[file.id] : nil)
                let record = try JSONDecoder().decode(SenseRecord.self, from: JSONValue.object(fields).serializedData(pretty: false))
                do {
                    let names = record.language == .native ? [] : try self.sourceFiles(record).keys.sorted()
                    return Version(record: record, files: names)
                } catch {
                    let failure = Self.failure("""
                        Sense \(retained.id), \(slot.rawValue) version \(record.version): \(error.localizedDescription) Saved source and authority were \
                        preserved.
                        """)
                    Self.report(failure)
                    // Keep lifecycle and authority intact; unavailable read presentation must not persist through sibling writes.
                    return Version(record: record, files: nil, sourceFailure: failure.message)
                }
            }
            let previous = catalog.retained[.previous]?[file.id]
            let slot: AbilityStore.Slot = catalog.retained[.current]?[file.id] == file ? .current : .next
            store.senses.append(Entry(id: file.id, current: try version(file, slot: slot),
                previous: try previous.map { try version($0, slot: .previous) }))
        }
        let defaultIDs = Set(defaults.map { $0.record.id.lowercased() })
        for file in catalog.files where defaultIDs.contains(file.id.lowercased()) && file.kind != .sense {
            throw Self.failure("Ability id collision: \(file.id) is also a bundled sense.")
        }
        for version in defaults where !store.senses.contains(where: { $0.id == version.record.id }) {
            var fields = try JSONValue.fromEncodable(version.record).objectValue!
            for (key, value) in states[version.record.id]?.objectValue ?? [:] { fields[key] = value }
            if fields["status"] == .string("on"), case .string = fields["unavailableReason"] ?? .null {
                fields["status"] = .string("unavailable")
            }
            fields = try AbilityStore.senseRecord(fields)
            let record = try JSONDecoder().decode(SenseRecord.self, from: JSONValue.object(fields).serializedData(pretty: false))
            store.senses.append(Entry(id: record.id, current: Version(record: record, files: version.files)))
        }
        try Self.validate(store)
        return store
    }

    /// Capture live identity under the publication lock; caller-owned draft helpers never enter canonical retirement.
    func helperSelection(_ record: SenseRecord) throws -> String {
        let metadata = try Self.metadata(record)
        if record.status == .draft {
            return "draft:" + SHA256.hash(data: try metadata.serializedData(pretty: false))
                .map { String(format: "%02x", $0) }.joined()
        }
        return try AbilityStore.withLock {
            guard let selected = Self.helperSelections[root.path]?[record.id], selected.metadata == metadata else {
                throw CancellationError()
            }
            return selected.identity
        }
    }

    private func selectHelpers(in store: Store) throws -> [String: HelperSelection] {
        let previous = Self.helperSelections[root.path] ?? [:]
        var selected: [String: HelperSelection] = [:]
        for entry in store.senses {
            let record = entry.current.record
            if record.status == .on, entry.current.sourceFailure == nil {
                let metadata = try Self.metadata(record)
                if let current = previous[entry.id], current.metadata == metadata { selected[entry.id] = current }
                else { selected[entry.id] = HelperSelection(metadata: metadata) }
            }
        }
        Self.helperSelections[root.path] = selected
        return selected
    }

    static func metadata(_ record: SenseRecord) throws -> JSONValue {
        var fields = try JSONValue.fromEncodable(record).objectValue!
        if record.status == .unavailable, record.disabledBy != "owner" { fields["status"] = .string("on") }
        for key in ["uses", "corrections", "lastUsedAt", "unavailableReason"] { fields.removeValue(forKey: key) }
        return .object(fields)
    }

    @discardableResult
    static func insert(_ input: SenseRecord, files: [String], into store: inout Store, turn: Turn?) throws -> SenseRecord {
        let previous = store.senses.first { $0.id == input.id }
        let current = previous?.current.record
        let record = try CapabilityLifecycle.preservingOwnerOff(input, before: current, enabling: input.status == .on, turn: turn)
        guard !store.senses.contains(where: { $0.id != record.id && $0.id.lowercased() == record.id.lowercased() }) else {
            throw failure("Sense id conflicts with an existing folder's spelling.")
        }
        let version = Version(record: record, files: files)
        try validate(version)
        if record.status == .on { displace(corner: record.corner, except: record.id, in: &store) }
        if let i = store.senses.firstIndex(where: { $0.id == record.id }) {
            guard !store.senses[i].versions.contains(where: { $0.record.version == record.version }) else {
                throw failure("Sense version changed before publication.")
            }
            store.senses[i].previous = store.senses[i].current
            store.senses[i].current = version
        } else {
            store.senses.append(Entry(id: record.id, current: version))
        }
        try validate(store)
        return record
    }

    static func index(_ id: String, in store: Store) throws -> Int {
        guard let i = store.senses.firstIndex(where: { $0.id == id }) else { throw failure("Sense not found: \(id).") }
        return i
    }

    static func displace(corner: SenseCorner, except id: String, in store: inout Store) {
        for i in store.senses.indices where store.senses[i].id != id {
            if store.senses[i].current.record.corner.key == corner.key && store.senses[i].current.record.status == .on {
                store.senses[i].current.record.status = .off
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
