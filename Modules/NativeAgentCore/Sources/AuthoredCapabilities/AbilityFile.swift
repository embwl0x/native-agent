import CryptoKit
import Experiences
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `AbilityFile.swift` | Canonical authored file, header, slot and reach representation |
extension AbilityStore {
    public enum Kind: String, CaseIterable, Sendable {
        /// Authored abilities use `ability` in their headers.
        case part = "ability", sense, turn
        /// A header's kind; `tool`, `skill` and `part` are an ability's older spellings.
        public init?(stored: String) { self.init(rawValue: ["tool", "skill", "part"].contains(stored) ? "ability" : stored) }
    }
    public static let sourceLimit = 512 * 1024
    public static let didChange = Notification.Name("NativeAgent.abilityDidChange")
    /// A wake source fired. The stem delivers it to each part whose `wake`
    /// lists the name (only `part`, when one is named), as that run's input.
    /// A payload carrying another agent's words names it as `agent`.
    public static let signalled = Notification.Name("NativeAgent.partSignalled")
    public static let partKeys: Set<String> = ["reach", "wake", "face", "resident", "learned", "choices"]
    /// Shared identity normalization below Parts.
    public static func normalizedID(_ given: String) -> String {
        given.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"[^a-z0-9_-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    public static func isAbilityID(_ id: String) -> Bool { id.range(of: #"^[a-z][a-z0-9_-]{1,63}$"#, options: .regularExpression) != nil }
    public static func knownReach(_ name: String) -> Bool {
        if ["app_data_read", "app_data_write", "network_localhost", "network_public", "network", "shell", "computer_files", "arbitrary_file_write", "model", "calendar", "reminders", "contacts", "screen.watch", "hands"].contains(name) { return true }
        let pieces = name.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if pieces.count == 2, pieces[0] == "secret" { return Keyring.validName(String(pieces[1])) }
        // `connector:<id>` still reads, so an older ability loads; it grants nothing since 10-21.
        return pieces.count == 2 && ["app_read", "app_write", "connector"].contains(pieces[0])
            && !pieces[1].isEmpty && pieces[1].allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }
    /// Exact app-action reach, independent of where an action's face is drawn.
    public static func reachActions(_ capabilities: [String]) -> [String] {
        let reads = ["files.read", "files.list", "files.info", "files.excerpt", "files.grep", "files.spotlight"]
        let files = reads + ["files.write", "files.move", "files.copy", "files.trash", "files.patch"]
        let actions: [String: [String]] = [
            "app_data_read": reads, "computer_files": reads,
            "app_data_write": files, "arbitrary_file_write": files,
            "calendar": ["calendar.upcoming", "calendar.calendars", "calendar.free_busy", "calendar.create", "calendar.modify", "calendar.delete"],
            "reminders": ["reminders.due_today", "reminders.query", "reminders.lists", "reminders.read", "reminders.create", "reminders.update", "reminders.complete", "reminders.delete", "reminders.list_rename", "reminders.list_create"],
            "contacts": ["contacts.search", "contacts.save", "contacts.delete"],
        ]
        return Set(capabilities.flatMap { actions[$0] ?? [] }).sorted()
    }
    /// The same header for every part. Abilities consume reach.capabilities;
    /// readPaths/hosts/apps serve senses. Legacy authority is projected.
    /// `saving` holds a new version to the wakes that are posted; a kept file
    /// reads as it was accepted, so one stale wake never stops the catalog.
    public static func partHeader(_ fields: [String: JSONValue], saving: Bool = false) throws -> [String: JSONValue] {
        var header = fields.filter { partKeys.contains($0.key) }
        var reach = header["reach"] ?? .object([:])
        guard case .object(var scope) = reach else { throw headerFailure("reach", accepted: "{capabilities?: [string], readPaths?: [string], hosts?: [string], apps?: [string]}") }
        if scope["capabilities"] == nil { scope["capabilities"] = fields["permissions"] ?? .array([]) }
        for key in ["capabilities", "readPaths", "hosts", "apps"] {
            if scope[key] == nil { scope[key] = .array([]) }
            guard case .array(let values)? = scope[key], values.allSatisfy({ if case .string(let text) = $0 { return !text.isEmpty }; return false }) else {
                throw headerFailure("reach.\(key)", accepted: "an array of nonempty strings")
            }
            if key == "capabilities", let invalid = values.compactMap(\.stringValue).first(where: { !knownReach($0) }) {
                throw headerFailure("reach.capabilities", accepted: "known reach names; use app {find:\"ability.save\"} for declarations", detail: "Unknown reach name: \(invalid).")
            }
        }
        if let key = scope.keys.sorted().first(where: { !["capabilities", "readPaths", "hosts", "apps"].contains($0) }) { throw headerFailure("reach.\(key)", accepted: "capabilities, readPaths, hosts or apps", detail: "Unknown reach key: \(key). Remove it or use an accepted key.", code: "unknown_header_reach_key") }
        header["reach"] = .object(scope)
        let wake = header["wake"] ?? .array([])
        guard case .array(let signals) = wake else { throw headerFailure("wake", accepted: "an array of signal-name strings") }
        for signal in signals {
            guard case .string(let name) = signal else { throw headerFailure("wake", accepted: "an array of signal-name strings") }
            let valid = ["app.installed", "turn.ended", "held", "resumed", "person.away", "person.here"].contains(name)
                || ["message.arrived:slack", "message.arrived:telegram"].contains(name)
                || (saving ? ["schedule:", "file.changed:"] : ["schedule:", "file.changed:", "message.arrived:"]).contains { prefix in
                    name.hasPrefix(prefix) && !name.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            guard valid else { throw headerFailure("wake", accepted: "schedule:<cron>, app.installed, file.changed:<path>, turn.ended, message.arrived:slack, message.arrived:telegram, held, resumed, person.away or person.here", detail: "Unknown wake name: \(name). Replace it with an accepted signal.") }
        }
        header["wake"] = wake
        guard case .object(let face) = header["face"] ?? .object([:]) else { throw headerFailure("face", accepted: "{page?: string, action?: string, projection?: bool}") }
        if let key = face.keys.sorted().first(where: { !["page", "action", "projection"].contains($0) }) { throw headerFailure("face.\(key)", accepted: "page, action or projection", detail: "Unknown face key: \(key). Remove it or use an accepted key.", code: "unknown_header_face_key") }
        if let projection = face["projection"], projection != .bool(true), projection != .bool(false) {
            throw headerFailure("face.projection", accepted: "a Boolean; true declares function face(input)")
        }
        if let action = face["action"], action.stringValue?.range(of: "^[a-z][a-z0-9_]*[.][a-z][a-z0-9_.]*$", options: .regularExpression) == nil {
            throw headerFailure("face.action", accepted: "a lowercase app action id, such as weather.forecast")
        }
        if let page = face["page"] {
            guard case .string(let name) = page, AppDoorNames.partPages.contains(name) else {
                throw headerFailure("face.page", accepted: AppDoorNames.partPages.sorted().joined(separator: ", "), detail: "Unknown face.page \(page). Select an accepted page.")
            }
        }
        header["face"] = .object(face)
        // Abilities use resident; sense helper retention uses SenseRecord.mode.
        guard case .bool = header["resident"] ?? .bool(false) else { throw headerFailure("resident", accepted: "a Boolean") }
        header["resident"] = header["resident"] ?? .bool(false)
        return header
    }
    static func headerFailure(_ field: String, accepted: String, detail: String? = nil, code: String? = nil) -> ToolFailureError {
        ToolFailureError(detail ?? "\(field) must be \(accepted).", argumentPath: field, accepted: accepted, effects: .none,
            code: code ?? "invalid_header_" + field.replacingOccurrences(of: ".", with: "_"), status: .refused,
            instruction: "Correct \(field) in this call or retained header to match accepted.", recovery: .correctArguments)
    }
    /// A part's code as she reads it: whole when it fits one read, else in
    /// pages that say where they are and how to go on, never a silent cut.
    /// A page is sized so a read carrying two (a skill's selected and waiting
    /// versions) stays inside one tool result, which is never re-cut.
    public static let sourcePageCharacters = 18_000
    public static func sourcePage(_ code: String, version: String, offset: Int, next: (Int) -> JSONValue) -> JSONValue {
        let from = min(max(0, offset), code.count)
        let start = code.index(code.startIndex, offsetBy: from)
        let end = code.index(start, offsetBy: sourcePageCharacters, limitedBy: code.endIndex) ?? code.endIndex
        var page: [String: JSONValue] = ["version": .string(version), "code": .string(String(code[start..<end]))]
        guard from > 0 || end < code.endIndex else { return .object(page) }
        let reached = from + code.distance(from: start, to: end)
        page["offset"] = .int(Int64(from)); page["total_chars"] = .int(Int64(code.count))
        if end < code.endIndex {
            page["next_call"] = next(reached)
            page["note"] = .string("Characters \(from) to \(reached) of \(code.count); the code continues. next_call reads on from \(reached).")
        } else {
            page["note"] = .string("Characters \(from) to \(reached) of \(code.count): the end of the code.")
        }
        return .object(page)
    }
    /// A revised body: each {old, new} in turn replaces the one place its old occurs.
    public static func edited(_ body: String, _ edits: JSONValue) throws -> String {
        guard case .array(let list) = edits, !list.isEmpty else { throw failure("edits is a nonempty list of {old, new}.") }
        var text = body
        for (i, edit) in list.enumerated() {
            guard case .object(let pair) = edit, case .string(let old)? = pair["old"], !old.isEmpty,
                  case .string(let new)? = pair["new"] else { throw failure("edits[\(i)] is {old, new}: old the exact text to replace, new its replacement.") }
            let found = text.ranges(of: old)
            guard found.count == 1 else {
                throw failure(found.isEmpty ? "edits[\(i)].old is not in the code (after the edits before it); copy it exactly from the latest source."
                    : "edits[\(i)].old occurs \(found.count) times; include more of its surrounding lines so it occurs once.")
            }
            text.replaceSubrange(found[0], with: new)
        }
        return text
    }
    public enum Slot: String, CaseIterable, Sendable { case current, previous, next }
    public struct File: Sendable, Equatable {
        public var id: String
        public var kind: Kind
        public var metadata: [String: JSONValue]
        public var body: String { didSet { bodyDigest = Self.digest(body) } }
        public private(set) var bodyDigest: String
        public var pathExtension: String
        public init(id: String, kind: Kind, metadata: [String: JSONValue], body: String, pathExtension: String) throws {
            self.id = id; self.kind = kind; self.metadata = metadata; self.body = body; self.pathExtension = pathExtension
            self.bodyDigest = Self.digest(body)
            if self.metadata["version"] == nil { self.metadata["version"] = .int(1) }
            let candidate = metadata["candidate"]?.objectValue ?? [:]
            let manifest = candidate["manifest"]?.objectValue ?? [:]
            let record = metadata["record"]?.objectValue ?? manifest["record"]?.objectValue ?? manifest
            var properties = record.merging(manifest.filter { AbilityStore.partKeys.contains($0.key) }) { _, value in value }
                .merging(metadata) { _, value in value }
            let program = candidate["program"]?.objectValue ?? [:]
            if properties["reach"] == nil { properties["reach"] = program["reach"] }
            if properties["permissions"] == nil { properties["permissions"] = program["permissions"] }
            self.metadata.merge(try AbilityStore.partHeader(properties)) { _, value in value }
            self.metadata.removeValue(forKey: "permissions")
            if var row = self.metadata["record"]?.objectValue {
                row.removeValue(forKey: "permissions")
                for key in AbilityStore.partKeys.union(kind == .sense ? ["kind"] : ["kind", "version"]) { row.removeValue(forKey: key) }
                self.metadata["record"] = .object(row)
            }
        }
        public var part: [String: JSONValue] { metadata.filter { AbilityStore.partKeys.contains($0.key) } }
        public var record: [String: JSONValue] {
            let manifest = metadata["candidate"]?.objectValue?["manifest"]?.objectValue ?? [:]
            var row = metadata["record"]?.objectValue ?? manifest["record"]?.objectValue ?? manifest
            row["id"] = .string(id); row["kind"] = .string(kind.rawValue)
            // A sense keeps its SenseRecord version; other parts use the header's.
            if kind != .sense { row["version"] = metadata["version"] }
            if kind == .turn { row["status"] = .string("installed") }
            else if metadata["record"]?.objectValue == nil { row["status"] = .string("draft") }
            row.merge(part) { _, value in value }
            if kind == .part { row["permissions"] = part["reach"]?.objectValue?["capabilities"] }
            if kind == .sense, let reach = part["reach"]?.objectValue {
                row["reach"] = .object(reach.filter { $0.key != "capabilities" })
                row.removeValue(forKey: "wake"); row.removeValue(forKey: "resident")
            }
            return row
        }
        public var partLine: String {
            if kind == .sense {
                return id + " · " + ["reach", "mode"].map {
                    $0 + ":" + ((try? (record[$0] ?? .null).serialize(pretty: false)) ?? "null")
                }.joined(separator: " ")
            }
            return id + " · " + ["reach", "wake", "face", "resident"].map {
                $0 + ":" + ((try? (metadata[$0] ?? .null).serialize(pretty: false)) ?? "null")
            }.joined(separator: " ")
        }
        /// What wakes it while it is on.
        public var wakes: [String] {
            let status = record["status"]?.stringValue
            guard kind == .part && status == "active" || kind == .sense && status == "on" else { return [] }
            return (metadata["wake"]?.arrayValue ?? []).compactMap(\.stringValue)
        }
        /// The checked decoded file carries its digest; changing its body
        /// refreshes it. Derived data does not change source-field equality.
        private static func digest(_ body: String) -> String {
            SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.metadata == rhs.metadata
                && lhs.body == rhs.body && lhs.pathExtension == rhs.pathExtension
        }
    }
}
