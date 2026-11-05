import CryptoKit
import Experiences
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `AbilityStore.swift` | `signalled`, `wakes`, `recordRounds`, `replayed`, `tape_replay`; sealed lifecycle, state and notebooks |
/// Catalog files and separate accounting/notebooks share backup with credential exclusions; phone sync carries eligible metadata only.
public struct AbilityStore: Sendable {
    public static func fileReachAllows(_ path: URL, write: Bool = false, turn: Turn?) -> Bool {
        guard let reach = turn?.fileReach, !write || reach.write else { return false }
        let root = reach.root.standardizedFileURL.resolvingSymlinksInPath().path
        let target = path.standardizedFileURL.resolvingSymlinksInPath().path
        return NativeAgentWorkspaceRoot.relativePath(target, under: root) != nil
    }
    public let dataRoot: URL
    public var root: URL { dataRoot.appendingPathComponent("abilities", isDirectory: true) }
    static let lock = NSRecursiveLock()
    nonisolated(unsafe) static var decoded: [String: (revision: String, file: File)] = [:]
    /// Each root keeps only its latest successful reading, checked by lstat on every read.
    nonisolated(unsafe) static var stateMemo: [String: (revision: String, rows: [String: JSONValue])] = [:]
    nonisolated(unsafe) static var redactedAccounting: [String: (revision: String, rows: [String: JSONValue])] = [:]
    /// Reuse walked parent roots only within the outermost store operation.
    nonisolated(unsafe) private static var walked: Set<String> = []
    nonisolated(unsafe) private static var depth = 0
    static let statistics: Set<String> = ["uses", "useCount", "lastUsedAt", "lastRunVersion", "lastRun",
        "lastCleanVersion", "runs", "corrections", "unavailableReason"]
    static let obsolete: Set<String> = ["versionOwners", "bodyPath", "activePath", "proposalPath", "quarantinePath",
        "rollbackCounterparts", "versionValidation", "builtIn", "registryPath", "sourceRoot", "versions", "previousVersion",
        "failuresInARow", "lastCleanDigest", "seeded", "validation_evidence", "candidate_validation_evidence", "candidateReview", "keepReview"]
    static let pending: Set<String> = ["candidateDigest", "candidatePrior", "candidateSelection", "candidateValidation", "candidateOrigin", "validationErrors"]
    public init(dataRoot: URL) { self.dataRoot = dataRoot.standardizedFileURL }
    /// Catalog identity includes external edits and replacements, but not run accounting.
    public func revision() throws -> [String] {
        try Self.withLock {
            guard try Self.fileRevision(root) != "missing" else { return [] }
            try VerifiedPath.confirmNoSymlink(root)
            return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter { $0.lastPathComponent != "state.json" }.sorted { $0.path < $1.path }
                .map { $0.lastPathComponent + ":" + (try Self.fileRevision($0)) }
        }
    }
    public static func fileRevision(_ url: URL) throws -> String {
        try fileStatus(url).map { fileRevision($0) } ?? "missing"
    }
    static func fileStatus(_ url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    static func fileRevision(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mode):"
            + "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
    /// Change notifications only announce completed source work; they never run parts.
    public func signal(_ name: String, part: String? = nil, _ payload: [String: JSONValue] = [:]) {
        var info: [String: Any] = ["signal": name, "payload": payload]
        info["part"] = part
        NotificationCenter.default.post(name: Self.signalled, object: dataRoot.path, userInfo: info)
    }
    public static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLock {
            depth += 1
            defer { depth -= 1; if depth == 0 { walked = [] } }
            return try body()
        }
    }
    public func path(id: String, slot: Slot = .current, pathExtension: String = "js") throws -> URL {
        let url = root.appendingPathComponent(try Self.fileName(id: id, slot: slot, pathExtension: pathExtension))
        // The root and its parents do not change within one store operation: walked once per operation, the file itself every time.
        try Self.withLock {
            try Self.checkItem(url)
            if !Self.walked.contains(root.path) { try Self.checkPath(root); Self.walked.insert(root.path) }
        }
        return url
    }
    static func fileName(id: String, slot: Slot, pathExtension: String) throws -> String {
        guard !id.isEmpty, !id.hasPrefix("."), !id.contains("/"), !id.contains("\\"), !id.contains("\0"),
              !id.hasSuffix(".prev"), !id.hasSuffix(".next"), ["js", "md"].contains(pathExtension) else {
            throw Self.failure("Invalid ability file identity: \(id).")
        }
        let suffix = slot == .current ? "" : slot == .previous ? ".prev" : ".next"
        return id + suffix + "." + pathExtension
    }
    public func read(id: String, slot: Slot = .current) throws -> File? {
        try Self.withLock {
            return try readFile(id: id, slot: slot)
        }
    }
    public func files(kind: Kind? = nil, includeProposals: Bool = true) throws -> [File] {
        try selectedFiles(retainedFiles(), kind: kind, includeProposals: includeProposals)
    }
    /// One inventory walk checks all retained slots; damaged files remain visible through inventory().damaged.
    public func retainedFiles() throws -> [(file: File, slot: Slot)] {
        try inventory().files
    }
    public func inventory() throws -> Inventory {
        try Self.withLock { try allFiles() }
    }
    func selectedFiles(_ inventory: [(file: File, slot: Slot)], kind: Kind?, includeProposals: Bool = true) -> [File] {
        let selected = inventory.filter { $0.slot == .current }
        let ids = Set(selected.map { $0.file.id.lowercased() })
        let proposed = includeProposals ? inventory.filter { $0.slot == .next && !ids.contains($0.file.id.lowercased()) } : []
        return (selected + proposed).map(\.file).filter { kind == nil || $0.kind == kind }.sorted { $0.id < $1.id }
    }
    /// `writing` runs at the write boundary: anything thrown before it left the disk untouched.
    public func write(_ file: File, slot: Slot = .current, turn: Turn?, writing: () -> Void = {}) throws {
        try Self.withLock {
            try CapabilityLifecycle.requireWrite(turn: turn)
            let siblings = try allFiles().files.filter { $0.file.id.lowercased() == file.id.lowercased() }
            // A taken id must point to its current part rather than silently replace it.
            if let owner = siblings.map(\.file).first(where: { $0.id != file.id || $0.kind != file.kind }) {
                let record = owner.record
                let name = record["name"]?.stringValue ?? owner.id
                let when = ["promotedAt", "updatedAt", "createdAt"].lazy.compactMap { record[$0]?.stringValue }.first
                let state = (record["status"]?.stringValue).map { " (" + $0 + (when.map { " since " + $0 } ?? "") + ")" } ?? ""
                let revise = switch owner.kind {
                case .part: "revise it with ability.save {id:\"\(owner.id)\", edits}"
                case .sense: "revise it with sense.make"
                case .turn: "it is your turn part"
                }
                throw Self.failure("\(file.id) is your \(owner.kind.rawValue) \(name)\(state); \(revise), or choose another id. Nothing was written.")
            }
            try writeFile(file, slot: slot, writing: writing)
        }
    }
    package func contains(id: String, name: String? = nil) throws -> Bool {
        try Self.withLock {
            let inventory = try allFiles()
            // A damaged file still holds its id.
            if inventory.damaged.contains(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) { return true }
            return inventory.files.contains { entry in
                let file = entry.file
                let manifest = file.metadata["candidate"]?.objectValue?["manifest"]?.objectValue
                return file.id.caseInsensitiveCompare(id) == .orderedSame || name.map { name in
                    [file.id, file.record["name"]?.stringValue, manifest?["name"]?.stringValue,
                     manifest?["record"]?.objectValue?["name"]?.stringValue].compactMap { $0 }
                        .contains { $0.caseInsensitiveCompare(name) == .orderedSame }
                } == true
            }
        }
    }
    /// The shipped catalog reserves its ids; native- reserves names for future seeds.
    public static func seedCatalog(resources: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: resources.appendingPathComponent("abilities"),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).filter { $0.pathExtension == "js" }
    }
    public static func reservedPart(_ id: String) throws -> String? {
        if id.hasPrefix("native-") { return id }
        for url in try seedCatalog() where try decode(url).id == id { return id }
        return nil
    }
    /// Update bundled seeds only while their complete authored/sealed identity is untouched; retain displaced seeds as previous.
    package func isCurrentSeed(_ file: File) throws -> Bool {
        try Self.withLock {
            guard let current = try readFile(id: file.id, slot: .current), Self.isSeed(current) else { return false }
            return Self.seedIdentity(current) == Self.seedIdentity(file)
        }
    }

    package func installSeed(_ file: File, turn: Turn?, checkingSeed: (File) throws -> Void) throws {
        try Self.withLock {
            guard let current = try readFile(id: file.id, slot: .current) else {
                guard try !contains(id: file.id) else { return }
                try write(file, turn: turn)
                return
            }
            guard Self.isSeed(current) else { return }
            // The executable owner checks its candidate and seal under this same selection lock: changed authored bytes never become replaceable seeds.
            try checkingSeed(current)
            guard Self.seedIdentity(current) != Self.seedIdentity(file) else { return }
            try CapabilityLifecycle.requireWrite(turn: turn)
            // Off is the ability's, not the bundle version's: it stays off, by whoever switched it.
            var file = file
            if var record = file.metadata["record"]?.objectValue, let before = current.metadata["record"]?.objectValue,
               before["status"] == .string("disabled") {
                for key in ["status", "disabledBy", "disabledReason"] { record[key] = before[key] }
                file.metadata["record"] = .object(record)
            }
            try writeFile(current, slot: .previous)
            try write(file, turn: turn)
        }
    }
    /// Exclude admission and installation bookkeeping from authored identity; manifests, programs and dependencies remain sealed inputs.
    private static func seedIdentity(_ file: File) -> JSONValue {
        let installed: Set<String> = ["status", "createdAt", "updatedAt", "promotedAt", "enabledAt",
            "disabledBy", "disabledReason", "activePath", "admission", "codeFingerprint"]
        return .object([
            "id": .string(file.id), "kind": .string(file.kind.rawValue), "body": .string(file.body),
            "header": .object(file.metadata.filter { !["proof", "record"].contains($0.key) }),
            "record": .object(Self.storedRecord(file.record, kind: file.kind).filter { !installed.contains($0.key) })
        ])
    }
    /// Only sealed bundle-owned proofs identify replaceable seeds; authored edits must survive installation.
    public static func isSeed(_ file: File) -> Bool {
        file.metadata["proof"]?.objectValue?["domain"] == .string("owned-program-seed")
    }
    public func remove(id: String, slot: Slot, turn: Turn?) throws {
        try Self.withLock {
            try CapabilityLifecycle.requireWrite(turn: turn)
            for ext in ["js", "md"] {
                let url = try path(id: id, slot: slot, pathExtension: ext)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                Self.decoded.removeValue(forKey: url.path)
            }
            if slot == .current { NotificationCenter.default.post(name: Self.didChange, object: root.appendingPathComponent(id).path) }
        }
    }
    public func remove(id: String, ownerAuthorized: Bool = false, preview: Bool = false, turn: Turn?) throws {
        try Self.withLock {
            if let file = try readFile(id: id, slot: .current) ?? readFile(id: id, slot: .next),
               let row = file.metadata["record"]?.objectValue {
                _ = try CapabilityLifecycle.preservingOwnerOff(row, before: row, ownerAuthorized: ownerAuthorized, enabling: true, preview: preview, turn: turn)
            }
            if preview { return }
            try CapabilityLifecycle.requireWrite(turn: turn)
            // Its notebook (host.state) goes with it: a new ability under this id starts blank. Never through a link, checked before anything is removed.
            let notebook = Self.notebookPath(dataRoot: dataRoot, id: id)
            try Self.checkPath(notebook)
            for slot in Slot.allCases { try remove(id: id, slot: slot, turn: turn) }
            var stats = try readState(); stats.removeValue(forKey: id)
            try writeState(stats)
            if FileManager.default.fileExists(atPath: notebook.path) { try FileManager.default.removeItem(at: notebook) }
        }
    }
    /// Reserved for recovery of the agent's throwing turn program, never a capability action.
    public func swap(id: String, turn: Turn?) throws {
        try Self.withLock {
            try CapabilityLifecycle.requireWrite(turn: turn)
            guard let current = try readFile(id: id, slot: .current), var previous = try readFile(id: id, slot: .previous) else {
                throw Self.failure("No previous version for \(id).")
            }
            guard current.kind == .turn, previous.kind == .turn else {
                throw Self.failure("Only a throwing turn program can select its previous version; revise other abilities forward.")
            }
            var restored: [String: JSONValue]? = nil
            let before = current.record
            if CapabilityLifecycle.requiresOwnerToEnable(before) {
                restored = try CapabilityLifecycle.preservingOwnerOff(restored ?? previous.record, before: before, turn: turn)
            }
            if let restored {
                previous.metadata["record"] = .object(Self.storedRecord(restored, kind: previous.kind).filter { !Self.pending.contains($0.key) })
                try writeFile(previous, slot: .previous)
            }
            let selected = try path(id: id, pathExtension: current.pathExtension)
            let retained = try path(id: id, slot: .previous, pathExtension: previous.pathExtension)
            guard renameatx_np(AT_FDCWD, selected.path, AT_FDCWD, retained.path, UInt32(RENAME_SWAP)) == 0 else {
                throw Self.failure("Could not swap ability versions for \(id): \(String(cString: strerror(errno))).")
            }
            if current.pathExtension != previous.pathExtension {
                try FileManager.default.moveItem(at: selected, to: path(id: id, slot: .previous, pathExtension: current.pathExtension))
                try FileManager.default.moveItem(at: retained, to: path(id: id, pathExtension: previous.pathExtension))
            }
            NotificationCenter.default.post(name: Self.didChange, object: root.appendingPathComponent(id).path)
        }
    }
    /// Accounting and readers share the selected-version identity.
    public func identity(_ file: File) -> String? {
        if file.kind == .turn { return file.bodyDigest }
        return file.metadata["candidate"]?.objectValue?["program"]?.objectValue?["version"]?.stringValue
            ?? file.metadata["record"]?.objectValue?["codeFingerprint"]?.stringValue
            ?? (file.kind == .sense ? file.record["version"]?.integer.map(String.init) : nil)
    }
    public func restoreState(_ state: JSONValue, expectedDigest: String, turn: Turn?) throws -> URL {
        try Self.withLock {
            try CapabilityLifecycle.requireWrite(turn: turn)
            let url = root.appendingPathComponent("state.json")
            try Self.checkPath(url)
            let original = try Data(contentsOf: url)
            guard SHA256.hash(data: original).map({ String(format: "%02x", $0) }).joined() == expectedDigest else {
                throw ToolFailureError("Ability run state changed. Read abilities/state.json again before restoring it.", argumentPath: "expected_digest",
                    effects: .none)
            }
            if (try? Self.decodeState(original)) != nil {
                throw ToolFailureError("Ability run state is readable; nothing was restored.", argumentPath: "state", effects: .none)
            }
            try state.validate(schema: Self.recoveryStateSchema)
            let bytes = try state.serializedData(pretty: true)
            let restored: [String: JSONValue]
            do { restored = try Self.decodeState(bytes) }
            catch { throw ToolFailureError("state must contain recovered accounting rows, including pending work.", argumentPath: "state", effects: .none) }
            if case .object(let readable)? = try? JSONValue.parse(original) {
                for (id, row) in readable where (try? Self.validateCounters([id: row])) != nil && restored[id] != row {
                    throw ToolFailureError("Preserve readable accounting rows unchanged; only repair damaged rows.", argumentPath: "state.\(id)",
                        effects: .none)
                }
            }
            for (id, value) in restored {
                _ = try path(id: id)
                guard let row = value.objectValue, Set(row.keys).isSubset(of: Self.statistics) else {
                    throw ToolFailureError("Restore only accounting fields; authority remains in each ability file.", argumentPath: "state.\(id)",
                        effects: .none)
                }
            }
            let archive = root.appendingPathComponent(".state-damaged-\(UUID().uuidString).json")
            try SwiftNativePersistenceCore.writeDataAtomicDurable(original, to: archive)
            guard try Data(contentsOf: archive) == original else { throw Self.failure("Damaged state preservation failed; state.json was not replaced.") }
            try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: url)
            guard try readState() == restored else { throw Self.failure("Restored ability state did not read back; the damaged bytes remain preserved.") }
            NotificationCenter.default.post(name: Self.didChange, object: root.path)
            return archive
        }
    }
    func writeState(_ state: [String: JSONValue]) throws {
        try Self.validateCounters(state)
        let bytes = try JSONValue.object(state).serializedData(pretty: true)
        let url = root.appendingPathComponent("state.json")
        let revision = try Self.fileRevision(url)
        if let known = Self.stateMemo[root.path], known.revision == revision, known.rows == state { return }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: url)
        let writtenRevision = try Self.fileRevision(url)
        if writtenRevision != "missing" { Self.stateMemo[root.path] = (writtenRevision, state) }
    }
    static func failure(_ detail: String) -> NSError {
        NSError(domain: "AbilityStore", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }
    func sourceFailure(_ source: URL, _ error: Error) -> ToolFailureError {
        let repair = repairFailure(source: source, detail: error.localizedDescription)
        let header = error as? ToolFailureError
        return ToolFailureError(repair.message, argumentPath: header?.argumentPath, accepted: header?.accepted, effects: .none,
            owner: repair.owner, nextCall: repair.nextCall, code: header?.code ?? "ability_source_unreadable",
            instruction: repair.instruction, recovery: .repair)
    }
    public func repairFailure(source: URL, detail: String) -> ToolFailureError {
        ToolFailureError("\(source.path): \(detail) Saved bytes remain authoritative and were preserved.", effects: .none,
            owner: source.path, instruction: ToolFailureError.fileRepairInstruction(source,
                shape:
                "It is an AbilityStore source that failed with: \(detail) Repair it with its directly referenced retained sources. "
                + "Preserve all current, previous and candidate versions, bodies, identities, digests and authority fields. "
                + "Do not invent disabledBy, change an owner off-switch, grant peer authority, enable a part, select another version "
                + "or delete retained material; if missing content or authority cannot be established, preserve it and name the missing evidence."))
    }
    /// Authoring recovery uses retained source; reserved turns expose reads only.
    public func repairCall(_ file: File) throws -> String {
        let record = file.record
        var args = file.part
        let action: String
        switch file.kind {
        case .part:
            action = "ability.save"
            // Revisions carry unchanged fields forward so code-only edits preserve their declarations.
            args.merge(["id": .string(file.id), "description": record["description"] ?? .string(file.id),
                "code": .string(file.body)]) { _, new in new }
        case .sense:
            let corner = record["corner"]?.objectValue ?? [:]
            let place = [("app", "bundleID", "app"), ("fileKind", "_0", "file"), ("site", "host", "site"), ("stream", "id", "stream"), ("need", "id", "need")]
                .compactMap { kind, field, prefix in
                corner[kind]?.objectValue?[field]?.stringValue.map { prefix + ":" + $0 }
            }.first
            guard let place else { throw repairFailure(source: root.appendingPathComponent(file.id + "." + file.pathExtension),
                detail: "Sense corner is missing or unreadable.") }
            action = "sense.make"
            args["code"] = .string(file.body); args["place"] = .string(place)
        case .turn:
            let slot: Slot = try readFile(id: file.id, slot: .current) == file ? .current : .previous
            return ToolFailureError.call("app", ["action": .string("files.read"), "args": .object([
                "path": .string(try path(id: file.id, slot: slot, pathExtension: file.pathExtension).path)])])
        }
        return ToolFailureError.call("app", ["action": .string(action), "args": .object(args)])
    }
    /// Notebook mutations share the deletion lock; backup includes notebooks except news/ledger, while export/sharing/sync exclude them.
    package static let notebookValueBytes = 16_384
    package static func notebookPath(dataRoot: URL, id: String) -> URL {
        dataRoot.appendingPathComponent("senses/\(id)/state.json")
    }
    package static func notebook(dataRoot: URL, id: String, setting: Bool, value: JSONValue,
                               failure: (String, String) -> any Error) throws -> JSONValue {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\") else {
            throw failure("bad_state", "Part notebook id is invalid.")
        }
        return try notebook(notebookPath(dataRoot: dataRoot, id: id), key: "part", setting: setting, value: value, failure: failure)
    }
    package static func notebook(_ notebook: URL, key: String, setting: Bool, value: JSONValue,
                               failure: (String, String) -> any Error) throws -> JSONValue {
        try withLock {
            guard notebook.resolvingSymlinksInPath().path == notebook.standardizedFileURL.path else {
                throw failure("bad_state", "Sense notebook cannot be a symbolic link.")
            }
            var state: [String: JSONValue] = [:]
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: notebook.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 65_536,
                      let saved = try? JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: notebook)) else {
                    throw failure("bad_state", "Sense notebook is malformed or too large.")
                }
                state = saved
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {}
            guard setting else { return state[key] ?? .null }
            guard try JSONEncoder().encode(value).count <= notebookValueBytes else {
                throw failure("state_limit", "Sense notebook values must be at most 16 KiB.")
            }
            state[key] = value
            let data = try JSONEncoder().encode(state)
            guard data.count <= 65_536 else { throw failure("state_limit", "Sense notebook exceeds 64 KiB.") }
            try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: notebook)
            return .null
        }
    }
}
extension JSONValue {
    var integer: Int64? { if case .int = self { integerValue } else { nil } }
}
