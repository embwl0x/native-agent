import SwiftUI
import Foundation
// Blueprint: | `FaceFormView.swift` | Shared public and protected field drawing, validation and retained form settlement |

/// The one on-colour of a switch on the Mac: a quiet neutral that follows light and dark. The app's shell uses it for its own switches too.
public enum FaceSwitchTint {
    public static let on = Color.primary.opacity(0.5)
}

@MainActor enum FaceFieldInput {
    static func line(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text).textFieldStyle(.roundedBorder).accessibilityLabel(label)
    }
    static func lines(_ label: String, text: Binding<String>) -> some View {
        let shape = RoundedRectangle(cornerRadius: NativeAgentRadius.control, style: .continuous)
        return TextEditor(text: text).font(.body).frame(minHeight: 160)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color.primary.opacity(0.04), in: shape)
            .overlay { shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 1).allowsHitTesting(false) }
            .accessibilityLabel(label)
    }
    /// The system switch, on in a quiet neutral on the Mac: a column of switches in the system's accent is colour on every control, and the
    /// app's one accent means something else. The tint is on the switch itself, never on a page.
    static func toggle(_ label: String, value: Binding<Bool>) -> some View {
        Toggle(label, isOn: value).labelsHidden().toggleStyle(.switch)
        #if os(macOS)
            .tint(FaceSwitchTint.on)
        #endif
    }
    /// A long list whose options carry a `path` nests into submenus, as Chat's model menu does; a short flat one stays one menu.
    @ViewBuilder static func choice(_ label: String, options: [PartFace.Control.Option], value: Binding<String>, allowsEmpty: Bool) -> some View {
        #if os(macOS)
        let usesMenu = true
        #else
        let usesMenu = options.contains(where: { ($0.path?.count ?? 0) > 1 })
        #endif
        if usesMenu {
            let selectedLabel = options.first { $0.id == value.wrappedValue }?.label ?? "Choose…"
            Menu {
                if allowsEmpty { Button("Choose…") { value.wrappedValue = "" } }
                FaceChoiceMenu(options: options, depth: 0, value: value)
            } label: {
                Text(selectedLabel).lineLimit(1).truncationMode(.tail)
            }
            .accessibilityLabel(label)
            .accessibilityValue(selectedLabel)
        } else {
            Picker(label, selection: value) {
                if allowsEmpty { Text("Choose…").tag("") }
                ForEach(options) { Text($0.label).tag($0.id) }
            }.labelsHidden().pickerStyle(.menu)
        }
    }
    static func date(_ label: String, value: Binding<Date>) -> some View {
        DatePicker(label, selection: value, displayedComponents: .date).labelsHidden()
    }
    static func number(_ label: String, words: String, increment: @escaping () -> Void, decrement: @escaping () -> Void) -> some View {
        Stepper { Text(words).monospacedDigit() } onIncrement: { increment() } onDecrement: { decrement() }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(label)
            .accessibilityValue(words)
    }
}

extension FacePageSession {
    private func formKey(_ block: PartFace.Block, field: String, section: String) -> String {
        draftKey(.init(section: section, row: block.key)) + "/field:" + String(field.utf8.count) + ":" + field
    }

    public func formValues(_ block: PartFace.Block, section: String) -> [String: PartFace.Value] {
        guard block.protected != true, block.fields?.contains(where: { $0.kind == "secret" }) != true else { return [:] }
        var values: [String: PartFace.Value] = [:]
        for field in block.fields ?? [] {
            var value = formValue(field, block: block, section: section)
            if ["number", "date", "choice"].contains(field.kind), case .string(let text) = value,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if field.kind == "number", case .string(let text) = value, let number = Double(text), number.isFinite { value = .double(number) }
            if value != .null { values[field.id] = value }
        }
        return values
    }

    func formValue(_ field: PartFace.FormField, block: PartFace.Block, section: String) -> PartFace.Value {
        drafts.value(formKey(block, field: field.id, section: section), seed: field.value ?? .null)
    }

    public func formBaseline(_ block: PartFace.Block, section: String) -> [String: PartFace.Value] {
        var values: [String: PartFace.Value] = [:]
        for field in block.fields ?? [] {
            values[field.id] = drafts.baseline(formKey(block, field: field.id, section: section), seed: field.value ?? .null)
        }
        return values
    }

    public func setFormValue(_ value: PartFace.Value, field: String, block: PartFace.Block, section: String) {
        guard block.protected != true, let spec = block.fields?.first(where: { $0.id == field }), spec.kind != "secret" else { return }
        drafts.set(value, for: formKey(block, field: field, section: section), baseline: spec.value ?? .null)
        if let state = self[row: block.key], state.formErrors[field] != nil { state.formErrors[field] = nil }
    }

    public func clearForm(_ block: PartFace.Block, section: String) {
        for field in block.fields ?? [] { drafts.clear(formKey(block, field: field.id, section: section)) }
        self[row: block.key]?.formErrors = [:]
    }

    func submitForm(_ block: PartFace.Block, section: String, action: PartFace.Action, door: any FaceDoor, validating: Bool = true) {
        guard !held(.init(section: section, row: block.key)), action.unavailable == nil,
              block.protected != true, block.fields?.contains(where: { $0.kind == "secret" }) != true,
              action.runs(from: FaceView.door), block.doors?.contains(FaceView.door) != false else { return }
        let values = formValues(block, section: section)
        let errors = validating ? block.formIssues(values: values) : [:]
        editRow(block.key).formErrors = errors
        guard errors.isEmpty else { return }
        var edits: [String: String] = [:]
        for field in block.fields ?? [] { edits[field.id] = formKey(block, field: field.id, section: section) }
        submit(.init(section: section, row: block.key), row: block.key, action: action.id, value: nil, call: action.call, door: door,
               values: values, formRevision: block.revision, formEdits: edits)
    }
}

struct FaceFormBlock: View {
    let block: PartFace.Block
    let section: String
    let session: FacePageSession
    let door: any FaceDoor
    @Environment(\.faceStyle) private var style
    @Environment(\.faceSecretForm) private var secretForm
    @Environment(\.faceProtectedEntry) private var protectedEntry
    @State private var confirming: PartFace.Action?
    private var item: FaceItemID { .init(section: section, row: block.key) }
    private var protected: Bool { block.protected == true || block.fields?.contains(where: { $0.kind == "secret" }) == true }
    private var unsupported: Bool {
        block.fields?.contains(where: { !["line", "lines", "choice", "switch", "number", "date", "secret"].contains($0.kind) }) == true
    }
    private var admitted: Bool { FaceView.door == "mac" && secretForm?.admits(block) == true }
    private var plain: PartFace.Block { protected ? block.withoutSecrets : block }

    private func submit(_ action: PartFace.Action) {
        if protected, admitted { secretForm?.submit(block, section: section, action: action, session: session) }
        else { session.submitForm(block, section: section, action: action, door: door) }
    }

    var body: some View {
        if FaceView.door != "mac", protected || block.doors == ["mac"] {
            note("This opens on your Mac.")
        } else if protected, !admitted {
            if let receiver = block.receiver, receiver.hasPrefix("keyring:"), let protectedEntry {
                protectedEntry(block)
            } else { note("This form requires its protected entry owner.") }
        } else if unsupported {
            note(PartFace.Block.updateNote)
        } else if let doors = block.doors, !doors.contains(FaceView.door) {
            note("This form opens on " + doors.joined(separator: " or ") + ".")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(block.fields ?? []) { field in
                    if field.kind == "secret", let secretForm, admitted {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.label).font(.callout)
                            SecureField(field.placeholder ?? field.label, text: secretForm.entry.binding(field.id))
                                .textFieldStyle(.roundedBorder).privacySensitive().accessibilityLabel(field.label)
                            if let error = session[row: block.key]?.formErrors[field.id] { Text(error).font(.caption).foregroundStyle(.red) }
                        }
                    } else {
                        FaceFormField(field: field, block: plain, section: section, session: session, commit: commit)
                    }
                }
                FaceFlow(spacing: 12) {
                    ForEach((block.submit ?? []).filter { $0.runs(from: FaceView.door) }) { action in
                        Button(action.label) {
                            if action.role == .destructive { confirming = action }
                            else { submit(action) }
                        }
                        .buttonStyle(FaceActionButtonStyle(fill: nil))
                        .disabled(session.held(item) || action.unavailable != nil)
                        .help(action.unavailable ?? action.label)
                    }
                }
                ForEach((block.submit ?? []).filter { $0.runs(from: FaceView.door) && $0.unavailable != nil }) { action in
                    if let reason = action.unavailable { Text(action.label + ": " + reason).font(.caption).foregroundStyle(.secondary) }
                }
                outcome
            }
            .padding(style.insets)
            .onChange(of: secretForm?.entry.generation) { session.discardCheckResult(block.key) }
            .onChange(of: session.formValues(plain, section: section)) { session.discardCheckResult(block.key) }
            .confirmationDialog(confirming?.label ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                                titleVisibility: .visible) {
                if let action = confirming {
                    Button(action.label, role: .destructive) {
                        submit(action); confirming = nil
                    }
                }
                Button("Cancel", role: .cancel) { confirming = nil }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(style.insets)
    }

    private func commit() {
        let actions = (block.submit ?? []).filter { $0.runs(from: FaceView.door) && $0.unavailable == nil }
        guard let action = actions.first(where: { $0.role == .primary }) ?? (actions.count == 1 ? actions.first : nil) else { return }
        if action.role == .destructive { confirming = action }
        else { submit(action) }
    }

    @ViewBuilder private var outcome: some View {
        if let refusal = session[row: block.key]?.refusal { Text(refusal.localizedDescription).foregroundStyle(.red).textSelection(.enabled) }
        let fields = Set((block.fields ?? []).map(\.id))
        ForEach((session[row: block.key]?.formErrors ?? [:]).keys.filter { !fields.contains($0) }.sorted(), id: \.self) { key in
            if let words = session[row: block.key]?.formErrors[key] { Text(key + ": " + words).foregroundStyle(.red) }
        }
        if let operation = session.operation(for: block.key) {
            if let outcome = operation.outcome, !operation.checking {
                if let failure = outcome.failure { Text(failure.localizedDescription).foregroundStyle(.red).textSelection(.enabled) }
                if let words = outcome.words { Text(words).textSelection(.enabled) }
                if outcome.unresolved {
                    Text("Not sure that went through. Check before sending again.").foregroundStyle(.secondary)
                    Button("Check") { session.check(item, door: door) }.buttonStyle(FaceActionButtonStyle(fill: nil))
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(operation.cancelling ? "Waiting on cancellation…" : "Waiting on " + door.waitingOn + "…")
                    Button(door.cancellationLabel) { session.cancel(item) }.disabled(operation.cancelling)
                }
            }
        }
    }
}

private struct FaceFormField: View {
    let field: PartFace.FormField
    let block: PartFace.Block
    let section: String
    let session: FacePageSession
    let commit: () -> Void
    private var value: PartFace.Value { session.formValue(field, block: block, section: section) }
    private func set(_ value: PartFace.Value) { session.setFormValue(value, field: field.id, block: block, section: section) }
    private var text: Binding<String> {
        Binding(get: {
            switch value {
            case .string(let text): text
            case .int(let number): String(number)
            case .double(let number): String(number)
            default: ""
            }
        }, set: { set(.string($0)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.label).font(.callout)
            control
            if let error = session[row: block.key]?.formErrors[field.id] { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var control: some View {
        switch field.kind {
        case "line":
            FaceFieldInput.line(field.label, placeholder: field.placeholder ?? field.label, text: text).onSubmit(commit)
        case "number":
            HStack {
                FaceFieldInput.line(field.label, placeholder: field.placeholder ?? field.label, text: text).onSubmit(commit)
                if let number = Double(text.wrappedValue), number.isFinite {
                    FaceFieldInput.number(field.label, words: text.wrappedValue, increment: { changeNumber(number, direction: 1) },
                                          decrement: { changeNumber(number, direction: -1) }).labelsHidden()
                }
            }
        case "date":
            HStack {
                FaceFieldInput.line(field.label, placeholder: field.placeholder ?? "ISO 8601 date", text: text).onSubmit(commit)
                if let date = UserDisplayFormatters.parseISOTimestamp(text.wrappedValue) {
                    FaceFieldInput.date(field.label, value: Binding(get: { date }, set: { set(.string($0.ISO8601Format())) }))
                }
            }
        case "lines":
            FaceFieldInput.lines(field.label, text: text)
                #if os(macOS)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    commit(); return .handled
                }
                #endif
        case "switch":
            FaceFieldInput.toggle(field.label, value: Binding(get: { value == .bool(true) }, set: { set(.bool($0)) }))
            if value == .null { Text("Not set").font(.caption).foregroundStyle(.secondary) }
        case "choice":
            FaceFieldInput.choice(field.label, options: field.options ?? [], value: text, allowsEmpty: true)
        default:
            Text("This field needs a door that supports " + field.kind + ".").foregroundStyle(.secondary)
        }
    }

    private func changeNumber(_ number: Double, direction: Double) {
        let changed = number + direction * (field.step ?? 1)
        guard changed.isFinite, field.min.map({ changed >= $0 }) != false, field.max.map({ changed <= $0 }) != false else { return }
        set(.double(changed))
    }
}

/// One level of a nested choice: the options that end here (checked when chosen), then a submenu per group, in the order the options came.
struct FaceChoiceMenu: View {
    let options: [PartFace.Control.Option]
    let depth: Int
    let value: Binding<String>

    private var leaves: [PartFace.Control.Option] { options.filter { ($0.path?.count ?? 1) <= depth + 1 } }
    private var nested: [PartFace.Control.Option] { options.filter { ($0.path?.count ?? 1) > depth + 1 } }
    private var groups: [String] {
        var seen = Set<String>()
        return nested.compactMap { $0.path?[depth] }.filter { seen.insert($0).inserted }
    }

    var body: some View {
        if !leaves.isEmpty {
            Picker("", selection: value) {
                ForEach(leaves) { Text($0.path?.last ?? $0.label).tag($0.id) }
            }.pickerStyle(.inline).labelsHidden()
        }
        ForEach(groups, id: \.self) { group in
            Menu(group) {
                FaceChoiceMenu(options: nested.filter { $0.path?[depth] == group }, depth: depth + 1, value: value)
            }
        }
    }
}
