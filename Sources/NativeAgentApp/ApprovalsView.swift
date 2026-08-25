import SwiftUI
import Observation
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

/// Approval risk arrives as durable, open-vocabulary storage data. The panel
/// must turn it into a human claim and a known badge style before rendering;
/// raw producer tokens are neither a label nor a color contract.
enum ApprovalRiskBadgePresentation {
    struct Badge: Sendable, Equatable {
        let label: String
        let status: String
    }

    static func badge(for rawRisk: String) -> Badge {
        switch rawRisk.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "low":
            return .init(label: "Low risk", status: "info")
        case "medium":
            return .init(label: "Medium risk", status: "warn")
        case "high":
            return .init(label: "High risk", status: "fail")
        case "critical":
            return .init(label: "Critical risk", status: "fail")
        case "confirm":
            return .init(label: "Confirmation needed", status: "warn")
        default:
            // Unknown must be conspicuous rather than inherit StatusBadge's
            // neutral fallback; a pending authorization needs an explainable
            // risk label before its buttons invite a decision.
            return .init(label: "Unrecognized risk", status: "warn")
        }
    }
}

/// An approval decision is only reviewable when the canonical inbox reader
/// supplied the payload preview that describes the proposed effect.  Treating
/// an omitted or whitespace-only preview as a harmless empty section lets a
/// damaged/partial row retain live Approve and Deny buttons without the facts
/// the human is meant to assess.
enum ApprovalPayloadPreviewPresentation {
    enum State: Sendable, Equatable {
        case available(String)
        case unavailable
    }

    static func state(for approval: ApprovalRequest) -> State {
        guard let rawPreview = approval.payloadPreview else { return .unavailable }
        let preview = rawPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else { return .unavailable }
        return .available(preview)
    }

    static func canResolve(_ approval: ApprovalRequest) -> Bool {
        if case .available = state(for: approval) { return true }
        return false
    }

    static let unavailableText = "Approval payload is unavailable. Review details must be restored before deciding."
}

/// Toasts describe the durable approval decision, never merely the button the
/// user pressed. An approval can be concurrently decided elsewhere or a
/// boundary can return an incomplete row; neither is evidence that this
/// surface approved an action.
enum ApprovalDecisionToastPresentation {
    struct Toast: Equatable, Sendable {
        let kind: SystemToast.Kind
        let text: String
    }

    static func toast(
        for resolvedApproval: ApprovalRequest,
        requestedID: String
    ) -> Toast {
        guard !requestedID.isEmpty, resolvedApproval.id == requestedID else {
            return .init(
                kind: .error,
                text: "Approval outcome could not be confirmed for this request."
            )
        }
        guard resolvedApproval.status.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "resolved" else {
            return .init(
                kind: .error,
                text: "Approval outcome could not be confirmed."
            )
        }
        switch resolvedApproval.decision?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approved":
            return .init(kind: .success, text: "Approval recorded as approved")
        case "denied":
            return .init(kind: .info, text: "Approval recorded as denied")
        case "canceled":
            return .init(kind: .info, text: "Approval recorded as canceled")
        default:
            return .init(
                kind: .error,
                text: "Approval outcome could not be confirmed."
            )
        }
    }

    static func unavailable(_ error: any Error) -> Toast {
        .init(kind: .error, text: "Approval update failed: \(error.localizedDescription)")
    }

    @MainActor
    static func publish(_ toast: Toast, to center: SystemToastCenter) {
        center.push(SystemToast(kind: toast.kind, text: toast.text))
    }
}

/// Approval history has to distinguish a durable denial from a cancellation
/// and from an incomplete/unknown terminal record. A check or cross is a
/// claim about the decision, so never infer either from a merely resolved
/// status when the decision field is absent or malformed.
enum ApprovalHistoryRowPresentation {
    enum Tone: Sendable, Equatable {
        case success
        case denial
        case neutral
        case warning
    }

    struct Icon: Sendable, Equatable {
        let systemName: String
        let tone: Tone
    }

    static func icon(for approval: ApprovalRequest) -> Icon {
        let decision = normalized(approval.decision)
        switch decision {
        case .some("approved"):
            return .init(systemName: "checkmark.circle.fill", tone: .success)
        case .some("denied"), .some("rejected"):
            return .init(systemName: "xmark.circle.fill", tone: .denial)
        case .some("canceled"), .some("cancelled"):
            return .init(systemName: "minus.circle.fill", tone: .neutral)
        case nil:
            return legacyStatusIcon(status: normalized(approval.status) ?? "")
        default:
            // A present but unsupported decision must not inherit a possibly
            // stale status label and claim a terminal outcome it does not prove.
            return .init(systemName: "exclamationmark.triangle.fill", tone: .warning)
        }
    }

    private static func legacyStatusIcon(status: String) -> Icon {
        switch status {
        case "approved":
            return .init(systemName: "checkmark.circle.fill", tone: .success)
        case "denied", "rejected":
            return .init(systemName: "xmark.circle.fill", tone: .denial)
        case "canceled", "cancelled":
            return .init(systemName: "minus.circle.fill", tone: .neutral)
        case "resolved":
            return .init(systemName: "exclamationmark.triangle.fill", tone: .warning)
        default:
            return .init(systemName: "questionmark.circle.fill", tone: .warning)
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    static func color(for tone: Tone) -> Color {
        switch tone {
        case .success: return .green
        case .denial: return .red
        case .neutral: return .secondary
        case .warning: return .orange
        }
    }
}

/// The mounted Approvals panel observes the exact inbox path its reader uses.
/// The source arms before its initial read, so a cross-surface decision racing
/// panel appearance is replayed instead of leaving a stale pending card.
enum ApprovalRequestsLiveRefresh {
    @MainActor
    static func observe(
        client: NativeClient,
        refresh: @escaping @MainActor @Sendable () async -> Void
    ) async {
        let approvalPath = await client.approvalRequestsPath()
        await ViewFileRefreshTask.run(paths: [approvalPath], refresh: refresh)
    }
}

/// Bounded, visible wording for a failed approval read. Retained records are
/// last-known, not evidence that the approval inbox is currently healthy.
enum ApprovalLoadFailurePresentation {
    static let maxDetailCharacters = 240

    static func banner(error: any Error, retainedApprovalCount: Int) -> String {
        let rawDetail = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = rawDetail.isEmpty
            ? "The approval reader returned no error details."
            : String(rawDetail.prefix(maxDetailCharacters))
        let retained = retainedApprovalCount == 1
            ? "Approvals couldn't refresh — showing 1 previously loaded approval."
            : retainedApprovalCount > 1
                ? "Approvals couldn't refresh — showing \(retainedApprovalCount) previously loaded approvals."
                : "Approvals couldn't load."
        return "\(retained) \(detail)"
    }
}

/// The mounted Approvals panel's refresh boundary. A failed reload leaves its
/// last successful rows visible but labels them as stale; a successful retry
/// clears the adverse state before publishing replacement rows.
@MainActor @Observable
final class ApprovalLoadState {
    private(set) var approvals: [ApprovalRequest]
    private(set) var refreshErrorText: String?
    private(set) var actionErrorText: String?

    var errorText: String? { actionErrorText ?? refreshErrorText }

    init(approvals: [ApprovalRequest] = []) {
        self.approvals = approvals
    }

    @discardableResult
    func reload(
        read: @escaping @MainActor () async throws -> [ApprovalRequest]
    ) async -> Bool {
        refreshErrorText = nil
        actionErrorText = nil
        do {
            approvals = try await read()
            return true
        } catch {
            refreshErrorText = ApprovalLoadFailurePresentation.banner(
                error: error,
                retainedApprovalCount: approvals.count
            )
            return false
        }
    }

    func showActionFailure(_ text: String) {
        actionErrorText = text
    }

    func clearError() {
        refreshErrorText = nil
        actionErrorText = nil
    }
}

// PATCH-2026-05-09: design-system-pass ApprovalsView — NativePanel cards, design tokens
struct ApprovalsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var approvalLoadState = ApprovalLoadState()
    @State private var isRefreshing = false
    @State private var decidingID: String?

    private var pending: [ApprovalRequest] {
        approvalLoadState.approvals.filter { $0.status.lowercased() == "pending" }
    }

    private var recent: [ApprovalRequest] {
        approvalLoadState.approvals.filter { $0.status.lowercased() != "pending" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                HStack {
                    GradientText(text: "Approvals", colors: [.orange, .red], font: NativeAgentFont.title)
                    Spacer()
                    StatusBadge(text: "\(approvalLoadState.approvals.count) total", status: "ok")
                    Button {
                        Task { await refreshApprovals() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRefreshing)
                    if !pending.isEmpty {
                        StatusBadge(text: "\(pending.count) pending", status: "warn")
                    }
                }
                .padding(.horizontal, NativeAgentSpacing.xl)
                .padding(.top, NativeAgentSpacing.lg)

                NativePanel(tint: approvalLoadState.refreshErrorText == nil ? (pending.isEmpty ? .green : .orange) : .red) {
                    HStack(alignment: .top, spacing: NativeAgentSpacing.md) {
                        Image(systemName: approvalLoadState.refreshErrorText == nil
                            ? (pending.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            : "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(approvalLoadState.refreshErrorText == nil ? (pending.isEmpty ? .green : .orange) : .red)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(approvalLoadState.refreshErrorText == nil
                                ? (pending.isEmpty ? "No actions need approval" : "\(pending.count) action\(pending.count == 1 ? "" : "s") need approval")
                                : (approvalLoadState.approvals.isEmpty ? "Approval status unavailable" : "Approval refresh failed"))
                                .font(NativeAgentFont.section)
                            Text(approvalLoadState.refreshErrorText == nil
                                ? "Approvals include tool calls, memory changes, Mac control, connector writes, browser/native actions, Desk tasks, and harness improvements."
                                : (approvalLoadState.approvals.isEmpty
                                    ? "No approval state has loaded yet. Retry when the local approval store is available."
                                    : "Showing the last successfully loaded approval state; retry to confirm what is current."))
                                .font(NativeAgentFont.body)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .padding(.horizontal, NativeAgentSpacing.xl)

                if let errorText = approvalLoadState.errorText {
                    NativePanel(tint: .red) {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(NativeAgentFont.body)
                            .foregroundStyle(.red)
                    }
                    .padding(.horizontal, NativeAgentSpacing.xl)
                }

                VStack(spacing: NativeAgentSpacing.md) {
                    if !pending.isEmpty {
                        ForEach(pending) { approval in
                            ApprovalRequestPanel(
                                approval: approval,
                                isDeciding: decidingID == approval.id || appModel.isResolvingApproval(id: approval.id),
                                onResolve: { decision in
                                    Task { await resolveApproval(id: approval.id, decision: decision) }
                                }
                            )
                        }
                    }

                    if !recent.isEmpty {
                        NativePanel(title: "Recent Decisions", systemImage: "clock.arrow.circlepath", tint: .secondary) {
                            VStack(spacing: 0) {
                                ForEach(recent.prefix(12)) { approval in
                                    ApprovalHistoryRow(approval: approval)
                                    if approval.id != recent.prefix(12).last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                    } else if pending.isEmpty, approvalLoadState.refreshErrorText == nil {
                        NativePanel(tint: .secondary) {
                            Label("No approval history yet. Risky actions will be listed here after they are approved or denied.", systemImage: "clock")
                                .font(NativeAgentFont.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, NativeAgentSpacing.xl)
                .padding(.bottom, NativeAgentSpacing.xl)
            }
        }
        .navigationTitle("Approvals")
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await ApprovalRequestsLiveRefresh.observe(client: appModel.client) {
                await refreshApprovals(showSpinner: false)
            }
        }
    }

    @MainActor
    private func refreshApprovals(showSpinner: Bool = true) async {
        if showSpinner { isRefreshing = true }
        defer { if showSpinner { isRefreshing = false } }
        if await approvalLoadState.reload(read: { try await appModel.getApprovals() }) {
            appModel.approvals = approvalLoadState.approvals
        }
    }

    @MainActor
    private func resolveApproval(id: String, decision: String) async {
        decidingID = id
        approvalLoadState.clearError()
        defer { decidingID = nil }
        switch await appModel.resolveApprovalOnce(id: id, decision: decision) {
        case .applied(let resolved):
            let toast = ApprovalDecisionToastPresentation.toast(
                for: resolved,
                requestedID: id
            )
            ApprovalDecisionToastPresentation.publish(toast, to: appModel.systemToasts)
            await refreshApprovals(showSpinner: false)
            if toast.kind == .error { approvalLoadState.showActionFailure(toast.text) }
            await appModel.loadHealthCard()
        case .noOpInFlight(let inFlightID):
            appModel.systemToasts.push(info: CapabilitiesApprovalInboxResolution.noOpInFlight(id: inFlightID).visibleMessage)
            await refreshApprovals(showSpinner: false)
        case .noOpAlreadyResolved(let resolvedID, let status):
            appModel.systemToasts.push(info: CapabilitiesApprovalInboxResolution.noOpAlreadyResolved(id: resolvedID, status: status).visibleMessage)
            await refreshApprovals(showSpinner: false)
        case .unavailable(let detail):
            let toast = ApprovalDecisionToastPresentation.unavailable(
                NSError(domain: "NativeAgentApproval", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
            )
            ApprovalDecisionToastPresentation.publish(toast, to: appModel.systemToasts)
            await refreshApprovals(showSpinner: false)
            approvalLoadState.showActionFailure(toast.text)
        }
    }
}

private struct ApprovalRequestPanel: View {
    var approval: ApprovalRequest
    var isDeciding: Bool
    var onResolve: (String) -> Void

    private var riskBadge: ApprovalRiskBadgePresentation.Badge {
        ApprovalRiskBadgePresentation.badge(for: approval.risk)
    }

    private var payloadPreview: ApprovalPayloadPreviewPresentation.State {
        ApprovalPayloadPreviewPresentation.state(for: approval)
    }

    var body: some View {
        NativePanel(tint: .orange) {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                HStack(alignment: .top) {
                    PulsingDot(color: .orange, size: 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(approval.title.isEmpty ? approval.action : approval.title)
                            .font(NativeAgentFont.section)
                        Text(approval.action)
                            .font(NativeAgentFont.label)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(text: riskBadge.label, status: riskBadge.status)
                }
                if let reason = approval.reason, !reason.isEmpty {
                    Text(reason)
                        .font(NativeAgentFont.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                }
                switch payloadPreview {
                case .available(let preview):
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                case .unavailable:
                    Label(
                        ApprovalPayloadPreviewPresentation.unavailableText,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                HStack(spacing: NativeAgentSpacing.sm) {
                    Button {
                        onResolve("approved")
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isDeciding || !ApprovalPayloadPreviewPresentation.canResolve(approval))
                    Button {
                        onResolve("denied")
                    } label: {
                        Label("Deny", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    .disabled(isDeciding || !ApprovalPayloadPreviewPresentation.canResolve(approval))
                    if isDeciding {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

private struct ApprovalHistoryRow: View {
    var approval: ApprovalRequest

    var body: some View {
        let icon = ApprovalHistoryRowPresentation.icon(for: approval)
        HStack(spacing: 10) {
            Image(systemName: icon.systemName)
                .foregroundStyle(ApprovalHistoryRowPresentation.color(for: icon.tone))
            VStack(alignment: .leading, spacing: 2) {
                Text(approval.title.isEmpty ? approval.action : approval.title)
                    .font(NativeAgentFont.label)
                    .lineLimit(1)
                Text("\(approval.decision ?? approval.status) · \(UserDisplayFormatters.humanizeISOTimestamp(approval.resolvedAt ?? approval.createdAt ?? ""))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}
