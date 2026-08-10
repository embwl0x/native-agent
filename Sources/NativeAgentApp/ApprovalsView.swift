import SwiftUI
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

// PATCH-2026-05-09: design-system-pass ApprovalsView — NativePanel cards, design tokens
struct ApprovalsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isRefreshing = false
    @State private var decidingID: String?
    @State private var errorText: String?

    private var pending: [ApprovalRequest] {
        appModel.approvals.filter { $0.status.lowercased() == "pending" }
    }

    private var recent: [ApprovalRequest] {
        appModel.approvals.filter { $0.status.lowercased() != "pending" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NativeAgentSpacing.lg) {
                HStack {
                    GradientText(text: "Approvals", colors: [.orange, .red], font: NativeAgentFont.title)
                    Spacer()
                    StatusBadge(text: "\(appModel.approvals.count) total", status: "ok")
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

                NativePanel(tint: pending.isEmpty ? .green : .orange) {
                    HStack(alignment: .top, spacing: NativeAgentSpacing.md) {
                        Image(systemName: pending.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .font(.title3)
                            .foregroundStyle(pending.isEmpty ? .green : .orange)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pending.isEmpty ? "No actions need approval" : "\(pending.count) action\(pending.count == 1 ? "" : "s") need approval")
                                .font(NativeAgentFont.section)
                            Text("Approvals include tool calls, memory changes, Mac control, connector writes, browser/native actions, Desk tasks, and harness improvements.")
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

                if let errorText {
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
                                isDeciding: decidingID == approval.id,
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
                    } else if pending.isEmpty {
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
            let approvalPath = PersistenceCore.defaultDataRoot()
                .appendingPathComponent("workflows", isDirectory: true)
                .appendingPathComponent("approvals", isDirectory: true)
                .appendingPathComponent("requests.json")
            await ViewFileRefreshTask.run(paths: [approvalPath]) {
                await refreshApprovals(showSpinner: false)
            }
        }
    }

    @MainActor
    private func refreshApprovals(showSpinner: Bool = true) async {
        if showSpinner { isRefreshing = true }
        defer { if showSpinner { isRefreshing = false } }
        do {
            appModel.approvals = try await appModel.getApprovals()
            errorText = nil
        } catch {
            errorText = "Failed to load approvals: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func resolveApproval(id: String, decision: String) async {
        decidingID = id
        errorText = nil
        defer { decidingID = nil }
        do {
            _ = try await appModel.resolveApproval(id: id, decision: decision)
            // PATCH-2026-06-06: branch toast kind by decision. "Denied" is not
            // a success — the green checkmark on a denial misreads as "your
            // denial succeeded" but the connotation is wrong in approval UX.
            // Approved -> .success (green check), denied -> .info (neutral).
            if decision == "approved" {
                appModel.systemToasts.push(success: "Approval approved")
            } else {
                appModel.systemToasts.push(info: "Approval denied")
            }
            await refreshApprovals(showSpinner: false)
            await appModel.loadHealthCard()
        } catch {
            errorText = "Approval update failed: \(error.localizedDescription)"
            await refreshApprovals(showSpinner: false)
        }
    }
}

private struct ApprovalRequestPanel: View {
    var approval: ApprovalRequest
    var isDeciding: Bool
    var onResolve: (String) -> Void

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
                    StatusBadge(text: approval.risk, status: approval.risk)
                }
                if let reason = approval.reason, !reason.isEmpty {
                    Text(reason)
                        .font(NativeAgentFont.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                }
                if let preview = approval.payloadPreview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                HStack(spacing: NativeAgentSpacing.sm) {
                    Button {
                        onResolve("approved")
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isDeciding)
                    Button {
                        onResolve("denied")
                    } label: {
                        Label("Deny", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    .disabled(isDeciding)
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

    private var decisionColor: Color {
        switch (approval.decision ?? approval.status).lowercased() {
        case "approved": return .green
        case "denied", "rejected": return .red
        case "canceled": return .secondary
        default: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: (approval.decision ?? "").lowercased() == "approved" ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(decisionColor)
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
