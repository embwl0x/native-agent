import BackgroundWork
import ApprovalTransactions
import SwiftUI
import Observation
import NativeAgentShared
import NativeAgentCore
import NotificationInbox
import TriggerScheduler
import DeviceSync
import StandingBots
import AppKit
import PersistenceCore
import Desk
import EngineRuntime
import Cognition
import BackgroundLoops
import ApprovalInbox

// Blueprint: | `InboxItemDetailSheet.swift` | Chat-capsule note detail, shared source presentation and single-flight outcomes; Activity uses the Inbox face |

extension InboxItemRecord {
    var severityColor: Color {
        switch severity {
        case "actionable": return .orange
        case "important": return .blue
        default: return .secondary
        }
    }

    var sourceIcon: String { presentation?.icon ?? "bell.fill" }
    var sourceBadgeLabel: String { presentation?.badge ?? "SOURCE UNKNOWN" }

    var sourceWord: String {
        let label = sourceBadgeLabel
        guard label != "REM" else { return label }
        let words = label.replacingOccurrences(of: "-", with: " ").lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    var detailEyebrow: String {
        let level = severity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !level.isEmpty, level.lowercased() != "info" else { return sourceWord }
        return "\(sourceWord) · \(AdvancedStatusWords.label(level))"
    }
}

struct InboxItemDetailSheet: View {
    let item: InboxItemRecord
    var allItems: [InboxItemRecord] = []
    let onAction: @MainActor (String) async -> InboxRowActionFlight.Outcome
    var onOpenGroup: ((InboxRelatedGroup) -> Void)? = nil
    var closesOnGroupSelection = true
    let onClose: () -> Void

    @State private var isActing = false
    @State private var actionError: String?

    private var visibleActions: [InboxActionRecord] {
        InboxVisibleActionsPresentation.actions(for: item)
    }

    private var relatedGroups: [InboxRelatedGroup] {
        InboxDigestGroups.groups(item: item, allItems: allItems)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                    VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                        AliveEyebrow(item.detailEyebrow)
                        Text(item.title)
                            .font(ShellType.title)
                            .foregroundStyle(NativeAgentShell.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(item.summary)
                            .font(ShellType.body)
                            .foregroundStyle(NativeAgentShell.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let paths = item.related_paths, !paths.isEmpty {
                        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                            AliveEyebrow("Files")
                            AliveGroupCard {
                                ForEach(paths.prefix(5), id: \.self) { path in
                                    Text(path)
                                        .font(ShellType.code)
                                        .foregroundStyle(NativeAgentShell.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    if let onOpenGroup, !relatedGroups.isEmpty {
                        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                            AliveEyebrow("Related notes")
                            AliveGroupCard {
                                ForEach(relatedGroups) { group in
                                    Button {
                                        onOpenGroup(group)
                                        if closesOnGroupSelection { onClose() }
                                    } label: {
                                        HStack(spacing: NativeAgentSpacing.sm) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(group.title)
                                                    .font(ShellType.labelMedium)
                                                    .foregroundStyle(NativeAgentShell.text)
                                                    .multilineTextAlignment(.leading)
                                                Text("\(group.displayCount) \(group.displayCount == 1 ? "note" : "notes")")
                                                    .font(ShellType.caption)
                                                    .foregroundStyle(NativeAgentShell.secondary)
                                            }
                                            Spacer(minLength: 0)
                                            Image(systemName: "chevron.right")
                                                .font(ShellType.caption)
                                                .foregroundStyle(NativeAgentShell.secondary)
                                                .accessibilityHidden(true)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NativeAgentSpacing.xl)
            }
            Divider()
            VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                if let actionError {
                    Text(actionError)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: NativeAgentSpacing.sm) {
                    Button("Close") { onClose() }
                        .keyboardShortcut(.cancelAction)
                    Spacer(minLength: 0)
                    ForEach(visibleActions.filter { !InboxActionWords.isPrimary($0.id) }, id: \.id) { action in
                        Button(action.label) { perform(action.id, closesOnSuccess: true) }
                            .disabled(isActing)
                    }
                    ForEach(visibleActions.filter { InboxActionWords.isPrimary($0.id) }, id: \.id) { action in
                        Button(action.label) { perform(action.id, closesOnSuccess: true) }
                            .buttonStyle(.borderedProminent)
                            .hazeTinted(.button)
                            .disabled(isActing)
                    }
                }
                .controlSize(.large)
            }
            .padding(.horizontal, NativeAgentSpacing.xl)
            .padding(.vertical, NativeAgentSpacing.lg)
        }
        .frame(minWidth: 460, idealWidth: 560, minHeight: 320, idealHeight: 480)
        .animation(NativeAgentMotion.standard, value: actionError)
        .onAppear { perform("read", closesOnSuccess: false) }
    }

    private func perform(_ actionID: String, closesOnSuccess: Bool) {
        guard !isActing else { return }
        isActing = true
        actionError = nil
        Task { @MainActor in
            defer { isActing = false }
            let outcome = await onAction(actionID)
            switch outcome {
            case .succeeded:
                // Dismiss only after the durable action write succeeds.
                if closesOnSuccess { onClose() }
            case .failed(let detail):
                actionError = detail
            case .dropped:
                break
            }
        }
    }

}

enum InboxActionWords {
    static func isPrimary(_ actionID: String) -> Bool {
        actionID == "act" || actionID == "approve" || actionID == "open_approvals" || actionID == "repair"
    }

}

/// One action flight prevents duplicate writes and preserves the terminal outcome.
@MainActor @Observable
final class InboxRowActionFlight {
    enum Outcome: Equatable {
        case dropped
        case succeeded
        case failed(String)
    }

    private(set) var isInFlight = false

    func perform(operation: @escaping @MainActor () async throws -> Void) async -> Outcome {
        guard !isInFlight else { return .dropped }
        isInFlight = true
        defer { isInFlight = false }

        do {
            try await operation()
            return .succeeded
        } catch {
            let detail = String(TurnSecretRedactor.redactText(error.localizedDescription).prefix(1_000))
            ModuleLog.app("%@", "[inbox] action failed: \(detail)")
            return .failed(detail)
        }
    }
}
