import CryptoKit
import Experiences
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `AbilityFile.swift` | Shared canonical part file, header, reach and argument schemas |
extension AbilityStore {
    public enum Kind: String, CaseIterable, Sendable {
        case part = "ability", sense, turn
    }
    public static let sourceLimit = 512 * 1024
    public static let didChange = Notification.Name("NativeAgent.abilityDidChange")
    /// Wake delivery selects declared source names and optional target parts; peer-word payloads retain their agent provenance.
    public static let signalled = Notification.Name("NativeAgent.partSignalled")
    public static let partKeys: Set<String> = ["reach", "wake", "face", "resident", "learned", "choices", "answers"]
    public static let partActionPattern = "^[a-z][a-z0-9_]*[.][a-z][a-z0-9_.]*$"
    /// The effect classes a verb a part answers may declare; read verbs run read-confined.
    public static let answerClasses = ["read", "write", "send", "destructive"]
    /// Header shapes live with the normalizer and are shared by both authoring doors.
    public static let partArgumentSchemas: [String: JSONValue] = {
        let strings: JSONValue = .object(["type": .string("array"), "items": .object(["type": .string("string"), "minLength": .int(1)])])
        return [
            "reach": .object(["type": .string("object"), "properties": .object([
                "capabilities": strings, "readPaths": strings, "hosts": strings, "apps": strings]),
                "required": .array([]), "additionalProperties": .bool(false)]),
            "face": .object(["type": .string("object"), "properties": .object([
                "page": .object(["type": .string("string"), "description": .string("""
                    The page where the part is placed, one of \(AppDoorNames.partPages.sorted().joined(separator: ", ")); with projection true, \
                    any other id makes this part a page of the agent's own by that id, drawn from its notebook.
                    """)]),
                "action": .object(["type": .string("string"), "pattern": .string(partActionPattern)]),
                "projection": .object(["type": .string("boolean")])]), "required": .array([]), "additionalProperties": .bool(false)]),
            "wake": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                "description": .string("""
                    Posted signals: schedule:<cron>, app.installed, file.changed:<path>, turn.ended, message.arrived:slack, message.arrived:telegram, held, \
                    resumed, person.away, person.here, network.down, network.up, chrome.tab_taken. Omit to inherit; [] clears.
                    """)]),
            "resident": .object(["type": .string("boolean"), "description": .string(
                "Retain JS and held resources across successful runs; default false, inherited on revision.")]),
            "learned": .object(["description": .string("""
                Any JSON retained as declared learned metadata; no shape is enforced and it earns no competence. Omit to inherit.
                """)]),
            "choices": .object(["description": .string("Any JSON retained as reserved choices metadata; no shape is enforced. Omit to inherit.")]),
            "answers": .object(["type": .string("object"), "propertyNames": .object(["pattern": .string(partActionPattern)]),
                "additionalProperties": answerSchema, "description": .string("""
                    Door verbs this part answers, by action id: each with its description, class (read runs read-confined), optional irreversible, \
                    screen, summary and warn, and its args JSON Schema. The part's run(input) receives {verb, ...args}. Omit to inherit; {} clears.
                    """)])
        ]
    }()
    static let answerSchema: JSONValue = .object(["type": .string("object"), "properties": .object([
        "summary": .object(["type": .string("string")]), "warn": .object(["type": .string("string")]),
        "description": .object(["type": .string("string"), "minLength": .int(1)]),
        "class": .object(["type": .string("string"), "enum": .array(answerClasses.map(JSONValue.string))]),
        "irreversible": .object(["type": .string("boolean")]), "screen": .object(["type": .string("boolean")]),
        "args": .object(["type": .string("object"), "additionalProperties": .bool(true),
            "description": .string("The verb's JSON Schema; type object. No argument is named verb.")])]),
        "required": .array(["description", "class", "args"].map(JSONValue.string)), "additionalProperties": .bool(false)])

    /// A part that answers verbs takes `{verb, ...args}`; each verb's own args are checked at the door against its declared schema.
    public static func answeredInputSchema(_ answers: JSONValue?) -> JSONValue? {
        guard case .object(let verbs)? = answers, !verbs.isEmpty else { return nil }
        return .object(["type": .string("object"), "properties": .object(["verb": .object(["type": .string("string"),
            "enum": .array(verbs.keys.sorted().map(JSONValue.string))])]), "required": .array([.string("verb")]),
            "additionalProperties": .bool(true)])
    }
    /// Identity normalization is shared below Parts.
    public static func normalizedID(_ given: String) -> String {
        given.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"[^a-z0-9_-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    public static func isAbilityID(_ id: String) -> Bool { id.range(of: #"^[a-z][a-z0-9_-]{1,63}$"#, options: .regularExpression) != nil }
    public static func knownReach(_ name: String) -> Bool {
        if ["app_data_read", "app_data_write", "network_localhost", "network_public", "network", "shell", "computer_files", "arbitrary_file_write", "model",
            "calendar", "reminders", "contacts", "screen.watch", "hands"].contains(name) { return true }
        let pieces = name.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if pieces.count == 2, pieces[0] == "secret" { return Keyring.validName(String(pieces[1])) }
        return pieces.count == 2 && ["app_read", "app_write"].contains(pieces[0])
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
            "reminders": ["reminders.due_today", "reminders.query", "reminders.lists", "reminders.read", "reminders.create", "reminders.update",
                "reminders.complete", "reminders.delete", "reminders.list_rename", "reminders.list_create"],
            "contacts": ["contacts.search", "contacts.save", "contacts.delete"],
        ]
        return Set(capabilities.flatMap { actions[$0] ?? [] }).sorted()
    }
    /// All part kinds share a header; abilities use capabilities while senses use readPaths/hosts/apps, with shared wake admission.
    public static func partHeader(_ fields: [String: JSONValue]) throws -> [String: JSONValue] {
        var header = fields.filter { partKeys.contains($0.key) }
        let reach = header["reach"] ?? .object([:])
        guard case .object(var scope) = reach else { throw headerFailure("reach",
            accepted: "{capabilities?: [string], readPaths?: [string], hosts?: [string], apps?: [string]}") }
        let reachKeys = Self.partArgumentSchemas["reach"]!.objectValue!["properties"]!.objectValue!.keys.sorted()
        for key in reachKeys {
            if scope[key] == nil { scope[key] = .array([]) }
            guard case .array(let values)? = scope[key], values.allSatisfy({ if case .string(let text) = $0 { return !text.isEmpty }; return false }) else {
                throw headerFailure("reach.\(key)", accepted: "an array of nonempty strings")
            }
            if key == "capabilities", let invalid = values.compactMap(\.stringValue).first(where: { !knownReach($0) }) {
                throw headerFailure("reach.capabilities", accepted: "known reach names; use app {find:\"ability.save\"} for declarations",
                    detail: "Unknown reach name: \(invalid).")
            }
        }
        if let key = scope.keys.sorted().first(where: { !reachKeys.contains($0) }) { throw headerFailure("reach.\(key)",
            accepted: "capabilities, readPaths, hosts or apps", detail: "Unknown reach key: \(key). Remove it or use an accepted key.",
            code: "unknown_header_reach_key") }
        header["reach"] = .object(scope)
        let wake = header["wake"] ?? .array([])
        guard case .array(let signals) = wake else { throw headerFailure("wake", accepted: "an array of signal-name strings") }
        for signal in signals {
            guard case .string(let name) = signal else { throw headerFailure("wake", accepted: "an array of signal-name strings") }
            let valid = ["app.installed", "turn.ended", "held", "resumed", "person.away", "person.here", "network.down", "network.up", "chrome.tab_taken"].contains(name)
                || ["message.arrived:slack", "message.arrived:telegram"].contains(name)
                || ["schedule:", "file.changed:"].contains { prefix in
                    name.hasPrefix(prefix) && !name.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            guard valid else { throw headerFailure("wake", accepted: """
                schedule:<cron>, app.installed, file.changed:<path>, turn.ended, message.arrived:slack, message.arrived:telegram, held, resumed, person.away, \
                person.here, network.down, network.up or chrome.tab_taken
                """, detail: "Unknown wake name: \(name). Replace it with an accepted signal.") }
        }
        header["wake"] = wake
        guard case .object(let face) = header["face"] ?? .object([:]) else { throw headerFailure("face",
            accepted: "{page?: string, action?: string, projection?: bool}") }
        let faceKeys = Self.partArgumentSchemas["face"]!.objectValue!["properties"]!.objectValue!.keys
        if let key = face.keys.sorted().first(where: { !faceKeys.contains($0) }) { throw headerFailure("face.\(key)", accepted: "page, action or projection",
            detail: "Unknown face key: \(key). Remove it or use an accepted key.", code: "unknown_header_face_key") }
        if let projection = face["projection"], projection != .bool(true), projection != .bool(false) {
            throw headerFailure("face.projection", accepted: "a Boolean; true declares function face(input)")
        }
        if let action = face["action"], action.stringValue?.range(of: partActionPattern, options: .regularExpression) == nil {
            throw headerFailure("face.action", accepted: "a lowercase app action id, such as weather.forecast")
        }
        // An app page names where the part is placed; with projection, any other id makes the part that page, a page of the agent's own.
        if let page = face["page"] {
            guard case .string(let name) = page else {
                throw headerFailure("face.page", accepted: "an app page, or with projection a page id of the agent's own")
            }
            if !AppDoorNames.partPages.contains(name) {
                guard face["projection"] == .bool(true) else {
                    throw headerFailure("face.page", accepted: AppDoorNames.partPages.sorted().joined(separator: ", "),
                        detail: "Unknown face.page \(name). Select an accepted page, or declare projection:true to make the part a page of its own.")
                }
                if let refusal = PartFaces.ownPageRefusal(name) {
                    throw headerFailure("face.page", accepted: "a page id of the agent's own, such as week or garden", detail: refusal)
                }
            }
        }
        header["face"] = .object(face)
        // An empty answers is no answers, so a header without verbs keeps its shape.
        if case .object(let verbs) = try checkedAnswers(header["answers"] ?? .object([:]), face: face), !verbs.isEmpty {
            header["answers"] = .object(verbs)
        } else { header.removeValue(forKey: "answers") }
        // Abilities use resident; sense helper retention uses SenseRecord.mode.
        guard case .bool = header["resident"] ?? .bool(false) else { throw headerFailure("resident", accepted: "a Boolean") }
        header["resident"] = header["resident"] ?? .bool(false)
        return header
    }
    /// A verb answered here is the part's door: one declaration per verb, never beside face.action, its args an object schema without `verb`.
    static func checkedAnswers(_ value: JSONValue, face: [String: JSONValue]) throws -> JSONValue {
        guard case .object(let verbs) = value else {
            throw headerFailure("answers", accepted: "an object of verb id → {description, class, args, irreversible?, screen?, summary?}")
        }
        if !verbs.isEmpty, face["action"] != nil {
            throw headerFailure("face.action", accepted: "no face.action beside answers", detail: "answers declares this part's verbs; remove face.action.")
        }
        let keys = Set(answerSchema.objectValue?["properties"]?.objectValue?.keys.map { $0 } ?? [])
        for (verb, entry) in verbs {
            let field = "answers." + verb
            guard verb.range(of: partActionPattern, options: .regularExpression) != nil else {
                throw headerFailure(field, accepted: "a lowercase app action id, such as mail.search")
            }
            guard case .object(let declared) = entry else { throw headerFailure(field, accepted: "{description, class, args}") }
            if let key = declared.keys.sorted().first(where: { !keys.contains($0) }) {
                throw headerFailure(field + "." + key, accepted: keys.sorted().joined(separator: ", "), detail: "Unknown answer key: \(key).")
            }
            guard case .string(let description)? = declared["description"], !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw headerFailure(field + ".description", accepted: "a nonempty string")
            }
            guard case .string(let effect)? = declared["class"], answerClasses.contains(effect) else {
                throw headerFailure(field + ".class", accepted: answerClasses.joined(separator: ", "))
            }
            for flag in ["irreversible", "screen"] {
                if let given = declared[flag], given != .bool(true), given != .bool(false) { throw headerFailure(field + "." + flag, accepted: "a Boolean") }
            }
            for words in ["summary", "warn"] {
                if let given = declared[words], given.stringValue?.isEmpty != false { throw headerFailure(field + "." + words, accepted: "a nonempty string") }
            }
            guard case .object(let args)? = declared["args"], args["type"] == .string("object") else {
                throw headerFailure(field + ".args", accepted: "a JSON Schema with type object")
            }
            if args["properties"]?.objectValue?["verb"] != nil {
                throw headerFailure(field + ".args", accepted: "arguments other than verb", detail: "verb names the answered verb in the part's input.")
            }
        }
        return value
    }
    static func headerFailure(_ field: String, accepted: String, detail: String? = nil, code: String? = nil) -> ToolFailureError {
        ToolFailureError(detail ?? "\(field) must be \(accepted).", argumentPath: field, accepted: accepted, effects: .none,
            code: code ?? "invalid_header_" + field.replacingOccurrences(of: ".", with: "_"), status: .refused,
            instruction: "Correct \(field) in this call or retained header to match accepted.", recovery: .correctArguments)
    }
    /// Paginate with explicit continuation; each page must let two versions fit one tool result without a second cut.
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
            let properties = record.merging(manifest.filter { AbilityStore.partKeys.contains($0.key) }) { _, value in value }
                .merging(metadata) { _, value in value }
            self.metadata.merge(try AbilityStore.partHeader(properties)) { _, value in value }
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
        public var wakes: [String] {
            let status = record["status"]?.stringValue
            guard kind == .part && status == "active" || kind == .sense && status == "on" else { return [] }
            return (metadata["wake"]?.arrayValue ?? []).compactMap(\.stringValue)
        }
        /// The checked decoded file carries its digest; changing its body refreshes it. Derived data does not change source-field equality.
        private static func digest(_ body: String) -> String {
            SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.metadata == rhs.metadata
                && lhs.body == rhs.body && lhs.pathExtension == rhs.pathExtension
        }
    }
}
