import Foundation
import MindCore
import NativeAgentShared
import Observation
import PersistenceCore
// Blueprint: | `CountsFeedProjection.swift` | `CountsFeedProjection`: off-main counts and availability assembly, comparison and feed publication |

public actor CountsFeedProjection {
    struct Input: Sendable {
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

    func updateOwner(_ input: Input) async {
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
    private weak var engine: NativeAgentEngine?
    private var pending: CountsFeedProjection.Input?
    private var drain: Task<Void, Never>?
    private var ownerChanges: Task<Void, Never>?

    init(engine: NativeAgentEngine) {
        self.engine = engine
        observe(engine)
    }

    isolated deinit {
        ownerChanges?.cancel()
        drain?.cancel()
    }

    private func observe(_ engine: NativeAgentEngine) {
        let changes = Observations { [desk = engine.desk] in
            CountsFeedProjection.Input(
                desk: desk.page.overview, deskIssue: desk.liveUpdateError ?? desk.page.deskUnavailable)
        }
        ownerChanges = Task { [weak self] in
            for await input in changes {
                guard !Task.isCancelled, let self else { return }
                pending = input
                startDrain()
            }
        }
    }

    private func startDrain() {
        guard let engine else { return }
        guard drain == nil else { return }
        let projection = engine.countsFeed
        drain = Task.detached { [weak self] in
            while let input = await self?.take() {
                await projection.updateOwner(input)
            }
        }
    }

    private func take() -> CountsFeedProjection.Input? {
        if let pending {
            self.pending = nil
            return pending
        }
        drain = nil
        return nil
    }
}
