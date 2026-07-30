import SwiftUI
import PersistenceCore

// JSON Schema-driven input form for an MCP tool. Renders one control per
// property in `schema.properties` and writes back to `values`. MVP supports
// string/integer/number/boolean/array/object plus enum, min/max, default,
// description, and required-asterisk hints. Unknown / union types fall back
// to a raw-JSON TextEditor. Submit is owned by the caller.
struct MCPInputSchemaForm: View {
    let schema: JSONValue?
    @Binding var values: [String: JSONValue]

    @State private var stringStore: [String: String] = [:]
    @State private var fallbackText: String = ""
    @State private var fallbackError: String? = nil
    @State private var jsonErrors: [String: String] = [:]
    @State private var didApplyDefaults: Bool = false

    var body: some View {
        Group {
            if let props = propertiesObject(schema), !props.isEmpty {
                let required = requiredSet(schema)
                let keys = Array(props.keys.sorted())
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(keys, id: \.self) { key in
                        if let propSchema = props[key] {
                            row(name: key, propSchema: propSchema, required: required.contains(key))
                                .padding(.vertical, 2)
                        }
                    }
                }
                .onAppear { applyDefaultsIfNeeded(props: props) }
            } else {
                fallbackEditor
            }
        }
    }

    // MARK: - Per-property row

    @ViewBuilder
    private func row(name: String, propSchema: JSONValue, required: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text(name).font(.caption)
                if required {
                    Text("*").foregroundStyle(.red).font(.caption)
                }
            }
            control(name: name, propSchema: propSchema)
            if let desc = propDescription(propSchema), !desc.isEmpty {
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let err = jsonErrors[name] {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func control(name: String, propSchema: JSONValue) -> some View {
        let typeStr = propType(propSchema)
        let typeIsUnion = propTypeIsArray(propSchema)
        let hasUnionKeyword = propHasAnyOfOneOf(propSchema)

        if typeIsUnion || hasUnionKeyword || typeStr == nil {
            jsonEditor(name: name, accept: { _ in true })
        } else if let t = typeStr {
            switch t {
            case "string":
                if let options = propEnum(propSchema) {
                    enumPicker(name: name, options: options, description: propDescription(propSchema))
                } else {
                    stringField(name: name, description: propDescription(propSchema))
                }
            case "integer":
                if let (lo, hi) = propMinMaxInt(propSchema) {
                    intStepper(name: name, lo: lo, hi: hi, description: propDescription(propSchema))
                } else {
                    intField(name: name, description: propDescription(propSchema))
                }
            case "number":
                numberField(name: name, description: propDescription(propSchema))
            case "boolean":
                boolToggle(name: name, description: propDescription(propSchema))
            case "array":
                jsonEditor(name: name, accept: { if case .array = $0 { return true } else { return false } })
            case "object":
                jsonEditor(name: name, accept: { if case .object = $0 { return true } else { return false } })
            default:
                jsonEditor(name: name, accept: { _ in true })
            }
        }
    }

    // MARK: - Field kinds

    private func stringField(name: String, description: String?) -> some View {
        let binding = Binding<String>(
            get: {
                if let s = stringStore[name] { return s }
                if case .string(let v) = values[name] ?? .null { return v }
                return ""
            },
            set: { newValue in
                stringStore[name] = newValue
                values[name] = .string(newValue)
            }
        )
        let f = TextField("", text: binding).textFieldStyle(.roundedBorder)
        return Group { if let d = description { f.help(d) } else { f } }
    }

    private func enumPicker(name: String, options: [String], description: String?) -> some View {
        let binding = Binding<String>(
            get: {
                if case .string(let v) = values[name] ?? .null { return v }
                return options.first ?? ""
            },
            // gpt-5.5 review: write through on read too — Picker shows the
            // first option when values[name] is nil, but submit would carry
            // .null (server sees absence, not the displayed value). Eager
            // seed of the visible default also handled in applyDefaultsIfNeeded.
            set: { values[name] = .string($0) }
        )
        let p = Picker(name, selection: binding) {
            ForEach(options, id: \.self) { opt in Text(opt).tag(opt) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        return Group { if let d = description { p.help(d) } else { p } }
    }

    private func intField(name: String, description: String?) -> some View {
        let binding = Binding<String>(
            get: {
                if let s = stringStore[name] { return s }
                if case .int(let v) = values[name] ?? .null { return String(v) }
                return ""
            },
            set: { newValue in
                stringStore[name] = newValue
                if let parsed = Int64(newValue) {
                    values[name] = .int(parsed)
                    jsonErrors[name] = nil
                } else if newValue.isEmpty {
                    values.removeValue(forKey: name)
                    jsonErrors[name] = nil
                } else {
                    jsonErrors[name] = "Not a valid integer"
                }
            }
        )
        let f = TextField("", text: binding).textFieldStyle(.roundedBorder)
        return Group { if let d = description { f.help(d) } else { f } }
    }

    private func intStepper(name: String, lo: Int, hi: Int, description: String?) -> some View {
        let binding = Binding<Int>(
            get: {
                if case .int(let v) = values[name] ?? .null { return Int(v) }
                return lo
            },
            set: { values[name] = .int(Int64($0)) }
        )
        let s = Stepper(value: binding, in: lo...hi) {
            Text("\(binding.wrappedValue)").font(.caption)
        }
        return Group { if let d = description { s.help(d) } else { s } }
    }

    private func numberField(name: String, description: String?) -> some View {
        let binding = Binding<String>(
            get: {
                if let s = stringStore[name] { return s }
                if case .double(let v) = values[name] ?? .null { return String(v) }
                if case .int(let v) = values[name] ?? .null { return String(v) }
                return ""
            },
            set: { newValue in
                stringStore[name] = newValue
                if newValue.isEmpty {
                    values.removeValue(forKey: name)
                    jsonErrors[name] = nil
                } else if let parsed = Double(newValue), parsed.isFinite {
                    // gpt-5.5 review: reject NaN/+Inf/-Inf — Double("nan")
                    // succeeds, but JSONSerialization later throws on
                    // non-finite values. Catch it at the form boundary.
                    values[name] = .double(parsed)
                    jsonErrors[name] = nil
                } else {
                    jsonErrors[name] = "Not a valid finite number"
                }
            }
        )
        let f = TextField("", text: binding).textFieldStyle(.roundedBorder)
        return Group { if let d = description { f.help(d) } else { f } }
    }

    private func boolToggle(name: String, description: String?) -> some View {
        let binding = Binding<Bool>(
            get: {
                if case .bool(let v) = values[name] ?? .null { return v }
                return false
            },
            set: { values[name] = .bool($0) }
        )
        let t = Toggle("", isOn: binding).labelsHidden()
        return Group { if let d = description { t.help(d) } else { t } }
    }

    private func jsonEditor(name: String, accept: @escaping (JSONValue) -> Bool) -> some View {
        let binding = Binding<String>(
            get: { stringStore[name] ?? "" },
            set: { newValue in
                stringStore[name] = newValue
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    values.removeValue(forKey: name)
                    jsonErrors[name] = nil
                    return
                }
                do {
                    let parsed = try JSONValue.parse(Data(trimmed.utf8))
                    if accept(parsed) {
                        values[name] = parsed
                        jsonErrors[name] = nil
                    } else {
                        values[name] = .null
                        jsonErrors[name] = "JSON value has wrong shape for this field"
                    }
                } catch {
                    values[name] = .null
                    jsonErrors[name] = "Invalid JSON"
                }
            }
        )
        return TextEditor(text: binding)
            .font(.system(.caption, design: .monospaced))
            .frame(minHeight: 60, maxHeight: 140)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
    }

    // MARK: - Fallback (no/empty schema)

    private var fallbackEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Input (JSON)").font(.caption)
            TextEditor(text: Binding(
                get: { fallbackText },
                set: { newValue in
                    fallbackText = newValue
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        values = [:]
                        fallbackError = nil
                        return
                    }
                    do {
                        let parsed = try JSONValue.parse(Data(trimmed.utf8))
                        if case .object(let dict) = parsed {
                            values = dict
                            fallbackError = nil
                        } else {
                            values = [:]
                            fallbackError = "Top-level JSON must be an object"
                        }
                    } catch {
                        values = [:]
                        fallbackError = "Invalid JSON"
                    }
                }
            ))
            .font(.system(.caption, design: .monospaced))
            .frame(minHeight: 80, maxHeight: 200)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            if fallbackText.isEmpty {
                Text("e.g. {\"path\": \"/tmp/x\"}")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let err = fallbackError {
                Text(err).font(.caption2).foregroundStyle(.red)
            }
        }
        .onAppear {
            // gpt-5.5 review: hydrate the JSON-text fallback editor from any
            // pre-existing values on (re-)appear. Otherwise re-expanding a
            // tool with prior input shows a blank editor while `values` still
            // holds the data, which the Run button then submits invisibly.
            if fallbackText.isEmpty && !values.isEmpty {
                let obj = JSONValue.object(values)
                if let data = try? obj.serializedData(pretty: true),
                   let text = String(data: data, encoding: .utf8) {
                    fallbackText = text
                }
            }
        }
    }

    // MARK: - Defaults

    private func applyDefaultsIfNeeded(props: [String: JSONValue]) {
        guard !didApplyDefaults else { return }
        didApplyDefaults = true
        for (key, propSchema) in props {
            guard values[key] == nil else { continue }
            // Explicit schema "default" wins.
            if let def = propDefault(propSchema) {
                values[key] = def
                continue
            }
            // gpt-5.5 review: seed implicit visible defaults so the server
            // receives what the user sees in the UI. Without this, Picker
            // shows the first enum, Stepper shows `lo`, Toggle shows `false`,
            // but values[name] is nil and submit carries absence, not the
            // visible value.
            let typeStr = propType(propSchema)
            if typeStr == "string", let options = propEnum(propSchema), let first = options.first {
                values[key] = .string(first)
            } else if typeStr == "boolean" {
                values[key] = .bool(false)
            } else if typeStr == "integer", let (lo, _) = propMinMaxInt(propSchema) {
                values[key] = .int(Int64(lo))
            }
            // string (non-enum), integer (no min/max), number, array, object,
            // and union/anyOf/oneOf controls stay unseeded — empty text /
            // empty editor correctly means absence, and submit will not
            // include those keys (intField/numberField explicitly remove the
            // key on empty input).
        }
        // gpt-5.5 review: also hydrate jsonEditor text from any pre-existing
        // values[name] (defaults applied above, or carried over from a prior
        // form session). Without this, re-expanding a tool form shows blank
        // editors even though values still holds the data.
        for (key, propSchema) in props {
            if stringStore[key] != nil { continue }
            let typeStr = propType(propSchema)
            let typeIsUnion = propTypeIsArray(propSchema)
            let hasUnionKeyword = propHasAnyOfOneOf(propSchema)
            let usesJsonEditor = typeIsUnion || hasUnionKeyword || typeStr == nil
                || typeStr == "array" || typeStr == "object"
            // gpt-5.5 v2 review: hydrate .null too — for union / unknown-type
            // JSON editors the user can legitimately submit explicit null, and
            // skipping it leaves the editor blank on re-expand while values
            // still carries the .null (same invisible-submit class as the
            // original Fix #4 bug).
            guard usesJsonEditor, let v = values[key] else { continue }
            if let data = try? v.serializedData(pretty: true),
               let text = String(data: data, encoding: .utf8) {
                stringStore[key] = text
            }
        }
    }

    // MARK: - Foundation conversion (used by callMCPToolWithInput)

    nonisolated static func toFoundationDict(_ values: [String: JSONValue]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in values { out[k] = jsonValueToAny(v) }
        return out
    }

    nonisolated private static func jsonValueToAny(_ v: JSONValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let arr): return arr.map { jsonValueToAny($0) }
        case .object(let obj):
            var dict: [String: Any] = [:]
            for (k, v) in obj { dict[k] = jsonValueToAny(v) }
            return dict
        }
    }
}

// MARK: - JSONValue schema helpers

private func propertiesObject(_ schema: JSONValue?) -> [String: JSONValue]? {
    guard let schema = schema, case .object(let root) = schema else { return nil }
    guard case .object(let props) = root["properties"] ?? .null else { return nil }
    return props
}

private func requiredSet(_ schema: JSONValue?) -> Set<String> {
    guard let schema = schema, case .object(let root) = schema else { return [] }
    guard case .array(let arr) = root["required"] ?? .null else { return [] }
    var out: Set<String> = []
    for item in arr {
        if case .string(let s) = item { out.insert(s) }
    }
    return out
}

private func propType(_ propSchema: JSONValue) -> String? {
    guard case .object(let obj) = propSchema else { return nil }
    if case .string(let s) = obj["type"] ?? .null { return s }
    return nil
}

private func propTypeIsArray(_ propSchema: JSONValue) -> Bool {
    guard case .object(let obj) = propSchema else { return false }
    if case .array = obj["type"] ?? .null { return true }
    return false
}

private func propHasAnyOfOneOf(_ propSchema: JSONValue) -> Bool {
    guard case .object(let obj) = propSchema else { return false }
    return obj["anyOf"] != nil || obj["oneOf"] != nil
}

private func propEnum(_ propSchema: JSONValue) -> [String]? {
    guard case .object(let obj) = propSchema else { return nil }
    guard case .array(let arr) = obj["enum"] ?? .null else { return nil }
    var out: [String] = []
    for item in arr {
        if case .string(let s) = item { out.append(s) }
    }
    return out.isEmpty ? nil : out
}

private func propDefault(_ propSchema: JSONValue) -> JSONValue? {
    guard case .object(let obj) = propSchema else { return nil }
    return obj["default"]
}

private func propDescription(_ propSchema: JSONValue) -> String? {
    guard case .object(let obj) = propSchema else { return nil }
    if case .string(let s) = obj["description"] ?? .null { return s }
    return nil
}

private func propMinMaxInt(_ propSchema: JSONValue) -> (Int, Int)? {
    guard case .object(let obj) = propSchema else { return nil }
    func asInt(_ v: JSONValue?) -> Int? {
        guard let v = v else { return nil }
        switch v {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        default: return nil
        }
    }
    guard let lo = asInt(obj["minimum"]), let hi = asInt(obj["maximum"]), lo <= hi else { return nil }
    return (lo, hi)
}
