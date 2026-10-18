import AuthoredCapabilities
import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore
import Senses

public struct SkillManifest: Codable, Identifiable, Sendable {
    public var id: String { name }
    public let schemaVersion: Int
    public let name: String
    public let version: String
    public let type: String
    public let description: String
    public let author: SkillAuthor?
    public let permissions: [String]?
    public let tools: [SkillTool]?
    public let oauth: SkillOAuth?
    public let tags: [String]?
    public let homepage: String?
}

public struct SkillAuthor: Codable, Sendable {
    public let name: String
    public let email: String?
    public let url: String?
}

public struct SkillOAuth: Codable, Sendable {
    public let provider: String
    public let scopes: [String]
    public let deviceFlow: Bool?
}

public struct SkillTool: Codable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String
}

public struct SkillInfo: Identifiable, Sendable {
    public let id: String
    public let manifest: SkillManifest
    public let registry: SkillRegistryEntry
    public let readme: String?
    public var candidateDigest: String? = nil
    public var validationStatus: String? = nil

    public static func learnedSkill(_ skill: SkillRecord, review: JSONValue?) -> SkillInfo {
        let skillId = skill.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? skill.name : skill.id
        let name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? skillId : skill.name
        let rawState = (skill.status ?? "active").lowercased()
        let state: String = {
            switch rawState {
            case "draft": return "drafted"
            case "disabled": return "dormant"
            default: return rawState.isEmpty ? "active" : rawState
            }
        }()
        let manifest = SkillManifest(
            schemaVersion: 1,
            name: name,
            version: "runtime",
            type: skill.kind ?? "learned_skill",
            description: skill.description,
            author: nil,
            permissions: nil,
            tools: nil,
            oauth: nil,
            tags: skill.autoCreated == true ? ["learned"] : nil,
            homepage: nil
        )
        let registry = SkillRegistryEntry(
            name: skillId,
            state: state,
            version: "runtime",
            type: skill.kind ?? "learned_skill",
            installedAt: skill.createdAt,
            path: skill.bodyPath ?? ""
        )
        let fields: [String: JSONValue] = if case .object(let value)? = review { value } else { [:] }
        let candidate: [String: JSONValue] = if case .object(let value)? = fields["candidate"] { value } else { [:] }
        let version = candidate["digest"] ?? fields["selected_version"]
        let validation = candidate["validation"] ?? fields["validation"] ?? (fields["runnable"] == .bool(true) ? .string("accepted") : .null)
        var script: [String: JSONValue] = if case .object(let value)? = candidate["script"] ?? fields["script"] { value } else { [:] }
        let code = script.removeValue(forKey: "source")
        let source = JSONValue.object(["description": .string(skill.description), "status": .string(state),
            "version": version ?? .null, "validation": validation, "versions": fields["versions"] ?? .null,
            "script": .object(script),
            "fixtures": candidate["fixtures"] ?? fields["fixtures"] ?? .array([])])
        let preview = try? source.serialize(pretty: true)
        let codeText = if case .string(let value)? = code { value } else { "No JS source is selected." }
        return SkillInfo(id: skillId, manifest: manifest, registry: registry,
                         readme: review == nil ? nil : preview.map { codeText + "\n\n" + $0 },
                         candidateDigest: { if case .string(let value)? = version { value } else { nil } }(),
                         validationStatus: { if case .string(let value) = validation { value } else { nil } }())
    }
}

/// The identity and availability projection shared by discovery, UI and recall.
public enum InstalledSkillInventory {
    public static func reviewInstallRefusal(
        version: String, state: String, name: String, hasCandidate: Bool, validationStatus: String?
    ) -> String? {
        let state = state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if version == "runtime" {
            guard hasCandidate else { return "No exact JS candidate is available for review. Read Tools census." }
            guard validationStatus == "valid" else { return "Validate this exact candidate with skill.validate before installing it." }
        }
        guard state == "drafted" || validationStatus == "valid" else {
            let shownState = state.isEmpty ? "missing" : state
            return "Only a drafted skill can be installed from this review sheet. This skill is currently \(shownState)."
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return "This draft has no id, so it cannot be installed safely."
        }
        return nil
    }
    public struct Entry: Sendable {
        public let row: [String: JSONValue]
        public var id: String { InstalledSkillInventory.string(row["id"]) ?? "" }
        public var name: String { InstalledSkillInventory.string(row["name"]) ?? "" }
        public var isAvailable: Bool { InstalledSkillInventory.isAvailable(row) }
        /// On, with a script whose exact digest an admission binds (`SkillScript`).
        public var isRunnable: Bool { SkillScript.isRunnable(row) }
        public var summary: JSONValue {
            var fields = row.filter { ["id", "name", "description", "triggers", "status", "source", "signature", "overrides"].contains($0.key) }
            if let script = row["script"] {
                fields["signature"] = .string(SkillScript.signature(script))
                fields["params"] = script.objectValue?["params"] ?? .object([:])
                fields["input_schema"] = SkillScript.inputSchema(script)
                if fields["params"] == .object([:]) { fields["input_note"] = .string("No inputs are declared. Read the routine with skill.read {source:true} before running it.") }
            }
            fields["runnable"] = .bool(isRunnable)
            fields["next_call"] = .object(["action": .string(isRunnable ? "skill.run" : "skill.read"),
                "args": .object(["name": .string(name)])])
            return .object(fields)
        }
    }

    public static func isAvailable(_ row: [String: JSONValue]) -> Bool {
        ["active", "installed"].contains((string(row["status"] ?? row["state"]) ?? "active").lowercased())
    }

    /// Compact view; checked consumers use entries and report registry errors.
    public static func list(dataRoot: URL) -> [JSONValue] {
        (try? entries(dataRoot: dataRoot))?.map(\.summary) ?? []
    }

    public static func entries(dataRoot: URL) throws -> [Entry] {
        let registry = try SkillsRegistry.decode(AbilityStore(dataRoot: dataRoot).registry(kind: .skill))
        var entries: [Entry] = []
        for value in registry {
            guard case .object(var row) = value else { throw SkillsError.invalidRegistry("skill registry contains a non-object row") }
            row["source"] = .string("runtime_registry")
            entries.append(Entry(row: row))
        }
        let bodies = defaultPersonaRoot(dataRoot: dataRoot).appendingPathComponent("skills/bodies")
        if FileManager.default.fileExists(atPath: bodies.path) {
            for file in try FileManager.default.contentsOfDirectory(at: bodies, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                where file.pathExtension == "md" {
                let id = file.deletingPathExtension().lastPathComponent
                guard !entries.contains(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }),
                      let original = try builtIn(["id": .string(id), "overrides": .string("built_in")], dataRoot: dataRoot) else { continue }
                entries.append(Entry(row: original))
            }
        }
        return entries.sorted {
            if $0.name.caseInsensitiveCompare($1.name) == .orderedSame, $0.isAvailable != $1.isAvailable { return $0.isAvailable }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Bundled originals stay outside the writable ability store.
    public static func builtIn(_ row: [String: JSONValue], dataRoot: URL) throws -> [String: JSONValue]? {
        guard row["overrides"] == .string("built_in"), let id = string(row["id"]) else { return nil }
        guard SkillMutation.isSafeSkillID(id) else { throw SkillsError.invalidRegistry("The built-in skill identity is invalid.") }
        let file = defaultPersonaRoot(dataRoot: dataRoot).appendingPathComponent("skills/bodies/\(id).md")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try VerifiedPath.confirmNoSymlink(file)
        let body = try String(contentsOf: file, encoding: .utf8)
        return ["id": .string(id), "name": row["name"] ?? .string(id),
                "description": .string(body.split(separator: "\n").first.map(String.init) ?? id),
                "triggers": .array([]), "status": .string("active"), "source": .string("persona_body"),
                "bodyPath": .string(file.path), "overrides": .string("built_in")]
    }

    public static func selected(_ row: [String: JSONValue], dataRoot: URL) throws -> [String: JSONValue] {
        return row
    }

    public static func match(_ name: String, in entries: [Entry]) -> Entry? {
        var matches = entries.filter { $0.id.caseInsensitiveCompare(name) == .orderedSame }
        if matches.isEmpty { matches = entries.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        return matches.first { $0.isAvailable } ?? matches.first
    }

    public static func match(_ name: String, in rows: [JSONValue]) -> Entry? {
        match(name, in: rows.compactMap { $0.objectValue.map { Entry(row: $0) } })
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }
}

/// A repeatable skill's script (skills-as-code PR 2): JavaScript in its
/// ability file with a small header. A write that adds or changes one lands
/// drafted, and it runs only while an admission binds the exact digest of
/// script and header, given by whoever may admit what steered it. Every field
/// here fails closed: missing or malformed means not runnable.
public enum SkillScript {
    public static let interpreterRevision = 2
    public static let sourceLimit = AbilityStore.sourceLimit
    public static let stepLimit = 50
    public static let actionLimit = 50
    static let types: Set<String> = ["string", "int", "number", "bool", "list", "object"]
    static let verbs: Set<String> = ["read", "find", "log", "expect", "expect_fail", "decide", "step"]
    /// A script whose origin no record names counts as a peer's.
    static let unrecorded = "unrecorded"

    /// A runner verb (read, app.find…), which actions never lists.
    public static func isVerb(_ spelled: String) -> Bool {
        let id = spelled.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return verbs.contains(id.hasPrefix("app.") ? String(id.dropFirst(4)) : id)
    }

    /// The action id an `actions` entry spells; nil for a runner verb or no id's shape.
    public static func dependencyID(_ spelled: String) -> String? {
        let id = spelled.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !isVerb(id) && id.range(of: "^[a-z0-9_-]+(\\.[a-z0-9_-]+)+$", options: .regularExpression) != nil ? id : nil
    }

    /// The stored form of a save's `script`, or why it is refused.
    public static func normalized(_ value: JSONValue?) throws -> JSONValue {
        func refuse(_ why: String) -> SkillsError { .invalidScript(why) }
        guard case .object(let raw)? = value else {
            throw refuse("script is an object: {source, params, actions, steps, of}.")
        }
        if let stray = raw.keys.sorted().first(where: { !["source", "params", "actions", "steps", "of", "entry"].contains($0) }) {
            throw refuse("script takes no \(stray); its keys are source, params, actions, steps and of.")
        }
        guard case .string(let source)? = raw["source"], !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.utf8.count <= sourceLimit else {
            throw refuse("source is the JavaScript, at most \(sourceLimit) bytes.")
        }
        var params: [String: JSONValue] = [:]
        if let given = raw["params"], given != .null {
            guard case .object(let fields) = given else { throw refuse("params maps each input name to its type or {type, description}.") }
            for (name, type) in fields {
                guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil,
                      let spelled = parameterType(type),
                      types.contains(spelled.hasSuffix("?") ? String(spelled.dropLast()) : spelled) else {
                    throw refuse("params maps each input name to string, int, number, bool, list or object; "
                        + "a trailing ? marks it optional.")
                }
                if case .object(let declaration) = type {
                    guard Set(declaration.keys) == ["type", "description"],
                          let description = string(declaration["description"]), !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw refuse("A described param is {type, description}, with a nonempty description.")
                    }
                }
                params[name] = type
            }
        }
        guard case .array(let listed)? = raw["actions"], listed.count <= actionLimit else {
            throw refuse("actions lists the app action ids it may call, at most \(actionLimit).")
        }
        var actions: [String] = []
        for item in listed {
            guard case .string(let spelled) = item else { throw refuse("each action is an app action id, like memory.recall.") }
            guard let id = dependencyID(spelled) else {
                throw refuse("\(spelled) is not an app action dependency. actions lists IDs such as memory.recall; "
                    + "app.read, app.find, app.log, app.expect, app.expect_fail, app.decide and app.step are built in. Use actions:[] for helpers alone.")
            }
            if !actions.contains(id) { actions.append(id) }
        }
        // Labelled steps say how many there are; `of` is needed only without them.
        let labelled: Int64 = if case .array(let labels)? = raw["steps"] { Int64(labels.count) } else { 0 }
        let of: Int64
        switch raw["of"] {
        case .int(let n)?: of = n
        case .double(let n)? where n.rounded() == n && abs(n) < 1_000: of = Int64(n)
        default: of = max(labelled, 1)
        }
        guard (1...Int64(stepLimit)).contains(of) else { throw refuse("of is how many steps it declares, 1 to \(stepLimit).") }
        var script: [String: JSONValue] = [
            "source": .string(source), "params": .object(params),
            "actions": .array(actions.map(JSONValue.string)), "of": .int(of),
        ]
        guard raw["entry"] == .string("run") else { throw refuse("entry is run: define function run(input).") }
        script["entry"] = .string("run")
        if let given = raw["steps"], given != .null, given != .array([]) {
            guard case .array(let labels) = given, labels.count == Int(of), labels.allSatisfy({
                if case .string(let label) = $0 { !label.isEmpty && label.count <= 160 } else { false }
            }) else { throw refuse("steps, when given, labels each of its \(of) steps, at most 160 characters each.") }
            script["steps"] = given
        }
        return .object(script)
    }

    /// The action ids its source calls by name (`app.memory.recall(`) that
    /// its header's actions don't declare, read with comments and the
    /// contents of strings left out. The runner's own verbs aren't actions;
    /// an id it builds at run time, or names in a string, can't be seen here,
    /// and the run's allowlist still stops it.
    public static func undeclared(_ script: JSONValue) -> [String] {
        guard case .object(let fields) = script, let source = string(fields["source"]),
              let regex = try? NSRegularExpression(pattern: #"\bapp\s*\.\s*(\w+)\s*\.\s*(\w+)\s*\("#) else { return [] }
        let code = codeMask(source)
        let declared = Set(strings(fields["actions"]))
        var found: [String] = []
        // app.<name>( that is no runner verb calls nothing that exists (app.call is not the API).
        if let bare = try? NSRegularExpression(pattern: #"\bapp\s*\.\s*(\w+)\s*\("#) {
            for match in bare.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let range = Range(match.range(at: 1), in: code), !verbs.contains(String(code[range])) else { continue }
                let call = "app.\(code[range])()"
                if !found.contains(call) { found.append(call) }
            }
        }
        for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            let parts = (1...2).compactMap { Range(match.range(at: $0), in: code).map { String(code[$0]) } }
            guard parts.count == 2, !verbs.contains(parts[0])
            else { continue }
            let id = parts.joined(separator: ".").lowercased()
            if !declared.contains(id), !found.contains(id) { found.append(id) }
        }
        return found
    }

    /// Keep offsets and lines while hiding literal text; template expressions are code.
    private static func codeMask(_ source: String) -> String {
        let text = Array(source.utf16)
        var masked = text, i = 0
        func word(_ c: UInt16) -> Bool { c >= 128 || (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c == 95 || c == 36 }
        func hide(_ start: Int) { for n in start..<i where text[n] != 10 && text[n] != 13 { masked[n] = 32 } }
        func literal(_ delimiter: UInt16) {
            let start = i
            i += 1
            var bracket = false
            while i < text.count {
                let c = text[i]; i += 1
                if c == 92 { i = min(i + 1, text.count); continue }
                if delimiter == 47, c == 91 { bracket = true }
                if delimiter == 47, c == 93 { bracket = false }
                if c == delimiter, !bracket { break }
            }
            if delimiter == 47 { while i < text.count, word(text[i]) { i += 1 } }
            hide(start)
        }
        func code(_ interpolation: Bool = false) {
            var regexAllowed = true, previous = "", parens: [Bool] = [], braces: [Bool] = []
            while i < text.count {
                let c = text[i], next = i + 1 < text.count ? text[i + 1] : 0
                if c == 32 || c == 9 || c == 10 || c == 13 { i += 1; continue }
                if c == 47, next == 47 || next == 42 {
                    let start = i; i += 2
                    while i < text.count {
                        if next == 47, text[i] == 10 || text[i] == 13 { break }
                        if next == 42, text[i] == 42, i + 1 < text.count, text[i + 1] == 47 { i += 2; break }
                        i += 1
                    }
                    hide(start); continue
                }
                if c == 34 || c == 39 || (c == 47 && regexAllowed) {
                    literal(c); regexAllowed = false; previous = "literal"; continue
                }
                if c == 96 {
                    var start = i; i += 1
                    while i < text.count {
                        if text[i] == 92 { i = min(i + 2, text.count); continue }
                        if text[i] == 96 { i += 1; hide(start); break }
                        if text[i] == 36, i + 1 < text.count, text[i + 1] == 123 {
                            i += 2; hide(start); code(true); start = i; continue
                        }
                        i += 1
                    }
                    hide(start); regexAllowed = false; previous = "literal"; continue
                }
                if word(c) {
                    let start = i
                    while i < text.count, word(text[i]) { i += 1 }
                    previous = String(decoding: text[start..<i], as: UTF16.self)
                    regexAllowed = ["return", "throw", "case", "delete", "void", "typeof", "new", "in", "of", "yield", "await", "else", "do"].contains(previous)
                    continue
                }
                if (c == 43 || c == 45), next == c {
                    i += 2; previous = "increment"; continue
                }
                i += 1
                if c == 123 { braces.append(["=", "(", "[", ",", ":", "?", "return", "yield", "await"].contains(previous) || (interpolation && previous.isEmpty)) }
                if c == 125 {
                    if interpolation, braces.isEmpty { masked[i - 1] = 32; return }
                    regexAllowed = !(braces.popLast() ?? false)
                    previous = "}"; continue
                }
                if c == 40 { parens.append(["if", "while", "for", "with", "switch", "catch"].contains(previous)) }
                regexAllowed = c == 41 ? (parens.popLast() ?? false) : ![93, 46].contains(c)
                previous = String(decoding: [c], as: UTF16.self)
            }
        }
        code()
        return String(decoding: masked, as: UTF16.self)
    }

    /// Source integrity for action pins; executable identity is the owned candidate.
    public static func sourceChecksum(_ script: JSONValue?) -> String? {
        guard case .object? = script, let text = try? script?.serialize(pretty: false) else { return nil }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func actions(_ script: JSONValue) -> [String] {
        guard let fields = script.objectValue else { return [] }
        var actions = strings(fields["actions"])
        guard let source = string(fields["source"]) else { return actions }
        let code = codeMask(source)
        let calls = try! NSRegularExpression(pattern: #"\bapp\s*\.\s*read\s*\("#)
        let literal = try! NSRegularExpression(pattern: #"^\s*(['"])([^'"\\]*)\1"#)
        for call in calls.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            let tail = (source as NSString).substring(from: NSMaxRange(call.range))
            let target = literal.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail))
                .map { (tail as NSString).substring(with: $0.range(at: 2)) }
            let read = target.map { "read \($0)" } ?? "app.read"
            if !actions.contains(read) { actions.append(read) }
        }
        return actions
    }

    /// Generated from the stored code and header; her description stays hers.
    public static func signature(_ script: JSONValue) -> String {
        guard case .object(let fields) = script else { return "" }
        var params: [String] = []
        if case .object(let given)? = fields["params"] {
            params = given.keys.sorted().map { "input.\($0): \(parameterType(given[$0]) ?? "?")" }
        }
        let called = actions(script)
        let reads = called.filter { $0.hasPrefix("read ") || $0 == "app.read" }.map { $0 == "app.read" ? $0 : String($0.dropFirst(5)) }
        let actions = called.filter { !$0.hasPrefix("read ") && $0 != "app.read" }
        let of = if case .int(let n)? = fields["of"] { n } else { Int64(0) }
        // In the header's own words: `actions` are the app actions it calls; reads are built in.
        return "run {\(params.joined(separator: ", "))} · \(of) step\(of == 1 ? "" : "s")"
            + (actions.isEmpty ? "" : " · actions \(actions.joined(separator: ", "))")
            + (reads.isEmpty ? "" : " · reads \(reads.joined(separator: ", "))")
    }

    /// Who steered the turn that wrote it: hers, or the peers that did
    /// (their words consumed, an elevated peer's included).
    public static func origin(steeredBy peers: [String]) -> JSONValue {
        peers.isEmpty ? .object(["by": .string("hers")])
            : .object(["by": .string("peer"), "peers": .array(peers.map(JSONValue.string))])
    }

    public static func origin(pack: String) -> JSONValue {
        .object(["by": .string("pack"), "pack": .string(pack)])
    }

    /// hers, peer or pack; nil when missing or malformed.
    public static func originKind(_ value: JSONValue?) -> String? {
        guard case .object(let fields)? = value, let by = string(fields["by"]) else { return nil }
        switch by {
        case "hers": return by
        case "peer":
            guard case .array(let peers)? = fields["peers"], !peers.isEmpty,
                  peers.allSatisfy({ !(string($0) ?? "").isEmpty }) else { return nil }
            return by
        case "pack": return (string(fields["pack"]) ?? "").isEmpty ? nil : by
        default: return nil
        }
    }

    /// Origins only ratchet toward User: no later edit, restore or enable of
    /// hers launders a peer's or a pack's mark. A nil entry is an origin that
    /// should exist and doesn't, an unrecorded peer.
    static func merged(_ origins: [JSONValue?]) -> JSONValue {
        var peers: [String] = []
        var pack: String?
        for origin in origins.isEmpty ? [nil] : origins {
            guard case .object(let fields)? = origin, let kind = originKind(origin) else {
                peers.append(unrecorded)
                continue
            }
            if kind == "peer" { peers += strings(fields["peers"]) }
            if let named = string(fields["pack"]), !named.isEmpty, kind != "hers" { pack = pack ?? named }
        }
        var seen: Set<String> = []
        peers = peers.filter { seen.insert($0).inserted }
        guard !peers.isEmpty else { return pack.map(origin(pack:)) ?? origin(steeredBy: []) }
        var fields: [String: JSONValue] = ["by": .string("peer"), "peers": .array(peers.map(JSONValue.string))]
        if let pack { fields["pack"] = .string(pack) }
        return .object(fields)
    }

    /// Whose words a line naming this skill carries: none for her own; a
    /// peer's, a pack's or an unrecorded script's name is theirs, so the line
    /// is filed as their step (masked title, taint latch).
    public static func voices(_ row: [String: JSONValue]) -> [String] {
        let recorded = recorded(row)
        guard !recorded.isEmpty, case .object(let origin) = merged(recorded) else { return [] }
        return strings(origin["peers"]) + [string(origin["pack"])].compactMap { $0 }
    }

    public static func agentMayAdmit(_ origin: JSONValue?) -> Bool {
        guard let kind = originKind(origin), origin?.objectValue?["pack"] == nil else { return false }
        return kind == "hers" || kind == "peer" && strings(origin?.objectValue?["peers"]).allSatisfy(CapabilityLifecycle.ownerTrusts)
    }

    /// Admission binds the immutable candidate, including source and dependencies.
    public static func admitted(_ row: [String: JSONValue]) -> Bool {
        guard let stored = row["script"], (try? normalized(stored)) == stored,
              let digest = string(row["codeFingerprint"]), digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              case .object(let admission)? = row["admission"], admission["candidate"] == .string(digest),
              originKind(row["origin"]) != nil else { return false }
        switch string(admission["by"]) {
        case "user": return true
        case "agent": return agentMayAdmit(row["origin"])
        default: return false
        }
    }

    /// On by an explicit status: the active default a guidance row gets
    /// never makes a script runnable.
    public static func isRunnable(_ row: [String: JSONValue]) -> Bool {
        ["active", "installed"].contains(string(row["status"])?.lowercased() ?? "") && admitted(row)
            && row["script"]?.objectValue?["entry"] == .string("run") && row["codeFingerprint"] != nil
            && row["actionPin"]?.objectValue?["interpreter"] == .int(Int64(interpreterRevision))
            && row["actionPin"]?.objectValue?["digest"] == sourceChecksum(row["script"]).map(JSONValue.string)
    }

    public static func inputSchema(_ script: JSONValue) -> JSONValue {
        let params = script.objectValue?["params"]?.objectValue ?? [:]
        let types = ["string": "string", "int": "integer", "number": "number", "bool": "boolean", "list": "array", "object": "object"]
        let properties = params.mapValues { value -> JSONValue in
            let type = parameterType(value) ?? ""
            var property: [String: JSONValue] = ["type": .string(types[type.hasSuffix("?") ? String(type.dropLast()) : type] ?? "")]
            if let description = value.objectValue?["description"] { property["description"] = description }
            return .object(property)
        }
        return .object(["type": .string("object"), "properties": .object(properties),
            "required": .array(params.keys.sorted().filter { !(parameterType(params[$0]) ?? "").hasSuffix("?") }.map(JSONValue.string)),
            "additionalProperties": .bool(false)])
    }

    public static func parameterType(_ value: JSONValue?) -> String? {
        string(value) ?? string(value?.objectValue?["type"])
    }

    /// The origin a row already carries, as one to merge: none for a row that
    /// never had a script or an origin, nil (unrecorded) for a script row without one.
    static func recorded(_ row: [String: JSONValue]?) -> [JSONValue?] {
        guard let row, row["script"] != nil || row["origin"] != nil else { return [] }
        return [row["origin"]] + (row["candidateOrigin"].map { [$0] } ?? [])
    }

    /// One rule for every write that leaves a script on a row (save, dedupe,
    /// restore, rollback, pack): the signature is regenerated, the origin
    /// merges every hand `origins` names, an admission survives only for the
    /// exact digest it bound, and a changed script or one with no admission
    /// lands drafted.
    static func settle(_ row: inout [String: JSONValue], before: [String: JSONValue]?, origins: [JSONValue?]) {
        // The ratchet outlives the script: a row that ever carried an origin
        // keeps every hand, even restored to a version from before its script.
        if row["script"] != nil || !recorded(before).isEmpty || row["origin"] != nil { row["origin"] = merged(origins) }
        guard let script = row["script"] else {
            for key in ["signature", "scriptDigest", "admission"] { row.removeValue(forKey: key) }
            return
        }
        row["signature"] = .string(signature(script))
        row["scriptDigest"] = sourceChecksum(script).map(JSONValue.string)
        if script != before?["script"] {
            row.removeValue(forKey: "admission")
            row["status"] = .string("draft")
            row["actionPin"] = .object(["digest": .string(sourceChecksum(script) ?? ""),
                "interpreter": .int(Int64(interpreterRevision))])
        } else {
            row["admission"] = before?["admission"]
        }
        if InstalledSkillInventory.isAvailable(row), !admitted(row) { row["status"] = .string("draft") }
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap(string)
    }
}
