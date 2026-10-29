import Desk
import ApprovalInbox
import Foundation
import NativeAgentCore
import DreamREMCycle
import NativeAgentShared
import PersistenceCore
import TrustCenter
import Observation
import Cognition
import CognitiveSubstrate
import Context
import ContextFlow
import TurnTrace
// Blueprint: | `EngineCognitionView.swift` | `CognitionViewFacade`: checked diary/gate revision and file invalidation shared by Dreams, Settings and search; root-scoped model-call readout/refresh; `LatestRead` owns observatory, proposals, vitals, model-call and Living Status publication; watched paths and coalesced refresh coordination; `DreamDiary`: `FileBackedDreamDiary` rows |

/// Observable page state over this engine's canonical cognition runtime.
/// Reads retain core types; controls and Dream/REM keep their existing executors.
@MainActor
@Observable
public final class CognitionViewFacade {
    public nonisolated let dataRoot: URL
    public nonisolated let runtime: NativeCognitionRuntime?

    public var detail: CognitiveObservatoryDetail?
    public var contextFlowHealth: ContextFlowObservatoryHealthState = .unavailable
    public var workshop: WorkshopObservatorySnapshot?
    public var lastRefresh: Date?
    public var subconsciousRuntime: NativeSubconsciousRuntimeState?
    public var reflectionRoute: NativeReflectionRouteStatus?
    public private(set) var modelCalls = ""
    public private(set) var diary: DreamDiary?
    public private(set) var diaryGate: DreamREMGatePolicy?
    public private(set) var diaryError: String?
    public var diaryLoading: Bool { pendingDiaryReads > 0 }
    private var pendingDiaryReads = 0
    @ObservationIgnored private var diaryLimit = 60
    @ObservationIgnored private let diaryRead = LatestRead()
    @ObservationIgnored private var diaryWatch: FileChangeWatcher?

    public var livingSnapshot: LivingStatusSnapshot?
    public var livingRefreshStatus: PanelRefreshStatus?
    @ObservationIgnored private let observatoryLatest = LatestRead()
    @ObservationIgnored private let detailRead = LatestRead()
    @ObservationIgnored private let vitalsRead = LatestRead()
    @ObservationIgnored private let modelCallsRead = LatestRead()
    @ObservationIgnored private let livingRead = LatestRead()
    private var pendingObservatoryReads = 0
    public var isRefreshing: Bool { pendingObservatoryReads > 0 }
    public var livingRefreshCoalescer = LivingStatusRefreshCoalescer()

    public nonisolated init(dataRoot: URL, runtime: NativeCognitionRuntime? = nil) {
        self.dataRoot = dataRoot
        self.runtime = runtime
    }

    public nonisolated func changes() async -> AsyncStream<NativeCognitionRuntimeChange> {
        guard let runtime else { return AsyncStream { $0.finish() } }
        return await runtime.changes()
    }

    public func refreshDetail() async {
        _ = await detailRead.read({ await runtime?.observatoryDetail() }, publish: { read in
            guard let read else { return }
            detail = read
            lastRefresh = Date()
        })
    }

    public func refreshVitals() async {
        _ = await vitalsRead.read({
            let subconscious = await runtime?.subconsciousRuntimeState()
            let route = await runtime?.reflectionRouteStatus()
            return (subconscious, route)
        }, publish: { subconsciousRuntime = $0.0; reflectionRoute = $0.1 })
    }

    public func refreshModelCalls() async {
        _ = await modelCallsRead.read({
            let firstOutputs = await runtime?.providerFirstOutputs() ?? "First outputs: cognition is not running."
            do { return firstOutputs + "\n\n" + (try await TurnTraceRecentReader(dataRootOverride: dataRoot).modelCalls().serialize(pretty: true)) }
            catch { return UserFacingError.cause(error, action: "read model calls") }
        }, publish: { modelCalls = $0 })
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
        DreamREMGatePolicy(authority: .read(dataRoot: dataRoot))
    }

    /// Manual REM changes persistent, approval-gated state. Unlike a passive
    /// compatibility read, its effect-time policy check must expose damaged
    /// authority bytes rather than turn a fail-closed projection into an
    /// apparently enabled REM cycle.
    public nonisolated func dreamGateChecked() async throws -> DreamREMGatePolicy {
        let policy = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicyChecked()
        return DreamREMGatePolicy(authority: .present(policy))
    }

    /// A dream needs both the scheduler and personality-cycle gates.
    public nonisolated func dreamEnabled() async -> Bool {
        await dreamGate().dreamEnabled
    }

    /// The file-backed diary, newest first, with its composite gate.
    public func dreamDiary(limit: Int = 30) async throws -> DreamDiary {
        diaryLimit = max(diaryLimit, limit)
        if diaryWatch == nil {
            diaryWatch = FileChangeWatcher(paths: [
                dataRoot.appendingPathComponent("dream_diary", isDirectory: true),
                SavedTrustPolicyAuthority.policyURL(dataRoot: dataRoot)
            ]) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshDiary() }
            }
        }
        pendingDiaryReads += 1
        defer { pendingDiaryReads -= 1 }
        let read: (DreamREMGatePolicy?, Result<DreamDiary, Error>) = await diaryRead.read({
            var gate: DreamREMGatePolicy?
            do {
                let checked = try await dreamGateChecked()
                gate = checked
                return (gate, .success(try await readDreamDiary(limit: diaryLimit, enabled: checked.dreamEnabled)))
            } catch { return (gate, .failure(error)) }
        }, publish: { gate, result in
            diaryGate = gate
            switch result {
            case .success(let next):
                diary = next
                diaryError = nil
            case .failure(let error):
                diaryError = UserFacingError.message(error, action: "load the dream diary")
            }
        })
        let next = try read.1.get()
        return DreamDiary(entries: Array(next.entries.prefix(max(1, limit))), enabled: next.enabled,
                          totalEntries: next.totalEntries, unreadableEntries: next.unreadableEntries)
    }

    public func refreshDiary(limit: Int = 60) async {
        do { _ = try await dreamDiary(limit: limit) } catch { /* Published by the owner. */ }
    }

    private nonisolated func readDreamDiary(limit: Int, enabled: Bool) async throws -> DreamDiary {
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
            enabled: enabled,
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

}

extension CognitionViewFacade {
    public func refreshLivingStatus(
        desk: DeskFacade,
        agentDisplayName: @MainActor () -> String,
        dreamErrorDidChange: @MainActor (String?) -> Void
    ) async {
        guard livingRefreshCoalescer.requestRefresh() else { return }
        while true {
            _ = await livingRead.read({
                await readLivingStatus(desk: desk,
                    agentDisplayName: agentDisplayName)
            }, publish: { outcome in
            if outcome.checkedDream { dreamErrorDidChange(outcome.dreamError) }
            livingSnapshot = outcome.snapshot ?? livingSnapshot
            let now = Date()
            livingRefreshStatus = PanelRefreshStatus(
                lastAttemptAt: now,
                lastSuccessAt: outcome.failedEndpoints.isEmpty ? now : livingRefreshStatus?.lastSuccessAt,
                failedEndpoints: outcome.failedEndpoints
            )
            })
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
        agentDisplayName: @MainActor () -> String
    ) async -> (snapshot: LivingStatusSnapshot?, failedEndpoints: [String], checkedDream: Bool, dreamError: String?) {
        guard let organism = await organismSnapshot() else {
            return (nil, ["Cognition"], false, nil)
        }
        var failedEndpoints: [String] = []
        // The Desk's own overview: its Needs you is the one "needs User".
        let board = await desk.loadBoard()
        guard let overview = board.overview else { return (nil, ["Desk"], false, nil) }
        if !overview.unavailable.isEmpty { failedEndpoints.append("Desk") }
        let activeDeskCount = board.items.filter { !$0.status.isTerminal }.count
        let blockedDeskCount = board.items.filter { $0.status == .blocked }.count

        var dreamError: String?
        let dreamDiary: DreamDiary?
        do {
            dreamDiary = try await self.dreamDiary(limit: 1)
        } catch {
            dreamDiary = nil
            dreamError = UserFacingError.message(error, action: "load the dream diary")
            failedEndpoints.append("Dream diary")
        }
        let latestDream = dreamDiary?.entries.first

        let approvalRows: [ApprovalRecord]
        do {
            approvalRows = try board.approvals.get()
        } catch {
            approvalRows = []
            failedEndpoints.append("Approvals")
        }

        guard failedEndpoints.isEmpty else {
            return (nil, failedEndpoints, true, dreamError)
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
            failedEndpoints: [], checkedDream: true, dreamError: dreamError
        )
    }
}

extension CognitionViewFacade {
    public func refreshObservatory(
        includeWorkshopReceipts: () -> Bool,
        contextFlowHealthRead: () async -> ContextFlowObservatoryHealthState
    ) async {
        pendingObservatoryReads += 1
        defer { pendingObservatoryReads -= 1 }
        guard runtime != nil else { return }
        await refreshDetail()
        _ = await observatoryLatest.read({
        let nextContextFlowHealth = await contextFlowHealthRead()
        let deskRoot = dataRoot
        let nextWorkshop = await WorkshopObservatorySnapshot.load(
            store: SwiftNativeDeskStore(dataRoot: deskRoot),
            receiptsPath: deskRoot
                .appendingPathComponent("workshop", isDirectory: true)
                .appendingPathComponent("receipts.jsonl"),
            includeReceipts: includeWorkshopReceipts()
        )
        return (nextContextFlowHealth, nextWorkshop)
        }, publish: { nextContextFlowHealth, nextWorkshop in
        if contextFlowHealth != nextContextFlowHealth { contextFlowHealth = nextContextFlowHealth }
        if workshop != nextWorkshop { workshop = nextWorkshop }
        })
    }
}
