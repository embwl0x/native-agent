import Foundation
import Experiences
import NativeAgentShared
import PersistenceCore
import ApprovalInbox
import Desk
// Blueprint: | `DiagnosticsLivingStatus.swift` | `LivingStatusOwner`: actor-owned living reading, coalescing and launch-scoped source/face subscriptions |

extension NativeAgentEngine {
    public func refreshDiagnosticsLivingStatus() async {
        await cognitionView.livingStatus.refresh(view: cognitionView, desk: desk, agentDisplayName: { await self.persona.displayName })
    }

    func observeDiagnosticsLivingStatus() async {
        async let files: Void = LivingStatusFileWatch.observe(dataRoot: dataRoot, availabilityDidChange: { [self] in
            await cognitionView.livingStatus.watchAvailability($0)
        }, refresh: { [self] in await refreshDiagnosticsLivingStatus() })
        async let matters: Void = observeLivingStatusMatters()
        async let faces: Void = observeLivingStatusFace()
        let changes = await cognitionView.changes()
        // Subscribe before the first read; process-local changes remain buffered while the read suspends.
        await refreshDiagnosticsLivingStatus()
        await pages.refresh(page: "diagnostics")
        for await _ in changes {
            guard !Task.isCancelled else { return }
            await refreshDiagnosticsLivingStatus()
        }
        await files
        await matters
        await faces
    }

    private func observeLivingStatusFace() async {
        for await _ in await cognitionView.livingStatus.changes() {
            guard !Task.isCancelled else { return }
            await pages.refresh(page: "diagnostics")
        }
    }

    private func observeLivingStatusMatters() async {
        for await _ in await ForPerson.at(dataRoot).changes() {
            guard !Task.isCancelled else { return }
            await refreshDiagnosticsLivingStatus()
        }
    }
}

extension LivingStatusFileWatch {
    @concurrent static func observe(
        dataRoot: URL,
        availabilityDidChange: @escaping @Sendable (Availability) async -> Void,
        refresh: @escaping @Sendable () async -> Void
    ) async {
        let paths = watchedPaths(dataRoot: dataRoot)
        let events = FileChangeEvents(paths: paths, emitInitial: false)
        defer { events.cancel() }
        let armed = await events.waitUntilArmed()
        guard !Task.isCancelled else { return }
        let unavailable = Availability.unavailable("status files could not be observed")
        await availabilityDidChange(armed ? .watching(inputCount: paths.count) : unavailable)
        await refresh()
        guard armed, !Task.isCancelled else { return }
        for await _ in events.stream {
            guard !Task.isCancelled else { break }
            await refresh()
        }
        if !Task.isCancelled { await availabilityDidChange(unavailable) }
    }
}

/// Living status keeps its reading and invalidation coalescing with the engine, independently of the window.
public actor LivingStatusOwner {
    public struct Reading: Equatable, Sendable {
        public var livingSnapshot: LivingStatusSnapshot?
        public var livingRefreshStatus: PanelRefreshStatus?
        public var livingWatchAvailability: LivingStatusFileWatch.Availability?
    }

    public private(set) var reading = Reading()
    private let latest = LatestRead()
    private var coalescer = LivingStatusRefreshCoalescer()
    private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init() {}

    isolated deinit { for listener in listeners.values { listener.finish() } }

    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        listeners[id] = continuation
        continuation.yield()
        continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        return stream
    }

    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }
    private func changed() { for listener in listeners.values { listener.yield() } }

    public func watchAvailability(_ availability: LivingStatusFileWatch.Availability) {
        guard reading.livingWatchAvailability != availability else { return }
        reading.livingWatchAvailability = availability
        changed()
    }

    public func refresh(view: CognitionViewFacade, desk: DeskFacade, agentDisplayName: @Sendable () async -> String) async {
        guard coalescer.requestRefresh() else { return }
        repeat {
            _ = await latest.read({ await read(view: view, desk: desk, agentDisplayName: agentDisplayName) }, publish: { outcome in
                if let snapshot = outcome.snapshot { reading.livingSnapshot = snapshot }
                let now = Date()
                reading.livingRefreshStatus = PanelRefreshStatus(lastAttemptAt: now,
                    lastSuccessAt: outcome.failed.isEmpty ? now : reading.livingRefreshStatus?.lastSuccessAt, failedEndpoints: outcome.failed)
                changed()
            })
            guard !Task.isCancelled else { coalescer.cancel(); return }
        } while coalescer.completePass()
    }

    private func read(view: CognitionViewFacade, desk: DeskFacade, agentDisplayName: @Sendable () async -> String) async
        -> (snapshot: LivingStatusSnapshot?, failed: [String]) {
        guard let organism = await view.organismSnapshot() else { return (nil, ["Cognition"]) }
        let board = await desk.loadBoard()
        guard let overview = board.overview else { return (nil, ["Desk"]) }
        var failed = overview.unavailable.isEmpty ? [] : ["Desk"]
        let diary: DreamDiary?
        do { diary = try await view.dreamDiary(limit: 1) }
        catch { diary = nil; failed.append("Dream diary: " + error.localizedDescription) }
        let approvals: [ApprovalRecord]?
        do { approvals = try board.approvals.get() }
        catch { approvals = nil; failed.append("Approvals: " + error.localizedDescription) }
        guard failed.isEmpty, let diary, let approvals else { return (nil, failed) }
        return (LivingStatusSnapshot.make(organism: organism,
            activeDeskCount: board.items.filter { !$0.status.isTerminal }.count,
            blockedDeskCount: board.items.filter { $0.status == .blocked }.count,
            ownerWaiting: overview.needsYouCount,
            pendingApprovals: approvals.filter { OwnerAttentionPolicy.approvalWaits(status: $0.status, agentOwned: $0.isAgentsOwnDecision) }.count,
            latestDream: diary.entries.first, agentDisplayName: await agentDisplayName()), [])
    }
}
