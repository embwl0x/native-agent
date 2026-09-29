import Foundation
import NativeAgentCore
import PersistenceCore

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
