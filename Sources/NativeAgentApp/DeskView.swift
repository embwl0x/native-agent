import SwiftUI
import PersistenceCore
import WorkshopExecution

// MARK: - DeskView — User's read-only window into Agent's Workshop bench
//
// Agent captures + mutates the desk through chat tools (desk_*); this tab is the
// human-pleasant render of the same live state (SwiftNativeDeskStore.liveState())
// plus the Workshop execution lane, and a disclosure showing the exact compact
// projection she reads in-context. READ-ONLY by design: User glances, Agent
// maintains.
//
// Sectioned bench (User, 2026-07-11: "it just shows up like her regular desk did
// — make it into sections"). The Workshop absorbed Missions, so this surface
// now tells the bench's story top-to-bottom by urgency and ownership:
//   1. Waiting on you    — approval-blocked executions + blocked/flagged items
//   2. On the bench      — queued/running Workshop executions
//   3. Her pursuits      — origin=agent self-pursuits, in her own words
//   4. The board         — User/system items, family-grouped as before
//   5. Recently finished — terminal items + recent terminal executions

private struct DeskViewSnapshot: Sendable {
    let deskState: DeskState?
    let deskError: String?
    let executions: [WorkshopExecution.WorkshopExecutionRecord]
    let githubItems: [GitHubCommandItem]
}

struct DeskView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var items: [DeskItem] = []
    // One listAll() scan, sliced client-side — the runner's listActive/
    // listHistory whitelists would make an unknown/corrupt status (e.g. a
    // future "retrying") vanish from BOTH sections. Nothing on this surface
    // may disappear: unknown statuses render on the bench with their raw pill.
    @State private var allExecutions: [WorkshopExecution.WorkshopExecutionRecord] = []
    @State private var loadError: String?
    @State private var expandedRoots: Set<String> = []
    // W2b: the GitHub Command operational lane (workshop-github-command.md).
    @State private var githubItems: [GitHubCommandItem] = []

    private var dataRoot: URL { PersistenceCore.defaultDataRoot() }

    private var store: SwiftNativeDeskStore {
        SwiftNativeDeskStore(dataRoot: dataRoot)
    }

    // MARK: section slices

    private var activeItems: [DeskItem] { items.filter { !$0.status.isTerminal } }
    private var doneItems: [DeskItem] { items.filter { $0.status.isTerminal } }

    private var pursuitItems: [DeskItem] { activeItems.filter(\.isPursuit) }

    // Partition over activeItems (disjoint + exhaustive — no item may vanish):
    // pursuits claim first; watches and board both gate !isPursuit and board
    // negates the exact watch predicate, so pursuits ∪ watches ∪ board =
    // activeItems. Inside board, kind == .gh is the sole discriminator.
    private static func isWatchShaped(_ item: DeskItem) -> Bool {
        item.kind == .watch || item.status == .watch
    }
    private var watchItems: [DeskItem] {
        activeItems.filter { !$0.isPursuit && Self.isWatchShaped($0) }
    }
    private var boardItems: [DeskItem] {
        activeItems.filter { !$0.isPursuit && !Self.isWatchShaped($0) }
    }
    private var boardNonGhItems: [DeskItem] { boardItems.filter { $0.kind != .gh } }
    private var ghItems: [DeskItem] { boardItems.filter { $0.kind == .gh } }
    private var ghByProject: [(project: String, items: [DeskItem])] {
        Dictionary(grouping: ghItems, by: \.project)
            .map { (project: $0.key, items: $0.value) }
            .sorted { $0.project < $1.project }
    }

    // Blocked/flagged PURSUITS belong in the attention strip too (review
    // finding: filtering boardItems alone hid a blocked pursuit's reason).
    private var attentionItems: [DeskItem] {
        activeItems.filter { $0.status == .blocked || $0.status == .flag }
    }

    // The stamped reason GitHubProjectTracking writes on every checks/review-
    // blocked item; matched verbatim so hand-written reasons that merely
    // mention GitHub keep their own inline text.
    private static let githubStampedBlockedReason =
        "GitHub checks or review state are blocking progress."

    private var githubBlockedAttentionItems: [DeskItem] {
        attentionItems.filter {
            $0.status == .blocked && $0.blockedReason == Self.githubStampedBlockedReason
        }
    }

    private var nonGitHubAttentionItems: [DeskItem] {
        attentionItems.filter {
            !($0.status == .blocked && $0.blockedReason == Self.githubStampedBlockedReason)
        }
    }

    private static let terminalExecutionStatuses: Set<String> = ["completed", "failed", "cancelled"]

    /// Bench = queued/running PLUS any unknown non-terminal status, so a
    /// corrupt or future status stays visible instead of vanishing.
    private var benchExecutions: [WorkshopExecution.WorkshopExecutionRecord] {
        allExecutions.filter {
            $0.status != "blocked_on_approval" && !Self.terminalExecutionStatuses.contains($0.status)
        }
    }
    private var approvalExecutions: [WorkshopExecution.WorkshopExecutionRecord] {
        allExecutions.filter { $0.status == "blocked_on_approval" }
    }
    private var recentDoneExecutions: [WorkshopExecution.WorkshopExecutionRecord] {
        Array(allExecutions
            .filter { Self.terminalExecutionStatuses.contains($0.status) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(5))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerRow

                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(10)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                if items.isEmpty && allExecutions.isEmpty && githubItems.isEmpty && loadError == nil {
                    emptyState
                } else {
                    attentionSection
                    githubCommandSection
                    benchSection
                    pursuitsSection
                    watchesSection
                    boardSection
                    finishedSection
                }
                // B2.6 (g): debug disclosures (agent projection + raw all-items
                // table) moved to Diagnostics ▸ Cognition (DeskDebugPanels).
                // This surface keeps zero debug chrome.
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Workshop")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh the bench")
            }
        }
        .task {
            let reloader = DeskLiveReloader.shared
            reloader.setSceneActive(scenePhase == .active)
            reloader.activate(
                paths: [store.opsPath, GitHubCommandStore(dataRoot: dataRoot).opsPath]
            ) { await load() }
        }
        .onDisappear { DeskLiveReloader.shared.deactivate() }
        .onChange(of: scenePhase) { _, phase in
            DeskLiveReloader.shared.setSceneActive(phase == .active)
        }
    }

    // MARK: header

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("The Workshop").font(.title2.weight(.semibold))
                Text("\(appModel.agentDisplayName)'s bench — your tasks, the agent's pursuits, and what's on it right now")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text(headerCounts)
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var headerCounts: String {
        var parts: [String] = []
        if !benchExecutions.isEmpty { parts.append("\(benchExecutions.count) on the bench") }
        if !pursuitItems.isEmpty { parts.append("\(pursuitItems.count) pursuit\(pursuitItems.count == 1 ? "" : "s")") }
        parts.append("\(boardItems.count) on the board")
        if !watchItems.isEmpty { parts.append("\(watchItems.count) watching") }
        return parts.joined(separator: " · ")
    }

    private func sectionHeader(_ title: String, count: Int? = nil, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(count.map { "\(title)  ·  \($0)" } ?? title)
                .font(.headline).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "hammer").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("The bench is clear").font(.headline)
            Text("Tell \(appModel.agentDisplayName) \u{201C}keep track of\u{2026}\u{201D} or give the agent a task and it lands here. Self-pursuits appear once something earns repeated attention.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 44)
    }

    // MARK: section 1 — waiting on you (only when something actually is)
    //
    // A compact attention strip, not duplicate rows: blocked/flagged items keep
    // their full row (and family context) on the board below — this strip only
    // points at them, plus any execution parked on an approval.

    @ViewBuilder
    private var attentionSection: some View {
        if !attentionItems.isEmpty || !approvalExecutions.isEmpty || !needsUserGitHubItems.isEmpty {
            sectionHeader("Waiting on you", systemImage: "hand.raised")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(approvalExecutions, id: \.id) { exec in
                    attentionLine(
                        icon: "checkmark.shield",
                        text: "\u{201C}\(exec.title)\u{201D} needs an approval to continue"
                    )
                }
                // One-pointer rule (contract): a needs-User GitHub item gets ONE
                // pointer here; the canonical card lives in GitHub Command below.
                ForEach(needsUserGitHubItems, id: \.itemId) { item in
                    attentionLine(
                        icon: "arrow.triangle.pull",
                        text: "\(item.repository) #\(item.number) needs your call — see GitHub Command"
                    )
                }
                // Taste pass 2026-07-24: GitHub-blocked items all carry the
                // same stamped blockedReason ("GitHub checks or review state
                // are blocking progress.") — repeated per row it turned the
                // strip into wallpaper, and those items are waiting on GitHub,
                // not on User. Group them under one honest header; every other
                // item keeps its own reason inline.
                ForEach(nonGitHubAttentionItems, id: \.handle) { item in
                    attentionLine(
                        icon: item.status == .blocked ? "stop.circle" : "flag",
                        text: item.status == .blocked
                            ? "\(item.title)\(item.blockedReason.map { " — \($0)" } ?? "")"
                            : "\(item.title)\(item.waitingOn.map { " — waiting on \($0)" } ?? "")"
                    )
                }
                if !githubBlockedAttentionItems.isEmpty {
                    attentionLine(
                        icon: "stop.circle",
                        text: "Blocked on GitHub checks or review — these move when GitHub does:"
                    )
                    ForEach(githubBlockedAttentionItems, id: \.handle) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").font(.caption).foregroundStyle(.secondary)
                            Text(item.title).font(.callout).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 20)
                    }
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func attentionLine(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(.orange)
            Text(text).font(.callout).lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    // MARK: GitHub Command — the operational lane (W2b)
    //
    // Directly below Waiting on you, above the bench (contract position).
    // Organized by who has the next move; healthy/waiting PRs collapse.
    // Absent entirely when nothing is tracked — an empty lane is noise.

    private enum GHBucket: String, CaseIterable {
        case needsCodex = "Needs Codex"
        case codexWorking = "Codex working"
        case needsUser = "Needs you"
        case waiting = "Waiting upstream"
        case attention = "Attention"
        case resolved = "Recently resolved"
    }

    private func bucket(_ item: GitHubCommandItem) -> GHBucket {
        switch item.state {
        case .detected, .needsCodex: return .needsCodex
        case .codexWorking, .verifying: return .codexWorking
        case .needsUser: return .needsUser
        case .waitingUpstream: return .waiting
        case .attention: return .attention
        case .resolved: return .resolved
        }
    }

    private func ghBucketItems(_ bucket: GHBucket) -> [GitHubCommandItem] {
        let matching = githubItems.filter { self.bucket($0) == bucket }
        if bucket == .resolved {
            return Array(matching.sorted { $0.updatedAt > $1.updatedAt }.prefix(5))
        }
        return matching
    }

    private var needsUserGitHubItems: [GitHubCommandItem] { ghBucketItems(.needsUser) }

    @ViewBuilder
    private var githubCommandSection: some View {
        // Always visible (User, 2026-07-12: "this is just my window into
        // checking on what she's got with human eyes") — a monitoring surface
        // that hides itself when quiet reads as missing, not as quiet.
        sectionHeader("GitHub Command", systemImage: "arrow.triangle.pull")
        if githubItems.isEmpty {
            Text("No tracked GitHub work in the command lane yet — items appear on the next tracking refresh, and anything actionable routes to codex automatically.")
                .font(.callout).foregroundStyle(.tertiary)
                .padding(.leading, 4)
        } else {
            ghPortfolioStrip
            ForEach([GHBucket.needsCodex, .codexWorking, .needsUser, .attention], id: \.rawValue) { bucket in
                let rows = ghBucketItems(bucket)
                if !rows.isEmpty {
                    ghSubheader(bucket.rawValue, count: rows.count,
                                tinted: bucket == .attention || bucket == .needsUser)
                    ForEach(rows, id: \.itemId) { ghItemRow($0) }
                }
            }
            ghWaitingCollapsed
            let resolved = ghBucketItems(.resolved)
            if !resolved.isEmpty {
                ghSubheader(GHBucket.resolved.rawValue, count: resolved.count, tinted: false)
                ForEach(resolved, id: \.itemId) { ghItemRow($0) }
            }
        }
    }

    private var ghPortfolioStrip: some View {
        HStack(spacing: 10) {
            ForEach(GHBucket.allCases, id: \.rawValue) { bucket in
                let count = githubItems.filter { self.bucket($0) == bucket }.count
                if count > 0 {
                    Text("\(bucket.rawValue) \(count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(bucket == .attention ? Color.red
                                         : bucket == .needsUser ? .orange : .secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func ghSubheader(_ title: String, count: Int, tinted: Bool) -> some View {
        Text("\(title)  ·  \(count)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tinted ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .padding(.top, 2)
    }

    // Waiting upstream: grouped by kind, collapsed by default (contract).
    @ViewBuilder
    private var ghWaitingCollapsed: some View {
        let waiting = ghBucketItems(.waiting)
        if !waiting.isEmpty {
            let toggleKey = "ghwait"
            let expanded = expandedRoots.contains(toggleKey)
            HStack(spacing: 8) {
                Text("Waiting upstream")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(GitHubCommandWaitingKind.allCases, id: \.rawValue) { kind in
                    let n = waiting.filter {
                        if case .waitingUpstream(let k) = $0.state { return k == kind }
                        return false
                    }.count
                    if n > 0 {
                        Text("\(kind.rawValue.replacingOccurrences(of: "_", with: " ")) \(n)")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { toggle(toggleKey, expanded: expanded) }
            if expanded {
                ForEach(waiting, id: \.itemId) { ghItemRow($0) }
            }
        }
    }

    private func ghItemRow(_ item: GitHubCommandItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ghStatePill(item)
                Text(item.title.isEmpty ? "\(item.repository) #\(item.number)" : item.title)
                    .font(.body.weight(.medium)).lineLimit(2)
                Spacer(minLength: 4)
                Text(relativeTime(item.motorUpdatedAt ?? item.updatedAt))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Text("\(item.repository) #\(item.number) · \(item.kind == .pullRequest ? "PR" : "issue")")
                    .font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                if let blocker = item.blocker {
                    Text("\(blocker.detail) — \(blocker.owner)")
                        .font(.caption).foregroundStyle(.orange)
                        .lineLimit(1).truncationMode(.tail)
                } else if let receipt = item.finalReceipt, !receipt.isEmpty {
                    Text(receipt)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                } else if let last = item.workLog.last {
                    Text(last.summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.leading, 2)
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func ghStatePill(_ item: GitHubCommandItem) -> some View {
        let (label, color): (String, Color) = {
            switch item.state {
            case .detected, .needsCodex: return ("needs codex", .gray)
            case .codexWorking: return ("codex working", .blue)
            case .verifying: return ("verifying", .teal)
            case .needsUser: return ("needs you", .orange)
            case .waitingUpstream(let kind):
                return ("waiting · \(kind.rawValue.replacingOccurrences(of: "_", with: " "))", .gray)
            case .attention(let reason):
                switch reason {
                case .codexFailed: return ("codex no result", .red)
                case .verificationFailed: return ("GitHub still actionable", .red)
                case .callbackOverdue: return ("codex stalled", .red)
                case .codexBusy: return ("legacy codex retry", .red)
                default: return (reason.rawValue.replacingOccurrences(of: "_", with: " "), .red)
                }
            case .resolved: return ("resolved", .green)
            }
        }()
        return Text(label)
            .capsuleTag(color)
    }

    // MARK: section 2 — on the bench (live Workshop executions)

    @ViewBuilder
    private var benchSection: some View {
        sectionHeader("On the bench", count: benchExecutions.isEmpty ? nil : benchExecutions.count,
                      systemImage: "hammer")
        if benchExecutions.isEmpty {
            Text("Quiet right now — nothing running.")
                .font(.callout).foregroundStyle(.tertiary)
                .padding(.leading, 4)
        } else {
            ForEach(benchExecutions, id: \.id) { executionRow($0) }
        }
    }

    private func executionRow(_ exec: WorkshopExecution.WorkshopExecutionRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                executionPill(exec.status)
                Text(exec.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(relativeTime(exec.updatedAt))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if !exec.objective.isEmpty {
                Text(exec.objective)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.tail)
                    .padding(.leading, 2)
            }
            if exec.status == "running", !exec.plan.isEmpty {
                let done = exec.stepsCompleted.count
                Text("step \(min(done + 1, exec.plan.count)) of \(exec.plan.count)")
                    .font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
            if let verification = exec.verification,
               exec.status == "completed" || verification.status == .failed {
                Label(
                    verificationLabel(verification),
                    systemImage: verification.status == .satisfied
                        ? "checkmark.seal.fill"
                        : verification.status == .failed
                            ? "exclamationmark.triangle.fill"
                            : "questionmark.circle"
                )
                .font(.caption2.weight(.medium))
                .foregroundStyle(
                    verification.status == .satisfied
                        ? Color.green
                        : verification.status == .failed ? Color.red : Color.secondary
                )
                .padding(.leading, 2)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func verificationLabel(_ verification: WorkshopVerificationRecord) -> String {
        switch verification.status {
        case .satisfied:
            let methods = verification.methods.map {
                switch $0 {
                case "exact_output": return "exact output"
                case "file_bytes": return "file bytes"
                default: return $0.replacingOccurrences(of: "_", with: " ")
                }
            }.joined(separator: " + ")
            return methods.isEmpty ? "verified" : "verified: \(methods)"
        case .failed:
            return "verification failed"
        case .unverified:
            return "completed; outcome not independently verified"
        }
    }

    private func executionPill(_ status: String) -> some View {
        let (label, color): (String, Color) = switch status {
        case "running": ("running", .blue)
        case "queued": ("queued", .gray)
        case "blocked_on_approval": ("needs approval", .orange)
        case "completed": ("done", .green)
        case "failed": ("failed", .red)
        case "cancelled": ("cancelled", .gray)
        default: (status, .gray)
        }
        return Text(label)
            .capsuleTag(color)
    }

    // MARK: section 3 — her pursuits (volition surface, in her own words)

    @ViewBuilder
    private var pursuitsSection: some View {
        sectionHeader("Agent pursuits", count: pursuitItems.isEmpty ? nil : pursuitItems.count,
                      systemImage: "sparkles")
        if pursuitItems.isEmpty {
            Text("None yet. A pursuit opens only when the evidence holds — something has to earn the agent's attention more than once.")
                .font(.callout).foregroundStyle(.tertiary)
                .padding(.leading, 4)
        } else {
            ForEach(pursuitItems, id: \.handle) { pursuitCard($0) }
        }
    }

    @ViewBuilder
    private func pursuitCard(_ item: DeskItem) -> some View {
        if let pursuit = item.pursuit {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    statusPill(item.status)
                    Text(pursuit.privateName ?? item.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text("\(pursuit.reservations.count)/\(pursuit.maxSessions) sessions")
                        .font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                }
                Text("\u{201C}\(pursuit.why)\u{201D}")
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(3).truncationMode(.tail)
                if item.status == .blocked, let reason = item.blockedReason, !reason.isEmpty {
                    Label(reason, systemImage: "stop.circle")
                        .font(.caption).foregroundStyle(.red)
                        .lineLimit(2)
                } else if let waiting = item.waitingOn, !waiting.isEmpty {
                    Label("waiting on \(waiting)", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.orange)
                        .lineLimit(1)
                }
                HStack(spacing: 12) {
                    Label {
                        Text(pursuit.doneLooksLike).lineLimit(1).truncationMode(.tail)
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                    .font(.caption).foregroundStyle(.tertiary)
                    if let last = pursuit.lastWorkedAt {
                        Text("worked \(relativeTime(last))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.purple.opacity(0.15), lineWidth: 1)
            )
        }
    }

    // MARK: section 4 — waiting & watches (ambient, quieter than active work)

    @ViewBuilder
    private var watchesSection: some View {
        if !watchItems.isEmpty {
            sectionHeader("Waiting & watches", count: watchItems.count, systemImage: "binoculars")
            ForEach(groups(watchItems), id: \.key) { groupView($0, section: "watch") }
        }
    }

    // MARK: section 5 — the board (User/system items, family-grouped; gh collapsed)

    @ViewBuilder
    private var boardSection: some View {
        if !boardItems.isEmpty {
            sectionHeader("The board", count: boardItems.count, systemImage: "list.clipboard")
            ForEach(groups(boardNonGhItems), id: \.key) { groupView($0, section: "board") }
            // GitHub rows collapse to one summary per project — the numbered
            // PR inventory look dies here. The dedicated GitHub Command lane
            // (routing state machine) arrives with W1's store; this is only
            // the presentation collapse.
            ForEach(ghByProject, id: \.project) { group in
                ghProjectSummary(group)
            }
        }
    }

    @ViewBuilder
    private func ghProjectSummary(_ group: (project: String, items: [DeskItem])) -> some View {
        let toggleKey = "gh:\(group.project)"
        let expanded = expandedRoots.contains(toggleKey)
        // A collapsed summary must not hide status-critical facts (review
        // finding): count the children that need eyes and say so on the line.
        let needsEyes = group.items.filter {
            $0.status == .blocked || $0.status == .flag
                || ($0.waitingOn?.isEmpty == false)
        }.count
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.triangle.pull")
                .font(.caption).foregroundStyle(.secondary)
            Text("GitHub · \(group.project)")
                .font(.body.weight(.medium)).foregroundStyle(.secondary)
                .lineLimit(1)
            if needsEyes > 0 {
                Text("\(needsEyes) need\(needsEyes == 1 ? "s" : "") attention")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.14), in: Capsule())
            }
            Spacer(minLength: 4)
            Text("\(group.items.count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: Capsule())
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { toggle(toggleKey, expanded: expanded) }
        if expanded {
            ForEach(group.items, id: \.handle) { itemRow($0) }
        }
    }

    // MARK: section 6 — recently finished (items + executions)

    @ViewBuilder
    private var finishedSection: some View {
        if !doneItems.isEmpty || !recentDoneExecutions.isEmpty {
            sectionHeader("Recently finished",
                          count: doneItems.count + recentDoneExecutions.count,
                          systemImage: "checkmark.seal")
            ForEach(recentDoneExecutions, id: \.id) { executionRow($0) }
            ForEach(groups(doneItems), id: \.key) { groupView($0, section: "done") }
        }
    }

    // MARK: grouped rendering — one row per top-level number, click to expand
    //
    // User's read (2026-07-03): every `.x` sub-item rendered flat made the
    // board "too spread out" — 13 rows where 7 families live. The board now
    // shows one row per top-level number; clicking a family with sub-items
    // reveals them (badge + chevron say there's something to open). A family
    // whose top-level parent isn't in the same section (e.g. the root is
    // already done while sub-items stay active) collapses under a synthetic
    // header that borrows the parent's title from the full item list — the
    // spread came mostly from exactly these orphan families. A lone orphan
    // sub-item renders flat; one row is already compact.

    private struct DeskGroup {
        let key: String
        let root: DeskItem?
        let parentTitle: String?   // title of a root living elsewhere (e.g. done)
        let children: [DeskItem]
    }

    private func groups(_ list: [DeskItem]) -> [DeskGroup] {
        var order: [String] = []
        var roots: [String: DeskItem] = [:]
        var children: [String: [DeskItem]] = [:]
        for item in list {
            let key = item.alias.split(separator: ".").first.map(String.init) ?? item.alias
            if roots[key] == nil && children[key] == nil { order.append(key) }
            if item.alias.contains(".") || roots[key] != nil {
                // Dot-nested items are children; so is any duplicate depth-0
                // alias (should never happen, but a dict overwrite would hide
                // an item entirely — nothing on this board may vanish).
                children[key, default: []].append(item)
            } else {
                roots[key] = item
            }
        }
        return order.map { key in
            DeskGroup(
                key: key,
                root: roots[key],
                parentTitle: roots[key] == nil
                    ? items.first(where: { $0.alias == key })?.title
                    : nil,
                children: children[key] ?? []
            )
        }
    }

    private func toggle(_ toggleKey: String, expanded: Bool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expanded { expandedRoots.remove(toggleKey) }
            else { expandedRoots.insert(toggleKey) }
        }
    }

    @ViewBuilder
    private func groupView(_ group: DeskGroup, section: String) -> some View {
        let toggleKey = "\(section):\(group.key)"
        let expanded = expandedRoots.contains(toggleKey)
        if let root = group.root {
            itemRow(root, childCount: group.children.count, expanded: expanded)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !group.children.isEmpty else { return }
                    toggle(toggleKey, expanded: expanded)
                }
            if expanded {
                ForEach(group.children, id: \.handle) { itemRow($0) }
            }
        } else if group.children.count > 1 {
            orphanFamilyHeader(group, expanded: expanded)
                .contentShape(Rectangle())
                .onTapGesture { toggle(toggleKey, expanded: expanded) }
            if expanded {
                ForEach(group.children, id: \.handle) { itemRow($0) }
            }
        } else {
            ForEach(group.children, id: \.handle) { itemRow($0) }
        }
    }

    // Collapsible header for a family whose top-level parent isn't in this
    // section — a plain grouping handle, deliberately NOT styled like an item
    // row so it never reads as an item claiming a status.
    private func orphanFamilyHeader(_ group: DeskGroup, expanded: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(group.parentTitle ?? "Sub-items")
                .font(.body.weight(.medium)).foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(group.children.count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: Capsule())
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: one item row (indented by nesting depth)

    private func itemRow(_ item: DeskItem, childCount: Int = 0, expanded: Bool = false) -> some View {
        let depth = item.alias.filter { $0 == "." }.count
        let sub = subLine(item)
        // Readability pass (2026-07-02): the TITLE leads the row — it was
        // buried after alias/pill/kind·project, so scanning meant skipping
        // three metadata tokens per row. Kind·project demotes to the second
        // line, and the sub-line is bounded so long notes can't wall-of-text
        // the whole board.
        // De-numbered (cockpit v2): raw aliases live in the All-items debug
        // view now — the primary row leads with the title, ends with freshness.
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusPill(item.status)
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if item.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                Text(relativeTime(item.updatedAt))
                    .font(.caption2).foregroundStyle(.tertiary)
                if childCount > 0 {
                    Text("\(childCount)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            // Surface the KIND too (watch/plan/project/gh/standing) — the
            // status pill alone hides it, so a plan with default `watch`
            // status would read as a generic watch item. Origin appears only
            // when it isn't User's — the honest existing-field proxy for owner.
            Text(item.origin == .owner
                 ? "\(item.kind.rawValue) · \(item.project)"
                 : "\(item.kind.rawValue) · \(item.project) · \(item.origin.rawValue)")
                .font(.caption2.weight(.medium)).foregroundStyle(.tertiary)
                .padding(.leading, 2)
            if !sub.isEmpty {
                Text(sub)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .padding(.leading, 2)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(depth == 0 ? Color.primary.opacity(0.04) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .padding(.leading, CGFloat(depth) * 18)
    }

    private func subLine(_ item: DeskItem) -> String {
        var parts: [String] = []
        // Status-critical facts lead: the sub-line is capped at 3 rendered
        // lines, so if anything truncates it must be summary prose, never
        // the blocked reason or the waiting-on target.
        if item.status == .blocked, let r = item.blockedReason, !r.isEmpty { parts.append("blocked: \(r)") }
        if let waiting = item.waitingOn, !waiting.isEmpty { parts.append("waiting on \(waiting)") }
        if let s = item.summary, !s.isEmpty { parts.append(s) }
        if let last = item.notes.last { parts.append("note: \(last.text)") }
        if !item.refs.isEmpty { parts.append("\(item.refs.count) ref\(item.refs.count == 1 ? "" : "s")") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: status pill

    private func statusPill(_ status: DeskStatus) -> some View {
        Text(status.rawValue)
            .capsuleTag(statusColor(status))
    }

    private func statusColor(_ status: DeskStatus) -> Color {
        switch status {
        case .now: .blue
        case .next: .teal
        case .blocked: .red
        case .flag: .orange
        case .done: .green
        case .todo, .watch, .canceled: .gray
        }
    }

    // MARK: relative time

    private func relativeTime(_ iso: String) -> String {
        guard let date = Self.parseISO(iso) else { return "" }
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<90: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }

    private static func parseISO(_ raw: String) -> Date? {
        UserDisplayFormatters.parseISOTimestamp(raw)
    }

    // Desk debug disclosures (agent projection + raw all-items table) moved to
    // Diagnostics ▸ Cognition (DeskDebugPanels.swift) — B2.6 (g).

    // MARK: load

    @MainActor private func load() async {
        let root = dataRoot
        let snapshot = await Task.detached(priority: .userInitiated) {
            let deskState: DeskState?
            let deskError: String?
            do {
                deskState = try await SwiftNativeDeskStore(dataRoot: root).liveState()
                deskError = nil
            } catch {
                deskState = nil
                deskError = "Couldn't load the bench: \(error.localizedDescription)"
            }
            // Execution and GitHub reads stay lenient and independent: one
            // broken lane never blanks the other live Workshop projections.
            let executions = await SwiftNativeWorkshopRunner(root: root).listAll()
            let githubItems = (try? await GitHubCommandStore(
                dataRoot: root
            ).liveState().items) ?? []
            return DeskViewSnapshot(
                deskState: deskState,
                deskError: deskError,
                executions: executions,
                githubItems: githubItems
            )
        }.value
        guard !Task.isCancelled else { return }
        if let state = snapshot.deskState {
            items = state.items
            loadError = nil
        } else {
            loadError = snapshot.deskError
        }
        allExecutions = snapshot.executions
        githubItems = snapshot.githubItems
    }
}
