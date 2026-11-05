import SwiftUI
import NativeAgentShared

enum ActivitySection: String, CaseIterable, Hashable {
    /// Approvals and notes are one Inbox, as on the Mac.
    case inbox
    case memoryProposals
    case selfImprovement
}

enum ActivityScreenPresentation {
    /// Signed paired phones may decide owner cards; studio canon remains the agent's, as enforced by the Mac.
    static func canDecideRemotely(action: String) -> Bool {
        action != "studio.canon"
    }

    /// Consume notification suppression once so a cancelled appearance cannot suppress the next refresh.
    static func shouldRefreshOnAppear(skipInitialRefresh: inout Bool) -> Bool {
        guard skipInitialRefresh else { return true }
        skipInitialRefresh = false
        return false
    }

    /// Open the queue that can resolve the review request; the Activity summary cannot decide it.
    static func activityDestination(for notificationScreen: String) -> ActivitySection? {
        switch notificationScreen.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approvals", "inbox": return .inbox
        default: return nil
        }
    }
}

/// Retain inline decisions until the Mac removes the row: action replies and snapshots arrive independently, risking duplicate decisions.
enum InlineMemoryProposalDecisionPresentation {
    enum Decision: Equatable {
        case accept
        case reject
    }

    enum State: Equatable {
        case ready
        case deciding
        case awaitingPublication(Decision)
        case failed(String)

        var canDecide: Bool {
            switch self {
            case .ready, .failed: return true
            case .deciding, .awaitingPublication: return false
            }
        }

        var showsProgress: Bool {
            if case .deciding = self { return true }
            return false
        }

        var feedback: (message: String, isError: Bool)? {
            switch self {
            case .ready, .deciding:
                return nil
            case .awaitingPublication(.accept):
                return ("Accepted; waiting for the Mac/iCloud snapshot.", false)
            case .awaitingPublication(.reject):
                return ("Rejected; waiting for the Mac/iCloud snapshot.", false)
            case let .failed(message):
                return (message, true)
            }
        }
    }

    static func submitted(approve: Bool) -> State {
        .awaitingPublication(approve ? .accept : .reject)
    }
}


struct ActivityView: View {
    @StateObject private var memoryStore = MemoryStore()
    private let sync = iCloudSyncEngine.shared
    @Binding var skipInitialRefresh: Bool
    @Binding var navigationTarget: ActivitySection?
    /// A card a link elsewhere asked to open.
    @Binding var cardTarget: String?

    @State private var path = NavigationPath()

    init(
        skipInitialRefresh: Binding<Bool> = .constant(false),
        navigationTarget: Binding<ActivitySection?> = .constant(nil),
        cardTarget: Binding<String?> = .constant(nil)
    ) {
        self._skipInitialRefresh = skipInitialRefresh
        self._navigationTarget = navigationTarget
        self._cardTarget = cardTarget
    }

    // MARK: - Pending slices

    private var pendingMemoryProposals: [MemoryProposalRecord] {
        sync.memoryProposals.filter(\.isPending)
    }

    /// Today as the Mac published it.
    private var today: PartFace? { sync.faces["today"]?.face }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            AlivePage(title: today?.title ?? "Today", line: today?.line, style: .root) {
                MobileFaceRows(page: "today") { path.append($0) }
                if !pendingMemoryProposals.isEmpty {
                    AliveSection("Other reviews", surface: .waiting) {
                        ForEach(Array(pendingMemoryProposals.prefix(2).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { AliveDivider() }
                            InlineMemoryProposalPreviewCard(proposal: item, store: memoryStore)
                        }
                    }
                }
            }
            .macSyncErrorBanner()
            .navigationDestination(for: FaceDestination.self) { $0.view }
            .navigationDestination(for: ActivitySection.self) { section in
                // Destinations share Activity's NavigationStack; nesting another breaks navigation.
                switch section {
                case .inbox:
                    MobileFacePage(page: "inbox")
                case .memoryProposals:
                    MemoryView(embedInNavigationStack: false)
                case .selfImprovement:
                    AutonomyView()
                }
            }
            .refreshable {
                await sync.refreshActivitySnapshot()
            }
            .task {
                if !ActivityScreenPresentation.shouldRefreshOnAppear(skipInitialRefresh: &skipInitialRefresh) {
                    return
                }
                await sync.refreshActivitySnapshot()
            }
            .onChange(of: navigationTarget) { _, section in
                openRequestedSection(section)
            }
            .onChange(of: cardTarget, initial: true) { _, id in
                // A card is a matter in the Inbox; the face reads it in place, with no selected row.
                guard id != nil else { return }
                openRequestedSection(.inbox)
                cardTarget = nil
            }
            .onAppear {
                openRequestedSection(navigationTarget)
                openDesignSampleScreen()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-todaySample") { sync.faces["today"] = Self.sampleToday }
                #endif
            }
        }
    }

    private func openRequestedSection(_ section: ActivitySection?) {
        guard let section else { return }
        path = NavigationPath()
        path.append(section)
        navigationTarget = nil
    }

    /// DEBUG screenshot routing opens otherwise untappable simulator destinations.
    private func openDesignSampleScreen() {
        switch MobileDesignSamples.screen {
        case "approvals", "inbox", "inboxItem": openRequestedSection(.inbox)
        default: break
        }
    }

    #if DEBUG
    /// Process-local visual fixture: Today as the agent's ability writes it, with every section style it uses.
    static let sampleToday = PartFaceSnapshot(part: "today", version: nil, sourceEpoch: 1, status: .ready, face: PartFace(
        title: "Today", line: "A quiet morning so far; one thing waits on you.", sections: [
            .init(id: "waiting:0", title: "Waiting for you", style: .list, rows: [
                .init(id: "a1", title: "Add a calendar block", detail: "Tomorrow 9–11 AM, “Outline”", open: "approval:sample-approval"),
                .init(id: "desk", title: "2 Desk items are waiting on you", open: "page:desk"),
            ]),
            .init(id: "did", title: "What I did", style: .timeline, rows: [
                .init(id: "talked", title: "Talked about tomorrow's plan", detail: "Kept the afternoon open for a walk",
                      at: "2026-11-04T15:02:00Z", open: "chat:main"),
                .init(id: "kept", title: "Kept two memories", at: "2026-11-04T15:20:00Z"),
                .init(id: "detail:kept:0", title: "You prefer quiet mornings", tone: .quiet),
            ]),
            .init(id: "ahead", title: "Ahead", style: .flow, rows: [
                .init(id: "outline", title: "Outline at 9", open: "page:calendar"),
                .init(id: "walk", title: "Walk after lunch"),
            ]),
            .init(id: "earlier:0", title: "Earlier", style: .values, rows: [
                .init(id: "n1", title: "Notes from yesterday", value: "3", at: "2026-11-03T21:00:00Z", tone: .quiet),
            ]),
            .init(id: "queues", style: .flow, rows: [
                .init(id: "approvals", title: "Approvals and past decisions", open: "page:today/approvals"),
                .init(id: "inbox", title: "Every note I've left you", open: "page:today/inbox"),
                .init(id: "self-improvement", title: "Self-improvement", open: "page:today/selfImprovement"),
                .init(id: "rem", title: "REM Replay Lineage", open: "page:today/cognitionProposals"),
            ]),
        ]), error: nil, owed: false)
    #endif
}

// MARK: - Waiting rows

private struct ActivityWaitingRow<Actions: View>: View {
    let kind: String
    let title: String
    var detail: String? = nil
    var note: String? = nil
    var noteIsError = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            AliveWaitingDot()
            VStack(alignment: .leading, spacing: 5) {
                Text(kind)
                    .font(.caption)
                    .foregroundStyle(AlivePalette.secondary)
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AlivePalette.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(AlivePalette.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note, !note.isEmpty {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(noteIsError ? NativeAgentMobileTheme.Colors.trouble : AlivePalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions()
                    .padding(.top, 6)
            }
        }
        .aliveRow()
    }
}

private struct InlineMemoryProposalPreviewCard: View {
    let proposal: MemoryProposalRecord
    @ObservedObject var store: MemoryStore

    @State private var decisionState: InlineMemoryProposalDecisionPresentation.State = .ready

    var body: some View {
        ActivityWaitingRow(
            kind: "Worth remembering · \(proposal.evidenceSummary.lowercased())",
            title: proposal.displayText ?? proposal.text,
            note: decisionState.feedback?.message,
            noteIsError: decisionState.feedback?.isError ?? false
        ) {
            AliveActionRow {
                Button("Remember") { decide(approve: true) }
                    .alivePrimaryButton()
                    .disabled(!decisionState.canDecide)
                Button("Skip") { decide(approve: false) }
                    .aliveSecondaryButton()
                    .disabled(!decisionState.canDecide)
                if decisionState.showsProgress {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func decide(approve: Bool) {
        guard decisionState.canDecide else { return }
        decisionState = .deciding
        Task {
            do {
                guard let result = await store.performMemoryProposalDecision(proposal, approve: approve) else {
                    decisionState = .ready
                    return
                }
                try result.get()
                if approve {
                    SystemToastCenter.shared.push(success: "Memory accepted")
                } else {
                    SystemToastCenter.shared.push(info: "Memory rejected")
                }
                decisionState = InlineMemoryProposalDecisionPresentation.submitted(approve: approve)
                await iCloudSyncEngine.shared.refreshActivitySnapshot()
            } catch {
                if case SyncError.responseUnconfirmed = error {
                    decisionState = InlineMemoryProposalDecisionPresentation.submitted(approve: approve)
                    SystemToastCenter.shared.push(info: "Decision sent; still waiting on the Mac")
                    await iCloudSyncEngine.shared.refreshActivitySnapshot()
                } else {
                    decisionState = .failed("Failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
