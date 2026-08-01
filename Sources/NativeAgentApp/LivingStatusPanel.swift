import SwiftUI
import CognitiveSubstrate
import NativeAgentShared
import PersistenceCore

enum LivingAttentionPolicy {
    static func ownerDecisionDeskCount(in items: [DeskItem]) -> Int {
        items.filter(\.requiresOwnerInput).count
    }

    static func organismNeedsAttention(_ organism: OrganismSnapshot) -> Bool {
        guard organism.enabled else { return false }
        let body = organism.bodySchema
        return !body.providersHealthy
            || !body.toolHandsAvailable
            || !body.notificationPathHealthy
            || !body.iPhoneReachable
            || !body.memoryHealthy
            || !body.dreamHealthy
            || !body.approvalChannelsOpen
            || body.resourcePressure != .nominal
            || organism.reflexSummary.reviewRequiredCount > 0
    }

    static func needsUser(pendingApprovals: Int, ownerDecisionDeskCount: Int) -> Bool {
        pendingApprovals > 0 || ownerDecisionDeskCount > 0
    }
}

struct LivingStatusSnapshot: Sendable, Equatable {
    var enabled: Bool
    var posture: String
    var postureStatus: String
    var bodyState: String
    var behaviorLine: String
    var homeLine: String
    var whyLine: String
    var carryLine: String
    var innerLine: String
    var deskSummary: String
    var approvalsSummary: String
    var lastDreamSummary: String
    var needsText: String
    var showsOrganismDetails: Bool

    var visibleText: [String] {
        [
            posture,
            bodyState,
            behaviorLine,
            homeLine,
            whyLine,
            carryLine,
            innerLine,
            deskSummary,
            approvalsSummary,
            lastDreamSummary,
            needsText,
        ]
    }

    static func make(
        organism: OrganismSnapshot,
        activeDeskCount: Int,
        blockedDeskCount: Int,
        ownerDecisionDeskCount: Int = 0,
        pendingApprovals: Int,
        latestDream: DreamEntry?,
        agentDisplayName: String = "NativeAgent"
    ) -> LivingStatusSnapshot {
        let needsUser = LivingAttentionPolicy.needsUser(
            pendingApprovals: pendingApprovals,
            ownerDecisionDeskCount: ownerDecisionDeskCount
        )
        let needsAttention = !needsUser && (
            blockedDeskCount > 0 || LivingAttentionPolicy.organismNeedsAttention(organism)
        )
        let posture = Self.posture(for: organism)
        let behaviorLine = Self.behaviorLine(for: organism)
        return LivingStatusSnapshot(
            enabled: organism.enabled,
            posture: posture,
            postureStatus: (needsUser || needsAttention) ? "warn" : (organism.enabled ? "ok" : "disabled"),
            bodyState: Self.bodyState(for: organism),
            behaviorLine: behaviorLine,
            homeLine: Self.homeLine(
                posture: posture,
                needsUser: needsUser,
                organism: organism,
                agentDisplayName: agentDisplayName
            ),
            whyLine: Self.whyLine(
                for: organism,
                pendingApprovals: pendingApprovals,
                blockedDeskCount: blockedDeskCount,
                ownerDecisionDeskCount: ownerDecisionDeskCount,
                agentDisplayName: agentDisplayName
            ),
            carryLine: Self.carryLine(for: organism),
            innerLine: Self.innerLine(from: organism.projectedBodyLine, enabled: organism.enabled),
            deskSummary: Self.deskSummary(active: activeDeskCount, blocked: blockedDeskCount),
            approvalsSummary: pendingApprovals == 0 ? "no approvals pending" : "\(pendingApprovals) approval\(pendingApprovals == 1 ? "" : "s") pending",
            lastDreamSummary: latestDream.map { "last dream \($0.date)" } ?? "no dream entry yet",
            needsText: needsUser ? "needs you" : (needsAttention ? "no action needed" : "needs nothing"),
            showsOrganismDetails: organism.enabled
        )
    }

    private static func posture(for organism: OrganismSnapshot) -> String {
        guard organism.enabled else { return "Quiet" }
        let body = organism.bodySchema
        let chemical = organism.chemicalState
        if !body.providersHealthy || !body.toolHandsAvailable || chemical.vigilance > 0.35 { return "Careful" }
        if chemical.urgency > 0.35 { return "Urgent" }
        if chemical.fatigue > 0.35 || body.resourcePressure != .nominal { return "Tired" }
        if chemical.warmth > 0.35 || chemical.tenderness > 0.30 { return "Warm" }
        if chemical.curiosity > 0.35 || chemical.novelty > 0.35 { return "Curious" }
        if chemical.coherence > 0.56 && chemical.confidence > 0.55 { return "Integrated" }
        return "Steady"
    }

    private static func bodyState(for organism: OrganismSnapshot) -> String {
        guard organism.enabled else { return "body kernel off" }
        let body = organism.bodySchema
        if !body.macAwake { return "resting" }
        if !body.providersHealthy || !body.toolHandsAvailable { return "provider/tool brittle" }
        if !body.iPhoneReachable || !body.notificationPathHealthy { return "phone path stale" }
        if !body.memoryHealthy { return "memory brittle" }
        if !body.dreamHealthy { return "dreams need attention" }
        if !body.approvalChannelsOpen { return "approval path closed" }
        if body.resourcePressure != .nominal { return "resource tight" }
        return "body steady"
    }

    private static func behaviorLine(for organism: OrganismSnapshot) -> String {
        guard organism.enabled else { return "behavior posture off" }
        guard let posture = OrganismBehaviorPosture.from(snapshot: organism) else {
            return "behavior posture quiet"
        }
        return sanitized("claims \(posture.claimDiscipline.rawValue), tools \(posture.toolStrategy.rawValue), loops \(posture.loopBudget.rawValue)")
    }

    private static func homeLine(
        posture: String,
        needsUser: Bool,
        organism: OrganismSnapshot,
        agentDisplayName: String
    ) -> String {
        guard organism.enabled else { return "\(agentDisplayName) is quiet until organism mode is enabled." }
        let ask = needsUser ? "needs you" : "does not need you"
        return sanitized("\(agentDisplayName) is \(posture.lowercased()) and \(ask).")
    }

    private static func whyLine(
        for organism: OrganismSnapshot,
        pendingApprovals: Int,
        blockedDeskCount: Int,
        ownerDecisionDeskCount: Int,
        agentDisplayName: String
    ) -> String {
        if pendingApprovals > 0 { return "Waiting on approval before irreversible movement." }
        if ownerDecisionDeskCount > 0 { return "Desk has work explicitly waiting on your decision." }
        guard organism.enabled else { return "No body line appears while the organism kernel is off." }
        let body = organism.bodySchema
        if !body.providersHealthy || !body.toolHandsAvailable { return "Provider or tool path is brittle, so completion claims tighten." }
        if !body.notificationPathHealthy || !body.iPhoneReachable { return "Phone path is stale, so delivery needs receipts." }
        if body.resourcePressure != .nominal { return "Resource pressure is shaping loop budget." }
        if !body.memoryHealthy || !body.dreamHealthy || !body.approvalChannelsOpen {
            return "A local body path needs \(agentDisplayName)'s attention, but no user action is requested."
        }
        if blockedDeskCount > 0 { return "Desk has blocked work, but it is not waiting on your decision." }
        if organism.reflexSummary.reviewRequiredCount > 0 {
            return "\(agentDisplayName) has review work queued, but no user action is requested."
        }
        if organism.projectedBodyLine == nil { return "No Body line appears because the body state is steady enough to stay quiet." }
        return "Body line is active because the current state is shaping the turn."
    }

    private static func carryLine(for organism: OrganismSnapshot) -> String {
        guard organism.enabled else { return "carrying no organism state" }
        let proposals = organism.dreamRepairSummary.proposedStandingViews
        let approved = organism.reflexSummary.approvedLowRiskCount
        return sanitized("carrying \(organism.signalCount) signals, \(organism.fieldSummary.nodeCount) field nodes, \(organism.reflexSummary.reviewRequiredCount) reflex reviews, \(approved) approved biases, \(proposals) dream proposals")
    }

    private static func deskSummary(active: Int, blocked: Int) -> String {
        let activeText = "\(max(0, active)) desk item\(active == 1 ? "" : "s")"
        guard blocked > 0 else { return activeText }
        return "\(activeText), \(blocked) blocked"
    }

    private static func innerLine(from projectedBodyLine: String?, enabled: Bool) -> String {
        guard enabled else { return "quiet until organism mode is enabled" }
        let raw = projectedBodyLine?
            .replacingOccurrences(of: "- Body:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let line = raw.isEmpty ? "steady enough to stay out of the way" : raw
        return sanitized(line)
    }

    private static func sanitized(_ value: String) -> String {
        let oneLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = oneLine.lowercased()
        let home = NSHomeDirectory().lowercased()
        let blockedFragments = [
            ["api", "key"].joined(separator: "_"),
            ["api", "key"].joined(),
            "authorization:",
            ["bear", "er "].joined(),
            ["token", "="].joined(),
            ["to", "ken:"].joined(),
            "secret",
            ["sk", ""].joined(separator: "-"),
            ["xox", "b-"].joined(),
            ["xa", "pp", "-"].joined(),
        ]
        if (!home.isEmpty && lower.contains(home)) || blockedFragments.contains(where: lower.contains) {
            return "private body cue hidden"
        }
        guard oneLine.count > 160 else { return oneLine }
        return String(oneLine.prefix(157)) + "..."
    }
}

struct LivingStatusPanel: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: LivingStatusSnapshot?
    @State private var isRefreshing = false
    @State private var refreshRequestedWhileLoading = false
    @State private var refreshStatus: AppModel.PanelRefreshStatus?

    private var store: SwiftNativeDeskStore {
        SwiftNativeDeskStore(dataRoot: PersistenceCore.defaultDataRoot())
    }

    private var refreshPresentation: AppModel.CompactReadPresentationState {
        AppModel.compactReadPresentationState(hasContent: snapshot != nil, status: refreshStatus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Today", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                if let snapshot {
                    StatusBadge(text: snapshot.needsText, status: snapshot.postureStatus)
                } else if refreshPresentation == .unavailable {
                    StatusBadge(text: "Unavailable", status: "warn")
                }
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: isRefreshing ? "hourglass" : "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh \(appModel.agentDisplayName)'s current state")
                .accessibilityLabel("Refresh \(appModel.agentDisplayName)'s current state")
                .disabled(isRefreshing)
            }

            if let snapshot {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: snapshot.postureStatus == "warn" ? "exclamationmark.triangle.fill" : "face.smiling")
                            .foregroundStyle(snapshot.postureStatus == "warn" ? .orange : .green)
                            .frame(width: 16)
                        Text(snapshot.homeLine)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                    Text(snapshot.whyLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(snapshot.carryLine)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    livingRow("Posture", snapshot.posture, icon: "figure.stand")
                    livingRow("Body", snapshot.bodyState, icon: "heart.text.square")
                    livingRow("Behavior", snapshot.behaviorLine, icon: "point.3.connected.trianglepath.dotted")
                    Text(snapshot.innerLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    livingRow("Desk", snapshot.deskSummary, icon: "checklist")
                    livingRow("Approvals", snapshot.approvalsSummary, icon: "checkmark.shield")
                    livingRow("Dream", snapshot.lastDreamSummary, icon: "moon.stars")
                }
                if refreshPresentation == .stale {
                    // Endpoint names are internal vocabulary — plain headline,
                    // technical detail demoted to a tooltip (same pattern as
                    // DetachedChatLoadFailureCopy).
                    Label("Some of this couldn't refresh — showing the last known state.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .help((refreshStatus?.failedEndpoints.isEmpty == false)
                            ? "Did not respond: " + (refreshStatus?.failedEndpoints.joined(separator: ", ") ?? "")
                            : "The status sources did not respond.")
                }
            } else if refreshPresentation == .unavailable {
                Label("\(appModel.agentDisplayName)'s current state is unavailable; no calm or needs-nothing state was inferred.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading \(appModel.agentDisplayName)'s current state.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await ViewFileRefreshTask.run(paths: livingStatePaths) {
                await refresh()
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            let changes = await NativeCognitionRuntime.shared.changes()
            // This source is process-local and not every visible cognition
            // delta necessarily produces a file edge. Subscribe first, then
            // read once so a change racing view activation remains buffered.
            await refresh()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    private func livingRow(_ label: String, _ value: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    @MainActor
    private func refresh() async {
        if isRefreshing {
            // File and runtime edges can arrive together. Preserve one
            // trailing refresh instead of dropping whichever source lost the
            // race with the in-flight read.
            refreshRequestedWhileLoading = true
            return
        }
        repeat {
            isRefreshing = true
            refreshRequestedWhileLoading = false
            await refreshOnce()
            isRefreshing = false
        } while refreshRequestedWhileLoading && !Task.isCancelled
    }

    @MainActor
    private func refreshOnce() async {
        let organism = await NativeCognitionRuntime.shared.organismSnapshot()
        var failedEndpoints: [String] = []
        let deskItems: [DeskItem]
        do {
            deskItems = try await store.liveState().items
        } catch {
            deskItems = []
            failedEndpoints.append("Desk")
        }
        let activeDeskCount = deskItems.filter { !$0.status.isTerminal }.count
        let blockedDeskCount = deskItems.filter { $0.status == .blocked }.count
        let ownerDecisionDeskCount = LivingAttentionPolicy.ownerDecisionDeskCount(in: deskItems)
        let dreamDiary = await appModel.fetchDreamDiary(limit: 1)
        if dreamDiary == nil { failedEndpoints.append("Dream diary") }
        let latestDream = dreamDiary?.entries.first
        let approvalRows: [ApprovalRequest]
        do {
            approvalRows = try await appModel.getApprovals()
        } catch {
            approvalRows = []
            failedEndpoints.append("Approvals")
        }
        guard failedEndpoints.isEmpty else {
            refreshStatus = AppModel.nextRefreshStatus(
                previous: refreshStatus,
                failedEndpoints: failedEndpoints,
                at: Date()
            )
            return
        }
        let pendingApprovals = approvalRows.filter { $0.status.lowercased() == "pending" }.count
        snapshot = LivingStatusSnapshot.make(
            organism: organism,
            activeDeskCount: activeDeskCount,
            blockedDeskCount: blockedDeskCount,
            ownerDecisionDeskCount: ownerDecisionDeskCount,
            pendingApprovals: pendingApprovals,
            latestDream: latestDream,
            agentDisplayName: appModel.agentDisplayName
        )
        refreshStatus = AppModel.nextRefreshStatus(
            previous: refreshStatus,
            failedEndpoints: [],
            at: Date()
        )
    }

    private var livingStatePaths: [URL] {
        let root = PersistenceCore.defaultDataRoot()
        let memory = root.appendingPathComponent("memory", isDirectory: true)
        return [
            root.appendingPathComponent("cognition/organism_state.json"),
            root.appendingPathComponent("desk/desk_ops.jsonl"),
            root.appendingPathComponent("desk/desk_state.json"),
            root.appendingPathComponent("workflows/approvals/requests.json"),
            root.appendingPathComponent("dream_diary", isDirectory: true),
            root.appendingPathComponent("mobile/signed_peer_evidence.json"),
            root.appendingPathComponent("mobile_push/receipts.jsonl"),
            root.appendingPathComponent("mobile_push/tokens.json"),
            root.appendingPathComponent("notifications/push_tokens.json"),
            memory.appendingPathComponent("memory.sqlite"),
            memory.appendingPathComponent("memory.sqlite-wal"),
            memory.appendingPathComponent("profile.json"),
            memory.appendingPathComponent("knowledge_graph.json"),
            memory.appendingPathComponent("hygiene_last_run.json"),
            root.appendingPathComponent("mcp/servers.json"),
            root.appendingPathComponent("mcp/cache/tools.json"),
            root.appendingPathComponent("tools/active", isDirectory: true),
            root.appendingPathComponent("traces/events.jsonl"),
            root.appendingPathComponent("providers", isDirectory: true),
        ]
    }
}
