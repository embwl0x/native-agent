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
// Blueprint: | `EngineCognitionView.swift` | Cognition controls, checked diary and observatory reads; living status belongs to LivingStatusOwner |

/// Keep canonical cognition types and executors across page reads and controls.
@MainActor
@Observable
public final class CognitionViewFacade {
    public nonisolated let dataRoot: URL
    public nonisolated let runtime: NativeCognitionRuntime?

    public var detail: CognitiveObservatoryDetail?
    public var contextFlowHealth: ContextFlowObservatoryHealthState = .unavailable
    public private(set) var contextFlowHealthCheckedAt: Date?
    public var lastRefresh: Date?
    public var subconsciousRuntime: NativeSubconsciousRuntimeState?
    public var reflectionRoute: NativeReflectionRouteStatus?
    public private(set) var diary: DreamDiary?
    public private(set) var diaryGate: DreamREMGatePolicy?
    public private(set) var diaryError: String?
    public var diaryLoading: Bool { pendingDiaryReads > 0 }
    private var pendingDiaryReads = 0
    @ObservationIgnored private var diaryLimit = 60
    @ObservationIgnored private let diaryRead = LatestRead()
    @ObservationIgnored private var diaryWatch: FileChangeWatcher?

    public nonisolated let livingStatus = LivingStatusOwner()
    @ObservationIgnored private let observatoryLatest = LatestRead()
    @ObservationIgnored private let detailRead = LatestRead()
    @ObservationIgnored private let vitalsRead = LatestRead()
    private var pendingObservatoryReads = 0
    public var isRefreshing: Bool { pendingObservatoryReads > 0 }

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

    /// Publish to the page root; enable Context Flow defaults only when unset.
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
        await refreshVitals()

        var contextFlowReady = true
        if enabled {
            let status: NativeContextFlowModeStatus
            if UserDefaults.standard.object(forKey: NativeContextFlowConfiguration.modeDefaultsKey) == nil {
                status = await contextFlow.setMode(.active)
            } else {
                status = await contextFlow.modeStatus()
            }
            if let mode = status.effectiveMode, status.unavailableReason == nil {
                contextFlowReady = mode.rawValue == UserDefaults.standard.string(
                    forKey: NativeContextFlowConfiguration.modeDefaultsKey)
            } else {
                contextFlowReady = false
            }
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
        await runtime?.moodWarmth() ?? 0
    }

    /// Read policy from TrustCenter and composite gate arithmetic from DreamREMCycle.
    public nonisolated func dreamGate() async throws -> DreamREMGatePolicy {
        try DreamREMGatePolicy(policy: SwiftNativeTrustCenter(dataRoot: dataRoot).loadSavedPolicyChecked())
    }

    /// Manual REM changes durable state: its effect-time gate must expose damaged authority, never an apparently enabled cycle.
    public nonisolated func dreamGateChecked() async throws -> DreamREMGatePolicy {
        let policy = try await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicyChecked()
        return try DreamREMGatePolicy(policy: policy)
    }

    /// Dreams require both scheduler and personality-cycle gates.
    public nonisolated func dreamEnabled() async throws -> Bool {
        try await dreamGate().dreamEnabled
    }

    public func dreamDiary(limit: Int = 30) async throws -> DreamDiary {
        diaryLimit = max(diaryLimit, limit)
        if diaryWatch == nil {
            let watcher = await FileChangeWatcher.armed(paths: [
                dataRoot.appendingPathComponent("dream_diary", isDirectory: true),
                SwiftNativeTrustCenter.policyURL(dataRoot: dataRoot)
            ]) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshDiary() }
            }
            if diaryWatch == nil { diaryWatch = watcher } else { watcher.cancel() }
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
        do { _ = try await dreamDiary(limit: limit) } catch { /* dreamDiary already published the failure. */ }
    }

    @concurrent nonisolated func readDreamDiary(limit: Int, enabled: Bool) async throws -> DreamDiary {
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

    /// A missing diary entry must remain a not-found error.
    public nonisolated func dreamEntry(date: String) async throws -> DreamEntry {
        guard let entry = try FileBackedDreamDiary(dataRoot: dataRoot).getEntry(date) else {
            throw DreamREMCycleError.underlying("No dream entry for \(date) in \(dataRoot.appendingPathComponent("dream_diary").path)")
        }
        return entry
    }
}

public struct DreamDiary: Equatable, Sendable {
    public var entries: [DreamEntry] = []
    public var enabled = false
    public var totalEntries: Int?
    public var unreadableEntries: Int?
    public init(entries: [DreamEntry] = [], enabled: Bool = false, totalEntries: Int? = nil, unreadableEntries: Int? = nil) {
        self.entries = entries
        self.enabled = enabled
        self.totalEntries = totalEntries
        self.unreadableEntries = unreadableEntries
    }

}

extension DreamEntry {
    public var text: String { content ?? "" }
}

/// Watch only durable inputs this panel actually reads; unrelated producers can signal refresh without updating displayed state.
public enum LivingStatusFileWatch {
    public enum Availability: Equatable, Sendable {
        case watching(inputCount: Int)
        case unavailable(String)
    }

    public static func watchedPaths(dataRoot: URL) -> [URL] {
        let desk = SwiftNativeDeskStore(dataRoot: dataRoot)
        return [
            // Process-local signals do not cover another process replacing persisted state.
            dataRoot.appendingPathComponent("cognition/organism_state.json"),
            // Watch both the append feed and compaction base because Desk commits may update either.
            desk.opsPath,
            desk.basePath,
            dataRoot.appendingPathComponent("workflows/approvals/requests.json"),
            // Watch the directory because dream reads select the newest dated entry.
            dataRoot.appendingPathComponent("dream_diary", isDirectory: true),
        ]
    }

}

extension CognitionViewFacade {
    public func refreshObservatory(
        contextFlowHealthRead: () async -> ContextFlowObservatoryHealthState
    ) async {
        pendingObservatoryReads += 1
        defer { pendingObservatoryReads -= 1 }
        await refreshDetail()
        await refreshContextFlowHealth(contextFlowHealthRead)
    }

    public func refreshContextFlowHealth(_ read: () async -> ContextFlowObservatoryHealthState) async {
        _ = await observatoryLatest.read({
            await read()
        }, publish: { nextContextFlowHealth in
            if contextFlowHealth != nextContextFlowHealth { contextFlowHealth = nextContextFlowHealth }
            contextFlowHealthCheckedAt = Date()
        })
    }
}
