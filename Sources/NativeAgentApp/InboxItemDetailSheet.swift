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
import WorkshopExecution
import Cognition
import BackgroundLoops
import ApprovalInbox

// Blueprint: | `InboxItemDetailSheet.swift` | Full note reader, related-note routes, action words and shared single-flight outcomes |

/// A full note, files, related routes and actions; failures appear above its buttons.
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
                    // Opening marks the note read; Close only closes.
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
                // Dismiss only after the action's durable write succeeds.
                if closesOnSuccess { onClose() }
            case .failed:
                actionError = InboxActionWords.failure(actionID)
            case .dropped:
                break
            }
        }
    }

}

/// Action labels and useful failure wording keep the writer's error text in the log.
enum InboxActionWords {
    static func isPrimary(_ actionID: String) -> Bool {
        actionID == "act" || actionID == "approve" || actionID == "open_approvals" || actionID == "repair"
    }

    static func failure(_ actionID: String) -> String {
        let what: String
        switch actionID {
        case "read": what = "mark this note read"
        case "archive": what = "archive this note"
        case "dismiss": what = "dismiss this note"
        case "approve": what = "approve this"
        case "reject", "deny": what = "decline this"
        default: what = "do that"
        }
        return "Couldn't \(what). Try again in a moment."
    }
}

/// One action flight prevents double submission and distinguishes failed writes from success.
@MainActor @Observable
final class InboxRowActionFlight {
    enum Outcome: Equatable {
        case dropped
        case succeeded
        case failed
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
            // The writer's text goes to the log; the page says what to do.
            ModuleLog.app("%@", "[inbox] action failed: \(error.localizedDescription)")
            return .failed
        }
    }
}
