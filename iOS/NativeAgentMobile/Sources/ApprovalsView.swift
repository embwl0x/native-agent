import SwiftUI
import NativeAgentShared
import UserNotifications
// Blueprint: | `ApprovalsView.swift` | Approval list, cards and history read the shared sync projection, including Mac-resolved decision and time |

// MARK: - Model

/// Approval snapshot shape shared with the Mac app.
/// `ApprovalRequest` in Models.swift covers most fields; this alias reuses it.
typealias PendingApproval = ApprovalRequest

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

// MARK: - Top-level view

struct ApprovalsView: View {
    @State private var resolvedLimit = 10
    @EnvironmentObject private var pairingStore: PairingStore
    @EnvironmentObject private var store: ApprovalsStore

    private var pending: [PendingApproval] {
        MobileDesignSamples.rows(store.approvals).filter { $0.outcome == .pending }
    }

    private var resolved: [PendingApproval] {
        MobileDesignSamples.rows(store.approvals).filter { $0.outcome != .pending }
    }

    private var headerLine: String {
        guard let overview = iCloudSyncEngine.shared.workOverview, overview.unavailable.isEmpty,
              let counts = overview.needsYouCounts else { return "Approval attention is unavailable." }
        let count = counts[.approval] ?? 0
        switch count {
        case 0: return resolved.isEmpty ? "Nothing to decide." : "You're all caught up."
        case 1: return "One thing is waiting on your yes."
        default: return "\(AliveWords.spelled(count)) things are waiting on your yes."
        }
    }

    var body: some View {
        approvalsContent
    }

    @ViewBuilder
    private var approvalsContent: some View {
        // A stale queue must not read as a measured-empty one.
        AlivePage(title: "Approvals", line: headerLine, freshnessGroup: "approvals") {
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
        // Keep sync failures visible while deciding an approval.
        .macSyncErrorBanner()
        .refreshable {
            await store.refresh(pairingStore: pairingStore)
        }
        .task {
            await store.refresh(pairingStore: pairingStore)
        }
        .onChange(of: iCloudSyncEngine.shared.approvals, initial: true) { _, _ in
            guard pairingStore.usesICloudTransport, store.isVisible else { return }
            store.applySyncedApprovalsFromSnapshot(notifyNewPending: false)
        }
        .onAppear { store.isVisible = true }
        .onDisappear { store.isVisible = false }
    }

    @ViewBuilder
    private var approvalsList: some View {
        if MobileDesignSamples.rows(store.approvals).isEmpty && store.bannerWarning == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Nothing is waiting on you.")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(AlivePalette.text)
                Text("When a call is yours — Trust, publishing in your name — I'll ask here.")
                    .font(.subheadline)
                    .foregroundStyle(AlivePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Check again") {
                    Task { await store.refresh(pairingStore: pairingStore) }
                }
                .aliveSecondaryButton()
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            }
            .padding(20)
            .aliveCard()
        } else {
            // Native sections, one row per approval.
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
    let onDecide: (ApprovalDecisionRoute) -> Void

    private var canSendDecision: Bool {
        pairingStore.isICloudSigned && bridge.available && bridgeClient.deviceIsOffline != true
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
           let date = UserDisplayFormatters.parseISOTimestamp(createdAtStr) {
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
                        withAnimation(AppMotion.snappy) { onDecide(.reject) }
                    } label: {
                        Text("Deny").frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .aliveSecondaryButton()
                    .disabled(isDeciding || !canSendDecision)

                    Button {
                        withAnimation(AppMotion.snappy) { onDecide(.approve) }
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
