import CryptoKit
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared

/// The files are the catalog. Accounting is the only separate document.
public struct AbilityStore: Sendable {
    @TaskLocal public static var fileReach: (root: URL, write: Bool)?

    public static func fileReachAllows(_ path: URL, write: Bool = false) -> Bool {
        guard let reach = fileReach, !write || reach.write else { return false }
        let root = reach.root.standardizedFileURL.resolvingSymlinksInPath().path
        let target = path.standardizedFileURL.resolvingSymlinksInPath().path
        return target == root || target.hasPrefix(root + "/")
    }

    public enum Kind: String, CaseIterable, Sendable { case tool, skill, sense, turn }
    public static let sourceLimit = 512 * 1024
    public static let didChange = Notification.Name("NativeAgent.abilityDidChange")
    /// A wake source fired. The stem delivers it to each part whose `wake`
    /// lists the name (only `part`, when one is named), as that run's input.
    /// A payload carrying another agent's words names it as `agent`.
    public static let signalled = Notification.Name("NativeAgent.partSignalled")
    public static let partKeys: Set<String> = ["reach", "wake", "face", "resident", "learned", "choices"]

    public static func knownReach(_ name: String) -> Bool {
        if ["app_data_read", "app_data_write", "network_localhost", "network_public", "network", "shell", "computer_files", "arbitrary_file_write", "model", "calendar", "reminders", "contacts"].contains(name) { return true }
        let pieces = name.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        return pieces.count == 2 && ["app_read", "app_write", "connector"].contains(pieces[0])
            && !pieces[1].isEmpty && pieces[1].allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }

    /// The same header for every part. Legacy authority is projected, never rewritten on read.
    public static func partHeader(_ fields: [String: JSONValue]) throws -> [String: JSONValue] {
        var header = fields.filter { partKeys.contains($0.key) }
        var reach = header["reach"] ?? .object([:])
        guard case .object(var scope) = reach else { throw failure("reach is {capabilities, readPaths, hosts, apps}.") }
        if scope["capabilities"] == nil { scope["capabilities"] = fields["permissions"] ?? .array([]) }
        for key in ["capabilities", "readPaths", "hosts", "apps"] {
            if scope[key] == nil { scope[key] = .array([]) }
            guard case .array(let values)? = scope[key], values.allSatisfy({ if case .string(let text) = $0 { return !text.isEmpty }; return false }) else {
                throw failure("reach.\(key) must be an array of nonempty strings.")
            }
            if key == "capabilities", let invalid = values.compactMap(\.stringValue).first(where: { !knownReach($0) }) {
                throw failure("Unknown reach name: \(invalid).")
            }
        }
        if let key = scope.keys.sorted().first(where: { !["capabilities", "readPaths", "hosts", "apps"].contains($0) }) { throw failure("Unknown reach key: \(key).") }
        header["reach"] = .object(scope)
        let wake = header["wake"] ?? .array([])
        guard case .array(let signals) = wake else { throw failure("wake must be an array of signal names.") }
        for signal in signals {
            guard case .string(let name) = signal else { throw failure("wake must contain strings.") }
            let valid = ["app.installed", "turn.ended"].contains(name)
                || ["schedule:", "file.changed:", "message.arrived:"].contains { prefix in
                    name.hasPrefix(prefix) && !name.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            guard valid else { throw failure("Unknown wake name: \(name). Use schedule:<cron>, app.installed, file.changed:<path>, turn.ended or message.arrived:<transport>.") }
        }
        header["wake"] = wake
        guard case .object(let face) = header["face"] ?? .object([:]) else { throw failure("face is {page?: string, action?: string}.") }
        if let key = face.keys.sorted().first(where: { !["page", "action"].contains($0) }) { throw failure("Unknown face key: \(key).") }
        if let action = face["action"], action.stringValue?.range(of: "^[a-z][a-z0-9_]*[.][a-z][a-z0-9_.]*$", options: .regularExpression) == nil {
            throw failure("face.action must be a lowercase door action id, such as weather.forecast.")
        }
        if let page = face["page"] {
            guard case .string(let name) = page, AppDoorNames.partPages.contains(name) else {
                throw failure("Unknown face.page \(page). Pages: \(AppDoorNames.partPages.sorted().joined(separator: ", ")).")
            }
        }
        header["face"] = .object(face)
        guard case .bool = header["resident"] ?? .bool(false) else { throw failure("resident must be a Boolean.") }
        header["resident"] = header["resident"] ?? .bool(false)
        return header
    }
    public enum Slot: String, CaseIterable, Sendable { case current, previous, next }
    public struct File: Sendable, Equatable {
        public var id: String
        public var kind: Kind
        public var metadata: [String: JSONValue]
        public var body: String
        public var pathExtension: String
        public init(id: String, kind: Kind, metadata: [String: JSONValue], body: String, pathExtension: String) {
            self.id = id; self.kind = kind; self.metadata = metadata; self.body = body; self.pathExtension = pathExtension
            if self.metadata["version"] == nil { self.metadata["version"] = .int(1) }
            let candidate = metadata["candidate"]?.objectValue ?? [:]
            let manifest = candidate["manifest"]?.objectValue ?? [:]
            let record = metadata["record"]?.objectValue ?? manifest["record"]?.objectValue ?? manifest
            var properties = record.merging(manifest.filter { AbilityStore.partKeys.contains($0.key) }) { _, value in value }
                .merging(metadata) { _, value in value }
            let program = candidate["program"]?.objectValue ?? [:]
            if properties["reach"] == nil { properties["reach"] = program["reach"] }
            if properties["permissions"] == nil { properties["permissions"] = program["permissions"] }
            var reach = properties["reach"] ?? .object([:])
            if case .object(var scope) = reach {
                scope["capabilities"] = scope["capabilities"] ?? properties["permissions"] ?? .array([])
                for key in ["readPaths", "hosts", "apps"] { scope[key] = scope[key] ?? .array([]) }
                reach = .object(scope)
            }
            properties["reach"] = reach
            properties["wake"] = properties["wake"] ?? .array([])
            properties["face"] = properties["face"] ?? .object([:])
            properties["resident"] = properties["resident"] ?? .bool(false)
            self.metadata.merge(properties.filter { AbilityStore.partKeys.contains($0.key) }) { _, value in value }
            self.metadata.removeValue(forKey: "permissions")
            if var row = self.metadata["record"]?.objectValue {
                row.removeValue(forKey: "permissions")
                for key in AbilityStore.partKeys { row.removeValue(forKey: key) }
                self.metadata["record"] = .object(row)
            }
        }
        public var part: [String: JSONValue] { metadata.filter { AbilityStore.partKeys.contains($0.key) } }
        public var record: [String: JSONValue]? {
            guard var row = metadata["record"]?.objectValue else { return nil }
            row.merge(part) { _, value in value }
            if kind == .tool { row["permissions"] = part["reach"]?.objectValue?["capabilities"] }
            if kind == .sense, let reach = part["reach"]?.objectValue { row["reach"] = .object(reach.filter { $0.key != "capabilities" }) }
            return row
        }
        public var partLine: String {
            id + " · " + ["reach", "wake", "face", "resident"].map {
                $0 + ":" + ((try? (metadata[$0] ?? .null).serialize(pretty: false)) ?? "null")
            }.joined(separator: " ")
        }
        /// What wakes it while it is on.
        public var wakes: [String] {
            let status = record?["status"]?.stringValue
            guard kind == .tool && status == "active" || kind == .skill && ["active", "installed"].contains(status)
                || kind == .sense && status == "on" else { return [] }
            return (metadata["wake"]?.arrayValue ?? []).compactMap(\.stringValue)
        }
        public var bodyDigest: String { SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined() }
    }

    public let dataRoot: URL
    public var root: URL { dataRoot.appendingPathComponent("abilities", isDirectory: true) }
    private static let lock = NSRecursiveLock()
    /// Each file as last decoded, by path, beside the size and modification time it had then.
    nonisolated(unsafe) private static var decoded: [String: (size: Int, modified: Date, file: File)] = [:]
    /// Bumped on every write this store makes, so what a reader derives from
    /// the store (the authored tool list) stays good until the store changes.
    nonisolated(unsafe) public private(set) static var generation: UInt64 = 0
    /// Roots whose parents this store operation already walked; cleared when the outermost operation ends.
    nonisolated(unsafe) private static var walked: Set<String> = []
    nonisolated(unsafe) private static var depth = 0
    nonisolated(unsafe) private static var arrival: (@Sendable (URL, String, String, [String]) -> Bool)?
    package static var healArrival: (@Sendable (URL, String, String, [String]) -> Bool)? {
        get { withLock { arrival } }
        set { withLock { arrival = newValue } }
    }
    nonisolated(unsafe) private static var voices: (@Sendable (File) -> [String])?
    package static var runVoices: (@Sendable (File) -> [String])? {
        get { withLock { voices } }
        set { withLock { voices = newValue } }
    }
    nonisolated(unsafe) private static var rollback: (@Sendable (URL, String, String) throws -> Void)?
    package static var skillRollback: (@Sendable (URL, String, String) throws -> Void)? {
        get { withLock { rollback } }
        set { withLock { rollback = newValue } }
    }
    private static let statistics: Set<String> = ["uses", "useCount", "lastUsedAt", "lastRunVersion", "lastRun",
        "lastCleanCode", "lastCleanVersion", "runs", "corrections", "unavailableReason"]
    private static let obsolete: Set<String> = ["versionOwners", "bodyPath", "activePath", "proposalPath", "quarantinePath",
        "rollbackCounterparts", "versionValidation", "builtIn", "registryPath", "sourceRoot", "versions", "previousVersion",
        "failuresInARow", "lastCleanDigest", "seeded"]
    private static let pending: Set<String> = ["candidateDigest", "candidatePrior", "candidateSelection", "candidateValidation", "candidateOrigin", "validationErrors"]

    public init(dataRoot: URL) { self.dataRoot = dataRoot.standardizedFileURL }
    /// Sources call this once they have done their own work; it never runs anything itself.
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
        guard !id.isEmpty, !id.hasPrefix("."), !id.contains("/"), !id.contains("\\"), !id.contains("\0"),
              !id.hasSuffix(".prev"), !id.hasSuffix(".next"), ["js", "md"].contains(pathExtension) else {
            throw Self.failure("Invalid ability file identity: \(id).")
        }
        let suffix = slot == .current ? "" : slot == .previous ? ".prev" : ".next"
        let url = root.appendingPathComponent(id + suffix + "." + pathExtension)
        // The root and its parents do not change within one store operation:
        // walked once per operation, the file itself every time.
        try Self.withLock {
            try Self.checkItem(url)
            if !Self.walked.contains(root.path) { try Self.checkPath(root); Self.walked.insert(root.path) }
        }
        return url
    }

    public func read(id: String, slot: Slot = .current) throws -> File? {
        try Self.withLock {
            try migrate()
            return try readFile(id: id, slot: slot)
        }
    }

    public func files(kind: Kind? = nil, includeProposals: Bool = true) throws -> [File] {
        try Self.withLock {
            try migrate()
            let selected = try allFiles().filter { $0.slot == .current }
            let ids = Set(selected.map { $0.file.id.lowercased() })
            let proposed = includeProposals ? try allFiles().filter { $0.slot == .next && !ids.contains($0.file.id.lowercased()) } : []
            return (selected + proposed).map(\.file).filter { kind == nil || $0.kind == kind }.sorted { $0.id < $1.id }
        }
    }

    /// `writing` runs at the write boundary: anything thrown before it left the disk untouched.
    public func write(_ file: File, slot: Slot = .current, writing: () -> Void = {}) throws {
        try Self.withLock {
            try migrate()
            try CapabilityLifecycle.requireWrite()
            let siblings = try allFiles().filter { $0.file.id.lowercased() == file.id.lowercased() }
            guard siblings.allSatisfy({ $0.file.id == file.id && $0.file.kind == file.kind }) else {
                throw Self.failure("Ability id collision: \(file.id). Choose a unique id across tools, skills and senses.")
            }
            try writeFile(file, slot: slot, writing: writing)
        }
    }

    package func contains(id: String, name: String? = nil) throws -> Bool {
        try Self.withLock {
            try migrate()
            return try allFiles().contains { entry in
                let file = entry.file
                let manifest = file.metadata["candidate"]?.objectValue?["manifest"]?.objectValue
                return file.id.caseInsensitiveCompare(id) == .orderedSame || name.map { name in
                    [file.id, file.record?["name"]?.stringValue, manifest?["name"]?.stringValue,
                     manifest?["record"]?.objectValue?["name"]?.stringValue].compactMap { $0 }
                        .contains { $0.caseInsensitiveCompare(name) == .orderedSame }
                } == true
            }
        }
    }

    /// A bundled seed lands once; after that it follows the bundle only while
    /// it is still the seed (her edit, a version of her own, is hers to keep).
    /// A newer seed takes the current slot with the old one as previous, so the
    /// judge can swap back exactly as for any version of her own.
    package func installSeed(_ file: File) throws {
        try Self.withLock {
            guard let current = try readFile(id: file.id, slot: .current) else {
                guard try !contains(id: file.id) else { return }
                try write(file)
                return
            }
            guard Self.isSeed(current), current.body != file.body else { return }
            try migrate(); try CapabilityLifecycle.requireWrite()
            try writeFile(current, slot: .previous)
            try write(file)
        }
    }

    /// Still the bundle's own seed: its proof was sealed as one, never replaced by her hand.
    public static func isSeed(_ file: File) -> Bool {
        file.metadata["proof"]?.objectValue?["domain"] == .string("owned-program-seed")
    }

    public func remove(id: String, slot: Slot) throws {
        try Self.withLock {
            try migrate(); try CapabilityLifecycle.requireWrite()
            for ext in ["js", "md"] {
                let url = try path(id: id, slot: slot, pathExtension: ext)
                Self.forget(url)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            if slot == .current { NotificationCenter.default.post(name: Self.didChange, object: root.appendingPathComponent(id).path) }
        }
    }

    public func remove(id: String, ownerAuthorized: Bool = false, preview: Bool = false) throws {
        try Self.withLock {
            try migrate()
            if let file = try readFile(id: id, slot: .current) ?? readFile(id: id, slot: .next),
               let row = file.metadata["record"]?.objectValue {
                _ = try CapabilityLifecycle.preservingOwnerOff(row, before: row, ownerAuthorized: ownerAuthorized, enabling: true, preview: preview)
            }
            if preview { return }
            try CapabilityLifecycle.requireWrite()
            for slot in Slot.allCases { try remove(id: id, slot: slot) }
            var stats = try readState(); stats.removeValue(forKey: id)
            try writeState(stats)
        }
    }

    public func swap(id: String, record: [String: JSONValue]? = nil) throws {
        try Self.withLock {
            try migrate(); try CapabilityLifecycle.requireWrite()
            guard let current = try readFile(id: id, slot: .current), var previous = try readFile(id: id, slot: .previous) else {
                throw Self.failure("No previous version for \(id).")
            }
            var restored = record
            if let before = current.record, CapabilityLifecycle.requiresOwnerToEnable(before),
               let fields = restored ?? previous.record {
                restored = try CapabilityLifecycle.preservingOwnerOff(fields, before: before)
            }
            if let restored {
                previous.metadata["record"] = .object(Self.storedRecord(restored).filter { !Self.pending.contains($0.key) })
                try writeFile(previous, slot: .previous)
            }
            let selected = try path(id: id, pathExtension: current.pathExtension)
            let retained = try path(id: id, slot: .previous, pathExtension: previous.pathExtension)
            Self.forget(selected, retained)
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

    /// Terminal evidence belongs to the stem, including on a peer-steered run.
    public func recordRun(id: String, version: String, receipt: JSONValue) throws {
        try Self.withLock {
            try migrate()
            guard let current = try readFile(id: id, slot: .current) else { return }
            let previous = try readFile(id: id, slot: .previous)
            guard let file = [current, previous].compactMap({ $0 }).first(where: { identity($0) == version }) else { return }
            var state = try readState(), row = state[id]?.objectValue ?? [:]
            var runs = row["runs"]?.objectValue ?? [:], versions = runs["versions"]?.objectValue ?? [:]
            func key(_ file: File) -> String { (identity(file) ?? file.bodyDigest) + "@" + String(file.metadata["version"]?.integer ?? 1) }
            if let previous, versions[key(previous)] == nil,
               row["lastCleanVersion"] == identity(previous).map(JSONValue.string),
               row["lastRunVersion"] == row["lastCleanVersion"], row["lastRun"]?.objectValue?["status"] == .string("ok"),
               let at = row["lastUsedAt"] {
                versions[key(previous)] = .object(["last": .object(["outcome": .string("ok"), "at": at]), "ok": .int(1)])
            }
            let selected = key(file), at = ISO8601DateFormatter().string(from: Date())
            var evidence = versions[selected]?.objectValue ?? [:]
            let outcome = Self.runOutcome(receipt)
            let count = (evidence["count"]?.integer ?? 0) + 1
            evidence["count"] = .int(count)
            evidence["last"] = .object(["outcome": .string(outcome), "at": .string(at)])
            evidence[outcome] = .int((evidence[outcome]?.integer ?? 0) + 1)
            let fields = receipt.objectValue ?? [:]
            if outcome == "error", evidence["firstError"] == nil {
                guard let voices = Self.voices else { throw Self.failure("Part-run provenance is unavailable; restart NativeAgent before retrying.") }
                let fault = fields["error"]?.objectValue ?? fields["stopped"]?.objectValue ?? fields
                evidence["firstError"] = .string(String(TurnSecretRedactor.redactText(fault["message"]?.stringValue ?? fault["detail"]?.stringValue
                    ?? fault["reason"]?.stringValue ?? "error").split(separator: "\n").first ?? "error"))
                evidence["firstErrorPeers"] = .array(voices(file).map(JSONValue.string))
            }
            versions[selected] = .object(evidence)
            versions = versions.filter { [key(current), previous.map(key)].compactMap({ $0 }).contains($0.key)
                || $0.value.objectValue?["pendingArrival"] != nil }
            runs["versions"] = .object(versions); row["runs"] = .object(runs)
            row["useCount"] = .int((row["useCount"]?.integer ?? 0) + 1)
            if file == current, file.kind == .sense, outcome == "ok", fields["read"] == .bool(true) {
                row["uses"] = .int((row["uses"]?.integer ?? 0) + 1)
            }
            row["lastUsedAt"] = .string(at); row["lastRunVersion"] = .string(version)
            row["lastRun"] = .object(fields.filter { ["status", "effects", "version", "calls", "error", "stopped"].contains($0.key) }
                .merging(evidence["last"]?.objectValue ?? [:]) { _, new in new })
            if outcome == "ok" { row["lastCleanVersion"] = .string(version) }
            // Judged on every failing run: a version that had no clean earlier
            // version at its first failure can gain one later. "notified" only
            // keeps the same no-clean-version line from being sent twice.
            if file == current, evidence["ok"] == nil, row["lastCleanVersion"] != .string(version),
               let firstError = evidence["firstError"]?.stringValue,
               evidence["pendingArrival"] == nil, evidence["pendingRollback"] == nil {
                let number = current.metadata["version"]?.integer ?? 1
                var line: String?
                // The previous version qualifies when it is the last version that
                // ran clean and its own latest run was not an error: a refusal, a
                // cut or the network is no more its fault than the current one's.
                if let previous, row["lastCleanVersion"] == identity(previous).map(JSONValue.string),
                   let last = versions[key(previous)]?.objectValue?["last"]?.objectValue,
                   last["outcome"] != .string("error"), let date = last["at"]?.stringValue {
                    evidence["pendingRollback"] = .string(key(previous))
                    line = "I rolled \(id) back to v\(previous.metadata["version"]?.integer ?? 1): v\(number) threw \(firstError) on \(count) runs; v\(previous.metadata["version"]?.integer ?? 1) last ran clean \(date)."
                } else if evidence["notified"] != .bool(true) {
                    line = "\(id) v\(number) has failed \(count) runs; there is no clean earlier version"
                }
                if let line {
                    evidence["pendingArrival"] = .string(line); versions[selected] = .object(evidence)
                    runs["versions"] = .object(versions); row["runs"] = .object(runs)
                }
            }
            state[id] = .object(row); try writeState(state)
            for selected in versions.keys.sorted() {
                guard var evidence = versions[selected]?.objectValue, let line = evidence["pendingArrival"]?.stringValue else { continue }
                // Older evidence did not attest whose input the error quoted.
                let peers = evidence["firstErrorPeers"]?.arrayValue?.compactMap(\.stringValue) ?? ["another agent"]
                if let target = evidence["pendingRollback"]?.stringValue {
                    guard let current = try readFile(id: id, slot: .current) else { throw Self.failure("The pending heal for \(id) has no current version.") }
                    if key(current) == selected,
                       evidence["ok"] != nil || versions[target]?.objectValue?["last"]?.objectValue?["outcome"] == .string("error") {
                        evidence.removeValue(forKey: "pendingRollback"); evidence.removeValue(forKey: "pendingArrival")
                        versions[selected] = .object(evidence)
                        runs["versions"] = .object(versions); row["runs"] = .object(runs)
                        state[id] = .object(row); try writeState(state)
                        continue
                    }
                    if key(current) != target {
                        guard key(current) == selected, let previous = try readFile(id: id, slot: .previous), key(previous) == target else {
                            throw Self.failure("The versions for the pending heal of \(id) changed; restore its retained versions before retrying.")
                        }
                        if current.kind == .skill {
                            guard let rollback = Self.rollback else { throw Self.failure("Skill rollback is unavailable; restart NativeAgent before retrying.") }
                            try rollback(dataRoot, id, identity(previous) ?? previous.bodyDigest)
                        } else {
                            // The restored version comes back as on as the one it replaces:
                            // healing never switches a part off (owner-off still holds in swap).
                            var record = previous.record ?? [:]
                            if let live = current.record {
                                for field in ["state", "status", "phase", "enabledAt", "disabledBy"] { record[field] = live[field] }
                            }
                            try swap(id: id, record: record)
                        }
                    }
                    evidence.removeValue(forKey: "pendingRollback"); row.removeValue(forKey: "unavailableReason")
                    versions[selected] = .object(evidence)
                    runs["versions"] = .object(versions); row["runs"] = .object(runs)
                    state[id] = .object(row); try writeState(state)
                }
                guard Self.arrival?(dataRoot, "heal:\(id):\(selected)", line, peers) == true else {
                    throw Self.failure("The heal arrival for \(id) could not be kept.")
                }
                evidence.removeValue(forKey: "pendingArrival"); evidence["notified"] = .bool(true)
                versions[selected] = .object(evidence)
                runs["versions"] = .object(versions); row["runs"] = .object(runs)
                state[id] = .object(row); try writeState(state)
            }
        }
    }

    public static func runOutcome(_ receipt: JSONValue) -> String {
        let fields = receipt.objectValue ?? [:]
        if fields["status"] == .string("ok") {
            if let returned = fields["returned"], let status = returned.objectValue?["status"]?.stringValue,
               ["failed", "refused", "cancelled", "timed_out"].contains(status) { return runOutcome(returned) }
            return "ok"
        }
        if fields["status"] == .string("timed_out") { return "cut" }
        let fault = fields["error"]?.objectValue ?? fields["stopped"]?.objectValue ?? fields
        let reason = fault["reason"]?.stringValue ?? fields["reason"]?.stringValue ?? ""
        if ["timeout", "resource_limit", "cancelled"].contains(reason) { return "cut" }
        if ["network", "http", "connection_failed", "connection_closed", "transport", "network_error", "http_error", "transport_error"].contains(reason) { return "network" }
        if ["javascript", "script_syntax", "script_name", "bad_output", "output_limit", "unreadable_return",
            "expect_failed", "expected_failure_not_seen", "expected_failure_succeeded", "validation_failed",
            "expect_fail_async", "expect_fail_nested", "expect_fail_one_call", "diverged", "script_error",
            "not_declared", "denied_in_skill", "unknown_action", "unknown_arg", "invalid_args", "missing_arg",
            "not_own_version", "no_own_read"].contains(reason) { return "error" }
        let calls = fields["calls"]?.arrayValue?.compactMap(\.objectValue) ?? []
        let failedCall = fault["n"]?.integer.flatMap { n in n > 0 && n <= Int64(calls.count) ? calls[Int(n) - 1] : nil }
            ?? (fields["error"] == nil ? calls.last : nil)
        if let call = failedCall, ![JSONValue.string("ok"), .string("preview"), .string("answered")].contains(call["status"] ?? .null) {
            return runOutcome(.object(call.merging(["calls": .array([])]) { _, new in new }))
        }
        if fault["origin"] == .string("javascript") || fields["status"] == .string("error") && reason.isEmpty { return "error" }
        return "refused"
    }

    public func states() throws -> [String: JSONValue] {
        try Self.withLock { try migrate(); return try readState() }
    }

    public func saveState(id: String, fields: [String: JSONValue]) throws {
        try Self.withLock {
            try migrate()
            var stats = try readState(); stats[id] = .object(fields)
            try writeState(stats)
        }
    }

    /// Domain records are projections of these files, never another persisted catalog.
    public func registry(kind: Kind) throws -> JSONValue {
        try Self.withLock {
            try migrate()
            let stats = try readState()
            let selected = try files(kind: kind)
            if kind == .sense {
                return .object(["format": .int(1), "senses": .array(try selected.compactMap { file in
                    guard let row = record(file, statistics: stats[file.id]) else { return nil }
                    var versions: [JSONValue] = []
                    if let previous = try readFile(id: file.id, slot: .previous), let old = record(previous, statistics: nil) {
                        versions.append(senseVersion(previous, record: old))
                    }
                    versions.append(senseVersion(file, record: row))
                    return .object(["id": .string(file.id), "currentVersion": row["version"] ?? .int(1), "versions": .array(versions)])
                })])
            }
            return .array(try selected.compactMap { file in
                guard var row = record(file, statistics: stats[file.id]) else { return nil }
                var versions: [JSONValue] = []
                if let previous = try readFile(id: file.id, slot: .previous), let digest = identity(previous) {
                    row["previousVersion"] = .string(digest); versions.append(.string(digest))
                }
                if let digest = identity(file) { versions.append(.string(digest)) }
                row["versions"] = .array(versions)
                if let next = try readFile(id: file.id, slot: .next), let digest = identity(next) {
                    row.merge((next.metadata["record"]?.objectValue ?? [:]).filter { Self.pending.contains($0.key) || $0.key == "updatedAt" }) { _, new in new }
                    row["candidateDigest"] = .string(digest)
                } else {
                    for key in Self.pending { row.removeValue(forKey: key) }
                    if file.metadata["proof"] != nil { row["candidateValidation"] = .string("valid") }
                }
                if kind == .tool {
                    if try readFile(id: file.id, slot: .current) != nil {
                        row["activePath"] = .string(try path(id: file.id, pathExtension: file.pathExtension).path)
                    }
                    if let next = try readFile(id: file.id, slot: .next) {
                        row["proposalPath"] = .string(try path(id: file.id, slot: .next, pathExtension: next.pathExtension).path)
                    }
                }
                return .object(row)
            })
        }
    }

    public func saveRegistry(_ value: JSONValue, kind: Kind, ownerAuthorized: Bool = false, enabling: Bool = false) throws {
        try Self.withLock {
            try migrate()
            let before = try registry(kind: kind)
            let checked = try CapabilityLifecycle.preservingOwnerOff(value, before: before, ownerAuthorized: ownerAuthorized, enabling: enabling)
            let rows: [[String: JSONValue]]
            if kind == .sense {
                guard let senses = checked.objectValue?["senses"]?.arrayValue else { throw Self.failure("Invalid sense records.") }
                rows = try senses.map { entry in
                    guard let fields = entry.objectValue,
                          let selected = fields["versions"]?.arrayValue?.first(where: { $0.objectValue?["record"]?.objectValue?["version"] == fields["currentVersion"] })?.objectValue?["record"]?.objectValue else {
                        throw Self.failure("Invalid selected sense record.")
                    }
                    return selected
                }
            } else {
                guard let values = checked.arrayValue, values.allSatisfy({ $0.objectValue != nil }) else { throw Self.failure("Invalid ability records.") }
                rows = values.compactMap(\.objectValue)
            }
            let publications = try rows.map { input in
                guard let id = input["id"]?.stringValue else { throw Self.failure("An ability record has no id.") }
                let current = try readFile(id: id, slot: .current), next = try readFile(id: id, slot: .next)
                let target = kind == .sense ? input["candidateDigest"]?.stringValue : input["codeFingerprint"]?.stringValue
                return (input: input, id: id, current: current, next: next, promote: next != nil && target != nil && target == identity(next!))
            }
            // Admit the complete publication before displacing any selected version.
            if enabling || publications.contains(where: { $0.promote }) {
                try CapabilityLifecycle.requireKeep(ownerAuthorized: ownerAuthorized || CapabilityLifecycle.keepAuthority(dataRoot))
            }
            var stats = try readState()
            let ids = Set(rows.compactMap { $0["id"]?.stringValue })
            for file in try files(kind: kind) where !ids.contains(file.id) { try remove(id: file.id, ownerAuthorized: ownerAuthorized); stats.removeValue(forKey: file.id) }
            for (input, id, current, next, promote) in publications {
                // SenseRecord owns these four fields, not the stem's run evidence.
                let accounting = kind == .sense ? (stats[id]?.objectValue ?? [:]).filter {
                    !["uses", "corrections", "lastUsedAt", "unavailableReason"].contains($0.key)
                } : [:]
                stats[id] = .object(accounting.merging(input.filter { Self.statistics.contains($0.key) }) { _, new in new })
                if input["bundledDefault"] == .bool(true) { continue }
                var slot: Slot = .current
                var file: File
                if promote {
                    if let current { try writeFile(current, slot: .previous) }
                    file = next!
                } else if let current { file = current }
                else if let next { file = next; slot = .next }
                else {
                    let script = input["script"]?.objectValue
                    file = File(id: id, kind: kind, metadata: ["record": .object(input)], body: script?["source"]?.stringValue ?? input["body"]?.stringValue ?? "",
                                pathExtension: script == nil && kind == .skill ? "md" : "js")
                }
                var row = Self.storedRecord(input)
                if kind == .sense, row["status"] == .string("unavailable"),
                   let saved = current?.metadata["record"]?.objectValue, saved["status"] == .string("on") {
                    row["status"] = .string("on"); row["disabledBy"] = saved["disabledBy"]
                }
                if kind != .sense, !promote, let current, var proposal = next {
                    let priorProposal = proposal.metadata["record"]?.objectValue ?? [:]
                    let changed = row.filter { Self.pending.contains($0.key) } != priorProposal.filter { Self.pending.contains($0.key) }
                    proposal.metadata["record"] = .object(row)
                    if proposal != next { try write(proposal, slot: .next) }
                    if changed, let selected = current.metadata["record"]?.objectValue { row = selected }
                    else if row["updatedAt"] == priorProposal["updatedAt"] { row["updatedAt"] = current.metadata["record"]?.objectValue?["updatedAt"] }
                    for key in Self.pending { row.removeValue(forKey: key) }
                }
                if kind != .sense, slot == .current { for key in Self.pending { row.removeValue(forKey: key) } }
                file.metadata["record"] = .object(row)
                if try readFile(id: id, slot: slot) != file { try write(file, slot: slot) }
                if promote { try remove(id: id, slot: .next) }
            }
            try writeState(stats)
        }
    }

    private static func storedRecord(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var row = input.filter { !statistics.contains($0.key) && !obsolete.contains($0.key)
            && !partKeys.contains($0.key) && !["permissions", "bundledDefault", "body"].contains($0.key) }
        if var script = row["script"]?.objectValue { script.removeValue(forKey: "source"); row["script"] = .object(script) }
        return row
    }

    private func record(_ file: File, statistics: JSONValue?) -> [String: JSONValue]? {
        guard var row = file.record else { return nil }
        row.merge(statistics?.objectValue ?? [:]) { _, new in new }
        if file.kind == .sense {
            row["uses"] = row["uses"] ?? .int(0); row["corrections"] = row["corrections"] ?? .int(0)
            if row["status"] == .string("on"), row["unavailableReason"] != nil { row["status"] = .string("unavailable") }
        }
        if var script = row["script"]?.objectValue { script["source"] = .string(file.body); row["script"] = .object(script) }
        return row
    }
    private func identity(_ file: File) -> String? {
        file.metadata["candidate"]?.objectValue?["program"]?.objectValue?["version"]?.stringValue
            ?? file.metadata["record"]?.objectValue?["codeFingerprint"]?.stringValue
            ?? (file.kind == .sense ? file.record?["version"]?.integer.map(String.init) : nil)
    }
    private func senseVersion(_ file: File, record: [String: JSONValue]) -> JSONValue {
        let files = file.metadata["sourceFiles"]?.objectValue?.keys.sorted() ?? []
        let names = Array(Set(files + [record["entry"]?.stringValue].compactMap { $0 })).sorted()
        return .object(["record": .object(record), "files": .array(names.map(JSONValue.string))])
    }

    private func readFile(id: String, slot: Slot) throws -> File? {
        let paths = try ["js", "md"].map { try path(id: id, slot: slot, pathExtension: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard paths.count <= 1 else { throw Self.failure("Ability id collision: \(id) has both JavaScript and Markdown files.") }
        return try paths.first.map(Self.decode)
    }
    private static func checkPath(_ url: URL) throws {
        var parent = url
        while parent.path != "/" {
            try checkItem(parent)
            parent.deleteLastPathComponent()
        }
    }
    /// The store's own writes drop what it decoded there: a replacement can keep both size and modification time.
    private static func forget(_ urls: URL...) {
        withLock { generation &+= 1; for url in urls { decoded.removeValue(forKey: url.path) } }
    }
    private static func checkItem(_ url: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw failure("Ability storage cannot follow symbolic links: \(url.path).") }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { }
    }
    private func allFiles() throws -> [(file: File, slot: Slot)] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        var result: [(file: File, slot: Slot)] = []
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).sorted(by: { $0.path < $1.path }) {
            if ["state.json", ".old-layout"].contains(url.lastPathComponent) { continue }
            guard ["js", "md"].contains(url.pathExtension) else { throw Self.failure("Unexpected ability storage: \(url.lastPathComponent).") }
            let stem = url.deletingPathExtension().lastPathComponent
            let slot: Slot = stem.hasSuffix(".prev") ? .previous : stem.hasSuffix(".next") ? .next : .current
            let file = try Self.decode(url)
            guard try path(id: file.id, slot: slot, pathExtension: file.pathExtension) == url else { throw Self.failure("Ability header id differs from its file: \(url.lastPathComponent).") }
            guard !result.contains(where: { $0.slot == slot && $0.file.id.lowercased() == file.id.lowercased() }) else { throw Self.failure("Ability id collision: \(file.id).") }
            result.append((file, slot))
        }
        return result
    }
    private func writeFile(_ file: File, slot: Slot, writing: () -> Void = {}) throws {
        let destination = try path(id: file.id, slot: slot, pathExtension: file.pathExtension)
        let data = try Self.encode(file)
        writing()
        let other = try path(id: file.id, slot: slot, pathExtension: file.pathExtension == "js" ? "md" : "js")
        Self.forget(destination, other)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: destination)
        if FileManager.default.fileExists(atPath: other.path) { try FileManager.default.removeItem(at: other) }
        if slot == .current { NotificationCenter.default.post(name: Self.didChange, object: root.appendingPathComponent(file.id).path) }
    }
    private static func encode(_ file: File) throws -> Data {
        var header = file.metadata
        header.merge(try partHeader(header)) { _, value in value }
        header.removeValue(forKey: "permissions")
        if var row = header["record"]?.objectValue {
            row.removeValue(forKey: "permissions")
            for key in partKeys { row.removeValue(forKey: key) }
            header["record"] = .object(row)
        }
        try validate(file, header: header)
        header["id"] = .string(file.id); header["kind"] = .string(file.kind.rawValue)
        let json = try JSONValue.object(header).serialize(pretty: true)
        let start = file.pathExtension == "md" ? "<!-- NativeAgent ability\n" : "/* NativeAgent ability\n"
        let end = file.pathExtension == "md" ? "\n-->\n" : "\n*/\n"
        return Data((start + json + end + file.body).utf8)
    }
    /// A file unchanged in size and modification time is the one already decoded:
    /// decoding every file on each registry read cost a quarter second, several
    /// times per app call. Only a successful decode is kept.
    public static func decode(_ url: URL) throws -> File {
        try VerifiedPath.confirmNoSymlink(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1, modified = attributes[.modificationDate] as? Date ?? .distantPast
        if let known = withLock({ decoded[url.path] }), known.size == size, known.modified == modified { return known.file }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let text = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw failure("Unreadable ability file: \(url.lastPathComponent).") }
        let start = url.pathExtension == "md" ? "<!-- NativeAgent ability\n" : "/* NativeAgent ability\n"
        let end = url.pathExtension == "md" ? "\n-->\n" : "\n*/\n"
        guard text.hasPrefix(start), let boundary = text.range(of: end, range: text.index(text.startIndex, offsetBy: start.count)..<text.endIndex),
              case .object(var header) = try JSONValue.parse(Data(text[text.index(text.startIndex, offsetBy: start.count)..<boundary.lowerBound].utf8)),
              let id = header.removeValue(forKey: "id")?.stringValue, let name = header.removeValue(forKey: "kind")?.stringValue,
              let kind = Kind(rawValue: name) else { throw failure("Invalid ability header: \(url.lastPathComponent).") }
        let file = File(id: id, kind: kind, metadata: header, body: String(text[boundary.upperBound...]), pathExtension: url.pathExtension)
        try validate(file, header: file.metadata)
        withLock { decoded[url.path] = (size, modified, file) }
        return file
    }
    private static func validate(_ file: File, header: [String: JSONValue]) throws {
        if let key = header.keys.sorted().first(where: { !partKeys.union(["id", "kind", "version", "record", "candidate", "proof", "sourceFiles", "permissions"]).contains($0) }) {
            throw failure("Unknown part header key: \(key).")
        }
        _ = try partHeader(header)
        guard file.body.utf8.count <= sourceLimit else { throw failure("Part source exceeds \(sourceLimit) bytes.") }
    }
    private func readState() throws -> [String: JSONValue] {
        let url = root.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        try VerifiedPath.confirmNoSymlink(url)
        guard case .object(let values) = try JSONValue.parse(Data(contentsOf: url)), values.values.allSatisfy({ $0.objectValue != nil }) else {
            throw Self.failure("Ability run state is unreadable; restore abilities/state.json. Saved bytes were preserved.")
        }
        return values
    }
    private func writeState(_ state: [String: JSONValue]) throws {
        let bytes = try JSONValue.object(state).serializedData(pretty: true)
        let url = root.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: url.path), try Data(contentsOf: url) == bytes { return }
        // Before the attempt: the durable writer publishes the file before its sync can throw.
        Self.withLock { Self.generation &+= 1 }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: url)
    }

    private static func failure(_ detail: String) -> NSError {
        NSError(domain: "AbilityStore", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
    }

    /// Prepare and read back every live selection before touching any old file.
    /// The presence of state.json commits the forward migration; archive moves
    /// resume on the next load if the process stopped during that final phase.
    public func migrate() throws {
        let fm = FileManager.default
        let legacy = [Kind.tool, .skill, .sense].map { ($0, dataRoot.appendingPathComponent($0.rawValue + "s")) }
        if fm.fileExists(atPath: root.appendingPathComponent(".old-layout").path) {
            try Self.checkPath(root.appendingPathComponent(".old-layout"))
            guard fm.fileExists(atPath: root.appendingPathComponent("state.json").path) else {
                throw Self.failure("Ability migration archive exists without run state. Preserve the archive and restore abilities/state.json before loading abilities.")
            }
            return
        }
        guard fm.fileExists(atPath: root.appendingPathComponent(".old-layout.incoming").path)
            || legacy.contains(where: { fm.fileExists(atPath: $0.1.appendingPathComponent("registry.json").path) }) else { return }
        if fm.fileExists(atPath: root.appendingPathComponent("state.json").path) {
            try archiveLegacy(legacy)
            return
        }
        var prepared: [(File, Slot)] = []
        var stats: [String: JSONValue] = [:]
        var ids: Set<String> = []
        for (kind, directory) in legacy {
            let registry = directory.appendingPathComponent("registry.json")
            guard fm.fileExists(atPath: registry.path) else { continue }
            let value: JSONValue
            do { value = try legacyJSON(registry) }
            catch { throw Self.failure("Ability migration blocked for \(kind.rawValue) registry: \(error.localizedDescription) No abilities migrated; the old stores remain authoritative and unavailable until repaired.") }
            let rows = value.arrayValue ?? value.objectValue?[kind == .sense ? "senses" : kind.rawValue + "s"]?.arrayValue
            guard let rows else { throw Self.failure("Ability migration blocked: \(kind.rawValue) registry has no rows. Old storage was preserved.") }
            for value in rows {
                let id = value.objectValue?["id"]?.stringValue ?? "<missing id>"
                do {
                    guard let outer = value.objectValue, id != "<missing id>" else { throw Self.failure("Row has no id.") }
                    let row: [String: JSONValue]
                    let previous: [String: JSONValue]?
                    if kind == .sense {
                        let versions = outer["versions"]?.arrayValue?.compactMap { $0.objectValue?["record"]?.objectValue } ?? []
                        guard let selected = versions.first(where: { $0["version"] == outer["currentVersion"] }) else { throw Self.failure("Selected sense version is missing.") }
                        row = selected
                        previous = versions.filter { ($0["version"]?.integer ?? 0) < (selected["version"]?.integer ?? 0) }
                            .max { ($0["version"]?.integer ?? 0) < ($1["version"]?.integer ?? 0) }
                    } else { row = outer; previous = nil }
                    let status = (row["status"] ?? row["state"])?.stringValue ?? "active"
                    let ownerOff = CapabilityLifecycle.requiresOwnerToEnable(row)
                    if !ownerOff, ["retired", "archived", "trashed", "rejected", "quarantined"].contains(status)
                        || ["retired", "trashedAt", "droppedAt"].contains(where: { row[$0] != nil && row[$0] != .null }) { continue }
                    guard ids.insert(id.lowercased()).inserted else { throw Self.failure("Id collides with another live tool, skill or sense.") }
                    _ = try path(id: id)
                    stats[id] = .object(row.filter { Self.statistics.contains($0.key) })
                    if kind == .sense, row["language"] == .string("native"), status == "on", row["disabledBy"] == nil { continue }
                    if kind != .sense, let digest = row["candidateDigest"]?.stringValue, digest != row["codeFingerprint"]?.stringValue {
                        prepared.append((try legacyFile(kind: kind, id: id, row: row, directory: directory, digest: digest, slot: .next), .next))
                        if row["codeFingerprint"]?.stringValue == nil,
                           kind == .tool || row["script"]?.objectValue != nil || ["proposed", "draft", "drafted"].contains(status) { continue }
                    }
                    let current = try legacyFile(kind: kind, id: id, row: row, directory: directory)
                    prepared.append((current, .current))
                    if let previous {
                        if let file = try? legacyFile(kind: kind, id: id, row: previous, directory: directory) { prepared.append((file, .previous)) }
                    } else {
                        let selected = row["codeFingerprint"]?.stringValue
                        let digest = row["previousVersion"]?.stringValue
                            ?? current.metadata["candidate"]?.objectValue?["prior"]?.objectValue?["codeFingerprint"]?.stringValue
                            ?? row["versions"]?.arrayValue?.compactMap(\.stringValue).last(where: { $0 != selected })
                        if let digest, let file = try? legacyFile(kind: kind, id: id, row: row, directory: directory, digest: digest) {
                            var previous = file
                            if case .int(let version)? = current.metadata["version"] { previous.metadata["version"] = .int(max(1, version - 1)) }
                            if var fields = previous.metadata["record"]?.objectValue,
                               let selection = current.metadata["candidate"]?.objectValue?["prior"]?.objectValue,
                               selection["codeFingerprint"] == .string(digest) {
                                fields.merge(selection) { _, old in old }
                                previous.metadata["record"] = .object(fields)
                            }
                            prepared.append((previous, .previous))
                        }
                    }
                } catch {
                    throw Self.failure("Ability migration blocked for \(kind.rawValue) \(id): \(error.localizedDescription) No abilities migrated; this row would lose its code or authority. The old layout was left untouched.")
                }
            }
        }
        try CapabilityLifecycle.requireWrite()
        if fm.fileExists(atPath: root.path), try !fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty {
            throw Self.failure("Ability migration found an incomplete abilities folder without state.json. Preserve it and repair the interrupted migration before retrying.")
        }
        let staging = dataRoot.appendingPathComponent(".abilities-incoming-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for (file, slot) in prepared {
            let destination = staging.appendingPathComponent(try path(id: file.id, slot: slot, pathExtension: file.pathExtension).lastPathComponent)
            try SwiftNativePersistenceCore.writeDataAtomicDurable(Self.encode(file), to: destination)
            guard try Self.decode(destination) == file else { throw Self.failure("Ability migration readback failed for \(file.kind.rawValue) \(file.id). Old layout was preserved.") }
        }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONValue.object(stats).serializedData(pretty: true), to: staging.appendingPathComponent("state.json"))
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        try fm.moveItem(at: staging, to: root)
        Self.withLock { Self.generation &+= 1 }
        try archiveLegacy(legacy)
    }

    private func legacyFile(kind: Kind, id: String, row input: [String: JSONValue], directory: URL, digest requested: String? = nil, slot: Slot = .current) throws -> File {
        var row = input
        var metadata: [String: JSONValue] = [:]
        let digest = requested ?? (kind == .sense ? row["candidateDigest"]?.stringValue : row["codeFingerprint"]?.stringValue)
        let body: String
        let ext: String
        if let digest {
            let owner = row["versionOwners"]?.objectValue?[digest]?.stringValue ?? id
            guard !owner.contains("/"), !digest.contains("/"), !digest.hasPrefix(".") else { throw Self.failure("Unsafe candidate identity.") }
            let folder = directory.appendingPathComponent("candidates/\(owner)/\(digest)")
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("candidate.json").path) {
                guard case .object(var candidate) = try legacyJSON(folder.appendingPathComponent("candidate.json")),
                      case .object(var program)? = candidate["program"], let source = program.removeValue(forKey: "source")?.stringValue else {
                    throw Self.failure("Candidate descriptor has no source.")
                }
                guard program["version"] == .string(digest), program["kind"] == .string(kind.rawValue) else {
                    throw Self.failure("Selected candidate identity or kind differs from its row.")
                }
                let sourceURL = folder.appendingPathComponent(kind.rawValue + ".js")
                try Self.checkPath(sourceURL)
                guard try Data(contentsOf: sourceURL) == Data(source.utf8),
                      try legacyJSON(folder.appendingPathComponent("manifest.json")) == candidate["manifest"],
                      try legacyJSON(folder.appendingPathComponent("tests.json")) == candidate["fixtures"] else {
                    throw Self.failure("Selected candidate source, manifest or fixtures changed.")
                }
                candidate["program"] = .object(program)
                if var manifest = candidate["manifest"]?.objectValue, var script = manifest["script"]?.objectValue {
                    script.removeValue(forKey: "source"); manifest["script"] = .object(script); candidate["manifest"] = .object(manifest)
                }
                metadata["candidate"] = .object(candidate)
                let proof = folder.appendingPathComponent("proof.json")
                if FileManager.default.fileExists(atPath: proof.path) { metadata["proof"] = try legacyJSON(proof) }
                body = source; ext = "js"
                if requested != nil, slot != .next, let manifest = candidate["manifest"]?.objectValue {
                    row = manifest
                    row["id"] = .string(id); row["codeFingerprint"] = .string(digest)
                    row["createdAt"] = input["createdAt"]; row["overrides"] = input["overrides"]
                    row["status"] = input["status"]; row["origin"] = input["origin"]
                    row["admission"] = candidate["prior"]?.objectValue?["admission"]
                    if kind == .skill, var script = row["script"]?.objectValue, let revision = input["actionPin"]?.objectValue?["interpreter"] {
                        script["source"] = .string(source)
                        let checksum = SHA256.hash(data: try JSONValue.object(script).serializedData(pretty: false)).map { String(format: "%02x", $0) }.joined()
                        row["scriptDigest"] = .string(checksum)
                        row["actionPin"] = .object(["digest": .string(checksum), "actions": candidate["dependencyShapes"] ?? .object([:]), "interpreter": revision])
                    }
                }
            } else if kind == .skill, let source = row["script"]?.objectValue?["source"]?.stringValue, requested == nil {
                throw Self.failure("Selected executable skill has no readable candidate \(digest); its validation and admission cannot be preserved (\(source.utf8.count) source bytes).")
            } else { throw Self.failure("Candidate \(digest) is missing from \(owner).") }
        } else if kind == .sense {
            if row["language"] == .string("native") { body = ""; ext = "js" }
            else {
                guard let entry = row["entry"]?.stringValue, let version = row["version"]?.integer else { throw Self.failure("Sense has no entry or version.") }
                let folder = directory.appendingPathComponent("\(id)/v\(version)")
                let entryURL = try legacyRelative(entry, under: folder)
                guard let source = String(data: try Data(contentsOf: entryURL), encoding: .utf8) else { throw Self.failure("Sense source is not UTF-8.") }
                body = source; ext = "js"
                var auxiliary: [String: JSONValue] = [:]
                if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let url as URL in enumerator where url.pathExtension == "js" && url != entryURL {
                        try Self.checkPath(url)
                        let name = String(url.path.dropFirst(folder.path.count + 1))
                        auxiliary[name] = .string(try Data(contentsOf: url).base64EncodedString())
                    }
                }
                metadata["sourceFiles"] = .object(auxiliary)
            }
        } else if kind == .skill {
            let file = directory.appendingPathComponent("bodies/\(id).md")
            try Self.checkPath(file)
            guard let source = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw Self.failure("Skill guidance is not UTF-8.") }
            body = source; ext = "md"
        } else { throw Self.failure("Live tool has no selected candidate.") }
        let ownerOff = CapabilityLifecycle.requiresOwnerToEnable(input)
        if ownerOff || kind == .sense && row["status"] == .string("archived") {
            row["status"] = .string(kind == .sense ? "off" : "disabled")
            if row["state"] != nil { row["state"] = row["status"] }
            if row["phase"] != nil { row["phase"] = row["status"] }
            if ownerOff { row["disabledBy"] = .string("owner") }
        }
        row = row.filter { !Self.statistics.contains($0.key) && !Self.obsolete.contains($0.key) }
        if kind != .sense, slot != .next { for key in Self.pending { row.removeValue(forKey: key) } }
        if var script = row["script"]?.objectValue { script.removeValue(forKey: "source"); row["script"] = .object(script) }
        metadata["record"] = .object(row)
        metadata["version"] = input["version"] ?? .int(Int64(max(1, input["versions"]?.arrayValue?.count ?? 1)))
        return File(id: id, kind: kind, metadata: metadata, body: body, pathExtension: ext)
    }

    private func legacyJSON(_ url: URL) throws -> JSONValue {
        try Self.checkPath(url)
        return try JSONValue.parse(Data(contentsOf: url))
    }
    private func legacyRelative(_ name: String, under root: URL) throws -> URL {
        let path = root.appendingPathComponent(name).standardizedFileURL
        guard path.path.hasPrefix(root.path + "/") else { throw Self.failure("Legacy sense source escapes its directory.") }
        try Self.checkPath(path)
        return path
    }
    private func archiveLegacy(_ legacy: [(Kind, URL)]) throws {
        let fm = FileManager.default
        let incoming = root.appendingPathComponent(".old-layout.incoming")
        for (kind, directory) in legacy {
            let archive = incoming.appendingPathComponent(kind.rawValue + "s")
            let originalRegistry = directory.appendingPathComponent("registry.json")
            let savedRegistry = archive.appendingPathComponent("registry.json")
            let registry = fm.fileExists(atPath: originalRegistry.path) ? originalRegistry : savedRegistry
            guard fm.fileExists(atPath: registry.path) else { continue }
            var names = ["registry.json.lock", "candidates", "proposals", "history", "bodies", "active", "quarantine", "by-id", "migrations"]
            if kind == .sense {
                names += [".trials"]
                for folder in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                    where try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    let versions = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                        .filter { $0.lastPathComponent.range(of: #"^v[0-9]+$"#, options: .regularExpression) != nil }
                    guard !versions.isEmpty else { continue }
                    for version in versions {
                        let destination = archive.appendingPathComponent(folder.lastPathComponent).appendingPathComponent(version.lastPathComponent)
                        try Self.checkPath(version)
                        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: version, to: destination)
                    }
                    if try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).isEmpty { try fm.removeItem(at: folder) }
                }
            }
            names.append("registry.json")
            for name in names {
                guard !name.contains("/"), name != ".", name != ".." else { throw Self.failure("Unsafe legacy storage name.") }
                let source = directory.appendingPathComponent(name)
                guard fm.fileExists(atPath: source.path) else { continue }
                let destination = archive.appendingPathComponent(name)
                guard !fm.fileExists(atPath: destination.path) else { throw Self.failure("Migration archive already contains \(kind.rawValue)s/\(name); preserve both copies and repair the interrupted move.") }
                try Self.checkPath(source)
                try fm.createDirectory(at: archive, withIntermediateDirectories: true)
                try fm.moveItem(at: source, to: destination)
            }
        }
        if fm.fileExists(atPath: incoming.path) { try fm.moveItem(at: incoming, to: root.appendingPathComponent(".old-layout")) }
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int64? { if case .int(let value) = self { value } else { nil } }
}
