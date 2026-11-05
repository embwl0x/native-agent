import ApprovalTransactions
import EngineRuntime
import ChatToolRuntime
import NativeAgentShared
import SwiftUI
import AppKit
import MemoryV2
import Foundation
import Combine
import Cognition
import NativeAgentCore
import PersistenceCore

// Blueprint: | `InlineCardView.swift` | InlineCardView renders every interaction state, field and choice; actions remain closures owned by the interaction |

extension InlineCardKind {
    var symbol: String {
        switch self {
        case .needsConnector: return "link"
        case .needsPermission: return "lock.open"
        case .needsModelChoice: return "sparkles"
        case .needsAPIKey: return "key"
        case .needsCapability: return "switch.2"
        case .choose: return "questionmark.circle"
        case .confirm: return "paperplane"
        case .work: return "gearshape"
        }
    }
}

extension InlineCardModel {
    var mark: InlineCardMark {
        switch state {
        case .settled: return .done
        case .declined: return .declined
        case .failed, .stopped, .unknown: return .unknown
        case .pending, .running, .superseded: return .done
        }
    }
}

enum InlineCardAction: Sendable, Equatable {
    /// Keep the first field in `value` and every field in `values` so the action receives the complete form.
    case primary(value: String?, choice: String?, values: [String: String] = [:])
    case fullSetup
    case secondary
    case retry
    case stop
}

typealias InlineCardActionSink = @MainActor (InlineCardAction) -> Void

/// Selecting a radio row must not execute it; only the primary command does.
struct InlineCardChoiceList: View {
    let choices: [InlineCardChoice]
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(choices) { choice in
                Button {
                    selection = choice.id
                } label: {
                    HStack(spacing: NativeAgentSpacing.sm) {
                        Image(systemName: selection == choice.id ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(selection == choice.id
                                             ? NativeAgentShell.needsYou : NativeAgentShell.tertiary)
                        Text(choice.title)
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: NativeAgentSpacing.sm)
                        if let note = choice.note {
                            Text(note)
                                .font(ShellType.caption)
                                .foregroundStyle(NativeAgentShell.tertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 34)
                    .background(selection == choice.id ? NativeAgentShell.softFill : Color.clear,
                                in: RoundedRectangle(cornerRadius: NativeAgentRadius.control, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable()
                .accessibilityIdentifier("inline-card.choice.\(choice.id)")
                .accessibilityAddTraits(selection == choice.id ? [.isSelected] : [])
            }
        }
    }
}

/// Send secrets through the action closure, never transcript content.
struct InlineCardSecretField: View {
    let field: InlineCardField
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
            Text(field.label)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
            Group {
                if field.isSecret {
                    SecureField(field.placeholder, text: $value)
                } else {
                    TextField(field.placeholder, text: $value)
                }
            }
            .textFieldStyle(.plain)
            .accessibilityLabel(field.label)
            .accessibilityIdentifier("inline-card.field")
            .font(ShellType.code)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(NativeAgentShell.quietFill,
                        in: RoundedRectangle(cornerRadius: NativeAgentRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: NativeAgentRadius.control, style: .continuous)
                .strokeBorder(NativeAgentShell.hairline, lineWidth: 1))
            if let helper = field.helper {
                Text(helper)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - The model-driven card

struct InlineCardView: View {
    let model: InlineCardModel
    let action: InlineCardActionSink

    @State private var fieldValues: [String: String] = [:]
    @State private var selection: String?
    @State private var relaunchError: String?

    /// Keep collected controls mounted during submission so values and dimensions survive while the primary shows busy.
    private var collectsInput: Bool {
        !model.fields.isEmpty || !model.choices.isEmpty
    }

    private func typed(_ field: InlineCardField) -> String {
        (fieldValues[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var signsIn: Bool {
        model.signInLabel != nil && model.fields.allSatisfy { typed($0).isEmpty }
    }

    private var primaryEnabled: Bool {
        if !model.choices.isEmpty && selection == nil { return false }
        if signsIn { return true }
        // Keep required fields visible so incomplete input explains disabled submission.
        return model.fields.allSatisfy { $0.isOptional || !typed($0).isEmpty }
    }

    private func fieldBinding(_ id: String) -> Binding<String> {
        Binding(get: { fieldValues[id] ?? "" }, set: { fieldValues[id] = $0 })
    }

    private var fieldRows: some View {
        ForEach(model.fields, id: \.id) { field in
            InlineCardSecretField(field: field, value: fieldBinding(field.id))
        }
    }

    /// Form values travel in actions, never transcripts.
    private func submit() {
        var values: [String: String] = [:]
        for field in model.fields where !typed(field).isEmpty { values[field.id] = typed(field) }
        action(.primary(value: model.field.flatMap { values[$0.id] },
                        choice: selection, values: values))
    }

    @ViewBuilder
    private var fullSetupLink: some View {
        if let label = model.fullSetupLabel {
            // Underline secondary links without introducing a second accent colour.
            Button { action(.fullSetup) } label: {
                Text(label).underline().foregroundStyle(NativeAgentShell.secondary)
            }
            .buttonStyle(.plain)
            .font(ShellType.label)
            .accessibilityIdentifier("inline-card.full-setup")
        }
    }

    private var primaryLabel: String {
        if signsIn, let signIn = model.signInLabel { return signIn }
        if let picked = selection,
           let choice = model.choices.first(where: { $0.id == picked }),
           let label = choice.actionLabel, !label.isEmpty {
            return label
        }
        return model.primaryLabel
    }

    var body: some View {
        switch model.state {
        case .pending, .running:
            liveCard.transition(.identity)
        case .failed, .stopped:
            failedCard.transition(.identity)
        case .settled, .declined, .unknown:
            receipt.transition(.identity)
        case .superseded:
            InlineCardSupersededLine()
                .accessibilityIdentifier("inline-card.\(model.kind.rawValue).superseded")
                .transition(.identity)
        }
    }

    private var liveCard: some View {
        InlineCard(symbol: model.kind.symbol,
                   symbolTint: NativeAgentShell.needsYou,
                   title: model.state == .running && !collectsInput
                       ? (model.busyLabel ?? model.title) : model.title,
                   reason: model.why) {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                scope
                fieldRows.disabled(model.state == .running)
                if !model.choices.isEmpty {
                    InlineCardChoiceList(choices: model.choices, selection: $selection)
                        .disabled(model.state == .running)
                }
                if model.state == .running && !collectsInput {
                    runningRow
                } else {
                    if model.state == .running, let note = model.busyNote { InlineCardBusyLine(text: note) }
                    InlineCardActions(
                        primary: model.state == .running
                            ? (model.busyLabel ?? primaryLabel) : primaryLabel,
                        primaryEnabled: model.state == .running || primaryEnabled,
                        busy: model.state == .running,
                        secondary: model.secondaryLabel,
                        consequence: model.consequence,
                        onPrimary: submit,
                        onSecondary: { action(.secondary) }
                    )
                    fullSetupLink
                }
                details
                cardRestart
            }
        }
        .accessibilityIdentifier("inline-card.\(model.kind.rawValue)")
    }

    /// The person's tap is the authority for this restart, under any Trust posture; the agent's own restart_app keeps its gate.
    @ViewBuilder
    private var cardRestart: some View {
        if let note = model.restartNote {
            Text(note)
                .font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary)
            Button("Restart NativeAgent") {
                AppRelaunch.relaunchApp(terminate: { AppDelegate.terminateForRestart() },
                    onSpawnFailure: { relaunchError = "Could not relaunch NativeAgent: \($0.localizedDescription)" })
            }
            if let relaunchError { Text(relaunchError).font(ShellType.caption) }
        }
    }

    private var runningRow: some View {
        HStack(spacing: NativeAgentSpacing.sm) {
            InlineCardBusyLine(text: model.busyNote ?? (model.busyLabel ?? "Working…"))
            Spacer(minLength: NativeAgentSpacing.sm)
            if model.canStop {
                InlineCardSecondaryButton(title: "Stop") { action(.stop) }
            }
            // A permission card waiting on macOS can wait across a restart; the person can still leave the rest off.
            if model.kind == .needsPermission {
                InlineCardSecondaryButton(title: model.secondaryLabel) { action(.secondary) }
            }
        }
    }

    // Keep failed cards and entered values; offer retry only when safe.
    private var failedCard: some View {
        InlineCard(symbol: model.kind.symbol,
                   symbolTint: NativeAgentShell.trouble,
                   title: model.outcome ?? model.title,
                   reason: model.outcomeMeta ?? model.why) {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                fieldRows
                // Keep choices mounted on failure so retry cannot submit a lost selection.
                if !model.choices.isEmpty {
                    InlineCardChoiceList(choices: model.choices, selection: $selection)
                }
                if model.canRetry {
                    InlineCardActions(
                        primary: model.state == .stopped ? "Resume" : "Try again",
                        primaryEnabled: primaryEnabled,
                        secondary: model.secondaryLabel,
                        consequence: model.consequence,
                        // Keep rejected input editable so retry uses the corrected value.
                        onPrimary: {
                            if collectsInput {
                                submit()
                            } else {
                                action(.retry)
                            }
                        },
                        onSecondary: { action(.secondary) }
                    )
                }
                fullSetupLink
                details
                cardRestart
            }
        }
        .accessibilityIdentifier("inline-card.\(model.kind.rawValue).failed")
    }

    private var receipt: some View {
        InlineCardReceipt(mark: model.mark,
                          outcome: model.outcome ?? model.title,
                          meta: model.outcomeMeta,
                          detailsLabel: model.detailsBody == nil ? nil : (model.detailsLabel ?? "Details"),
                          quiet: model.state == .declined) {
            if let body = model.detailsBody {
                Text(body)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("inline-card.\(model.kind.rawValue).\(model.state.rawValue)")
    }

    @ViewBuilder
    private var scope: some View {
        if !model.scopeLines.isEmpty || model.identifier != nil {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(model.scopeLines.enumerated()), id: \.offset) { _, line in
                    InlineCardScopeLine(text: line)
                }
                if let identifier = model.identifier {
                    Text(identifier)
                        .font(ShellType.code)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        let note = model.persistenceNote
        if model.detailsBody != nil || note != nil {
            InlineCardDetails(label: model.detailsLabel ?? "What happens") {
                VStack(alignment: .leading, spacing: NativeAgentSpacing.xs) {
                    if let body = model.detailsBody {
                        Text(body)
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note {
                        Text(note)
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
