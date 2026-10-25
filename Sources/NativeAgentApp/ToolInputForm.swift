import ToolRegistry
import Foundation
import SwiftUI
import PersistenceCore

// Blueprint: | `ToolInputForm.swift` | `ToolInputForm`: schema-driven argument draft, field validation and explicit submit for tools requiring structured input |

// PATCH-Phase7b: ToolInputForm — shown when a slash-command tool needs multiple
// or non-string fields that can't be satisfied by free-text alone.
//
// Opened as a .sheet from dispatchSlashCommandTool (ContentView) when
// DispatchPlanMode == .formNeeded.

// ---------------------------------------------------------------------------
// MARK: - Main sheet
// ---------------------------------------------------------------------------

struct ToolInputForm: View {
    @Environment(AppModel.self) private var appModel
    let plan: DispatchArgPlan
    /// Called on "Run" with a validated, JSON-shaped dispatch body.
    let onSubmit: (Data) -> Void
    let onCancel: () -> Void

    private struct Draft {
        var strings: [String: String] = [:]
        var bools: [String: Bool] = [:]
        var ints: [String: Int] = [:]
    }
    private var draftSubject: String { "tool-input/\(plan.sessionId)/\(plan.tool.name)" }
    @State private var localDraft: Draft?
    @State private var retainsDraft = false
    private var draft: Binding<Draft> {
        Binding(get: {
            retainsDraft ? appModel.editDraft(draftSubject, seed: initialDraft())
                : localDraft ?? initialDraft()
        }, set: {
            if retainsDraft { appModel.setEditDraft($0, for: draftSubject) }
            else { localDraft = $0 }
        })
    }
    @State private var validationError: String? = nil

    @State private var tool: ToolCapability?
    @State private var checking = false
    private var schema: ToolInputSchema? { tool?.inputSchema }
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
                    Text("Run \(plan.tool.name)")
                        .font(NativeAgentFont.title)
                    if let tool, !tool.description.isEmpty {
                        Text(tool.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if let tool { AutonomyFormBadge(autonomy: tool.effectiveAutonomy) }
            }
            .padding(.horizontal, NativeAgentSpacing.lg)
            .padding(.vertical, NativeAgentSpacing.md)

            Divider()

            // Field form
            ScrollView {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                    if tool == nil {
                        if validationError == nil { ProgressView() }
                    } else if orderedFields.isEmpty {
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
                                    stringValues: draft.strings,
                                    boolValues: draft.bools,
                                    intValues: draft.ints
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
                Button("Cancel") { appModel.clearEditDraft(draftSubject); onCancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityIdentifier("tool-input-form-cancel")
                Button("Run") { checking = true }
                    .disabled(tool == nil || checking)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .hazeTinted(.button)
                    .accessibilityIdentifier("tool-input-form-run")
            }
            .padding(.horizontal, NativeAgentSpacing.lg)
            .padding(.vertical, NativeAgentSpacing.md)
        }
        .frame(minWidth: 460, minHeight: 300)
        .task(id: checking) { if checking { await attemptSubmit() } }
        .task {
            do {
                let descriptor = try await appModel.engine.tools.inputDescriptor(named: plan.tool.name)
                guard !Task.isCancelled else { return }
                accept(descriptor)
            } catch {
                validationError = "Couldn't check input schema: \(error.localizedDescription)"
            }
        }
    }

    private func initialDraft() -> Draft {
        var draft = Draft()
        for (key, value) in plan.prefilled {
            if let string = value as? String { draft.strings[key] = string }
            else if let bool = value as? Bool { draft.bools[key] = bool }
            else if let int = value as? Int { draft.ints[key] = int }
            else { draft.strings[key] = "\(value)" }
        }
        return draft
    }

    private func accept(_ descriptor: ToolCapability) {
        tool = descriptor
        retainsDraft = descriptor.inputSchema?.containsSecret == false
        if !retainsDraft { appModel.clearEditDraft(draftSubject) }
    }

    private func attemptSubmit() async {
        guard let tool else { return }
        defer { checking = false }
        validationError = nil
        do {
            let current = try await appModel.engine.tools.inputDescriptor(named: tool.name)
            try Task.checkCancellation()
            guard current == tool else {
                localDraft = nil
                appModel.clearEditDraft(draftSubject)
                accept(current)
                validationError = "This tool changed. Review its current inputs before running it."
                return
            }
            let inputData = try ChatToolCatalogSnapshot.serializedInput(
                schema: schema,
                stringValues: draft.wrappedValue.strings,
                boolValues: draft.wrappedValue.bools,
                intValues: draft.wrappedValue.ints
            )
            onSubmit(inputData)
            appModel.clearEditDraft(draftSubject)
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
                .hazeTinted()
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
