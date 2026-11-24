import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `AbilityStorage.swift` | Checked identity-matched file/state encoding and recovery validation |
extension AbilityStore {
    /// Recovery restores accounting only. Counter relationships still belong to validateCounters.
    public static let recoveryStateSchema: JSONValue = {
        let count = ToolSchema.intSchema(minimum: 0)
        func object(_ properties: [String: JSONValue], open: Bool = true, required: [String] = []) -> JSONValue {
            .object(["type": .string("object"), "properties": .object(properties), "additionalProperties": .bool(open),
                "required": .array(required.map(JSONValue.string))])
        }
        func map(_ value: JSONValue) -> JSONValue {
            .object(["type": .string("object"), "additionalProperties": value])
        }
        let operation = object(Dictionary(uniqueKeysWithValues:
            ["completed", "cut", "network", "error", "refused", "last_run"].map { ($0, count) }))
        var evidence = Dictionary(uniqueKeysWithValues: (["count", "reads"] + runOutcomes).map { ($0, count) })
        evidence["operations"] = map(operation)
        evidence["rounds"] = map(count); evidence["surprise"] = map(count)
        evidence["hours"] = map(map(count)); evidence["first_seen"] = .object(["type": .string("string")])
        evidence["surprise_through"] = .object(["type": .string("string")])
        var row = Dictionary(uniqueKeysWithValues: statistics.map { ($0, JSONValue.object([
            "description": .string("Retained accounting metadata; preserve its recovered JSON unchanged.")])) })
        for name in ["uses", "useCount", "corrections"] { row[name] = count }
        row["runs"] = object(["versions": map(object(evidence, required: ["count"]))])
        let text: JSONValue = .object(["type": .string("string")])
        let opened = ["version", "kept", "why", "opened"]
        row["trial"] = object(Dictionary(uniqueKeysWithValues: opened.map { ($0, text) }), required: opened)
        var closed = Dictionary(uniqueKeysWithValues: (opened + ["closed", "set_aside_why"]).map { ($0, text) })
        closed["verdict"] = .object(["enum": .array(trialVerdicts.sorted().map(JSONValue.string))])
        closed["by"] = .object(["enum": .array(trialDeciders.sorted().map(JSONValue.string))])
        row["trials"] = .object(["type": .string("array"), "maxItems": .int(Int64(CapabilityLifecycle.inputLimit)),
            "items": object(closed, required: opened + ["closed", "verdict", "by"])])
        var result = map(object(row, open: false)).objectValue!
        result["description"] = .string("""
            Ability id → recovered accounting row. Only accounting keys are admitted; preserve readable rows exactly. Nonnegative counters must agree: \
            outcomes sum to count, reads ≤ ok, operation and hour totals ≤ count. Authority stays in each ability file.
            """)
        return .object(result)
    }()

    func readFile(id: String, slot: Slot) throws -> File? {
        _ = try Self.fileName(id: id, slot: slot, pathExtension: "js")
        while true {
            let reading = try fileSnapshot()
            do { return try reading.value.file(id: id, slot: slot, in: self) }
            catch {
                if try folderRevision() == reading.revision { throw error }
            }
        }
    }
    static func checkPath(_ url: URL) throws {
        var parent = url
        while parent.path != "/" {
            try checkItem(parent)
            parent.deleteLastPathComponent()
        }
    }
    static func checkItem(_ url: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw failure(
                "Ability storage cannot follow symbolic links: \(url.path).") }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { }
    }
    /// Inventory reports each unreadable file separately; only a folder read failure prevents the whole catalog.
    public struct Inventory: Sendable {
        public struct Damaged: Sendable {
            public let id: String
            public let slot: Slot
            public let failure: ToolFailureError
            fileprivate let revision: String?
        }
        public var files: [(file: File, slot: Slot)] = []
        public var damaged: [Damaged] = []
    }
    struct FileSnapshot: Sendable {
        let inventory: Inventory
        let current: [File]
        let selected: [File]
        let retained: [Slot: [String: File]]
        let guidanceExclusions: Set<String>
        let partRows: [String: Projection<RecordProjection>]
        let registries = Dictionary(uniqueKeysWithValues: ([Kind?.none] + Kind.allCases.map(Optional.some)).map {
            ($0, Projection<Registry>())
        })
        let senseRecords = Projection<[FileSenseRegistry.Entry]>()
        var hasCheckedSources: Bool { inventory.damaged.allSatisfy { $0.revision != nil } }

        func file(id: String, slot: Slot, in store: AbilityStore) throws -> File? {
            func matches(_ other: String, ext: String) throws -> Bool {
                if other == id { return true }
                guard other.caseInsensitiveCompare(id) == .orderedSame else { return false }
                guard let requested = try AbilityStore.fileStatus(store.path(id: id, slot: slot, pathExtension: ext)),
                      let retained = try AbilityStore.fileStatus(store.path(id: other, slot: slot, pathExtension: ext)) else { return false }
                return requested.st_dev == retained.st_dev && requested.st_ino == retained.st_ino
            }
            let file = try retained[slot]?[id] ?? retained[slot]?.values.first { try matches($0.id, ext: $0.pathExtension) }
            for damage in inventory.damaged where damage.slot == slot {
                guard let path = damage.failure.owner else { continue }
                let ext = URL(fileURLWithPath: path).pathExtension
                guard ["js", "md"].contains(ext), try matches(damage.id, ext: ext) else { continue }
                let other = try store.path(id: id, slot: slot, pathExtension: ext == "md" ? "js" : "md")
                if try AbilityStore.fileStatus(other) != nil {
                    throw ToolFailureError("Ability \(id) has both JavaScript and Markdown files in slot \(slot.rawValue).", effects: .none,
                        owner: store.root.path, nextCall: ToolFailureError.call("app", ["action": .string("files.list"),
                            "args": .object(["path": .string(store.root.path)])]), code: "ability_id_collision",
                        instruction: "Inspect both files; resolve their identity collision while preserving both bodies and retained versions.", recovery: .inspect)
                }
                throw damage.failure
            }
            if let file { try VerifiedPath.confirmNoSymlink(store.path(id: id, slot: slot, pathExtension: file.pathExtension)) }
            return file
        }
    }

    func fileSnapshot() throws -> Stamped<[EntryStamp], FileSnapshot> {
        try checked(\.files, stamp: folderRevision, publishable: { _, files in files.hasCheckedSources }) { stamps in
            let inventory = try allFiles(stamps)
            let retained = Dictionary(grouping: inventory.files, by: \.slot).mapValues {
                Dictionary(uniqueKeysWithValues: $0.map { ($0.file.id, $0.file) })
            }
            let current = inventory.files.filter { $0.slot == .current }.map(\.file).sorted { $0.id < $1.id }
            let ids = Set(current.map { $0.id.lowercased() })
            let proposals = inventory.files.filter { $0.slot == .next && !ids.contains($0.file.id.lowercased()) }.map(\.file)
            let selected = (current + proposals).sorted { $0.id < $1.id }
            return FileSnapshot(inventory: inventory, current: current, selected: selected, retained: retained,
                guidanceExclusions: Set(selected.filter { $0.kind == .part }.map { $0.id.lowercased() }),
                partRows: Dictionary(uniqueKeysWithValues: selected.filter { $0.kind == .part && Self.isPublished($0) }
                    .map { ($0.id, Projection<RecordProjection>()) }))
        }
    }

    package func guidanceExclusions() throws -> Set<String> { try fileSnapshot().value.guidanceExclusions }

    private func allFiles(_ stamps: [EntryStamp]) throws -> Inventory {
        try Self.checkPath(root)
        if try Self.fileStatus(root) != nil { try VerifiedPath.confirmNoSymlink(root) }
        var inventory = Inventory(), seen: Set<String> = []
        for entry in stamps {
            let url = root.appendingPathComponent(entry.name)
            let stem = url.deletingPathExtension().lastPathComponent
            let slot: Slot = stem.hasSuffix(".prev") ? .previous : stem.hasSuffix(".next") ? .next : .current
            var verified: String?
            do {
                guard ["js", "md"].contains(url.pathExtension) else {
                    if entry.error == nil { verified = entry.stamp }
                    throw Self.failure("Unexpected ability storage: \(url.lastPathComponent).")
                }
                if let error = entry.error {
                    try VerifiedPath.confirmNoSymlink(url)
                    throw NSError(domain: NSPOSIXErrorDomain, code: error)
                }
                try Self.checkItem(url)
                let (bytes, stamp) = try Self.checkedBytes(url)
                guard stamp == entry.stamp else { throw ReadingChanged() }
                verified = stamp
                let file = try Self.decodeContents(bytes, at: url)
                guard try Self.fileName(id: file.id, slot: slot, pathExtension: file.pathExtension) == url.lastPathComponent else { throw Self.failure(
                    "Ability header id differs from its file: \(url.lastPathComponent).") }
                guard seen.insert("\(slot.rawValue):\(file.id.lowercased())").inserted else {
                    throw ToolFailureError("Ability id collision: \(file.id) in slot \(slot.rawValue), including \(url.lastPathComponent).", effects: .none,
                        code: "ability_id_collision",
                            instruction: "Inspect both retained sources and restore their correct ids without discarding either body.", recovery: .inspect)
                }
                inventory.files.append((file, slot))
            } catch is ReadingChanged { throw ReadingChanged() }
            catch {
                if verified == nil, let status = try? Self.fileStatus(url), Self.fileRevision(status) == entry.stamp,
                   status.st_mode & mode_t(S_IFMT) != mode_t(S_IFREG) { verified = entry.stamp }
                let id = slot == .current ? stem : String(stem.dropLast(5))
                inventory.damaged.append(.init(id: id, slot: slot, failure: sourceFailure(url, error), revision: verified))
            }
        }
        return inventory
    }
    func writeFile(_ file: File, slot: Slot, writing: () -> Void = {}) throws {
        let destination = try path(id: file.id, slot: slot, pathExtension: file.pathExtension)
        let data = try Self.encode(file)
        writing()
        let other = try path(id: file.id, slot: slot, pathExtension: file.pathExtension == "js" ? "md" : "js")
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: destination)
        if FileManager.default.fileExists(atPath: other.path) { try FileManager.default.removeItem(at: other) }
        _ = try? fileSnapshot()
        if slot == .current { Self.DidChange(path: root.appendingPathComponent(file.id).path).post() }
    }
    package static func encode(_ file: File) throws -> Data {
        var header = file.metadata
        header.merge(try partHeader(header)) { _, value in value }
        if var row = header["record"]?.objectValue {
            row.removeValue(forKey: "permissions")
            for key in partKeys.union(file.kind == .sense ? ["kind"] : ["kind", "version"]) { row.removeValue(forKey: key) }
            header["record"] = .object(row)
        }
        try validate(file, header: header)
        header["id"] = .string(file.id); header["kind"] = .string(file.kind.rawValue)
        let json = try JSONValue.object(header).serialize(pretty: true)
        let start = file.pathExtension == "md" ? "<!-- NativeAgent ability\n" : "/* NativeAgent ability\n"
        let end = file.pathExtension == "md" ? "\n-->\n" : "\n*/\n"
        return Data((start + json + end + file.body).utf8)
    }
    public static func decode(_ url: URL) throws -> File {
        try decodeContents(checkedBytes(url).0, at: url)
    }
    private static func checkedBytes(_ url: URL) throws -> (Data, String) {
        let descriptor = try VerifiedPath.open(url, flags: O_RDONLY | O_NONBLOCK)
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard unsafe fstat(descriptor, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw failure("Unreadable ability file: \(url.lastPathComponent).") }
        let before = fileRevision(info)
        let bytes = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        guard unsafe fstat(descriptor, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard fileRevision(info) == before else { throw ReadingChanged() }
        return (bytes, before)
    }
    private static func decodeContents(_ data: Data, at url: URL) throws -> File {
        guard let text = String(data: data, encoding: .utf8) else { throw failure("Unreadable ability file: \(url.lastPathComponent).") }
        let start = url.pathExtension == "md" ? "<!-- NativeAgent ability\n" : "/* NativeAgent ability\n"
        let end = url.pathExtension == "md" ? "\n-->\n" : "\n*/\n"
        guard text.hasPrefix(start), let boundary = text.range(of: end, range: text.index(text.startIndex, offsetBy: start.count)..<text.endIndex) else {
            throw headerFailure("envelope", accepted: "a NativeAgent ability comment before the body", detail: """
                Invalid ability header comment: \(url.lastPathComponent). Restore its delimiters from retained evidence.
                """)
        }
        let value: JSONValue
        do { value = try JSONValue.parse(Data(text[text.index(text.startIndex, offsetBy: start.count)..<boundary.lowerBound].utf8)) }
        catch { throw headerFailure("json", accepted: "a JSON object inside the header comment",
            detail: "Invalid ability header JSON in \(url.lastPathComponent): \(error.localizedDescription)") }
        guard case .object(var header) = value else { throw headerFailure("json", accepted: "a JSON object inside the header comment") }
        guard let id = header.removeValue(forKey: "id")?.stringValue else { throw headerFailure("id", accepted: "the retained ability's string id") }
        guard let name = header.removeValue(forKey: "kind")?.stringValue, let kind = Kind(rawValue: name) else {
            throw headerFailure("kind", accepted: "ability, sense or turn")
        }
        guard header["reach"]?.objectValue != nil else {
            throw headerFailure("reach", accepted: "the current reach object", detail: """
                Ability \(url.lastPathComponent) has no current reach declaration. Preserve its bytes and re-author it through ability.save or sense.make \
                from its authenticated source.
                """)
        }
        let file = try File(id: id, kind: kind, metadata: header, body: String(text[boundary.upperBound...]), pathExtension: url.pathExtension)
        try validate(file, header: file.metadata)
        return file
    }
    private static func validate(_ file: File, header: [String: JSONValue]) throws {
        if let key = header.keys.sorted().first(where: { !partKeys.union(["id", "kind", "version", "record", "candidate", "proof"]).contains($0) }) {
            throw headerFailure(key, accepted: partKeys.union(["id", "kind", "version", "record", "candidate", "proof"]).sorted().joined(separator: ", "),
                detail: "Unknown ability header key: \(key). Remove it or use an accepted key.", code: "unknown_ability_header_key")
        }
        _ = try partHeader(header)
        guard file.body.utf8.count <= sourceLimit else { throw failure("Part source exceeds \(sourceLimit) bytes.") }
    }
    func stateRevision() throws -> String {
        let url = root.appendingPathComponent("state.json")
        let revision = try Self.fileRevision(url)
        do {
            if revision == "missing" { try Self.checkPath(url) }
            else { try VerifiedPath.confirmNoSymlink(url) }
        } catch { throw repairFailure(source: url, detail: error.localizedDescription) }
        return revision
    }
    func readState() throws -> [String: JSONValue] {
        try accountingSnapshot().value.rows
    }
    struct Accounting: Sendable {
        let rows: [String: JSONValue]
        private let redacted = Projection<[String: JSONValue]>()

        init(rows: [String: JSONValue]) { self.rows = rows }

        func redactedRows() throws -> [String: JSONValue] {
            try redacted.read {
                guard case .object(let values) = AbilityStore.redactedEvidence(.object(rows)) else {
                    throw AbilityStore.failure("Redacted ability accounting must remain an object.")
                }
                return values.mapValues(AbilityStore.publishedStatistics)
            }
        }
    }
    func accountingSnapshot() throws -> Stamped<String, Accounting> {
        try checked(\.accounting, stamp: stateRevision) { Accounting(rows: try loadState($0)) }
    }
    private func loadState(_ revision: String) throws -> [String: JSONValue] {
        guard revision != "missing" else { return [:] }
        let url = root.appendingPathComponent("state.json")
        let bytes: Data
        do {
            let read = try Self.checkedBytes(url)
            guard read.1 == revision else { throw ReadingChanged() }
            bytes = read.0
        } catch is ReadingChanged { throw ReadingChanged() }
        catch { throw repairFailure(source: url, detail: error.localizedDescription) }
        do {
            return try Self.decodeState(bytes)
        }
        catch {
            throw ToolFailureError("""
                Ability run state is unreadable: \(error.localizedDescription) Read abilities/state.json with files.read, recover its state object without \
                inventing run evidence, then pass state to abilities.restore_state. Saved bytes were preserved.
                """, effects: .none,
                owner: "abilities/state.json", nextCall: ToolFailureError.call("app", ["action": .string("files.read"), "args": .object(["path": .string(url
                    .path)])]),
                instruction: """
                    After reconstructing state, call abilities.restore_state with state and expected_digest: \
                    \(SHA256Hex.of(bytes)).
                    """)
        }
    }
    static func decodeState(_ bytes: Data) throws -> [String: JSONValue] {
        guard case .object(let values) = try JSONValue.parse(bytes), values.values.allSatisfy({ $0.objectValue != nil }) else {
            throw failure("Ability run state must be an object of accounting rows.")
        }
        try validateCounters(values)
        return values
    }
    private static func counter(_ value: JSONValue?, field: String) throws -> Int64 {
        guard let value else { return 0 }
        guard case .int(let number) = value, number >= 0 else { throw failure("Invalid accounting counter at \(field).") }
        return number
    }
    static func increment(_ value: JSONValue?, field: String) throws -> Int64 {
        let (next, overflow) = try counter(value, field: field).addingReportingOverflow(1)
        guard !overflow else { throw failure("Accounting counter overflow at \(field); stored bytes preserved.") }
        return next
    }
    static func accountingObject(_ value: JSONValue?, field: String) throws -> [String: JSONValue] {
        guard let value else { return [:] }
        guard let fields = value.objectValue else { throw failure("Invalid accounting object at \(field).") }
        return fields
    }
    private static let runOutcomes = ["ok", "cut", "network", "error", "refused"]
    static func outcomeCount(_ evidence: [String: JSONValue], at path: String, names: [String] = runOutcomes) throws -> Int64 {
        var total: Int64 = 0
        for name in names {
            let n = try counter(evidence[name], field: path + "." + name)
            let (sum, overflow) = total.addingReportingOverflow(n)
            guard !overflow else { throw failure("Accounting counter overflow at \(path).\(name).") }
            total = sum
        }
        return total
    }
    static func validateCounters(_ values: [String: JSONValue]) throws {
        for (id, value) in values {
            let field = "state.\(id)"
            let row = try accountingObject(value, field: field)
            for name in ["uses", "useCount", "corrections"] { _ = try counter(row[name], field: field + "." + name) }
            let runs = try accountingObject(row["runs"], field: field + ".runs")
            for (version, value) in try accountingObject(runs["versions"], field: field + ".runs.versions") {
                guard let evidence = value.objectValue else { throw failure("Invalid accounting row at \(field).runs.versions.\(version).") }
                let path = field + ".runs.versions." + version
                let count = try counter(evidence["count"], field: path + ".count")
                let reads = try counter(evidence["reads"], field: path + ".reads")
                guard reads <= (try counter(evidence["ok"], field: path + ".ok")) else { throw failure("Invalid accounting relationship at \(path).reads.") }
                _ = try tallyCounters(evidence, at: path)
                if let seen = evidence["first_seen"], seen.stringValue.flatMap(NativeTimestampFormat.parseISO8601) == nil {
                    throw failure("Invalid accounting time at \(path).first_seen.")
                }
                if let end = evidence["surprise_through"], end.stringValue.flatMap(NativeTimestampFormat.parseISO8601) == nil {
                    throw failure("Invalid accounting time at \(path).surprise_through.")
                }
                for (key, value) in try accountingObject(evidence["operations"], field: path + ".operations") {
                    guard let operation = value.objectValue else { throw failure("Invalid accounting scope at \(path).operations.\(key).") }
                    let total = try outcomeCount(operation, at: path + ".operations.\(key)", names: ["completed", "cut", "network", "error", "refused"])
                    guard total <= count else { throw failure("Invalid accounting total at \(path).operations.\(key).") }
                    for name in ["completed", "cut", "network", "error", "refused", "last_run"] {
                        let n = try counter(operation[name], field: path + ".operations.\(key)." + name)
                        guard n <= count else { throw failure("Invalid accounting relationship at \(path).operations.\(key).\(name).") }
                    }
                }
            }
        }
    }

    /// The trial reader and store admission share the exact counter, hour and histogram laws. No multiplication in integer space.
    static func tallyCounters(_ evidence: [String: JSONValue], at path: String) throws -> (uses: Int, misses: Int, surprises: Int, rounds: [Int: Int]) {
        func add(_ a: Int64, _ b: Int64, _ field: String) throws -> Int64 {
            let (sum, overflow) = a.addingReportingOverflow(b)
            guard !overflow else { throw failure("Accounting counter overflow at \(field).") }
            return sum
        }
        guard evidence["count"] != nil else { throw failure("Missing accounting counter at \(path).count.") }
        let uses = try counter(evidence["count"], field: path + ".count")
        guard try outcomeCount(evidence, at: path) == uses else { throw failure("Accounting outcomes disagree with \(path).count.") }
        var hours: Int64 = 0, hourOutcomes: [String: Int64] = [:]
        for (hour, value) in try accountingObject(evidence["hours"], field: path + ".hours") {
            let hourPath = path + ".hours." + hour
            let bucket = try accountingObject(value, field: hourPath)
            guard NativeTimestampFormat.parseISO8601(hour + ":00:00Z") != nil,
                  Set(bucket.keys).isSubset(of: Set(runOutcomes)) else { throw failure("Invalid accounting hour at \(hourPath).") }
            hours = try add(hours, outcomeCount(bucket, at: hourPath), path + ".hours")
            guard hours <= uses else { throw failure("Accounting hour totals exceed \(path).count.") }
            for outcome in runOutcomes {
                let total = try add(hourOutcomes[outcome] ?? 0, counter(bucket[outcome], field: hourPath + "." + outcome), hourPath + "." + outcome)
                guard total <= (try counter(evidence[outcome], field: path + "." + outcome)) else {
                    throw failure("Accounting hour outcomes exceed \(path).\(outcome).")
                }
                hourOutcomes[outcome] = total
            }
        }
        let misses = try outcomeCount(evidence, at: path, names: ["error", "cut"])
        guard misses <= uses else { throw failure("Accounting misses exceed \(path).count.") }
        var surprises = misses
        for (kind, value) in try accountingObject(evidence["surprise"], field: path + ".surprise") {
            guard surpriseKinds.contains(kind) else { throw failure("Unknown accounting surprise at \(path).surprise.\(kind).") }
            surprises = try add(surprises, counter(value, field: path + ".surprise." + kind), path + ".surprise")
        }
        var rounds: [Int: Int] = [:], tries: Int64 = 0
        for (key, value) in try accountingObject(evidence["rounds"], field: path + ".rounds") {
            guard let n = Int(key), n >= 0, String(n) == key else { throw failure("Invalid accounting round bucket at \(path).rounds.\(key).") }
            let count = try counter(value, field: path + ".rounds." + key)
            tries = try add(tries, count, path + ".rounds")
            guard tries <= uses, let count = Int(exactly: count) else { throw failure("Accounting round uses exceed \(path).count.") }
            rounds[n] = count
        }
        guard let uses = Int(exactly: uses), let misses = Int(exactly: misses), let surprises = Int(exactly: surprises) else {
            throw failure("Accounting tally exceeds the integer range at \(path).")
        }
        return (uses, misses, surprises, rounds)
    }
}
