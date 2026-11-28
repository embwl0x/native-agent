import Synchronization
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `AbilityStore.swift` | `AbilityStore.Signalled`, `wakes`, `recordRounds`, `replayed`, `tape_replay`; sealed lifecycle, state and notebooks |
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
    private static let lock = Mutex(())
    final class Projection<Value: Sendable>: Sendable {
        private final class Box: Sendable {
            let value: Value
            init(_ value: Value) { self.value = value }
        }
        private let result = AtomicLazyReference<Box>()
        private let creation = Mutex(())

        func read(_ make: () throws -> Value) rethrows -> Value {
            if let box = result.load() { return box.value }
            return try creation.withLock { _ in
                if let box = result.load() { return box.value }
                return result.storeIfNil(Box(try make())).value
            }
        }
    }
    struct Stamped<Key: Equatable & Sendable, Value: Sendable>: Sendable {
        let revision: Key
        let value: Value
    }
    struct Published: Sendable {
        var files: Stamped<[EntryStamp], FileSnapshot>?
        var accounting: Stamped<String, Accounting>?
    }
    private static let published = Mutex<[String: Published]>([:])
    private final class PathWalk {
        var checkedRoots: Set<String> = []
        var changed: [String: Published] = [:]

        func check(_ url: URL, under root: URL) throws {
            try AbilityStore.checkItem(url)
            if !checkedRoots.contains(root.path) {
                try AbilityStore.checkPath(root)
                checkedRoots.insert(root.path)
            }
        }
    }
    private static let walkKey = "NativeAgent.AbilityStore.PathWalk"
    private static var walk: PathWalk? { Thread.current.threadDictionary[walkKey] as? PathWalk }
    private var held: Published {
        Self.walk?.changed[root.path] ?? Self.published.withLock { $0[root.path] ?? Published() }
    }
    struct ReadingChanged: Error {}
    func checkPaths(_ urls: some Sequence<URL>) throws {
        let walk = Self.walk ?? PathWalk()
        for url in urls { try walk.check(url, under: root) }
    }

    func checked<Key, Value>(_ field: WritableKeyPath<Published, Stamped<Key, Value>?>,
        stamp: () throws -> Key, publishable: (Key, Value) -> Bool = { _, _ in true },
        load: (Key) throws -> Value) throws -> Stamped<Key, Value> {
        let revision = try stamp()
        if let known = held[keyPath: field], known.revision == revision { return known }
        return try Self.withPathWalk { walk in
            var before = try stamp()
            while true {
                try Task.checkCancellation()
                if let known = held[keyPath: field], known.revision == before { return known }
                let loaded = Result { try load(before) }
                let after = try stamp()
                if before == after {
                    if case .failure(let error) = loaded, error is ReadingChanged { continue }
                    let reading = Stamped(revision: before, value: try loaded.get())
                    guard publishable(before, reading.value) else { return reading }
                    var current = held
                    current[keyPath: field] = reading
                    walk.changed[root.path] = current
                    return reading
                }
                before = after
            }
        }
    }
    static let statistics: Set<String> = ["uses", "useCount", "lastUsedAt", "lastRunVersion", "lastRun",
        "lastCleanVersion", "runs", "corrections", "unavailableReason", "trial", "trials"]
    static let projections: Set<String> = ["activePath", "proposalPath", "versions", "previousVersion",
        "validation_evidence", "candidate_validation_evidence", "keepReview"]
    static let pending: Set<String> = ["candidateDigest", "candidatePrior", "candidateSelection", "candidateValidation", "candidateOrigin", "validationErrors"]
    public init(dataRoot: URL) { self.dataRoot = dataRoot.standardizedFileURL }
    /// Catalog identity includes external edits and replacements, but not run accounting.
    public func revision() throws -> [String] {
        try folderRevision().map { try $0.key() }
    }
    struct EntryStamp: Equatable, Sendable {
        let name: String
        let stamp: String
        let error: Int?

        func key() throws -> String {
            if let error { throw NSError(domain: NSPOSIXErrorDomain, code: error) }
            return name + ":" + stamp
        }
    }
    func folderRevision() throws -> [EntryStamp] {
        while true {
            try Task.checkCancellation()
            guard try Self.fileStatus(root) != nil else {
                try Self.checkPath(root)
                if try Self.fileStatus(root) == nil { return [] }
                continue
            }
            let fd = try VerifiedPath.open(root, flags: O_RDONLY | O_DIRECTORY)
            defer { _ = Darwin.close(fd) }
            var before = stat()
            guard unsafe fstat(fd, &before) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let entries = Result { try Self.directoryEntries(fd) }
            if try Self.fileRevision(root) == Self.fileRevision(before) { return try entries.get() }
        }
    }
    private static func directoryEntries(_ fd: Int32) throws -> [EntryStamp] {
        let common = UInt32(ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME
            | ATTR_CMN_ACCESSMASK | ATTR_CMN_FLAGS | ATTR_CMN_FILEID)
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = common | UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_ERROR) | UInt32(ATTR_CMN_FNDRINFO)
        attrs.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS | ATTR_DIR_DATALENGTH)
        attrs.fileattr = UInt32(ATTR_FILE_DATALENGTH)
        var entries: [EntryStamp] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        try buffer.withUnsafeMutableBytes { bytes in
            while true {
                try Task.checkCancellation()
                let count = unsafe getattrlistbulk(fd, &attrs, bytes.baseAddress, bytes.count, 0)
                guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                if count == 0 { return }
                var offset = 0
                for _ in 0..<count {
                    guard bytes.count - offset >= MemoryLayout<UInt32>.size else { throw POSIXError(.EIO) }
                    let length = Int(unsafe bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                    guard length >= MemoryLayout<UInt32>.size, length <= bytes.count - offset else { throw POSIXError(.EIO) }
                    let record = unsafe UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(bytes)[offset..<(offset + length)])
                    if let entry = try unsafe directoryEntry(record, common: common) { entries.append(entry) }
                    offset += length
                }
            }
        }
        return entries.sorted { $0.name < $1.name }
    }
    private static func directoryEntry(_ bytes: UnsafeRawBufferPointer, common: UInt32) throws -> EntryStamp? {
        var offset = MemoryLayout<UInt32>.size, fixedEnd = bytes.count
        func read<T: BitwiseCopyable>(_ type: T.Type) throws -> T {
            guard MemoryLayout<T>.size <= fixedEnd - offset else { throw POSIXError(.EIO) }
            defer { offset += MemoryLayout<T>.size }
            return unsafe bytes.loadUnaligned(fromByteOffset: offset, as: type)
        }
        let returned = try read(attribute_set_t.self)
        let error = returned.commonattr & UInt32(ATTR_CMN_ERROR) == 0 ? 0 : try read(UInt32.self)
        guard returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 else { throw POSIXError(.EIO) }
        let referenceOffset = offset
        let reference = try read(attrreference_t.self)
        let start = referenceOffset + Int(reference.attr_dataoffset), end = start + Int(reference.attr_length)
        guard start >= offset, end > start + 1, end <= fixedEnd, unsafe bytes[end - 1] == 0 else { throw POSIXError(.EIO) }
        if unsafe bytes[start] == 0x2e { return nil }
        guard let name = unsafe String(bytes: bytes[start..<(end - 1)], encoding: .utf8) else { throw POSIXError(.EILSEQ) }
        if name == "state.json" { return nil }
        fixedEnd = start
        if error == UInt32(ENOENT) { return EntryStamp(name: name, stamp: "missing", error: nil) }
        if error != 0 { return EntryStamp(name: name, stamp: "", error: Int(error)) }
        let unsupported = EntryStamp(name: name, stamp: "", error: Int(ENOTSUP))
        guard returned.commonattr & common == common else { return unsupported }
        var info = stat()
        info.st_dev = try read(dev_t.self)
        let type = try read(fsobj_type_t.self)
        info.st_mtimespec = try read(timespec.self)
        info.st_ctimespec = try read(timespec.self)
        if returned.commonattr & UInt32(ATTR_CMN_FNDRINFO) != 0 {
            guard fixedEnd - offset >= 32 else { throw POSIXError(.EIO) }
            if unsafe bytes[offset + 8] & 0x40 != 0 { return nil }
            offset += 32
        }
        let access = try read(UInt32.self)
        let flags = try read(UInt32.self)
        if flags & UInt32(UF_HIDDEN) != 0 { return nil }
        info.st_ino = try read(ino_t.self)
        let mode: mode_t
        switch type {
        case VREG.rawValue: mode = S_IFREG
        case VDIR.rawValue: mode = S_IFDIR
        case VLNK.rawValue: mode = S_IFLNK
        case VBLK.rawValue: mode = S_IFBLK
        case VCHR.rawValue: mode = S_IFCHR
        case VFIFO.rawValue: mode = S_IFIFO
        case VSOCK.rawValue: mode = S_IFSOCK
        default: return unsupported
        }
        info.st_mode = mode | (mode_t(truncatingIfNeeded: access) & ~S_IFMT)
        if mode == S_IFDIR {
            guard returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS) != 0 else { return unsupported }
            let mount = try read(UInt32.self)
            guard mount & UInt32(DIR_MNTSTATUS_MNTPOINT) == 0, flags & UInt32(SF_FIRMLINK) == 0,
                  returned.dirattr & UInt32(ATTR_DIR_DATALENGTH) != 0 else { return unsupported }
        } else if returned.fileattr & UInt32(ATTR_FILE_DATALENGTH) == 0 { return unsupported }
        info.st_size = try read(off_t.self)
        return EntryStamp(name: name, stamp: fileRevision(info), error: nil)
    }
    public static func fileRevision(_ url: URL) throws -> String {
        try fileStatus(url).map { fileRevision($0) } ?? "missing"
    }
    static func fileStatus(_ url: URL) throws -> stat? {
        var info = stat()
        if unsafe lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    static func fileRevision(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mode):"
            + "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
    /// Change notifications only announce completed source work; they never run parts.
    public func signal(_ name: String, part: String? = nil, _ payload: [String: JSONValue] = [:], origin: WakeOrigin = .signal) {
        let message = Signalled(root: dataRoot.path, signal: name, part: part, payload: payload, origin: origin)
        NotificationCenter.default.post(message, subject: message.root as NSString)
    }
    public static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try withPathWalk { _ in try body() }
    }
    private static func withPathWalk<T>(_ body: (PathWalk) throws -> T) rethrows -> T {
        let thread = Thread.current.threadDictionary
        if let walk = thread[walkKey] as? PathWalk { return try body(walk) }
        var value: T?
        try lock.withLock { _ in
            let walk = PathWalk()
            thread[walkKey] = walk
            defer {
                if !walk.changed.isEmpty {
                    published.withLock { $0.merge(walk.changed) { _, new in new } }
                }
                thread.removeObject(forKey: walkKey)
            }
            value = try body(walk)
        }
        return value!
    }
    public func path(id: String, slot: Slot = .current, pathExtension: String = "js") throws -> URL {
        let url = root.appendingPathComponent(try Self.fileName(id: id, slot: slot, pathExtension: pathExtension))
        if let walk = Self.walk { try walk.check(url, under: root) }
        else { try Self.checkPath(url) }
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
    /// The parts that are pages of the agent's own, by part id: each active part whose face is `{projection:true, page:"<id>"}` with an id
    /// no app page, alias, room or tab has (a part whose page is an app page is placed there, never that page), with its page.
    public func pageParts() throws -> [(part: String, page: String)] {
        try files(kind: .part, includeProposals: false).sorted { $0.id < $1.id }.compactMap { file in
            guard file.record["status"] == .string("active"), let face = file.part["face"]?.objectValue, face["projection"] == .bool(true),
                  case .string(let page)? = face["page"], AppDoorNames.ownPageRefusal(page) == nil else { return nil }
            return (file.id, page)
        }
    }
    public func read(id: String, slot: Slot = .current) throws -> File? {
        try readFile(id: id, slot: slot)
    }
    public func files(kind: Kind? = nil, includeProposals: Bool = true) throws -> [File] {
        let snapshot = try fileSnapshot().value
        let files = includeProposals ? snapshot.selected : snapshot.current
        return files.filter { kind == nil || $0.kind == kind }
    }
    public func inventory() throws -> Inventory {
        try fileSnapshot().value.inventory
    }
    /// `writing` runs at the write boundary: anything thrown before it left the disk untouched.
    public func write(_ file: File, slot: Slot = .current, turn: Turn?, writing: () -> Void = {}) throws {
        try Self.withLock {
            try CapabilityLifecycle.requireWrite(turn: turn)
            let siblings = try inventory().files.filter { $0.file.id.lowercased() == file.id.lowercased() }
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
        let inventory = try inventory()
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
        guard let current = try readFile(id: file.id, slot: .current), Self.isSeed(current) else { return false }
        return Self.seedIdentity(current) == Self.seedIdentity(file)
    }

    /// A current version follows the shipped part while it is a seed or is that same part (`samePart`, read by the executable owner under this
    /// selection lock); any other is the agent's own and stays. A different part is retained as previous and returned; the same part is replaced
    /// in place, so its previous version stays the way back.
    @discardableResult
    package func installSeed(_ file: File, turn: Turn?, samePart: (File) throws -> Bool) throws -> File? {
        try Self.withLock { () throws -> File? in
            guard let current = try readFile(id: file.id, slot: .current) else {
                guard try !contains(id: file.id) else { return nil }
                try write(file, turn: turn)
                return nil
            }
            // The owner also checks a seed's candidate and seal here: changed authored bytes never become replaceable seeds.
            let same = try samePart(current)
            guard Self.isSeed(current) || same, !Self.isSeed(current) || Self.seedIdentity(current) != Self.seedIdentity(file) else { return nil }
            try CapabilityLifecycle.requireWrite(turn: turn)
            // Off is the ability's, not the bundle version's: it stays off, by whoever switched it.
            var file = file
            if var record = file.metadata["record"]?.objectValue, let before = current.metadata["record"]?.objectValue,
               before["status"] == .string("disabled") {
                for key in ["status", "disabledBy", "disabledReason"] { record[key] = before[key] }
                file.metadata["record"] = .object(record)
            }
            if !same { try writeFile(current, slot: .previous) }
            try write(file, turn: turn)
            return same ? nil : current
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
    /// Only seed seals identify replaceable seeds: the bundle's, or a kept version that is the shipped part. Authored edits survive installation.
    public static func isSeed(_ file: File) -> Bool {
        file.metadata["proof"]?.objectValue?["domain"] == .string("owned-program-seed")
    }
    public func remove(id: String, slot: Slot, turn: Turn?) throws {
        try Self.withLock {
            try CapabilityLifecycle.requireWrite(turn: turn)
            for ext in ["js", "md"] {
                let url = try path(id: id, slot: slot, pathExtension: ext)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            _ = try? fileSnapshot()
            if slot == .current { Self.DidChange(path: root.appendingPathComponent(id).path).post() }
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
                throw Self.failure("Could not swap ability versions for \(id): \(unsafe String(cString: strerror(errno))).")
            }
            if current.pathExtension != previous.pathExtension {
                try FileManager.default.moveItem(at: selected, to: path(id: id, slot: .previous, pathExtension: current.pathExtension))
                try FileManager.default.moveItem(at: retained, to: path(id: id, pathExtension: previous.pathExtension))
            }
            _ = try? fileSnapshot()
            Self.DidChange(path: root.appendingPathComponent(id).path).post()
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
            guard SHA256Hex.of(original) == expectedDigest else {
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
            Self.DidChange(path: root.path).post()
            return archive
        }
    }
    func writeState(_ state: [String: JSONValue]) throws {
        try Self.validateCounters(state)
        let bytes = try JSONValue.object(state).serializedData(pretty: true)
        let url = root.appendingPathComponent("state.json")
        if let known = held.accounting, known.revision != "missing", try known.revision == stateRevision(), known.value.rows == state { return }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: url)
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
    /// A part wrote its notebook (object: the part id); a page drawn from that notebook reads it again.
    public struct NotebookDidChange: NotificationCenter.AsyncMessage {
        public typealias Subject = NSString
        public let part: String
    }
    /// Notebook mutations share the deletion lock; backup includes notebooks except news/ledger, while export/sharing/sync exclude them.
    package static let notebookValueBytes = 262_144
    private static let notebookTotalBytes = 2_097_152
    private static let notebookMaxKeys = 256

    enum NotebookCall: Sendable {
        case get(String)
        case set(String, JSONValue, ttl: Int64?, legacy: Bool)
        case delete(String)
        case list(String)
        case cas(String, expected: JSONValue, value: JSONValue, ttl: Int64?)
        case page

        var writes: Bool { writeKey != nil }

        var keyedWrite: Bool {
            if case .set(_, _, _, let legacy) = self { return !legacy }
            return writes
        }

        var writeKey: String? {
            switch self {
            case .set(let key, _, _, _), .delete(let key), .cas(let key, _, _, _): key
            case .get, .list, .page: nil
            }
        }

        func checkedWriteValue() throws -> Data? {
            let value: JSONValue
            switch self {
            case .set(_, let next, _, _), .cas(_, _, let next, _): value = next
            default: return nil
            }
            let data = try value.serializedData(pretty: false)
            let text = String(decoding: data, as: UTF8.self)
            guard NativeAgentSecretRedactor.secretPath(value) == nil,
                  Keyring.names(in: value).isEmpty, !text.contains("{{secret:"),
                  !NativeAgentSecretRedactor.containsAuditSecret(text) else { throw AbilityStore.notebookSecretFailure }
            return data
        }

        init(_ operation: String, _ args: [JSONValue], legacy: Bool = true) throws(SenseFailure) {
            let bad = SenseFailure(code: "bad_state", message: """
                Use get(key), set(key, value, options?), delete(key), list(prefix?), or cas(key, expected, value, options?). \
                Keys are 1–256 UTF-8 bytes and ttl_seconds is an integer from 1 through 31536000.
                """)
            if operation == "list" {
                if args.isEmpty { self = .list(""); return }
                guard args.count == 1 else { throw bad }
                if args[0] == .null { self = .list(""); return }
                guard case .string(let prefix) = args[0], prefix.utf8.count <= SenseWire.stateKeyBytes else { throw bad }
                self = .list(prefix)
                return
            }
            if legacy, operation == "get", args.isEmpty { self = .get("part"); return }
            if legacy, operation == "set", args.count == 1 { self = .set("part", args[0], ttl: nil, legacy: true); return }
            guard case .string(let key)? = args.first, SenseWire.validStateKey(key) else { throw bad }
            func ttl(at index: Int) throws(SenseFailure) -> Int64? {
                guard args.count > index else { return nil }
                guard args.count == index + 1 else { throw bad }
                if args[index] == .null { return nil }
                guard case .object(let options) = args[index] else { throw bad }
                if options.isEmpty { return nil }
                guard options.count == 1, case .int(let seconds)? = options["ttl_seconds"],
                      (1...31_536_000).contains(seconds) else { throw bad }
                return seconds
            }
            switch operation {
            case "get" where args.count == 1: self = .get(key)
            case "set" where args.count >= 2: self = .set(key, args[1], ttl: try ttl(at: 2), legacy: false)
            case "delete" where args.count == 1: self = .delete(key)
            case "cas" where args.count >= 3: self = .cas(key, expected: args[1], value: args[2], ttl: try ttl(at: 3))
            default: throw bad
            }
        }

        func writtenValue(reply: JSONValue?) -> JSONValue? {
            switch self {
            case .set(_, let value, _, _): value
            case .delete: .null
            case .cas(_, _, let value, _) where reply?.objectValue?["swapped"] == .bool(true): value
            default: nil
            }
        }
    }

    private struct NotebookMetadata: Codable {
        let updated_at: Date
        let expires_at: Date?
        let rev: Int64
    }

    package static var notebookSecretFailure: SenseFailure {
        SenseFailure(code: "secret_in_state_forbidden", message: "The notebook cannot hold credential values or secret references.")
    }

    package static func notebookPath(dataRoot: URL, id: String) -> URL {
        dataRoot.appendingPathComponent("senses/\(id)/state.json")
    }
    static func notebook(dataRoot: URL, id: String, call: NotebookCall, expectedVersion: String? = nil,
                         writing: () -> Void = {}, writeUncertain: () -> Void = {},
                         listChange: ((JSONValue) -> Void)? = nil) throws -> JSONValue {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\") else {
            throw SenseFailure(code: "bad_state", message: "Part notebook id is invalid.")
        }
        var changed = false
        let result = try withLock {
            if let expectedVersion {
                guard let part = try AbilityStore(dataRoot: dataRoot).selectedPart(id), part.file != nil,
                      part.row["status"] == .string("active"), part.row["codeFingerprint"] == .string(expectedVersion) else {
                    throw SenseFailure(code: "state_changed", message: "The notebook's ability was stopped or replaced.")
                }
            }
            return try notebook(notebookPath(dataRoot: dataRoot, id: id), call: call,
                writing: { changed = true; writing() }, writeUncertain: writeUncertain, listChange: listChange)
        }
        if changed { NotificationCenter.default.post(NotebookDidChange(part: id), subject: id as NSString) }
        return result
    }
    static func notebook(_ notebook: URL, call: NotebookCall,
                         writing: () -> Void = {}, writeUncertain: () -> Void = {},
                         listChange: ((JSONValue) -> Void)? = nil) throws -> JSONValue {
        try withLock {
            try Task.checkCancellation()
            guard notebook.resolvingSymlinksInPath().path == notebook.standardizedFileURL.path else {
                throw SenseFailure(code: "bad_state", message: "Sense notebook cannot be a symbolic link.")
            }
            try checkItem(notebook.deletingLastPathComponent())
            try checkItem(notebook)
            var state: [String: JSONValue] = [:]
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: notebook.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= notebookTotalBytes,
                      let saved = try? JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: notebook)) else {
                    throw SenseFailure(code: "bad_state", message: "Sense notebook is malformed or too large.")
                }
                state = saved
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {}

            let savedMetadata = state.removeValue(forKey: "")
            var metadata: [String: NotebookMetadata] = [:]
            if let savedMetadata {
                guard let decoded = try? JSONDecoder().decode([String: NotebookMetadata].self, from: savedMetadata.serializedData(pretty: false)),
                      decoded.allSatisfy({ state[$0.key] != nil && $0.value.rev > 0 }) else {
                    throw SenseFailure(code: "bad_state", message: "Sense notebook metadata is malformed.")
                }
                metadata = decoded
            }
            let now = Date()
            let expired = metadata.compactMap { key, entry in
                entry.expires_at.map { $0 <= now } == true ? key : nil
            }
            for key in expired { state.removeValue(forKey: key); metadata.removeValue(forKey: key) }
            let keyLimit = max(notebookMaxKeys, state.count)
            func encoded() throws -> Data {
                var envelope = state
                if !metadata.isEmpty { envelope[""] = try .fromEncodable(metadata) }
                return try JSONEncoder().encode(envelope)
            }
            func listRow(_ key: String) throws -> JSONValue? {
                guard let value = state[key] else { return nil }
                let entry = metadata[key]
                return .object(["key": .string(key), "bytes": .int(Int64(try JSONEncoder().encode(value).count)),
                                "rev": .int(entry?.rev ?? 0), "updated_at": entry.map { .string($0.updated_at.formatted(.iso8601)) } ?? .null,
                                "expires_at": entry?.expires_at.map { .string($0.formatted(.iso8601)) } ?? .null])
            }
            let before: (key: String, row: JSONValue, bytes: Int)? = if listChange != nil, let key = call.writeKey {
                (key, try listRow(key) ?? .null, try encoded().count)
            } else { nil }
            var changed = !expired.isEmpty
            func set(_ key: String, _ value: JSONValue, ttl: Int64?, legacy: Bool) throws -> Int64 {
                let previous = metadata[key]
                if legacy, state[key] == value, previous?.expires_at == nil { return previous?.rev ?? 0 }
                guard try JSONEncoder().encode(value).count <= SenseWire.stateValueBytes else {
                    throw SenseFailure(code: "state_limit", message: "Notebook values must be at most 256 KiB.")
                }
                let (rev, overflow) = (previous?.rev ?? 0).addingReportingOverflow(1)
                guard !overflow else { throw SenseFailure(code: "state_limit", message: "Notebook key exhausted its revisions.") }
                state[key] = value
                metadata[key] = NotebookMetadata(updated_at: now, expires_at: ttl.map { now.addingTimeInterval(Double($0)) }, rev: rev)
                changed = true
                return rev
            }
            let result: JSONValue
            switch call {
            case .get(let key): return state[key] ?? .null
            case .list(let prefix):
                let keys = try state.keys.sorted().filter { $0.hasPrefix(prefix) }.compactMap { try listRow($0) }
                return .object(["keys": .array(keys), "total_bytes": .int(Int64(try encoded().count)), "limit_bytes": .int(Int64(notebookTotalBytes))])
            case .page:
                let packet = state.removeValue(forKey: "part") ?? .null
                guard packet == .null || packet.objectValue != nil else {
                    throw SenseFailure(code: "bad_notebook", message: "The part's notebook page packet must be an object.")
                }
                var facts = packet.objectValue ?? [:]
                if !state.isEmpty { facts["notebook"] = .object(state) }
                return .object(facts)
            case .set(let key, let value, let ttl, let legacy):
                _ = try set(key, value, ttl: ttl, legacy: legacy)
                result = .null
            case .delete(let key):
                if state.removeValue(forKey: key) != nil { changed = true }
                metadata.removeValue(forKey: key)
                result = .null
            case .cas(let key, let expected, let value, let ttl):
                guard (state[key] ?? .null) == expected else {
                    return .object(["swapped": .bool(false), "current_rev": state[key].map { _ in .int(metadata[key]?.rev ?? 0) } ?? .null])
                }
                result = .object(["swapped": .bool(true), "rev": .int(try set(key, value, ttl: ttl, legacy: false))])
            }
            guard changed else { return result }
            let data = try encoded()
            guard data.count <= notebookTotalBytes, state.count <= keyLimit else {
                throw SenseFailure(code: "state_limit", message: "Notebook is limited to 2 MiB and 256 keys.")
            }
            let delta: JSONValue? = if let before {
                .object(["key": .string(before.key), "before": before.row, "after": try listRow(before.key) ?? .null,
                         "bytes": .int(Int64(data.count - before.bytes))])
            } else { nil }
            do { try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: notebook) }
            catch {
                // The durable write can fail after rename.
                writeUncertain()
                throw error
            }
            writing()
            if let delta { listChange?(delta) }
            return result
        }
    }
}
extension JSONValue {
    var integer: Int64? { if case .int = self { integerValue } else { nil } }
}
