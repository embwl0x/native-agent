import Foundation
import NativeAgentCore
import PersistenceCore

/// A find-and-load request uses the final catalog ranking. Loading never
/// executes the selected capability.
///
/// 2026-09-24 (tool discovery cost): 95 of 188 September searches were
/// followed by a separate tool_load before she could act. A search with a
/// query now loads its best matches in the same call (`load:false` opts
/// out), and every match row carries its `call` signature.
public enum ToolCatalogSelection {
    public static func selectedName(in result: JSONValue) -> String? {
        guard case .object(let envelope) = result,
              envelope["status"] == .string("ok"),
              case .array(let matches)? = envelope["matches"],
              let first = matches.first, case .object(let winner) = first,
              case .string(let name)? = winner["name"],
              !name.hasPrefix("mcp__"),
              case .int(let score)? = winner["match_score"], score > 0 else { return nil }
        // A tied shortlist needs the agent's judgment; don't load competing
        // families or use alphabetical order as a capability decision.
        if matches.dropFirst().contains(where: { value in
            guard case .object(let row) = value else { return false }
            return row["match_score"] == .int(score)
        }) { return nil }
        // A one-row requested limit can conceal a tie; callers obtain at least
        // two rows before consulting this selector.
        return name
    }

    /// The unique best native match, or up to three tied best matches: loading
    /// grants nothing, so a small tie is loaded whole rather than handed back
    /// as a separate tool_load step.
    public static func selectedNames(in result: JSONValue) -> [String] {
        if let name = selectedName(in: result) { return [name] }
        guard case .object(let envelope) = result, envelope["status"] == .string("ok"),
              case .array(let matches)? = envelope["matches"],
              case .object(let winner)? = matches.first,
              case .int(let score)? = winner["match_score"], score > 0 else { return [] }
        let tied = matches.compactMap { value -> String? in
            guard case .object(let row) = value, row["match_score"] == .int(score),
                  case .string(let name)? = row["name"] else { return nil }
            return name
        }
        guard tied.count <= 3, !tied.contains(where: { $0.hasPrefix("mcp__") }) else { return [] }
        return tied
    }

    /// A query loads its best match unless the caller said `load:false`.
    public static func wantsLoad(_ input: [String: JSONValue]) -> Bool {
        switch input["load"] {
        case .bool(let value)?: return value
        case .string(let text)?:
            let word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["false", "no", "0"].contains(word) { return false }
            if ["true", "yes", "1"].contains(word) { return true }
        default: break
        }
        guard case .string(let query)? = input["query"] else { return false }
        return !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The caller asked for the load (`load:true`), rather than a plain query.
    public static func loadWasAsked(_ input: [String: JSONValue]) -> Bool {
        input["load"] != nil && input["load"] != .null && wantsLoad(input)
    }

    public static func searchInput(_ input: [String: JSONValue]) -> [String: JSONValue] {
        var search = input
        // Explicitly off: the search itself must not select-and-load again.
        search["load"] = .bool(false)
        let limit: Int64
        switch search["limit"] {
        case .int(let value): limit = value
        case .double(let value): limit = Int64(exactly: value) ?? 10
        default: limit = 10
        }
        search["limit"] = .int(max(2, min(25, limit)))
        return search
    }

    public static func finish(_ result: JSONValue, selected: [String], loading: JSONValue?) -> JSONValue {
        guard case .object(var envelope) = result else { return result }
        guard !selected.isEmpty, let loading else {
            envelope["selection_note"] = .string("Nothing was loaded: pick a tool from matches and call it by name with its call signature; calling loads it.")
            return .object(envelope)
        }
        var loaded: Set<String> = []
        if case .object(let receipt) = loading {
            // Keep the existing loader contract at the usual envelope level,
            // including schemas for providers whose tool list is turn-pinned.
            for key in ["loaded", "loaded_now", "already_active", "schemas_added"] {
                envelope[key] = receipt[key]
            }
            for key in ["loaded", "already_active"] {
                if case .array(let values)? = receipt[key] {
                    loaded.formUnion(values.compactMap { if case .string(let name) = $0 { name } else { nil } })
                }
            }
            if receipt["status"] == .string("refused") { envelope["loading"] = loading }
        }
        let ready = selected.filter(loaded.contains)
        envelope["selected_tools"] = .array(selected.map(JSONValue.string))
        envelope["selection_status"] = .string(ready.isEmpty ? "not_loaded" : "loaded")
        if !ready.isEmpty {
            envelope["selection_note"] = .string("Loaded \(ready.joined(separator: ", ")). Call it now with the arguments its call signature shows; no tool_load needed.")
            envelope.removeValue(forKey: "load_next")
            if case .array(let matches)? = envelope["matches"] {
                envelope["matches"] = .array(matches.map { value in
                    guard case .object(var row) = value, case .string(let name)? = row["name"], ready.contains(name) else { return value }
                    row["load_state"] = .string("loaded")
                    return .object(row)
                })
            }
        }
        return .object(envelope)
    }
}

/// A tool's arguments as one line a caller can copy from:
/// `act(target*, verb*=click|open, app, front:bool, steps:[str|{verb*,target*,text}])`.
/// Required first (`*`), then by name; auto-filled session fields are left out.
public enum ToolSignature {
    private static func properties(_ data: Data) -> (props: [String: [String: Any]], required: Set<String>)? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = raw["properties"] as? [String: Any] else { return nil }
        var visible: [String: [String: Any]] = [:]
        for (key, value) in props {
            let property = value as? [String: Any] ?? [:]
            let about = (property["description"] as? String ?? "").lowercased()
            if key == "__session_id" || about.contains("auto-fill") || about.contains("supplied automatically") { continue }
            visible[key] = property
        }
        return (visible, Set(raw["required"] as? [String] ?? []))
    }

    private static func ordered(_ props: [String: [String: Any]], _ required: Set<String>) -> [String] {
        props.keys.sorted { a, b in required.contains(a) != required.contains(b) ? required.contains(a) : a < b }
    }

    private static func type(_ property: [String: Any]) -> String? {
        if let type = property["type"] as? String { return type }
        if let types = property["type"] as? [String] { return types.first { $0 != "null" } }
        if let any = (property["anyOf"] ?? property["oneOf"]) as? [[String: Any]] {
            return any.compactMap(type).first { $0 != "null" }
        }
        return nil
    }

    /// `str`, `int`, `{a*,b}`, `[str|{verb*,target*}]` — the value's shape.
    private static func shape(_ property: [String: Any], depth: Int = 0) -> String {
        if let alternatives = (property["anyOf"] ?? property["oneOf"]) as? [[String: Any]] {
            let shapes = alternatives.filter { type($0) != "null" }.map { shape($0, depth: depth) }
            if !shapes.isEmpty { return shapes.joined(separator: "|") }
        }
        switch type(property) {
        case "integer": return "int"
        case "number": return "num"
        case "boolean": return "bool"
        case "array":
            let items = property["items"] as? [String: Any] ?? [:]
            return "[" + (depth > 1 ? "…" : shape(items, depth: depth + 1)) + "]"
        case "object":
            guard depth <= 1, let props = property["properties"] as? [String: Any], !props.isEmpty else { return "{}" }
            let required = Set(property["required"] as? [String] ?? [])
            let keys = props.keys.sorted { a, b in required.contains(a) != required.contains(b) ? required.contains(a) : a < b }
            return "{" + keys.map { $0 + (required.contains($0) ? "*" : "") }.joined(separator: ",") + "}"
        default:
            if let values = property["enum"] as? [String], (1...8).contains(values.count) { return values.joined(separator: "|") }
            return "str"
        }
    }

    public static func call(_ name: String, _ parametersJSON: Data) -> String {
        guard let (props, required) = properties(parametersJSON) else { return name + "()" }
        let parts = ordered(props, required).map { key -> String in
            let property = props[key] ?? [:]
            let mark = required.contains(key) ? "*" : ""
            let form = shape(property)
            if form == "str" { return key + mark }
            if property["enum"] != nil, !form.hasPrefix("[") { return key + mark + "=" + form }
            return key + mark + ":" + form
        }
        return name + "(" + parts.joined(separator: ", ") + ")"
    }

    /// One short line per argument, same order: "steps: up to 12 acts in ONE call…".
    /// Argument names, required and optional, auto-filled ones left out.
    public static func argumentNames(_ parametersJSON: Data) -> (required: [String], optional: [String]) {
        guard let (props, required) = properties(parametersJSON) else { return ([], []) }
        let all = ordered(props, required)
        return (all.filter(required.contains), all.filter { !required.contains($0) })
    }

    public static func params(_ parametersJSON: Data, limit: Int = 90) -> [String] {
        guard let (props, required) = properties(parametersJSON) else { return [] }
        return ordered(props, required).compactMap { key in
            guard let about = (props[key]?["description"] as? String)?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces), !about.isEmpty else { return nil }
            return key + ": " + (about.count > limit ? String(about.prefix(limit - 1)) + "…" : about)
        }
    }
}
