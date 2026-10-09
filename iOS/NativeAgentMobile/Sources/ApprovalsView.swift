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

/// An approval in plain words on the phone: the kind of ask instead of its
/// dotted action id, and the reason without internal tags or raw markdown.
enum ApprovalText {
    @MainActor static var agentDecision: String { "\(iCloudSyncEngine.shared.agentDisplayName) decides her studio canon." }

    /// "self_improvement.apply" → "Self-improvement"; unknown ids read as words.
    static func kind(_ action: String) -> String {
        let id = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let head = id.split(separator: ".").first.map(String.init) ?? id
        switch head {
        case "self_improvement", "improvement": return "Self-improvement"
        case "skill": return "New skill"
        case "memory", "rem": return "Memory"
        case "autonomy": return "Autonomy"
        case "mission", "execution", "workshop": return "Task step"
        default: return id.isEmpty ? "Before I go ahead" : ToolActivityPresentation.title(id)
        }
    }

    static func title(_ approval: PendingApproval) -> String {
        approval.title.isEmpty ? ToolActivityPresentation.title(approval.action)
            : ToolActivityPresentation.approvalText(approval.title, tool: approval.action)
    }

    static func reason(_ approval: PendingApproval) -> String? {
        approval.reason.map { readable(ToolActivityPresentation.approvalText($0, tool: approval.action)) }
    }

    /// "[run_memory_hygiene] Run memory hygiene…" → "Run memory hygiene…";
    /// a markdown draft loses its heading marks, slug headings and backticks.
    static func readable(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tag = text.firstMatch(of: /^\[[A-Za-z0-9_.\-]+\]\s*/) { text.removeSubrange(tag.range) }
        var lines: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let marks = line.firstMatch(of: /^#{1,6}\s*/) {
                line.removeSubrange(marks.range)
                // "# learned-workspace-then-workspace-8c211c66": a generated name.
                if !line.contains(" "), line.contains(where: { "-_.".contains($0) }) { continue }
            }
            line = line.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The warning slot is reserved for a real asynchronous handoff. A healthy
/// snapshot does not need a persistent warning just because it arrived through
/// iCloud.
enum ApprovalBannerPresentation {
    static let pendingDecisionMessage =
        "Decision unconfirmed. Reconnect, then refresh to check the result. If still pending, retry the decision."

    static func warning(hasPendingLocalDecision: Bool) -> String? {
        hasPendingLocalDecision ? "Decision accepted. Waiting for the updated list from your Mac." : nil
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
    @Published private(set) var hasLoadedSnapshot = false
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
        if iCloudSyncEngine.shared.approvalsSnapshotLoaded { hasLoadedSnapshot = true }
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
            if route == .approve {
                _ = try await iCloudSyncEngine.shared.approveApproval(id: id)
            } else if route == .cancel {
                _ = try await iCloudSyncEngine.shared.cancelApproval(id: id)
            } else {
                _ = try await iCloudSyncEngine.shared.rejectApproval(id: id)
            }
            markApprovalFinal(id: id, decision: route.finalDecision)
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
        let merged = mergeLocalFinalDecisions(iCloudSyncEngine.shared.approvals)
        withAnimation(AppMotion.snappy) { approvals = merged }
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
            content.body = ApprovalText.title(approval)
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
            do {
                let request = UNNotificationRequest(identifier: "nativeagent.approval.summary.\(UUID().uuidString)",
                    content: try await CommunicationNotification.decorate(content), trigger: nil)
                try await center.add(request)
            } catch {
                NSLog("[NativeAgentMobile] Approval summary notification failed: %@", error.localizedDescription)
            }
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

    private var headerLine: String {
        switch pending.count {
        case 0: return resolved.isEmpty ? "Nothing to decide." : "You're all caught up."
        case 1: return "One thing is waiting on your yes."
        default: return "\(AliveWords.spelled(pending.count)) things are waiting on your yes."
        }
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
        // E6: a stale queue must not read as a measured-empty one.
        AlivePage(title: "Approvals", line: headerLine, freshnessGroup: "approvals") {
            if store.isLoading { ProgressView().controlSize(.small) }
        } content: {
            // "Pair to view" is already said by the header and its Pair with Mac.
            let bannerError = store.bannerError == "Pair to view" ? nil : store.bannerError
            if store.bannerWarning != nil || bannerError != nil {
                VStack(spacing: 8) {
                    if let warn = store.bannerWarning {
                        BannerView(message: warn, style: .warning)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let err = bannerError {
                        BannerView(message: err, style: .error)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            approvalsList
        }
        .animation(AppMotion.snappy, value: store.bannerError)
        .animation(AppMotion.snappy, value: store.bannerWarning)
        // Sweep R4 C11.3: an approval decision made against a stale snapshot is
        // exactly the case where a silent sync failure hurts most.
        .macSyncErrorBanner()
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
            ProgressView("Checking with your Mac…")
                .tint(AlivePalette.secondary)
                .foregroundStyle(AlivePalette.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
        } else if MobileDesignSamples.rows(store.approvals).isEmpty && store.bannerWarning == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Nothing is waiting on you.")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(AlivePalette.text)
                Text("When a call is yours — Trust, publishing in your name — I'll ask here.")
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check again") {
                    Task { await store.refresh(client: bridgeClient, pairingStore: pairingStore) }
                }
                .aliveSecondaryButton()
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            }
            .padding(20)
            .aliveCard()
        } else {
            // Native sections, one row per approval (User 09-27: all native).
            if !pending.isEmpty {
                Section("Waiting for you") {
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
                    }
                }
            }

            if !resolved.isEmpty {
                Section("Decided") {
                    ForEach(resolved.prefix(resolvedLimit)) { approval in
                        ResolvedRow(approval: approval)
                    }
                    if resolved.count > resolvedLimit {
                        Button("Show \(min(10, resolved.count - resolvedLimit)) more") {
                            resolvedLimit += 10
                        }
                    }
                }
            }
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

    private var canSendDecision: Bool {
        pairingStore.isICloudSigned && bridge.available && bridgeClient.bridgeStatus != .deviceOffline
    }

    private var isAgentDecision: Bool {
        !ActivityScreenPresentation.canDecideRemotely(action: approval.action)
    }

    /// "Medium risk · 4m ago": what kind of ask, and when.
    private var kindLine: String {
        var parts: [String] = []
        let risk = approval.risk.trimmingCharacters(in: .whitespacesAndNewlines)
        if !risk.isEmpty { parts.append("\(risk.capitalized) risk") }
        if let createdAtStr = approval.createdAt,
           let date = ISO8601DateFormatter().date(from: createdAtStr) {
            parts.append(relativeTime(from: date))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AliveWaitingDot()
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(kindLine.isEmpty ? "Before I go ahead" : kindLine)
                    .font(.caption)
                    .foregroundStyle(AlivePalette.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(ApprovalText.title(approval))
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(AlivePalette.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !approval.title.isEmpty {
                    Text(ApprovalText.kind(approval.action))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AlivePalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let reason = ApprovalText.reason(approval), !reason.isEmpty {
                Text(reason)
                    .font(.body)
                    .foregroundStyle(AlivePalette.text.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Never raw payload on the card: a plain line, or a quiet Details.
            PayloadPreview(approval: approval)

            if isAgentDecision {
                Text(ApprovalText.agentDecision)
                    .font(.footnote)
                    .foregroundStyle(AlivePalette.secondary)
            } else {
                // Unpaired, the page's note already says so; this line is for
                // a paired phone that cannot reach the Mac right now.
                if !canSendDecision && pairingStore.usesICloudTransport {
                    Text("Still waiting. Pair with your Mac over iCloud to answer from here; a decision is never retried on its own.")
                        .font(.footnote)
                        .foregroundStyle(AlivePalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button {
                        withAnimation(AppMotion.snappy) { onDecide("deny") }
                    } label: {
                        Text("Deny").frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .aliveSecondaryButton()
                    .disabled(isDeciding || !canSendDecision)

                    Button {
                        withAnimation(AppMotion.snappy) { onDecide("approve") }
                    } label: {
                        Text(isDeciding ? "Approving…" : "Approve").frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .alivePrimaryButton()
                    .disabled(isDeciding || !canSendDecision)
                }
                .font(.body.weight(.semibold))
                .controlSize(.large)
            }
        }
        .aliveRow()
        .aliveCard()
        .opacity(isDeciding ? 0.72 : 1)
    }

    private func relativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86_400 { return "\(Int(interval / 3600))h ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Payload preview

/// What will be sent, said on the card in plain lines ("To: Sam", "Message:
/// …") above Approve: nobody says yes to something they cannot see, and
/// nobody reads JSON. Keys become words; braces, quotes and ids never show.
/// The full raw view stays one tap away in "Details". When the Mac sent
/// nothing, one plain line says so; nothing is ever synthesized.
struct PayloadPreview: View {
    let approval: PendingApproval
    /// Chat's inline card is shorter: fewer lines before "Details".
    var maxLines = 6
    @State private var showsDetails = false

    static let missingLine = "Full details appear once your Mac sends them."

    /// The Mac's own payload, or nil.
    var payload: String? {
        guard let preview = approval.payloadPreview?.trimmingCharacters(in: .whitespacesAndNewlines),
              !preview.isEmpty else { return nil }
        return preview
    }

    var body: some View {
        if let payload {
            let lines = Self.readableLines(payload)
            VStack(alignment: .leading, spacing: 6) {
                if let lines {
                    ForEach(Array(lines.prefix(maxLines).enumerated()), id: \.offset) { _, line in
                        (Text(line.label + ": ").foregroundStyle(AlivePalette.secondary)
                            + Text(line.value).foregroundStyle(AlivePalette.text))
                            .font(.subheadline)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    // The Mac wrote a sentence, not a payload: its first
                    // paragraph in plain words; the rest stays in Details.
                    Text(ApprovalText.readable(payload).components(separatedBy: "\n\n").first ?? payload)
                        .font(.subheadline)
                        .foregroundStyle(AlivePalette.text)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let hidden = max(0, (lines?.count ?? 0) - maxLines)
                Button(hidden > 0 ? "Details \u{00b7} \(hidden) more" : "Details") { showsDetails = true }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AlivePalette.secondary)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityHint("Shows everything your Mac sent for this request")
            }
            .sheet(isPresented: $showsDetails) {
                ApprovalDetailsSheet(title: ApprovalText.title(approval),
                                     payload: payload) { showsDetails = false }
            }
        } else {
            Text(Self.missingLine)
                .font(.footnote)
                .foregroundStyle(AlivePalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    struct Line: Equatable {
        let label: String
        let value: String
    }

    /// A JSON payload as readable lines, or nil when it is not a JSON object
    /// (the Mac's own human preview). A connector call's `input` (or
    /// arguments) is what will be sent, so it leads.
    static func readableLines(_ payload: String) -> [Line]? {
        guard let data = payload.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var body = object
        for key in ["input", "arguments", "args", "params", "parameters"] {
            if let inner = object[key] as? [String: Any], !inner.isEmpty { body = inner; break }
        }
        var lines: [Line] = []
        for key in readingOrder(body.keys) where !isID(key) {
            if let nested = body[key] as? [String: Any] {
                for inner in readingOrder(nested.keys) where !isID(inner) {
                    if let value = words(nested[inner]) { lines.append(Line(label: label(inner), value: value)) }
                }
            } else if let value = words(body[key]) {
                lines.append(Line(label: label(key), value: value))
            }
        }
        return lines
    }

    /// Who and where first, then what, then the message, then the rest:
    /// the order a person reads an envelope, not the alphabet.
    private static func readingOrder<S: Sequence>(_ keys: S) -> [String] where S.Element == String {
        let lead = ["to", "recipient", "recipients", "channel", "chat", "calendar", "list", "account",
                    "cc", "bcc", "subject", "title", "name", "when", "date", "start", "start_date",
                    "startdate", "end", "end_date", "enddate", "message", "text", "body", "content", "notes"]
        func rank(_ key: String) -> Int {
            let flat = key.lowercased().replacingOccurrences(of: "-", with: "_")
            return lead.firstIndex(of: flat) ?? lead.firstIndex(of: flat.replacingOccurrences(of: "_", with: "")) ?? lead.count
        }
        return keys.sorted { (rank($0), $0) < (rank($1), $1) }
    }

    private static func isID(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower == "id" || lower.hasSuffix("_id") || lower.hasSuffix("-id") || lower.hasSuffix("uuid")
            || (key.hasSuffix("Id") || key.hasSuffix("ID")) && key.count > 2
    }

    /// "startDate" / "start_date" → "Start date".
    private static func label(_ key: String) -> String {
        var spaced = ""
        for (index, char) in key.enumerated() {
            if index > 0, char.isUppercase, let last = spaced.last, last.isLowercase { spaced.append(" ") }
            spaced.append(char)
        }
        let words = AliveWords.humanized(spaced.lowercased())
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A value as words: strings as they are (dates readable), numbers,
    /// Yes/No, short lists joined. Nested structures stay in Details.
    private static func words(_ value: Any?) -> String? {
        let text: String
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            text = AliveWords.date(trimmed) != nil ? AliveWords.readable(trimmed) : trimmed
        case let number as NSNumber:
            text = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "Yes" : "No") : number.stringValue
        case let list as [Any]:
            let items = list.compactMap { $0 is [String: Any] || $0 is [Any] ? nil : words($0) }
            guard !items.isEmpty else { return nil }
            text = items.count > 4 ? items.prefix(4).joined(separator: ", ") + ", +\(items.count - 4) more"
                : items.joined(separator: ", ")
        default:
            return nil
        }
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 160 ? String(flat.prefix(159)) + "\u{2026}" : flat
    }
}

/// The approval's details: exactly what the Mac sent, off the card.
private struct ApprovalDetailsSheet: View {
    let title: String
    let payload: String
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            AlivePage(title: title, line: "What your Mac sent for this request.", style: .pushed) {
                Section {
                    Text(payload)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(AlivePalette.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toolbar { Button("Done", action: onDone) }
        }
    }
}

// MARK: - Risk badge

struct RiskBadge: View {
    let risk: String
    let color: Color

    var body: some View {
        Text("\(risk.capitalized) risk")
            .font(.caption)
            .foregroundStyle(AlivePalette.secondary)
    }
}

// MARK: - Resolved row (history)

struct ResolvedRow: View {
    let approval: PendingApproval

    var body: some View {
        MobileAdaptiveRow {
            VStack(alignment: .leading, spacing: 3) {
                Text(ApprovalText.title(approval))
                    .font(.body)
                    .foregroundStyle(AlivePalette.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !approval.title.isEmpty {
                    Text(ApprovalText.kind(approval.action))
                        .font(.footnote)
                        .foregroundStyle(AlivePalette.secondary)
                }
                if let summary = approval.expirationGuidance(agentName: iCloudSyncEngine.shared.agentDisplayName) ?? approval.executionSummary {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(AlivePalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(approval.decisionSummary)
                .font(.subheadline)
                .foregroundStyle(AlivePalette.secondary)
        }
        .aliveRow()
    }
}

// MARK: - Banner

private struct BannerView: View {
    enum Style { case error, warning }
    let message: String
    let style: Style

    private var icon: String {
        style == .error ? "wifi.slash" : "clock"
    }

    var body: some View {
        AliveStatusNote(systemImage: icon, text: message)
    }
}

// MARK: - Badge helper (used by ContentView tab item)

extension ApprovalsStore {
    /// Returns a red badge label string for the tab item, or nil when count is 0.
    var tabBadge: String? {
        pendingCount > 0 ? "\(pendingCount)" : nil
    }
}
