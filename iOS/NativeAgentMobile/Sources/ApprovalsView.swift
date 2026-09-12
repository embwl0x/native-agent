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

/// Closed translation from visible card verbs to the signed Mac action.
/// Unknown input must fail before a card can accidentally take a privileged
/// affirmative path.
enum ApprovalDecisionRoute: Equatable {
    case approve
    case reject
    case cancel

    var action: String {
        switch self {
        case .approve: return "approve"
        case .reject: return "reject"
        case .cancel: return "cancel"
        }
    }

    var finalDecision: String {
        switch self {
        case .approve: return "approved"
        case .reject: return "denied"
        case .cancel: return "canceled"
        }
    }

    static func resolve(_ value: String) -> ApprovalDecisionRoute? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approve", "approved": return .approve
        case "deny", "denied", "reject", "rejected": return .reject
        case "cancel", "canceled": return .cancel
        default: return nil
        }
    }
}

/// The warning slot is reserved for a real asynchronous handoff. A healthy
/// snapshot does not need a persistent warning just because it arrived through
/// iCloud.
enum ApprovalBannerPresentation {
    static let pendingDecisionMessage =
        "Decision unconfirmed. Reconnect, then refresh to check the result. If still pending, retry the decision."

    static func warning(hasPendingLocalDecision: Bool) -> String? {
        hasPendingLocalDecision ? pendingDecisionMessage : nil
    }
}

/// Pure notification policy for approval snapshots. Keeping the policy apart
/// from `UNUserNotificationCenter` makes the cold-load, visibility, and burst
/// rules executable without asking the system to present a notification.
enum ApprovalPendingNotificationPresentation {
    static let individualNotificationLimit = 3

    struct Plan: Equatable {
        let individualApprovalIDs: [String]
        let summaryCount: Int?

        static let none = Plan(individualApprovalIDs: [], summaryCount: nil)
    }

    static func plan(
        hasLoadedApprovals: Bool,
        isVisible: Bool,
        pendingIDs: [String],
        notifiedIDs: Set<String>
    ) -> Plan {
        guard hasLoadedApprovals, !isVisible else { return .none }

        var newIDs: [String] = []
        var seenIDs = Set<String>()
        for id in pendingIDs where !notifiedIDs.contains(id) && seenIDs.insert(id).inserted {
            newIDs.append(id)
        }

        guard !newIDs.isEmpty else { return .none }
        if newIDs.count > individualNotificationLimit {
            return Plan(individualApprovalIDs: [], summaryCount: newIDs.count)
        }
        return Plan(individualApprovalIDs: newIDs, summaryCount: nil)
    }
}

// MARK: - Store

@MainActor
final class ApprovalsStore: ObservableObject {
    @Published var approvals: [PendingApproval] = []
    @Published var isLoading = false
    @Published var bannerError: String? = nil
    @Published var bannerWarning: String? = nil
    /// Distinct approval decisions may be sent together. The former single id
    /// made every other card look tappable while silently discarding its tap.
    @Published private(set) var decidingApprovalIDs = Set<String>()
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
        bannerWarning = ApprovalBannerPresentation.warning(
            hasPendingLocalDecision: !locallyFinalizedApprovals.isEmpty
        )
        bannerError = nil
    }

    // MARK: - Decide

    func decide(id: String, decision: String, client: MacBridgeClient, pairingStore: PairingStore) async {
        guard beginDecision(id: id) else { return }
        defer { finishDecision(id: id) }
        guard pairingStore.usesICloudTransport else {
            bannerError = "Pair to view"
            return
        }
        do {
            guard let route = ApprovalDecisionRoute.resolve(decision) else {
                bannerError = "Unsupported approval decision."
                return
            }
            markApprovalFinal(id: id, decision: route.finalDecision)
            if route == .approve {
                _ = try await iCloudSyncEngine.shared.approveApproval(id: id)
            } else if route == .cancel {
                _ = try await iCloudSyncEngine.shared.cancelApproval(id: id)
            } else {
                _ = try await iCloudSyncEngine.shared.rejectApproval(id: id)
            }
            await refresh(client: client, pairingStore: pairingStore)
        } catch {
            if iCloudSyncEngine.isMacResponseTimeout(error) {
                await refresh(client: client, pairingStore: pairingStore)
                bannerWarning = ApprovalBannerPresentation.pendingDecisionMessage
                bannerError = nil
            } else {
                locallyFinalizedApprovals.removeValue(forKey: id)
                // Rebuild from transport truth while preserving any other
                // concurrently submitted local decisions. Restoring the whole
                // pre-call array would resurrect sibling cards that succeeded.
                let merged = mergeLocalFinalDecisions(iCloudSyncEngine.shared.approvals)
                withAnimation(AppMotion.snappy) { approvals = merged }
                iCloudSyncEngine.shared.approvals = merged
                bannerWarning = nil
                bannerError = "Failed to record decision: \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func beginDecision(id: String) -> Bool {
        let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !decidingApprovalIDs.contains(clean) else { return false }
        decidingApprovalIDs.insert(clean)
        return true
    }

    func finishDecision(id: String) {
        decidingApprovalIDs.remove(id.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Hold a confirmed local final decision until the Mac snapshot reflects
    /// it, so a card cannot be offered again in the handoff window.
    func markApprovalFinal(id: String, decision: String) {
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
        let pendingIDs = pending.map(\.id)
        defer {
            notifiedPendingIDs.formUnion(pendingIDs)
            hasLoadedApprovals = true
        }

        let plan = ApprovalPendingNotificationPresentation.plan(
            hasLoadedApprovals: hasLoadedApprovals,
            isVisible: isVisible,
            pendingIDs: pendingIDs,
            notifiedIDs: notifiedPendingIDs
        )
        for id in plan.individualApprovalIDs {
            guard let approval = pending.first(where: { $0.id == id }) else { continue }
            fireApprovalNotification(approval)
        }
        if let summaryCount = plan.summaryCount {
            fireApprovalSummaryNotification(count: summaryCount)
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
    @State private var resolvedLimit = 10
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
        MobileDesignSamples.rows(store.approvals).filter { $0.status.lowercased() == "pending" }
    }

    private var resolved: [PendingApproval] {
        MobileDesignSamples.rows(store.approvals).filter { $0.status.lowercased() != "pending" }
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
        VStack(spacing: 0) {
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
            approvalsList
        }
        .mobileReadingScreen()
        .navigationTitle("Approvals")
        // Sweep R4 C11.3: an approval decision made against a stale snapshot is
        // exactly the case where a silent sync failure hurts most.
        .macSyncErrorBanner()
        .safeAreaInset(edge: .top, spacing: 0) { MacStatusChip().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16) }
        // E6: and a stale queue must not read as a measured-empty one.
        .macSnapshotFreshnessBadge(group: "approvals")
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
        if store.isLoading && MobileDesignSamples.rows(store.approvals).isEmpty {
            ProgressView("Loading approvals…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if MobileDesignSamples.rows(store.approvals).isEmpty && store.bannerWarning == nil {
            MobileReadingEmptyState(
                title: "No actions need approval",
                systemImage: "checkmark.shield",
                kind: .empty,
                description: "Tool calls, memory changes, Mac control, connector writes, Desk tasks, and harness improvements show up here when they need a decision."
            )
        } else {
            List {
                if !pending.isEmpty {
                    Section("Pending (\(pending.count))") {
                        ForEach(pending) { approval in
                            ApprovalCard(
                                approval: approval,
                                isDeciding: store.decidingApprovalIDs.contains(approval.id)
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
                        ForEach(resolved.prefix(resolvedLimit)) { approval in
                            ResolvedRow(approval: approval)
                        }
                        if resolved.count > resolvedLimit {
                            MobileLoadedRecordsDisclosure(title: "Show more decisions", remaining: resolved.count - resolvedLimit) {
                                resolvedLimit += 10
                            }
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
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var bridgeClient: MacBridgeClient
    @ObservedObject private var bridge = iCloudBridge.shared
    let approval: PendingApproval
    var isDeciding = false
    let onDecide: (String) -> Void

    @State private var expanded = false

    private var canSendDecision: Bool {
        pairingStore.isICloudSigned && bridge.available && bridgeClient.bridgeStatus != .deviceOffline
    }

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
        MobileReadingSurface {
            VStack(alignment: .leading, spacing: 12) {

                // Header row: action name + risk badge
                MobileAdaptiveRow(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(approval.title.isEmpty ? approval.action : approval.title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(approval.action)
                            .font(.callout)
                            .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                    }
                    Spacer()
                    RiskBadge(risk: approval.risk, color: riskColor)
                }

                // Reason
                if let reason = approval.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.body)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Created-at relative time
                if let createdAtStr = approval.createdAt,
                   let date = ISO8601DateFormatter().date(from: createdAtStr) {
                    Text(relativeTime(from: date))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Payload preview (mono, truncated)
                PayloadPreview(approval: approval, expanded: $expanded)

                // Action buttons
                if isMacOnly {
                    Label("Review this one on the Mac app", systemImage: "macwindow.badge.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    if !canSendDecision {
                        Text("Still pending. Connect iCloud and pair with the Mac to send a decision. Decisions are not automatically retried.")
                            .font(.callout)
                            .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                    }
                    MobileActionRow {
                        // Approve gradient fill
                        Button {
                            withAnimation(AppMotion.snappy) { onDecide("approve") }
                        } label: {
                            Label(isDeciding ? "Approving" : "Approve", systemImage: isDeciding ? "hourglass" : "checkmark")
                                .font(.headline)
                                .foregroundStyle(NativeAgentMobileTheme.Colors.onAccent)
                                .frame(minHeight: 44)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background {
                                    Capsule().fill(NativeAgentMobileTheme.Colors.accentText)
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeciding || !canSendDecision)

                        // Deny — bordered
                        Button {
                            withAnimation(AppMotion.snappy) { onDecide("deny") }
                        } label: {
                            Label("Deny", systemImage: "xmark")
                                .font(.headline)
                                .foregroundStyle(NativeAgentMobileTheme.Colors.accentText)
                                .frame(minHeight: 44)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background {
                                    Capsule()
                                        .strokeBorder(NativeAgentMobileTheme.Colors.accentText, lineWidth: 1.2)
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeciding || !canSendDecision)
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
    var payloadText: String {
        if let preview = approval.payloadPreview, !preview.isEmpty {
            return preview
        }
        // This is context inferred from the approval envelope, not the real
        // Mac-side payload. Never render it as though it were canonical.
        var dict: [String: Any] = [
            "action": approval.action,
        ]
        if let r = approval.reason { dict["reason"] = r }
        if let json = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: json, encoding: .utf8) {
            return "Preview generated from action/reason — Mac did not publish the real payload.\n\n\(str)"
        }
        return "Preview generated from action/reason — Mac did not publish the real payload.\n\n{ \"action\": \"\(approval.action)\" }"
    }

    private let maxLines = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(expanded ? .vertical : []) {
                Text(payloadText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                    .lineLimit(expanded ? nil : maxLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: expanded ? 220 : nil)

            Button {
                withAnimation(AppMotion.snappy) { expanded.toggle() }
            } label: {
                Text(expanded ? "Show less" : "Show more")
                    .font(.caption)
                    .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(NativeAgentMobileTheme.Colors.contentSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Risk badge

struct RiskBadge: View {
    let risk: String
    let color: Color

    var body: some View {
        Text(risk.uppercased())
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(NativeAgentMobileTheme.Colors.quietFill, in: Capsule())
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
        MobileAdaptiveRow {
            VStack(alignment: .leading, spacing: 4) {
                Text(approval.title.isEmpty ? approval.action : approval.title)
                    .font(.callout)
                Text(approval.action)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let decision = approval.decision {
                Text(decision.capitalized)
                    .font(.caption)
                    .foregroundStyle(NativeAgentMobileTheme.Colors.readingSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(NativeAgentMobileTheme.Colors.quietFill, in: Capsule())
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
        NativeAgentMobileTheme.Colors.contentSurface
    }

    private var icon: String {
        style == .error ? "wifi.slash" : "exclamationmark.triangle"
    }

    var body: some View {
        MobileAdaptiveRow(spacing: 8) {
            Image(systemName: icon).font(.caption.weight(.semibold))
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .foregroundStyle(.primary)
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
