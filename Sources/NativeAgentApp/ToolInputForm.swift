import Foundation
import SwiftUI

/// The schema-owned conversion boundary between the visual form controls and
/// the dispatch transport. Every accepted value is JSON-shaped, so a sheet
/// cannot close and accidentally turn a malformed complex field into `{}`.
enum ToolInputFormInput {
    enum ValidationError: LocalizedError, Equatable {
        case missingRequiredField(String)
        case missingSchemaForRequiredField(String)
        case invalidJSON(field: String, expected: String)
        case serializationFailed

        var errorDescription: String? {
            switch self {
            case .missingRequiredField(let field):
                return "Field \"\(field)\" is required."
            case .missingSchemaForRequiredField(let field):
                return "Required field \"\(field)\" has no usable schema."
            case .invalidJSON(let field, let expected):
                return "Field \"\(field)\" must be valid JSON \(expected)."
            case .serializationFailed:
                return "Tool input could not be encoded for dispatch."
            }
        }
    }

    static func serializedInput(
        schema: ToolInputSchema?,
        stringValues: [String: String],
        boolValues: [String: Bool],
        intValues: [String: Int]
    ) throws -> Data {
        guard let schema else {
            return try JSONSerialization.data(withJSONObject: [:])
        }
        guard let properties = schema.properties else {
            if let required = schema.required, let field = required.first {
                throw ValidationError.missingSchemaForRequiredField(field)
            }
            return try JSONSerialization.data(withJSONObject: [:])
        }

        let required = Set(schema.required ?? [])
        for field in required where properties[field] == nil {
            throw ValidationError.missingSchemaForRequiredField(field)
        }

        var collected: [String: Any] = [:]
        for (name, prop) in properties {
            let type = (prop.type ?? "string").lowercased()
            switch type {
            case "boolean":
                if required.contains(name) || boolValues[name] != nil {
                    collected[name] = boolValues[name] ?? false
                }
            case "integer":
                if let value = intValues[name] {
                    collected[name] = value
                } else if let raw = stringValues[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
                          let value = Int(raw) {
                    collected[name] = value
                }
            case "object", "array":
                guard let raw = nonblank(stringValues[name]) else { continue }
                guard let data = raw.data(using: .utf8),
                      let decoded = try? JSONSerialization.jsonObject(with: data) else {
                    throw ValidationError.invalidJSON(field: name, expected: "\(type) text")
                }
                if type == "object", let object = decoded as? [String: Any] {
                    collected[name] = object
                } else if type == "array", let array = decoded as? [Any] {
                    collected[name] = array
                } else {
                    throw ValidationError.invalidJSON(field: name, expected: "\(type) text")
                }
            default:
                if let value = nonblank(stringValues[name]) {
                    collected[name] = value
                }
            }
        }

        for field in required where collected[field] == nil {
            throw ValidationError.missingRequiredField(field)
        }
        guard JSONSerialization.isValidJSONObject(collected) else {
            throw ValidationError.serializationFailed
        }
        do {
            return try JSONSerialization.data(withJSONObject: collected)
        } catch {
            throw ValidationError.serializationFailed
        }
    }

    private static func nonblank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

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
    /// Called on "Run" with a validated, JSON-shaped dispatch body.
    let onSubmit: (Data) -> Void
    let onCancel: () -> Void

    // Per-field control values, validated and converted at the dispatch boundary.
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
                            .accessibilityIdentifier("tool-input-form-validation-error")
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
                    .accessibilityIdentifier("tool-input-form-cancel")
                Button("Run") { attemptSubmit() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("tool-input-form-run")
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
        do {
            let inputData = try ToolInputFormInput.serializedInput(
                schema: schema,
                stringValues: stringValues,
                boolValues: boolValues,
                intValues: intValues
            )
            onSubmit(inputData)
        } catch {
            validationError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
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

    private var fieldType: String { (prop.type ?? "string").lowercased() }

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
                .accessibilityIdentifier("tool-input-field-\(name)")

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
                .accessibilityIdentifier("tool-input-field-\(name)")

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
                    .accessibilityIdentifier("tool-input-field-\(name)")
                }

            default: // "string"
                TextField(prop.description ?? name, text: Binding(
                    get: { stringValues[name, default: ""] },
                    set: { stringValues[name] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .accessibilityIdentifier("tool-input-field-\(name)")
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
