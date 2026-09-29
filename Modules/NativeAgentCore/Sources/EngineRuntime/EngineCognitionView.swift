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
    public var contextFlowFallback: ContextFlowFallbackState?
    public var workshop: WorkshopObservatorySnapshot?
    public var enabled = false
    public var capsuleEnabled = false
    public var backgroundEnabled = false
    public var reflectionEnabled = false
    public var organismEnabled = false
    public var organismControlReadinessRevision: UInt64 = 0
    public var reflectionBudget = 0
    public var lastRefresh: Date?
    public var proposalsDetail: CognitiveObservatoryDetail?
    public var subconsciousRuntime: NativeSubconsciousRuntimeState?
    public var reflectionRoute: NativeReflectionRouteStatus?
    public var livingSnapshot: LivingStatusSnapshot?
    public var livingRefreshStatus: PanelRefreshStatus?
    @ObservationIgnored public lazy var refreshCoordinator = CognitionObservatoryRefreshCoordinator()
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
        guard let detail = await runtime?.observatoryDetail(), detail.configuration.enabled else {
            return .unavailable("Cognition proposals are unavailable while cognition is off.")
        }
        return .available(.init(
            standingViews: detail.standingViews.filter { $0.status == .proposed },
            schemaProposals: []
        ))
    }

    public func refreshProposals() async {
        proposalsDetail = await runtime?.observatoryDetail()
    }

    public func refreshVitals() async {
        subconsciousRuntime = await runtime?.subconsciousRuntimeState()
        reflectionRoute = await runtime?.reflectionRouteStatus()
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
        let entries = try await makeDreamREMCycle(root: dataRoot).listDreamDiary(limit: limit)
        // Same file set the listing reads (top level + archive/<year>), so the
        // header's count and the list agree after REM archives older nights.
        let diaryNames = FileBackedDreamDiary(dataRoot: dataRoot).entryFileNames()
        // FileBackedDreamDiary intentionally skips individual unreadable files
        // so one damaged entry does not hide readable ones. Carry that evidence
        // forward: an all-unreadable window must not become "No dreams yet."
        let boundedCount = min(max(1, limit), diaryNames.count)
        let visibleNames = Set(entries.compactMap(\.filename))
        let unreadableEntries = diaryNames.prefix(boundedCount).count {
            !visibleNames.contains($0)
        }
        return DreamDiary(
            entries: entries,
            enabled: await dreamEnabled(),
            totalEntries: diaryNames.count,
            unreadableEntries: unreadableEntries
        )
    }

    /// One night's entry; a missing one is the read route's not-found error.
    public nonisolated func dreamEntry(date: String) async throws -> DreamEntry {
        guard let entry = try await makeDreamREMCycle(root: dataRoot).getDreamForDate(date) else {
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
