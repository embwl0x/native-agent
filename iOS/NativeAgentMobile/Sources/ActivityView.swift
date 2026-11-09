import SwiftUI
import NativeAgentShared

enum ActivitySection: String, CaseIterable, Hashable {
    /// Approvals and notes are one Inbox, as on the Mac.
    case inbox
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

struct ActivityView: View {
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

    /// Today as the Mac published it.
    private var today: PartFace? { sync.faces["today"]?.face }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            AlivePage(title: today?.title ?? "Today", line: today?.line, style: .root) {
                MobileFaceRows(page: "today") { path.append($0) }
            }
            .macSyncErrorBanner()
            .navigationDestination(for: FaceDestination.self) { $0.view }
            .navigationDestination(for: ActivitySection.self) { section in
                // Destinations share Activity's NavigationStack; nesting another breaks navigation.
                switch section {
                case .inbox:
                    MobileFacePage(page: "inbox")
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
                .init(id: "rem", title: "REM Replay Lineage", open: "page:today/cognitionProposals"),
            ]),
        ]), error: nil, owed: false)
    #endif
}
