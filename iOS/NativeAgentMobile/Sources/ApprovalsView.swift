// ApprovalsView.swift — iOS Approvals surface for risky action gates.
//
// Reads the iCloud approvals snapshot while visible; approve/deny decisions are
// signed iCloud bridge messages that the Mac app applies through the in-process
// Swift runtime. The hot path reads only approvals.json so the tab does not
// repeatedly hydrate every Mac snapshot while visible.

import SwiftUI
import NativeAgentShared
import UserNotifications

// MARK: - Model

/// Approval snapshot shape shared with the Mac app.
/// `ApprovalRequest` in Models.swift covers most fields; this alias reuses it.
typealias PendingApproval = ApprovalRequest

// MARK: - Store

@MainActor
final class ApprovalsStore: ObservableObject {
    @Published var approvals: [PendingApproval] = []
    @Published var isLoading = false
    @Published var bannerError: String? = nil
    @Published var bannerWarning: String? = nil
    @Published var decidingApprovalID: String? = nil
    var isVisible = false
    private var hasLoadedApprovals = false
    private var notifiedPendingIDs = Set<String>()
    private var locallyFinalizedApprovals: [String: (decision: String, resolvedAt: String)] = [:]

    // Pending count for the tab badge
    var pendingCount: Int {
        approvals.filter { $0.status.lowercased() == "pending" }.count
    }

    // MARK: - Fetch

    func refresh(client: MacBridgeClient, pairingStore: PairingStore) async {
        guard pairingStore.usesICloudTransport else {
            bannerWarning = nil
            bannerError = "Pair to view"
            withAnimation(AppMotion.snappy) { approvals = [] }
            return
        }
        await iCloudSyncEngine.shared.refreshApprovalsSnapshot()
        applySyncedApprovalsFromSnapshot()
    }

    func applySyncedApprovalsFromSnapshot(animated: Bool = true, notifyNewPending: Bool = true) {
        let merged = mergeLocalFinalDecisions(iCloudSyncEngine.shared.approvals)
        if iCloudSyncEngine.shared.approvals != merged {
            iCloudSyncEngine.shared.approvals = merged
        }
        if notifyNewPending {
            notifyForNewPendingApprovals(merged)
        } else {
            rememberPendingApprovals(merged)
        }
        if animated {
            withAnimation(AppMotion.snappy) { approvals = merged }
        } else {
            approvals = merged
        }
        bannerWarning = "Approvals are syncing through iCloud. Decisions run when the Mac app receives them."
        bannerError = nil
    }

    // MARK: - Decide

    func decide(id: String, decision: String, client: MacBridgeClient, pairingStore: PairingStore) async {
        if decidingApprovalID != nil { return }
        decidingApprovalID = id
        defer { decidingApprovalID = nil }
        guard pairingStore.usesICloudTransport else {
            bannerError = "Pair to view"
            return
        }
        let previousApprovals = approvals
        do {
            let normalized = decision.lowercased()
            let action: String
            let finalDecision: String
            if normalized == "approve" || normalized == "approved" {
                action = "approve"
                finalDecision = "approved"
            } else if normalized == "cancel" {
                action = "cancel"
                finalDecision = "canceled"
            } else {
                action = "reject"
                finalDecision = "denied"
            }
            markApprovalFinal(id: id, decision: finalDecision)
            if action == "approve" {
                _ = try await iCloudSyncEngine.shared.approveApproval(id: id)
            } else if action == "cancel" {
                _ = try await iCloudSyncEngine.shared.cancelApproval(id: id)
            } else {
                _ = try await iCloudSyncEngine.shared.rejectApproval(id: id)
            }
            await refresh(client: client, pairingStore: pairingStore)
        } catch {
            if iCloudSyncEngine.isMacResponseTimeout(error) {
                await refresh(client: client, pairingStore: pairingStore)
                bannerWarning = "Decision sent. The Mac is still running it; this list will clear when iCloud publishes the result."
                bannerError = nil
            } else {
                locallyFinalizedApprovals.removeValue(forKey: id)
                withAnimation(AppMotion.snappy) { approvals = previousApprovals }
                iCloudSyncEngine.shared.approvals = previousApprovals
                bannerError = "Failed to record decision: \(error.localizedDescription)"
            }
        }
    }

    private func markApprovalFinal(id: String, decision: String) {
        let resolvedAt = ISO8601DateFormatter().string(from: Date())
        locallyFinalizedApprovals[id] = (decision: decision, resolvedAt: resolvedAt)
        notifiedPendingIDs.insert(id)
        let merged = mergeLocalFinalDecisions(approvals)
        withAnimation(AppMotion.snappy) { approvals = merged }
        iCloudSyncEngine.shared.approvals = mergeLocalFinalDecisions(iCloudSyncEngine.shared.approvals)
    }

    private func mergeLocalFinalDecisions(_ source: [PendingApproval]) -> [PendingApproval] {
        source.map { approval in
            guard let final = locallyFinalizedApprovals[approval.id] else { return approval }
            if approval.status.lowercased() != "pending" {
                locallyFinalizedApprovals.removeValue(forKey: approval.id)
                return approval
            }
            var resolved = approval
            resolved.status = final.decision
            resolved.decision = final.decision
            resolved.resolvedAt = final.resolvedAt
            return resolved
        }
    }

    private func rememberPendingApprovals(_ next: [PendingApproval]) {
        let pendingIDs = Set(next.filter { $0.status.lowercased() == "pending" }.map(\.id))
        notifiedPendingIDs.formUnion(pendingIDs)
        hasLoadedApprovals = true
    }

    private func notifyForNewPendingApprovals(_ next: [PendingApproval]) {
        let pending = next.filter { $0.status.lowercased() == "pending" }
        let pendingIDs = Set(pending.map(\.id))
        defer {
            notifiedPendingIDs.formUnion(pendingIDs)
            hasLoadedApprovals = true
        }
        guard hasLoadedApprovals else { return }
        guard !isVisible else { return }
        let newPending = pending.filter { !notifiedPendingIDs.contains($0.id) }
        for approval in newPending.prefix(3) {
            fireApprovalNotification(approval)
        }
        if newPending.count > 3 {
            fireApprovalSummaryNotification(count: newPending.count)
        }
    }

    private func fireApprovalNotification(_ approval: PendingApproval) {
        Task.detached {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            let content = UNMutableNotificationContent()
            content.title = "NativeAgent approval needed"
            content.body = approval.title.isEmpty ? approval.action : approval.title
            content.sound = .default
            var userInfo = ["screen": "activity", "source": "approval", "approvalId": approval.id]
            let eventID = NativeAgentDeviceEventIdentity.notification(userInfo: userInfo)
            userInfo["eventId"] = eventID
            content.userInfo = userInfo
            _ = try? await NativeAgentNotificationEventGate.add(
                content: content, eventID: eventID, trigger: nil, center: center
            )
        }
    }

    private func fireApprovalSummaryNotification(count: Int) {
        Task.detached {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            let content = UNMutableNotificationContent()
            content.title = "NativeAgent approvals needed"
            content.body = "\(count) new actions are waiting for review."
            content.sound = .default
            content.userInfo = ["screen": "activity", "source": "approval_summary"]
            let request = UNNotificationRequest(identifier: "nativeagent.approval.summary.\(UUID().uuidString)", content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}

// MARK: - Top-level view

struct ApprovalsView: View {
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @EnvironmentObject private var store: ApprovalsStore

    /// `false` when pushed as a navigationDestination from another
    /// NavigationStack (e.g. ActivityView). Nesting NavigationStacks causes
    /// the destination to render and immediately pop back. Default `true`
    /// keeps the tab-root call site working.
    let embedInNavigationStack: Bool

    init(embedInNavigationStack: Bool = true) {
        self.embedInNavigationStack = embedInNavigationStack
    }

    private var pending: [PendingApproval] {
        store.approvals.filter { $0.status.lowercased() == "pending" }
    }

    private var resolved: [PendingApproval] {
        store.approvals.filter { $0.status.lowercased() != "pending" }
    }

    var body: some View {
        Group {
            if embedInNavigationStack {
                NavigationStack { approvalsContent }
            } else {
                approvalsContent
            }
        }
    }

    @ViewBuilder
    private var approvalsContent: some View {
        ZStack(alignment: .top) {
            approvalsList

            // Error / warning banners
            VStack(spacing: 0) {
                if let warn = store.bannerWarning {
                    BannerView(message: warn, style: .warning)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let err = store.bannerError {
                    BannerView(message: err, style: .error)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(AppMotion.snappy, value: store.bannerError)
            .animation(AppMotion.snappy, value: store.bannerWarning)
        }
        .navigationTitle("Approvals")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if store.isLoading {
                    ProgressView().scaleEffect(0.8)
                }
            }
        }
        .refreshable {
            await store.refresh(client: bridgeClient, pairingStore: pairingStore)
        }
        .task {
            await store.refresh(client: bridgeClient, pairingStore: pairingStore)
        }
        .onReceive(iCloudSyncEngine.shared.$approvals) { _ in
            guard pairingStore.usesICloudTransport, store.isVisible else { return }
            store.applySyncedApprovalsFromSnapshot(animated: false, notifyNewPending: false)
        }
        .onAppear { store.isVisible = true }
        .onDisappear { store.isVisible = false }
    }

    @ViewBuilder
    private var approvalsList: some View {
        if store.isLoading && store.approvals.isEmpty {
            ProgressView("Loading approvals…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.approvals.isEmpty && store.bannerWarning == nil {
            AppEmptyState(
                title: "No actions need approval",
                systemImage: "checkmark.shield",
                description: "Tool calls, memory changes, Mac control, connector writes, Workshop tasks, and harness improvements show up here when they need a decision."
            )
        } else {
            List {
                if !pending.isEmpty {
                    Section("Pending (\(pending.count))") {
                        ForEach(pending) { approval in
                            ApprovalCard(
                                approval: approval,
                                isDeciding: store.decidingApprovalID == approval.id
                            ) { decision in
                                Task {
                                    await store.decide(
                                        id: approval.id,
                                        decision: decision,
                                        client: bridgeClient,
                                        pairingStore: pairingStore
                                    )
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                    }
                }

                if !resolved.isEmpty {
                    Section("Resolved") {
                        ForEach(resolved.prefix(10)) { approval in
                            ResolvedRow(approval: approval)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Approval card (pending)

struct ApprovalCard: View {
    let approval: PendingApproval
    var isDeciding = false
    let onDecide: (String) -> Void

    @State private var expanded = false

    private var riskColor: Color {
        switch approval.risk.lowercased() {
        case "low":    return .green
        case "medium": return NativeAgentPalette.agentAccent
        case "high":   return .orange
        case "critical": return .red
        default:       return .secondary
        }
    }

    private var isMacOnly: Bool {
        approval.localOnly == true || approval.remoteResolvable == false
    }

    var body: some View {
        GlassCard(tint: riskColor) {
            VStack(alignment: .leading, spacing: 12) {

                // Header row: action name + risk badge
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(approval.title.isEmpty ? approval.action : approval.title)
                            .font(AppFont.section)
                        Text(approval.action)
                            .font(AppFont.label)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    RiskBadge(risk: approval.risk, color: riskColor)
                }

                // Reason
                if let reason = approval.reason, !reason.isEmpty {
                    Text(reason)
                        .font(AppFont.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                // Created-at relative time
                if let createdAtStr = approval.createdAt,
                   let date = ISO8601DateFormatter().date(from: createdAtStr) {
                    Text(relativeTime(from: date))
                        .font(AppFont.tag)
                        .foregroundStyle(.tertiary)
                }

                // Payload preview (mono, truncated)
                PayloadPreview(approval: approval, expanded: $expanded)

                // Action buttons
                if isMacOnly {
                    Label("Review this one on the Mac app", systemImage: "macwindow.badge.exclamationmark")
                        .font(AppFont.label)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    HStack(spacing: 12) {
                        // Approve gradient fill
                        Button {
                            withAnimation(AppMotion.snappy) { onDecide("approve") }
                        } label: {
                            Label(isDeciding ? "Approving" : "Approve", systemImage: isDeciding ? "hourglass" : "checkmark")
                                .font(AppFont.section)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background {
                                    Capsule().fill(NativeAgentPalette.agentGradient)
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeciding)

                        // Deny — bordered
                        Button {
                            withAnimation(AppMotion.snappy) { onDecide("deny") }
                        } label: {
                            Label("Deny", systemImage: "xmark")
                                .font(AppFont.section)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background {
                                    Capsule()
                                        .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1.2)
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeciding)
                    }
                }
            }
        }
        .opacity(isDeciding ? 0.72 : 1)
    }

    private func relativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }
}

// MARK: - Payload preview

struct PayloadPreview: View {
    let approval: PendingApproval
    @Binding var expanded: Bool

    // Build a pretty-printed JSON string from the approval for display
    private var payloadText: String {
        if let preview = approval.payloadPreview, !preview.isEmpty {
            return preview
        }
        // Encode the approval's action + title as a rough preview dict
        // (the real payload dict isn't decoded separately — the Mac can add it as
        //  a top-level "payload" key; for now we show the fields we have)
        var dict: [String: Any] = [
            "action": approval.action,
        ]
        if let r = approval.reason { dict["reason"] = r }
        if let json = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: json, encoding: .utf8) {
            return str
        }
        return "{ \"action\": \"\(approval.action)\" }"
    }

    private let maxLines = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(expanded ? .vertical : []) {
                Text(payloadText)
                    .font(AppFont.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : maxLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: expanded ? 220 : nil)

            Button {
                withAnimation(AppMotion.snappy) { expanded.toggle() }
            } label: {
                Text(expanded ? "Show less" : "Show more")
                    .font(AppFont.tag)
                    .foregroundStyle(NativeAgentPalette.agentAccent)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Risk badge

struct RiskBadge: View {
    let risk: String
    let color: Color

    var body: some View {
        Text(risk.uppercased())
            .font(AppFont.tag)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }
}

// MARK: - Resolved row (history)

struct ResolvedRow: View {
    let approval: PendingApproval

    private var decisionColor: Color {
        switch approval.decision?.lowercased() {
        case "approve", "approved": return .green
        case "deny", "denied", "reject", "rejected": return .red
        default:        return .secondary
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(approval.title.isEmpty ? approval.action : approval.title)
                    .font(AppFont.label)
                Text(approval.action)
                    .font(AppFont.tag)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let decision = approval.decision {
                Text(decision.capitalized)
                    .font(AppFont.tag)
                    .foregroundStyle(decisionColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(decisionColor.opacity(0.12), in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Banner

private struct BannerView: View {
    enum Style { case error, warning }
    let message: String
    let style: Style

    private var bgColor: Color {
        style == .error ? Color.red.opacity(0.85) : Color.orange.opacity(0.85)
    }

    private var icon: String {
        style == .error ? "wifi.slash" : "exclamationmark.triangle"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption.weight(.semibold))
            Text(message).font(AppFont.label).lineLimit(2)
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(bgColor)
        .ignoresSafeArea(edges: .horizontal)
    }
}

// MARK: - Badge helper (used by ContentView tab item)

extension ApprovalsStore {
    /// Returns a red badge label string for the tab item, or nil when count is 0.
    var tabBadge: String? {
        pendingCount > 0 ? "\(pendingCount)" : nil
    }
}
