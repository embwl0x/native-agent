import CryptoKit
import Foundation
import NativeAgentCore
import PersistenceCore

/// The identity and availability projection shared by discovery, UI and recall.
public enum InstalledSkillInventory {
    public struct Entry: Sendable {
        public let row: [String: JSONValue]
        public let bodyURL: URL?
        public var id: String {
            let value = InstalledSkillInventory.string(row["id"]) ?? ""
            return value.isEmpty ? name : value
        }
        public var name: String { InstalledSkillInventory.string(row["name"]) ?? "" }
        public var isAvailable: Bool { InstalledSkillInventory.isAvailable(row) }
        /// On, with a script whose exact digest an admission binds (`SkillScript`).
        public var isRunnable: Bool { SkillScript.isRunnable(row) }
    }

    public static func isAvailable(_ row: [String: JSONValue]) -> Bool {
        ["active", "installed"].contains((string(row["status"]) ?? "active").lowercased())
    }

    /// Compact compatibility view. Checked consumers use entries so a bad
    /// registry cannot be mistaken for permission to expose its loose bodies.
    public static func list(dataRoot: URL, sourceRoot: URL? = nil, personaRoot: URL? = nil) -> [JSONValue] {
        (try? entries(dataRoot: dataRoot, sourceRoot: sourceRoot, personaRoot: personaRoot))?.map { entry in
            var row = entry.row.filter { ["id", "name", "description", "triggers", "status", "source", "signature"].contains($0.key) }
            if let script = entry.row["script"] { row["signature"] = .string(SkillScript.signature(script)) } // rows saved before input.x
            if row["source"] != .string("runtime_registry") {
                row["status"] = .string("installed")
                row.removeValue(forKey: "id")
                row.removeValue(forKey: "triggers")
            }
            return .object(row)
        } ?? []
    }

    public static func entries(dataRoot: URL, sourceRoot: URL? = nil, personaRoot: URL? = nil) throws -> [Entry] {
        try entries(
            registryURL: dataRoot.appendingPathComponent("skills/registry.json"),
            bodiesDirs: [dataRoot.appendingPathComponent("skills/bodies"),
                         (personaRoot ?? defaultPersonaRoot(dataRoot: dataRoot)).appendingPathComponent("skills/bodies")],
            sourceRoot: sourceRoot ?? dataRoot.deletingLastPathComponent()
        )
    }

    public static func entries(registryURL: URL?, bodiesDirs: [URL], sourceRoot: URL? = nil) throws -> [Entry] {
        let fm = FileManager.default
        var registry: [JSONValue] = []
        if let registryURL, fm.fileExists(atPath: registryURL.path) {
            let raw = try JSONValue.parse(Data(contentsOf: registryURL))
            registry = try SkillsRegistry.decode(raw)
        }
        var result: [Entry] = []
        var seen: Set<String> = []
        let base = sourceRoot ?? registryURL?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for value in registry {
            guard case .object(var row) = value else {
                throw SkillsError.invalidRegistry("skill registry contains a non-object row")
            }
            let id = string(row["id"]) ?? ""
            let name = string(row["name"]) ?? id
            var candidates: [URL] = []
            if let raw = string(row["bodyPath"]), !raw.isEmpty {
                let expanded = (raw as NSString).expandingTildeInPath
                let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base?.appendingPathComponent(expanded)
                if let url { candidates.append(url) }
                seen.insert(URL(fileURLWithPath: expanded).deletingPathExtension().lastPathComponent.lowercased())
            }
            for handle in [id, name] where safeHandle(handle) {
                candidates += bodiesDirs.map { $0.appendingPathComponent("\(handle).md") }
            }
            if !id.isEmpty { seen.insert(id.lowercased()) }
            if !name.isEmpty { seen.insert(name.lowercased()) }
            let bodyURL = candidates.first { readableBody(at: $0, roots: bodiesDirs) != nil }
            if let bodyURL, let body = readableBody(at: bodyURL, roots: bodiesDirs),
               !SkillBodyHygiene.violations(in: body).isEmpty { continue }
            row["source"] = .string("runtime_registry")
            result.append(Entry(row: row, bodyURL: bodyURL))
        }
        for (index, directory) in bodiesDirs.enumerated() {
            guard fm.fileExists(atPath: directory.path) else { continue }
            let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension.lowercased() == "md" {
                let name = url.deletingPathExtension().lastPathComponent
                guard !seen.contains(name.lowercased()),
                      let body = readableBody(at: url, roots: bodiesDirs),
                      SkillBodyHygiene.violations(in: body).isEmpty else { continue }
                seen.insert(name.lowercased())
                result.append(Entry(row: [
                    "id": .string(name), "name": .string(name),
                    "description": .string(String((SkillBodyHygiene.firstUsefulLine(in: body) ?? "Skill body.").prefix(240))),
                    "triggers": .array([]), "kind": .string("skill"), "status": .string("active"),
                    "autoCreated": .bool(false), "bodyPath": .string(url.path),
                    "source": .string(index == 0 ? "runtime_body" : "persona_body"),
                ], bodyURL: url))
            }
        }
        return result.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    public static func match(_ name: String, in entries: [Entry]) -> Entry? {
        entries.first { $0.id.caseInsensitiveCompare(name) == .orderedSame }
            ?? entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func safeHandle(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("..") && !name.hasPrefix(".")
    }

    private static func readableBody(at url: URL, roots: [URL]) -> String? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard roots.contains(where: { resolved.path.hasPrefix($0.standardizedFileURL.resolvingSymlinksInPath().path + "/") }),
              (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return try? String(contentsOf: resolved, encoding: .utf8)
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }
}

/// A repeatable skill's script (skills-as-code PR 2): JavaScript in its
/// registry row with a small header, never in its body, so body hygiene
/// neither reads nor rewrites it. A write that adds or changes one lands
/// drafted, and it runs only while an admission binds the exact digest of
/// script and header, given by whoever may admit what steered it. Every field
/// here fails closed: missing or malformed means not runnable.
public enum SkillScript {
    public static let sourceLimit = 8 * 1024
    public static let stepLimit = 50
    public static let actionLimit = 50
    static let types: Set<String> = ["string", "int", "number", "bool", "list", "object"]
    /// A script whose origin no record names counts as a peer's.
    static let unrecorded = "unrecorded"

    /// The stored form of a save's `script`, or why it is refused.
    public static func normalized(_ value: JSONValue?) throws -> JSONValue {
        func refuse(_ why: String) -> SkillsError { .invalidScript(why) }
        guard case .object(let raw)? = value else {
            throw refuse("script is an object: {source, params, actions, steps, of}.")
        }
        if let stray = raw.keys.sorted().first(where: { !["source", "params", "actions", "steps", "of"].contains($0) }) {
            throw refuse("script takes no \(stray); its keys are source, params, actions, steps and of.")
        }
        guard case .string(let source)? = raw["source"], !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.utf8.count <= sourceLimit else {
            throw refuse("source is the JavaScript, at most \(sourceLimit) bytes.")
        }
        var params: [String: JSONValue] = [:]
        if let given = raw["params"], given != .null {
            guard case .object(let fields) = given else { throw refuse("params maps each input name to its type.") }
            for (name, type) in fields {
                guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil,
                      case .string(let spelled) = type,
                      types.contains(spelled.hasSuffix("?") ? String(spelled.dropLast()) : spelled) else {
                    throw refuse("params maps each input name to string, int, number, bool, list or object; "
                        + "a trailing ? marks it optional.")
                }
                params[name] = type
            }
        }
        guard case .array(let listed)? = raw["actions"], (1...actionLimit).contains(listed.count) else {
            throw refuse("actions lists the app action ids it may call, 1 to \(actionLimit).")
        }
        var actions: [String] = []
        for item in listed {
            guard case .string(let spelled) = item else { throw refuse("each action is an app action id, like memory.recall.") }
            let id = spelled.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard id.range(of: "^[a-z0-9_-]+(\\.[a-z0-9_-]+)+$", options: .regularExpression) != nil else {
                throw refuse("\(spelled) is not an app action id, like memory.recall.")
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
        // The code alone: // and /* */ comments dropped, each string kept as its quotes.
        var code = "", quote: Character?, comment: Character?, escaped = false, last: Character = " "
        for char in source {
            defer { last = char }
            if comment == "/" { if char == "\n" { comment = nil; code.append(char) }; continue }
            if comment == "*" { if last == "*", char == "/" { comment = nil }; continue }
            if let open = quote {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == open { quote = nil; code.append(char) }
                continue
            }
            if last == "/", code.last == "/", char == "/" || char == "*" { code.removeLast(); comment = char; continue }
            if char == "\"" || char == "'" || char == "`" { quote = char }
            code.append(char)
        }
        let declared = Set(strings(fields["actions"]))
        let verbs: Set<String> = ["read", "find", "log", "expect", "expect_fail", "decide", "step"]
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

    /// SHA-256 of the stored script and header, canonical JSON (sorted keys).
    public static func digest(_ script: JSONValue?) -> String? {
        guard case .object? = script, let text = try? script?.serialize(pretty: false) else { return nil }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The one line generated from the header; her description stays hers.
    public static func signature(_ script: JSONValue) -> String {
        guard case .object(let fields) = script else { return "" }
        var params: [String] = []
        if case .object(let given)? = fields["params"] {
            params = given.keys.sorted().map { "input.\($0): \(string(given[$0]) ?? "?")" }
        }
        let actions = strings(fields["actions"])
        let of = if case .int(let n)? = fields["of"] { n } else { Int64(0) }
        return "script {\(params.joined(separator: ", "))} · \(of) step\(of == 1 ? "" : "s") · calls \(actions.joined(separator: ", "))"
    }

    /// Who steered the turn that wrote it: hers, or the peers that did
    /// (their words consumed, an elevated peer's included).
    public static func origin(steeredBy peers: [String]) -> JSONValue {
        peers.isEmpty ? .object(["by": .string("hers")])
            : .object(["by": .string("peer"), "peers": .array(peers.prefix(8).map(JSONValue.string))])
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
        var fields: [String: JSONValue] = ["by": .string("peer"), "peers": .array(peers.prefix(8).map(JSONValue.string))]
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

    public static func admission(_ script: JSONValue, by: String, at: String) -> JSONValue {
        .object(["digest": .string(digest(script) ?? ""), "by": .string(by), "at": .string(at)])
    }

    /// An admission that binds this row's exact, well-formed script, given by
    /// User, or by her for a script of her own origin.
    public static func admitted(_ row: [String: JSONValue]) -> Bool {
        guard let stored = row["script"], (try? normalized(stored)) == stored, let digest = digest(stored),
              case .object(let admission)? = row["admission"], admission["digest"] == .string(digest),
              let kind = originKind(row["origin"]) else { return false }
        switch string(admission["by"]) {
        case "user": return true
        case "agent": return kind == "hers"
        default: return false
        }
    }

    /// On by an explicit status: the active default a guidance row gets
    /// never makes a script runnable.
    public static func isRunnable(_ row: [String: JSONValue]) -> Bool {
        ["active", "installed"].contains(string(row["status"])?.lowercased() ?? "") && admitted(row)
    }

    /// The origin a row already carries, as one to merge: none for a row that
    /// never had a script or an origin, nil (unrecorded) for a script row without one.
    static func recorded(_ row: [String: JSONValue]?) -> [JSONValue?] {
        guard let row, row["script"] != nil || row["origin"] != nil else { return [] }
        return [row["origin"]]
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
        row["scriptDigest"] = digest(script).map(JSONValue.string)
        if digest(script) != digest(before?["script"]) {
            row.removeValue(forKey: "admission")
            row["status"] = .string("draft")
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
