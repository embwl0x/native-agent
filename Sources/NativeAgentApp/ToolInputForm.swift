import SwiftUI

// PATCH-Phase7b: ToolInputForm — shown when a slash-command tool needs multiple
// or non-string fields that can't be satisfied by free-text alone.
//
// Opened as a .sheet from dispatchSlashCommandTool (ContentView) when
// DispatchPlanMode == .formNeeded.

// ---------------------------------------------------------------------------
// MARK: - Main sheet
// ---------------------------------------------------------------------------

struct ToolInputForm: View {
    let plan: DispatchArgPlan
    /// Called on "Run" with the collected values.
    let onSubmit: ([String: Any]) -> Void
    let onCancel: () -> Void

    // Per-field text storage (all fields start as strings; we coerce on submit).
    @State private var stringValues: [String: String] = [:]
    @State private var boolValues:   [String: Bool]   = [:]
    @State private var intValues:    [String: Int]     = [:]
    @State private var validationError: String? = nil

    private var tool: ToolCapability { plan.tool }
    private var schema: ToolInputSchema? { tool.inputSchema }
    private var requiredFields: Set<String> { Set(schema?.required ?? []) }

    // Ordered property names: required first, then optional.
    private var orderedFields: [String] {
        guard let props = schema?.properties else { return [] }
        let req  = (schema?.required ?? []).filter { props[$0] != nil }
        let opt  = props.keys.filter { !requiredFields.contains($0) }.sorted()
        return req + opt
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: NativeAgentSpacing.md) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run \(tool.name)")
                        .font(NativeAgentFont.title)
                    if !tool.description.isEmpty {
                        Text(tool.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                AutonomyFormBadge(autonomy: tool.effectiveAutonomy)
            }
            .padding(.horizontal, NativeAgentSpacing.lg)
            .padding(.vertical, NativeAgentSpacing.md)

            Divider()

            // Field form
            ScrollView {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    if orderedFields.isEmpty {
                        Text("This tool takes no inputs. Press Run to dispatch immediately.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, NativeAgentSpacing.sm)
                    } else {
                        ForEach(orderedFields, id: \.self) { fieldName in
                            if let prop = schema?.properties?[fieldName] {
                                ToolFieldRow(
                                    name: fieldName,
                                    prop: prop,
                                    required: requiredFields.contains(fieldName),
                                    stringValues: $stringValues,
                                    boolValues:   $boolValues,
                                    intValues:    $intValues
                                )
                            }
                        }
                    }

                    if let err = validationError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(Color.red)
                    }
                }
                .padding(NativeAgentSpacing.lg)
            }

            Divider()

            // Footer buttons
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Run") { attemptSubmit() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, NativeAgentSpacing.lg)
            .padding(.vertical, NativeAgentSpacing.md)
        }
        .frame(minWidth: 460, minHeight: 300)
        .onAppear { seedPrefilled() }
    }

    // Seed pre-filled values coming from the plan (e.g. single-arg shortcut that
    // opened the form as a fallback after detecting formNeeded).
    private func seedPrefilled() {
        for (k, v) in plan.prefilled {
            if let s = v as? String { stringValues[k] = s }
            else if let b = v as? Bool { boolValues[k] = b }
            else if let i = v as? Int { intValues[k] = i }
            else { stringValues[k] = "\(v)" }
        }
    }

    private func attemptSubmit() {
        validationError = nil
        var collected: [String: Any] = [:]

        guard let props = schema?.properties else {
            onSubmit([:])
            return
        }

        for (name, prop) in props {
            switch prop.type ?? "string" {
            case "boolean":
                collected[name] = boolValues[name] ?? false
            case "integer":
                if let v = intValues[name] {
                    collected[name] = v
                }
                // Fallback: try parsing the string value if present.
                else if let s = stringValues[name], let i = Int(s) {
                    collected[name] = i
                }
            default: // "string", "object", "array", unknown → string
                if let s = stringValues[name], !s.isEmpty {
                    collected[name] = s
                }
            }
        }

        // Validate required fields are present and non-empty.
        for field in schema?.required ?? [] {
            let missing: Bool
            switch props[field]?.type ?? "string" {
            case "boolean": missing = false // booleans always have a value
            case "integer": missing = collected[field] == nil
            default:        missing = (collected[field] as? String)?.isEmpty != false
                                      && collected[field] == nil
            }
            if missing {
                validationError = "Field \"\(field)\" is required."
                return
            }
        }

        onSubmit(collected)
    }
}

// ---------------------------------------------------------------------------
// MARK: - Per-field row
// ---------------------------------------------------------------------------

private struct ToolFieldRow: View {
    let name: String
    let prop: ToolInputProp
    let required: Bool
    @Binding var stringValues: [String: String]
    @Binding var boolValues:   [String: Bool]
    @Binding var intValues:    [String: Int]

    private var fieldType: String { prop.type ?? "string" }

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
            // Label row
            HStack(spacing: 4) {
                Text(name)
                    .font(.caption.weight(.semibold))
                if required {
                    Text("*")
                        .foregroundStyle(Color.red)
                        .font(.caption.weight(.bold))
                }
                Spacer()
                Text(fieldType)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let desc = prop.description, !desc.isEmpty {
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Input control
            switch fieldType {
            case "boolean":
                Toggle(isOn: Binding(
                    get: { boolValues[name] ?? false },
                    set: { boolValues[name] = $0 }
                )) {
                    Text(boolValues[name] == true ? "true" : "false")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

            case "integer":
                Stepper(
                    value: Binding(
                        get: { intValues[name] ?? 0 },
                        set: { intValues[name] = $0 }
                    ),
                    in: Int.min...Int.max
                ) {
                    Text("\(intValues[name] ?? 0)")
                        .font(.caption)
                        .monospacedDigit()
                }

            case "object", "array":
                // Free-form JSON string input with placeholder hint.
                ZStack(alignment: .topLeading) {
                    if stringValues[name, default: ""].isEmpty {
                        Text(fieldType == "object" ? "{}" : "[]")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                    }
                    TextEditor(text: Binding(
                        get: { stringValues[name, default: ""] },
                        set: { stringValues[name] = $0 }
                    ))
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                }

            default: // "string"
                TextField(prop.description ?? name, text: Binding(
                    get: { stringValues[name, default: ""] },
                    set: { stringValues[name] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Autonomy badge (local copy scoped to this file)
// ---------------------------------------------------------------------------

// Private to this form because its labels describe form-level autonomy.
private struct AutonomyFormBadge: View {
    let autonomy: String

    var body: some View {
        let label: String
        let status: String
        switch autonomy.lowercased() {
        case "auto":    label = "Auto";           status = "ok"
        case "confirm": label = "Needs approval"; status = "warn"
        case "blocked": label = "Blocked";        status = "fail"
        default:        label = autonomy.capitalized; status = "warn"
        }
        return StatusBadge(text: label, status: status)
    }
}
