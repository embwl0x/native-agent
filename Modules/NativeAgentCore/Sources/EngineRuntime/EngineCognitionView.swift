import Desk
import ApprovalInbox
import Foundation
import DreamREMCycle
import NativeAgentShared
import PersistenceCore
import TrustCenter
import Observation
import Cognition
import CognitiveSubstrate
import Context
import ContextFlow

/// Observable page state over this engine's canonical cognition runtime.
/// Reads retain core types; controls and Dream/REM keep their existing executors.
@MainActor
@Observable
public final class CognitionViewFacade {
    public nonisolated let dataRoot: URL
    public nonisolated let runtime: NativeCognitionRuntime?

    public var detail: CognitiveObservatoryDetail?
    public var detailEvidenceStatus: CognitiveObservatoryDetailRead.EvidenceStatus?
    public var contextFlowHealth: ContextFlowObservatoryHealthState = .unavailable
    public var workshop: WorkshopObservatorySnapshot?
    public var enabled = false
    public var capsuleEnabled = false
    public var backgroundEnabled = false
    public var reflectionEnabled = false
    public var organismEnabled = false
    public var reflectionBudget = 0
    public var lastRefresh: Date?
    public var proposalsDetail: CognitiveObservatoryDetail?
    public var subconsciousRuntime: NativeSubconsciousRuntimeState?
    public var reflectionRoute: NativeReflectionRouteStatus?
    public var livingSnapshot: LivingStatusSnapshot?
    public var livingRefreshStatus: PanelRefreshStatus?
    @ObservationIgnored private var refreshGate = LatestAsyncRequestGate()
    public private(set) var isRefreshing = false
    public var livingRefreshCoalescer = LivingStatusRefreshCoalescer()

    public nonisolated init(dataRoot: URL, runtime: NativeCognitionRuntime? = nil) {
        self.dataRoot = dataRoot
        self.runtime = runtime
    }

    public nonisolated func changes() async -> AsyncStream<NativeCognitionRuntimeChange> {
        guard let runtime else { return AsyncStream { $0.finish() } }
        return await runtime.changes()
    }

    public nonisolated func observatoryRead() async -> CognitiveObservatoryDetailRead? {
        await runtime?.observatoryDetailRead()
    }

    public nonisolated func pendingProposals() async -> CognitionProposalsFeed.Read {
        guard let standingViews = await runtime?.proposedStandingViews() else {
            return .unavailable("Cognition proposals are unavailable while cognition is off.")
        }
        return .available(.init(
            standingViews: standingViews
        ))
    }

    public func beginRefresh() -> UInt64 {
        isRefreshing = true
        return refreshGate.begin()
    }

    public func settleRefresh(_ generation: UInt64) -> Bool {
        guard refreshGate.accepts(generation) else { return false }
        isRefreshing = false
        return true
    }

    public func refreshProposals() async {
        proposalsDetail = await runtime?.observatoryDetail()
    }

    public func refreshVitals() async {
        subconsciousRuntime = await runtime?.subconsciousRuntimeState()
        reflectionRoute = await runtime?.reflectionRouteStatus()
    }

    public nonisolated func setDreamCycleEnabled(_ enabled: Bool) async throws -> TrustPolicy {
        try await TrustPolicyToolWriter.applyTrustPolicyPatch(
            body: [
                "personalityPolicy": ["dream_cycle_enabled": enabled],
                "trainingPolicy": ["dream_scheduler": enabled],
            ],
            dataRoot: dataRoot
        )
    }

    public nonisolated func setRemCycleEnabled(_ enabled: Bool) async throws -> TrustPolicy {
        try await TrustPolicyToolWriter.applyTrustPolicyPatch(
            body: ["trainingPolicy": ["rem_cycle_enabled": enabled]], dataRoot: dataRoot
        )
    }

    /// The app supplies its existing live owners; this facade publishes to the
    /// page's root. Enabling supplies a Context Flow default only when unset.
    public func setInnerLifeEnabled(
        _ enabled: Bool,
        runtime: NativeCognitionRuntime,
        contextFlow: NativeContextFlowRuntime
    ) async -> (state: NativeSubconsciousRuntimeState, contextFlowReady: Bool) {
        let budget = UserDefaults.standard.object(forKey: "cognitiveSubstrateDailyReflectionBudget") as? Int ?? 2
        let state = await runtime.setSubconsciousMasterEnabled(
            enabled,
            reflectionBudget: enabled ? max(1, budget) : 0
        )
        subconsciousRuntime = state
        await NativeCognitionRuntime.reloadStudioWanderInstallation()
        await refreshVitals()

        var contextFlowReady = true
        if enabled {
            let stored = UserDefaults.standard.string(
                forKey: NativeContextFlowConfiguration.modeDefaultsKey
            ).flatMap(ContextFlowMode.init(rawValue:))
            let preferred = stored ?? .active
            let status: NativeContextFlowModeStatus
            if stored == nil {
                status = await contextFlow.setMode(.active)
            } else {
                status = await contextFlow.modeStatus()
            }
            contextFlowReady = status.effectiveMode == preferred
        }
        return (state, contextFlowReady)
    }

    public nonisolated func organismSnapshot() async -> OrganismSnapshot? {
        await runtime?.organismSnapshot()
    }

    public nonisolated func towardRead() async -> OrganismTowardRead? {
        await runtime?.towardRead()
    }

    public nonisolated func moodWarmth() async -> Double {
        guard let reading = await runtime?.innerStateReading(
            windowHours: CognitiveInnerStateReading.defaultWindowHours, detail: .compact
        ), reading.available, !reading.feltNodes.isEmpty else { return 0 }
        let sum = reading.feltNodes.reduce(0.0) { $0 + $1.warmth }
        return min(1, max(0, sum / Double(reading.feltNodes.count)))
    }

    /// TrustCenter supplies policy; DreamREMCycle owns the composite gate arithmetic.
    public nonisolated func dreamGate() async -> DreamREMGatePolicy {
        let policy = await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicy()
        return Self.dreamGate(from: policy)
    }

    /// Manual REM changes persistent, approval-gated state. Unlike a passive
    /// compatibility read, its effect-time policy check must expose damaged
    /// authority bytes rather than turn a fail-closed projection into an
    /// apparently enabled REM cycle.
    public nonisolated func dreamGateChecked() async throws -> DreamREMGatePolicy {
        let policy = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicyChecked()
        return Self.dreamGate(from: policy)
    }

    /// A dream needs both the scheduler and personality-cycle gates.
    public nonisolated func dreamEnabled() async -> Bool {
        await dreamGate().dreamEnabled
    }

    nonisolated private static func dreamGate(from policy: [String: JSONValue]) -> DreamREMGatePolicy {
        func boolAt(_ section: String, _ key: String, default def: Bool) -> Bool {
            guard case .object(let sec)? = policy[section] else { return def }
            if case .bool(let b)? = sec[key] { return b }
            return def
        }
        // `policy` here is the NORMALIZED policy (loadTrustPolicy merges
        // defaultTrustPolicy), so these fallbacks only fire for keys the
        // shipped defaults do not carry. Keep them equal to TrustCenter+Defaults
        // anyway — a false here silently disagreed with the shipped `true`.
        return DreamREMGatePolicy(
            dreamScheduler: boolAt("trainingPolicy", "dream_scheduler", default: true),
            dreamCycleEnabled: boolAt("personalityPolicy", "dream_cycle_enabled", default: true),
            remCycleEnabled: boolAt("trainingPolicy", "rem_cycle_enabled", default: true)
        )
    }

    /// The file-backed diary, newest first, with its composite gate.
    public nonisolated func dreamDiary(limit: Int = 30) async throws -> DreamDiary {
        let diary = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: diary.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw DreamREMCycleError.underlying("dream_diary is not a directory")
        }
        let reader = FileBackedDreamDiary(dataRoot: dataRoot)
        let listing = reader.listEntriesChecked(limit: limit)
        guard !listing.storageUnreadable else {
            throw DreamREMCycleError.underlying("The dream diary or an archive directory could not be read.")
        }
        return DreamDiary(
            entries: listing.entries,
            enabled: await dreamEnabled(),
            totalEntries: listing.totalEntries,
            unreadableEntries: listing.unreadableEntries
        )
    }

    /// One night's entry; a missing one is the read route's not-found error.
    public nonisolated func dreamEntry(date: String) async throws -> DreamEntry {
        guard let entry = try FileBackedDreamDiary(dataRoot: dataRoot).getEntry(date) else {
            throw DaemonError.notFound("/v1/dream/\(date)")
        }
        return entry
    }
}

/// A bounded window of the dream diary.
public struct DreamDiary: Equatable, Sendable {
    public var entries: [DreamEntry] = []
    public var enabled = false
    /// Number of diary `.md` files before applying the caller's bounded window.
    public var totalEntries: Int?
    /// `.md` files in the bounded diary window that could not be decoded.
    public var unreadableEntries: Int?
    public init(entries: [DreamEntry] = [], enabled: Bool = false, totalEntries: Int? = nil, unreadableEntries: Int? = nil) {
        self.entries = entries
        self.enabled = enabled
        self.totalEntries = totalEntries
        self.unreadableEntries = unreadableEntries
    }

}

extension DreamEntry {
    /// The entry's text; a body-less entry reads as empty.
    public var text: String { content ?? "" }
}

/// The durable inputs read by `LivingStatusPanel` that can change outside this
/// process. This is deliberately a small, consumer-owned list: watching a
/// producer that the panel does not read creates a reassuring refresh signal
/// without changing the displayed state.
public enum LivingStatusFileWatch {
    public enum Availability: Equatable, Sendable {
        case watching(inputCount: Int)
        case unavailable(String)
    }

    public static func watchedPaths(dataRoot: URL) -> [URL] {
        let desk = SwiftNativeDeskStore(dataRoot: dataRoot)
        return [
            // The process-local cognition stream covers in-process changes;
            // this file covers another process replacing the persisted state.
            dataRoot.appendingPathComponent("cognition/organism_state.json"),
            // `liveState()` reconstructs from both the append-only feed and
            // its compaction base. A Desk commit can update either.
            desk.opsPath,
            desk.basePath,
            dataRoot.appendingPathComponent("workflows/approvals/requests.json"),
            // The Desk overview also counts actionable inbox rows as needs you.
            dataRoot.appendingPathComponent("notifications/inbox.jsonl"),
            // Dream reads choose the newest dated entry, so the directory—not
            // a guessed filename—is the canonical invalidation boundary.
            dataRoot.appendingPathComponent("dream_diary", isDirectory: true),
        ]
    }

    /// FileChangeWatcher can follow missing targets through a parent vnode, but
    /// it cannot observe a parent that is a regular file or cannot be created.
    /// Make that arming boundary observable rather than leaving the card with
    /// a successful initial read and no future invalidations.
    public static func availability(dataRoot: URL) -> Availability {
        let paths = watchedPaths(dataRoot: dataRoot)
        // Deterministic order: Set iteration follows the per-process hash seed,
        // so an unwatchable root could report a different (order-dependent)
        // unavailable reason from run to run. Sorted, the shallowest parent —
        // the data root itself — is always diagnosed first.
        let parents = Set(paths.map { $0.deletingLastPathComponent().standardizedFileURL })
            .sorted { $0.path < $1.path }
        for parent in parents {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else {
                    return .unavailable("a status storage folder is not a directory")
                }
            } else {
                do {
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                } catch {
                    return .unavailable("a status storage folder could not be prepared")
                }
            }
        }
        return .watching(inputCount: paths.count)
    }
}

extension CognitionViewFacade {
    public func refreshLivingStatus(
        desk: DeskFacade,
        approvals: ApprovalsFacade,
        agentDisplayName: @MainActor () -> String,
        dreamErrorDidChange: @MainActor (String?) -> Void
    ) async {
        guard livingRefreshCoalescer.requestRefresh() else { return }
        while true {
            let outcome = await readLivingStatus(desk: desk, approvals: approvals,
                agentDisplayName: agentDisplayName, dreamErrorDidChange: dreamErrorDidChange)
            livingSnapshot = outcome.snapshot ?? livingSnapshot
            let now = Date()
            livingRefreshStatus = PanelRefreshStatus(
                lastAttemptAt: now,
                lastSuccessAt: outcome.failedEndpoints.isEmpty ? now : livingRefreshStatus?.lastSuccessAt,
                failedEndpoints: outcome.failedEndpoints
            )
            guard !Task.isCancelled else {
                livingRefreshCoalescer.cancel()
                return
            }
            guard livingRefreshCoalescer.completePass() else { return }
            if !livingRefreshCoalescer.trailingPassConsumed {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    livingRefreshCoalescer.cancel()
                    return
                }
            }
        }
    }

    private func readLivingStatus(
        desk: DeskFacade,
        approvals: ApprovalsFacade,
        agentDisplayName: @MainActor () -> String,
        dreamErrorDidChange: @MainActor (String?) -> Void
    ) async -> (snapshot: LivingStatusSnapshot?, failedEndpoints: [String]) {
        guard let organism = await organismSnapshot() else {
            return (nil, ["Cognition"])
        }
        var failedEndpoints: [String] = []
        // The Desk's own overview: its Needs you is the one "needs User".
        let board = await desk.loadBoard(includeOverview: true)
        let overview = board.overview!
        if !overview.unavailable.isEmpty { failedEndpoints.append("Desk") }
        let activeDeskCount = board.items.filter { !$0.status.isTerminal }.count
        let blockedDeskCount = board.items.filter { $0.status == .blocked }.count

        dreamErrorDidChange(nil)
        let dreamDiary: DreamDiary?
        do {
            dreamDiary = try await self.dreamDiary(limit: 1)
        } catch {
            dreamDiary = nil
            dreamErrorDidChange(UserFacingError.message(error, action: "load the dream diary"))
            failedEndpoints.append("Dream diary")
        }
        let latestDream = dreamDiary?.entries.first

        let approvalRows: [ApprovalRecord]
        do {
            approvalRows = try await approvals.list()
        } catch {
            approvalRows = []
            failedEndpoints.append("Approvals")
        }

        guard failedEndpoints.isEmpty else {
            return (nil, failedEndpoints)
        }
        return (
            snapshot: LivingStatusSnapshot.make(
                organism: organism,
                activeDeskCount: activeDeskCount,
                blockedDeskCount: blockedDeskCount,
                ownerWaiting: overview.needsYouCount,
                pendingApprovals: approvalRows.filter { OwnerAttentionPolicy.approvalWaits(status: $0.status, agentOwned: $0.isAgentsOwnDecision) }.count,
                latestDream: latestDream,
                agentDisplayName: agentDisplayName()
            ),
            failedEndpoints: []
        )
    }
}

extension CognitionViewFacade {
    public func refreshObservatory(
        includeWorkshopReceipts: () -> Bool,
        contextFlowHealthRead: () async -> ContextFlowObservatoryHealthState
    ) async {
        let refreshGeneration = beginRefresh()
        guard let nextRead = await observatoryRead() else {
            _ = settleRefresh(refreshGeneration)
            return
        }
        let next = nextRead.detail
        let nextContextFlowHealth = await contextFlowHealthRead()
        let deskRoot = dataRoot
        let nextWorkshop = await WorkshopObservatorySnapshot.load(
            store: SwiftNativeDeskStore(dataRoot: deskRoot),
            receiptsPath: deskRoot
                .appendingPathComponent("workshop", isDirectory: true)
                .appendingPathComponent("receipts.jsonl"),
            includeReceipts: includeWorkshopReceipts()
        )
        guard !Task.isCancelled, settleRefresh(refreshGeneration) else { return }
        detail = next
        detailEvidenceStatus = nextRead.evidenceStatus
        if contextFlowHealth != nextContextFlowHealth { contextFlowHealth = nextContextFlowHealth }
        if workshop != nextWorkshop { workshop = nextWorkshop }
        enabled = next.configuration.enabled
        capsuleEnabled = next.configuration.capsuleInjectionEnabled
        backgroundEnabled = next.configuration.backgroundMicrocyclesEnabled
        reflectionEnabled = next.configuration.reflectiveCallsEnabled
        organismEnabled = next.organism.enabled
        reflectionBudget = next.configuration.dailyReflectionCallBudget
        lastRefresh = Date()
    }
}
