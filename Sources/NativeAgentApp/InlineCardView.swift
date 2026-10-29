import ApprovalTransactions
import EngineRuntime
import ChatToolRuntime
import MacIntegration
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
    /// Which mark a terminal card wears. A failure is not a receipt, so it
    /// never reaches here as one — see `InlineCardView`.
    var mark: InlineCardMark {
        switch state {
        case .settled: return .done
        case .declined: return .declined
        case .failed, .stopped, .unknown: return .unknown
        case .pending, .running, .superseded: return .done
        }
    }
}

/// What the person did. Resolution belongs to the mechanism; the view only
/// says which command was taken and with what.
enum InlineCardAction: Sendable, Equatable {
    /// The primary command, carrying whatever the card collected: `value` is
    /// the first field, `values` every field by id.
    case primary(value: String?, choice: String?, values: [String: String] = [:])
    /// The quiet "Open full setup" link.
    case fullSetup
    /// The quiet secondary: "Not now", "Don't send", "Decide later".
    case secondary
    /// Retry after a safe failure.
    case retry
    /// Stop the work this card is showing.
    case stop
}

typealias InlineCardActionSink = @MainActor (InlineCardAction) -> Void

/// Radio rows. Selecting a row never executes the choice — the primary does.
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

/// A labelled field. A secret is typed into a `SecureField` and goes to the
/// action closure, never into transcript content.
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

/// One card for one interaction, through every state it passes: ready, in
/// flight, settled, declined, failed. It appears in place and settles in
/// place — no bounce, no shimmer, and no modal anywhere.
struct InlineCardView: View {
    let model: InlineCardModel
    let action: InlineCardActionSink

    @State private var fieldValues: [String: String] = [:]
    @State private var selection: String?
    @State private var relaunchError: String?

    /// A card that collects something keeps its controls while it submits: the
    /// primary takes the spinner and the busy label ("Connecting…"), the quiet
    /// secondary stays live, and the dimensions do not move. A card that is
    /// merely showing work in flight has nothing to submit, so it gets the busy
    /// line and its Stop instead.
    private var collectsInput: Bool {
        !model.fields.isEmpty || !model.choices.isEmpty
    }

    private func typed(_ field: InlineCardField) -> String {
        (fieldValues[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nothing typed and a sign-in offered: the primary signs in.
    private var signsIn: Bool {
        model.signInLabel != nil && model.fields.allSatisfy { typed($0).isEmpty }
    }

    private var primaryEnabled: Bool {
        if !model.choices.isEmpty && selection == nil { return false }
        if signsIn { return true }
        // Required fields stay visible and disable submission until filled.
        return model.fields.allSatisfy { $0.isOptional || !typed($0).isEmpty }
    }

    private func fieldBinding(_ id: String) -> Binding<String> {
        Binding(get: { fieldValues[id] ?? "" }, set: { fieldValues[id] = $0 })
    }

    /// Every field the card shows, before its buttons in the key-view order.
    private var fieldRows: some View {
        ForEach(model.fields, id: \.id) { field in
            InlineCardSecretField(field: field, value: fieldBinding(field.id))
        }
    }

    /// Values travel in the action, never in the transcript.
    private func submit() {
        var values: [String: String] = [:]
        for field in model.fields where !typed(field).isEmpty { values[field.id] = typed(field) }
        action(.primary(value: model.field.flatMap { values[$0.id] },
                        choice: selection, values: values))
    }

    @ViewBuilder
    private var fullSetupLink: some View {
        if let label = model.fullSetupLabel {
            // Secondary text, underlined: a link without system blue, which
            // would be a second accent on the card.
            Button { action(.fullSetup) } label: {
                Text(label).underline().foregroundStyle(NativeAgentShell.secondary)
            }
            .buttonStyle(.plain)
            .font(ShellType.label)
            .accessibilityIdentifier("inline-card.full-setup")
        }
    }

    /// The primary names the selected choice's outcome, or the card's own.
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
        // A card becomes its receipt in place without crossfading.
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

    // A live card: the fill, the ask, the control, and what declining costs.
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
                    // What a running sign-in asks of the person (a device code) shows beside its fields too.
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
                screenRecordingRelaunch
            }
        }
        .accessibilityIdentifier("inline-card.\(model.kind.rawValue)")
    }

    @ViewBuilder
    private var screenRecordingRelaunch: some View {
        if (model.state == .running || model.state == .failed),
           model.systemPermissions.contains(.screenRecording),
           SystemPermissionPreflight.status(.screenRecording) != .granted {
            Text("If you've allowed Screen Recording, relaunch to finish. Your work will continue.")
                .font(ShellType.caption).foregroundStyle(NativeAgentShell.secondary)
            Button("Relaunch to finish") {
                AppRelaunch.relaunchApp(terminate: { AppDelegate.terminateForRestart() },
                    onSpawnFailure: { relaunchError = "Could not relaunch NativeAgent: \($0.localizedDescription)" })
            }
            if let relaunchError { Text(relaunchError).font(ShellType.caption) }
        }
    }

    // Still, not shimmering: one indicator, the honest note beside it, and Stop
    // wherever the owning operation supports it.
    private var runningRow: some View {
        HStack(spacing: NativeAgentSpacing.sm) {
            InlineCardBusyLine(text: model.busyNote ?? (model.busyLabel ?? "Working…"))
            Spacer(minLength: NativeAgentSpacing.sm)
            if model.canStop {
                InlineCardSecondaryButton(title: "Stop") { action(.stop) }
            }
        }
    }

    // A failure keeps the card — the entered values, the explanation, and a
    // retry only when retrying is safe.
    private var failedCard: some View {
        InlineCard(symbol: model.kind.symbol,
                   symbolTint: NativeAgentShell.trouble,
                   title: model.outcome ?? model.title,
                   reason: model.outcomeMeta ?? model.why) {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                fieldRows
                // A failure keeps what the card COLLECTS, not just what was
                // typed into it: a remount has no selection, so a failed
                // choice card with no list has nothing to answer with and
                // "Try again" submits nil for ever.
                if !model.choices.isEmpty {
                    InlineCardChoiceList(choices: model.choices, selection: $selection)
                }
                if model.canRetry {
                    InlineCardActions(
                        primary: model.state == .stopped ? "Resume" : "Try again",
                        primaryEnabled: primaryEnabled,
                        secondary: model.secondaryLabel,
                        consequence: model.consequence,
                        // A failure keeps what was typed, so the retry carries
                        // it: a key the provider rejected is corrected in place
                        // rather than re-entered from nothing.
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
                screenRecordingRelaunch
            }
        }
        .accessibilityIdentifier("inline-card.\(model.kind.rawValue).failed")
    }

    private var receipt: some View {
        InlineCardReceipt(mark: model.mark,
                          outcome: model.outcome ?? model.title,
                          meta: model.outcomeMeta,
                          detailsLabel: model.detailsBody == nil ? nil : (model.detailsLabel ?? "Details"),
                          // A decline is the quietest thing in the transcript.
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

    /// Decision details explain the effect and duration, with persistence in the mechanics.
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
