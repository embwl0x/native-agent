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
    @Binding var navigationTarget: ActivitySection?
    /// A card a link elsewhere asked to open.
    @Binding var cardTarget: String?

    @State private var pushed: FaceDestination?

    init(
        navigationTarget: Binding<ActivitySection?> = .constant(nil),
        cardTarget: Binding<String?> = .constant(nil)
    ) {
        self._navigationTarget = navigationTarget
        self._cardTarget = cardTarget
    }

    /// Today as the Mac published it.
    private var today: PartFace? { sync.faces["today"]?.face }

    // MARK: - Body

    var body: some View {
        AlivePage(title: today?.title ?? "Today", line: today?.line) {
            MobileFaceRows(page: "today") { pushed = $0 }
        }
        .navigationDestination(item: $pushed) { $0.view }
        .refreshable {
            _ = await sync.refreshSnapshotGroup(.faces)
            await sync.refreshActivitySnapshot()
        }
        .task {
            _ = await sync.refreshSnapshotGroup(.faces)
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

    private func openRequestedSection(_ section: ActivitySection?) {
        guard section == .inbox else { return }
        pushed = .page("inbox")
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
                .init(id: "rem", title: "Growth proposals", open: "page:today/cognitionProposals"),
            ]),
        ]), error: nil, owed: false)
    #endif
}
