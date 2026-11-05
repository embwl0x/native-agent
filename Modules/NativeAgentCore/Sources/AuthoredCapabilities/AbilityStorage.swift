import CryptoKit
import Experiences
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
        var row = Dictionary(uniqueKeysWithValues: statistics.map { ($0, JSONValue.object([
            "description": .string("Retained accounting metadata; preserve its recovered JSON unchanged.")])) })
        for name in ["uses", "useCount", "corrections"] { row[name] = count }
        row["runs"] = object(["versions": map(object(evidence, required: ["count"]))])
        var result = map(object(row, open: false)).objectValue!
        result["description"] = .string("""
            Ability id → recovered accounting row. Only accounting keys are admitted; preserve readable rows exactly. Nonnegative counters must agree: \
            outcomes sum to count, reads ≤ ok, operation totals ≤ count. Authority stays in each ability file.
            """)
        return .object(result)
    }()

    func readFile(id: String, slot: Slot) throws -> File? {
        let paths = try ["js", "md"].map { try path(id: id, slot: slot, pathExtension: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard paths.count <= 1 else {
            throw ToolFailureError("Ability \(id) has both JavaScript and Markdown files in slot \(slot.rawValue).", effects: .none,
                owner: root.path, nextCall: ToolFailureError.call("app", ["action": .string("files.list"), "args": .object(["path": .string(root.path)])]),
                code: "ability_id_collision", instruction: """
                    Inspect both files; resolve their identity collision while preserving both bodies and retained versions.
                    """, recovery: .inspect)
        }
        guard let source = paths.first else { return nil }
        do { return try Self.decode(source) }
        catch { throw sourceFailure(source, error) }
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
        public struct Damaged: Sendable { public let id: String; public let slot: Slot; public let failure: ToolFailureError }
        public var files: [(file: File, slot: Slot)] = []
        public var damaged: [Damaged] = []
    }
    func allFiles() throws -> Inventory {
        guard FileManager.default.fileExists(atPath: root.path) else { return Inventory() }
        try VerifiedPath.confirmNoSymlink(root)
        var inventory = Inventory(), seen: Set<String> = []
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).sorted(
            by: { $0.path < $1.path }) {
            if ["state.json", ".old-layout"].contains(url.lastPathComponent) { continue }
            let stem = url.deletingPathExtension().lastPathComponent
            let slot: Slot = stem.hasSuffix(".prev") ? .previous : stem.hasSuffix(".next") ? .next : .current
            do {
                guard ["js", "md"].contains(url.pathExtension) else { throw Self.failure("Unexpected ability storage: \(url.lastPathComponent).") }
                let status: stat?
                do { status = try Self.fileStatus(url) }
                catch {
                    // Preserve checked-open failure evidence before consulting lstat.
                    try VerifiedPath.confirmNoSymlink(url)
                    throw error
                }
                let file = try Self.decode(url, status: status)
                guard try Self.fileName(id: file.id, slot: slot, pathExtension: file.pathExtension) == url.lastPathComponent else { throw Self.failure(
                    "Ability header id differs from its file: \(url.lastPathComponent).") }
                guard seen.insert("\(slot.rawValue):\(file.id.lowercased())").inserted else {
                    throw ToolFailureError("Ability id collision: \(file.id) in slot \(slot.rawValue), including \(url.lastPathComponent).", effects: .none,
                        code: "ability_id_collision",
                            instruction: "Inspect both retained sources and restore their correct ids without discarding either body.", recovery: .inspect)
                }
                inventory.files.append((file, slot))
            } catch {
                let id = slot == .current ? stem : String(stem.dropLast(5))
                inventory.damaged.append(.init(id: id, slot: slot, failure: sourceFailure(url, error)))
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
        let revision = try Self.fileRevision(destination)
        if revision != "missing" { Self.decoded[destination.path] = (revision, try Self.decodeContents(data, at: destination)) }
        if FileManager.default.fileExists(atPath: other.path) { try FileManager.default.removeItem(at: other) }
        Self.decoded.removeValue(forKey: other.path)
        if slot == .current { NotificationCenter.default.post(name: Self.didChange, object: root.appendingPathComponent(file.id).path) }
    }
    static func encode(_ file: File) throws -> Data {
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
    /// Only a successful decode is kept, under the catalog's exact file identity.
    public static func decode(_ url: URL) throws -> File {
        try VerifiedPath.confirmNoSymlink(url)
        return try decode(url, status: fileStatus(url), pathChecked: true)
    }
    private static func decode(_ url: URL, status: stat?, pathChecked: Bool = false) throws -> File {
        guard let status else { throw VerifiedPath.Failure.notFound }
        let type = status.st_mode & mode_t(S_IFMT)
        guard type != mode_t(S_IFLNK) else { throw VerifiedPath.Failure.symlinkComponent(url.lastPathComponent) }
        let revision = fileRevision(status)
        if let known = withLock({ decoded[url.path] }), known.revision == revision { return known.file }
        // Cache misses retain checked-open errors, including unreadable source failures.
        if !pathChecked { try VerifiedPath.confirmNoSymlink(url) }
        guard type == mode_t(S_IFREG) else { throw failure("Unreadable ability file: \(url.lastPathComponent).") }
        let file = try decodeContents(Data(contentsOf: url), at: url)
        withLock { decoded[url.path] = (revision, file) }
        return file
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
    func readState() throws -> [String: JSONValue] {
        let url = root.appendingPathComponent("state.json")
        let revision = try Self.fileRevision(url)
        guard revision != "missing" else {
            Self.stateMemo.removeValue(forKey: root.path)
            Self.redactedAccounting.removeValue(forKey: root.path)
            return [:]
        }
        if let known = Self.stateMemo[root.path], known.revision == revision {
            do { try VerifiedPath.confirmNoSymlink(root) }
            catch { throw repairFailure(source: url, detail: error.localizedDescription) }
            return known.rows
        }
        Self.stateMemo.removeValue(forKey: root.path)
        Self.redactedAccounting.removeValue(forKey: root.path)
        let bytes: Data
        do { try VerifiedPath.confirmNoSymlink(url); bytes = try Data(contentsOf: url) }
        catch { throw repairFailure(source: url, detail: error.localizedDescription) }
        do {
            let rows = try Self.decodeState(bytes)
            Self.stateMemo[root.path] = (revision, rows)
            return rows
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
                    \(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()).
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
    private static func accountingObject(_ value: JSONValue?, field: String) throws -> [String: JSONValue] {
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
                guard evidence["count"] != nil else { throw failure("Missing accounting counter at \(path).count.") }
                let count = try counter(evidence["count"], field: path + ".count")
                let total = try outcomeCount(evidence, at: path)
                if total != count { throw failure("Accounting outcomes disagree with \(path).count.") }
                let reads = try counter(evidence["reads"], field: path + ".reads")
                guard reads <= (try counter(evidence["ok"], field: path + ".ok")) else { throw failure("Invalid accounting relationship at \(path).reads.") }
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
}
