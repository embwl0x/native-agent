import Foundation
import MemoryV2
import NativeAgentShared
import Observation
import StandingBots
import Privacy
// Blueprint: | `CountsFeedProjection.swift` | `CountsFeedProjection`: off-main counts and availability assembly, comparison and feed publication |

public actor CountsFeedProjection {
    struct Input: Sendable {
        let proposals: [ProposalRecord]
        let proposalsLoaded: Bool
        let proposalsIssue: String?
        let helpers: [BotsShelfRecord]
        let runningHelpers: Set<UUID>
        let helpersLoaded: Bool
        let helpersIssue: String?
        let desk: WorkOverview?
        let deskIssue: String?
    }

    private let feed: FaceFeedSource
    private var value = CountsFace()
    private var sent: CountsFace?
    private var publication: Task<Void, Never>?

    public init(feed: FaceFeedSource) { self.feed = feed }

    public func updateInbox(_ inbox: InboxCountsFace) async {
        value.inbox = inbox
        await publish()
    }

    public func updateApprovals(_ approvals: ApprovalsFace) async {
        value.approvals = approvals
        await publish()
    }

    public func updateStatuses(_ statuses: CountStatusValues) async {
        value.statuses = statuses
        await publish()
    }

    public func updatePanels(_ panels: PanelFreshnessFace) async {
        value.panels = panels
        await publish()
    }

    func updateUnreadSessionIDs(_ ids: Set<String>) async {
        value.unreadSessionIDs = ids
        await publish()
    }

    func updateOwner(_ input: Input) async {
        value.memoryProposals = .init(value: input.proposalsLoaded ? input.proposals.filter { $0.status == "pending" }.count : nil,
                                     issue: input.proposalsIssue.map(NativeAppSecretRedactor.redactText))
        value.helpers = .init(value: input.helpersLoaded ? input.helpers.count : nil,
                              issue: input.helpersIssue.map(NativeAppSecretRedactor.redactText))
        value.runningHelpers = .init(value: input.helpersLoaded ? input.runningHelpers.count : nil,
                                     issue: input.helpersIssue.map(NativeAppSecretRedactor.redactText))
        let gaps = input.desk?.unavailable ?? []
        let deskIssue = input.deskIssue ?? (gaps.isEmpty ? nil : gaps.joined(separator: "\n"))
        value.deskWaiting = .init(value: input.desk?.needsYouCount, issue: deskIssue.map(NativeAppSecretRedactor.redactText))
        await publish()
    }

    private func publish() async {
        if let publication { await publication.value; return }
        guard sent != value else { return }
        let task = Task { await drain() }
        publication = task
        await task.value
    }

    private func drain() async {
        while sent != value {
            let finished = value
            sent = finished
            await feed.post(finished, at: .counts)
        }
        publication = nil
    }
}

/// Capture existing owner values briefly; counting and comparing belong to the projection actor.
@MainActor
final class CountSources {
    private enum Change: Sendable {
        case owners(CountsFeedProjection.Input)
        case unread(Set<String>)
    }
    private weak var engine: NativeAgentEngine?
    private var pending: CountsFeedProjection.Input?
    private var pendingUnread: Set<String>?
    private var drain: Task<Void, Never>?
    private var unreadObserver: NSObjectProtocol?

    init(engine: NativeAgentEngine) {
        self.engine = engine
        unreadObserver = NotificationCenter.default.addObserver(
            forName: MacChatUnreadSessions.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.captureUnread() }
        }
        captureUnread()
        capture()
    }

    isolated deinit {
        drain?.cancel()
        if let unreadObserver { NotificationCenter.default.removeObserver(unreadObserver) }
    }

    private func capture() {
        guard let engine else { return }
        let input = withObservationTracking {
            CountsFeedProjection.Input(
                proposals: engine.memory.proposals, proposalsLoaded: engine.memory.hasLoadedProposals,
                proposalsIssue: engine.memory.proposalsReadError,
                helpers: engine.contactThreads.helpers, runningHelpers: engine.contactThreads.running,
                helpersLoaded: engine.contactThreads.helpersLoaded, helpersIssue: engine.contactThreads.helpersRefreshError,
                desk: engine.desk.page.overview, deskIssue: engine.desk.liveUpdateError ?? engine.desk.page.deskUnavailable)
        } onChange: { [weak self] in
            Task { @MainActor in self?.capture() }
        }
        pending = input
        startDrain()
    }

    private func startDrain() {
        guard let engine else { return }
        guard drain == nil else { return }
        let projection = engine.countsFeed
        drain = Task.detached { [weak self] in
            while let change = await self?.take() {
                switch change {
                case .owners(let input): await projection.updateOwner(input)
                case .unread(let ids): await projection.updateUnreadSessionIDs(ids)
                }
            }
        }
    }

    private func captureUnread() {
        pendingUnread = MacChatUnreadSessions.shared.ids
        startDrain()
    }

    private func take() -> Change? {
        if let pending {
            self.pending = nil
            return .owners(pending)
        }
        if let pendingUnread {
            self.pendingUnread = nil
            return .unread(pendingUnread)
        }
        drain = nil
        return nil
    }
}
