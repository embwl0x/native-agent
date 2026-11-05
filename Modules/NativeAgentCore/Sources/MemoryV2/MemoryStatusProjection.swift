import Foundation
import PersistenceCore
// Blueprint: | `MemoryStatusProjection.swift` | `MemoryV2NativeStackSnapshot`: memory and embedding health, recent misses |

public enum MemoryRecoveryReadout {
    public static func afterTurnRecovery(dataRoot: URL) async -> AfterTurnMemoryRecoveryStatus {
        let owed = await AdaptiveMemoryPromoter.shared.owedMomentCount(dataRoot: dataRoot)
        return AfterTurnMemoryRecoveryStatus(status: owed.map { $0 == 0 ? "ready" : "owed" } ?? "unavailable",
                                             owedCount: owed)
    }

    public static func getMemoryV2Status(dataRoot: URL) async throws -> MemoryV2Status {
        // Counts stay in SQLite; embedding fields share one runtime snapshot.
        var memCount: Int?
        var activeCount: Int?
        var pinnedCount: Int?
        var pendingProposals: Int? = nil
        var storageReadable = false
        var storageFailure: String?
        do {
            let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            let counts = try await storage.statusCounts()
            storageReadable = true
            memCount = counts.memories
            activeCount = counts.active
            pinnedCount = counts.pinned
            pendingProposals = counts.pendingProposals
        } catch {
            storageFailure = String(describing: error)
        }
        let runtimeSnapshot = await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot).embeddingRuntimeSnapshot()
        let effective = runtimeSnapshot?.effectiveBackend
        let isReal = (effective == ManagedEmbeddingProvider.coreMLBackend)
        let backend = runtimeSnapshot.map { "\($0.modelId)/d\($0.dimensions)" }
        let fallback: String? = {
            guard !isReal else { return nil }
            switch effective {
            case ManagedEmbeddingProvider.mockBackend:
                return "Semantic embeddings are explicitly set to mock in config/embeddings.json"
            case ManagedEmbeddingProvider.failClosedBackend:
                return """
                    bge-large-en-v1.5 semantic embeddings unavailable; recall is fail-closed. \
                    \(runtimeSnapshot?.lastLoadError ?? "Read Doctor for the model file and failure.")
                    """
            default:
                // An unwired runtime is unavailable, never a healthy snapshot.
                return "Semantic embedding runtime is unavailable"
            }
        }()
        return MemoryV2Status(
            // Keep failed count provenance so unreadable storage cannot appear empty.
            status: storageReadable ? (memCount == 0 ? "empty" : "ready") : "unavailable",
            version: "swift-native",
            embedding: MemoryV2Embedding(
                activeBackend: backend,
                realSemanticAvailable: isReal,
                fallbackReason: fallback
            ),
            counts: MemoryV2Counts(
                memories: memCount,
                active: activeCount,
                pinned: pinnedCount,
                pendingProposals: pendingProposals
            ),
            afterTurn: await afterTurnRecovery(dataRoot: dataRoot),
            createdAt: ISO8601DateFormatter().string(from: Date()),
            storageFailure: storageFailure
        )
    }

    /// Count every canonical occurrence in the requested weeks, including graduated rows, before bounding examples. Incomplete history fails explicitly;
    /// disclosure withholds text but never counts.
    public static func misses(dataRoot: URL, weeks: [String], surface: String? = nil) async throws -> [MemoryMissLesson] {
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        let calendar = Calendar(identifier: .iso8601)
        let windows = try weeks.map { week -> DateInterval in
            let parts = week.components(separatedBy: "-W")
            guard parts.count == 2, let year = Int(parts[0]), let number = Int(parts[1]),
                  let start = calendar.date(from: DateComponents(weekday: 2, weekOfYear: number, yearForWeekOfYear: year)),
                  isoWeek(start) == week,
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else {
                throw MemoryStorageError.invalidTemporalEvidence("invalid correction week: \(week)")
            }
            return DateInterval(start: start, end: end)
        }
        guard let start = windows.map(\.start).min(), let end = windows.map(\.end).max() else { return [] }
        var lessons: [String: (firstSeen: Int, misses: [(date: Date, miss: MemoryMiss)])] = [:]
        for occurrence in try await storage.correctionOccurrences(from: start, to: end) {
            let m = occurrence.memory
            let week = isoWeek(occurrence.date)
            guard weeks.contains(week) else { continue }
            // Archived and graduated misses stay in history; hidden rows contribute counts without exposing lesson names or words.
            let record = MemoryRecord(stored: m)
            let shown = surface == nil || MemoryRecordDisclosurePolicy.classify(
                personaID: record.personaId, status: "active", lifecycle: nil, tags: record.tags, metadata: record.extras
            )?.permits(surface: surface, personaID: nil) == true
            let name = !shown ? "not shown on this surface"
                : m.metadata?.objectValue?["lesson"]?.stringValue ?? lesson(metadata: m.metadata, text: m.content)
            let text = shown ? m.content : ""
            let miss = MemoryMiss(originId: occurrence.originID, memoryId: m.id, text: text, at: occurrence.at, week: week,
                                  sessionId: occurrence.sessionID, history: occurrence.history)
            let firstSeen = lessons.count
            lessons[name, default: (firstSeen, [])].misses.append((occurrence.date, miss))
        }
        var groups: [(name: String, firstSeen: Int, misses: [(date: Date, miss: MemoryMiss)])] = []
        for (name, group) in lessons {
            let misses = group.misses.sorted { $0.date > $1.date }
            groups.append((name: name, firstSeen: group.firstSeen, misses: misses))
        }
        groups.sort { a, b in
            let latestA = a.misses[0].date, latestB = b.misses[0].date
            return latestA == latestB ? a.firstSeen < b.firstSeen : latestA > latestB
        }
        return groups.map { group in
            let counts = Dictionary(grouping: group.misses, by: { $0.miss.week }).mapValues { $0.count }
            return MemoryMissLesson(lesson: group.name, countsByWeek: counts,
                                    misses: group.misses.prefix(10).map(\.miss))
        }
    }

    public static func isoWeek(_ date: Date = Date(), ago: Int = 0) -> String {
        let date = date.addingTimeInterval(-Double(ago) * 7 * 86_400)
        let parts = Calendar(identifier: .iso8601).dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
    }

    public static let genericSubjects: Set<String> = [
        "instruction", "correction", "preference", "policy", "user", "agent", "claude", "codex", "nativeagent",
    ]

    /// Stamp one lesson tag when kept; derive unstamped labels with the same subject, tag/topic and first-clause priority.
    public static func lesson(metadata: JSONValue?, text: String) -> String {
        func tag(_ text: String) -> String {
            text.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(4).joined(separator: "-")
        }
        var labels = [metadata?.objectValue?["correction_subject"]?.stringValue].compactMap { $0 }
        if case .object(let meta)? = metadata {
            for key in ["tags", "context_topics"] {
                guard case .array(let values)? = meta[key] else { continue }
                labels += values.compactMap { if case .string(let label) = $0 { label } else { nil } }
            }
        }
        if let label = labels.map(tag).first(where: { !$0.isEmpty && !genericSubjects.contains($0) }) {
            return label
        }
        return tag(text.split { ".,;:—(".contains($0) }.first.map(String.init) ?? text)
    }

}

public struct MemoryV2NativeStackSnapshot: Sendable, Equatable {
    public var sqliteRecordCount: Int
    public var sqliteProposalCount: Int
    /// `nil` before the direct store probe, `false` when it could not read.
    public var storageReadable: Bool?
    public var coreMLReady: Bool
    public var coreMLModelLabel: String
    public var embedderDimensions: Int
    public var runtimeEmbedderDimensions: Int? = nil
    // Runtime state distinguishes an installed model from a working embedder.
    public var coreMLLoaded: Bool
    public var coreMLLastLoadError: String?
    public var coreMLLoadCount: Int
    public var embeddingMode: String
    public var requestedEmbeddingBackend: String
    public var effectiveEmbeddingBackend: String
    public var spotlightReindexed: Bool
    public var spotlightIndexedCount: Int
    public var spotlightLastError: String? = nil
    public var cloudKitAccountStatus: String
    public var dataRootPath: String

    /// Distinguish real inference readiness from disabled or synthetic search.
    public enum EmbedderHealth {
        case working(loadCount: Int)
        case ready
        case broken(reason: String)
        case missing
        case disabled
        case mock

        public var needsAttention: Bool {
            switch self {
            case .broken, .missing: return true
            default: return false
            }
        }
    }

    public var embedderHealth: EmbedderHealth {
        if requestedEmbeddingBackend == ManagedEmbeddingProvider.mockBackend {
            return .disabled
        }
        if effectiveEmbeddingBackend == ManagedEmbeddingProvider.mockBackend {
            return .mock
        }
        if let err = coreMLLastLoadError {
            return .broken(reason: err)
        }
        if coreMLLoaded {
            return .working(loadCount: coreMLLoadCount)
        }
        if coreMLReady {
            return .ready
        }
        return .missing
    }

    public var shouldPollEmbeddingStartup: Bool {
        embeddingMode == ManagedEmbeddingProvider.performanceMode
            && effectiveEmbeddingBackend == ManagedEmbeddingProvider.coreMLBackend
            && coreMLReady
            && !coreMLLoaded
            && coreMLLastLoadError == nil
    }

    public static let empty = MemoryV2NativeStackSnapshot(
        sqliteRecordCount: 0,
        sqliteProposalCount: 0,
        storageReadable: nil,
        coreMLReady: false,
        coreMLModelLabel: "bge-large-en-v1.5 (not loaded)",
        embedderDimensions: CoreMLEmbeddingProvider.bundledDimensions,
        coreMLLoaded: false,
        coreMLLastLoadError: nil,
        coreMLLoadCount: 0,
        embeddingMode: "unknown",
        requestedEmbeddingBackend: "unknown",
        effectiveEmbeddingBackend: "unknown",
        spotlightReindexed: false,
        spotlightIndexedCount: 0,
        cloudKitAccountStatus: "checking…",
        dataRootPath: ""
    )

    public static func read(
        dataRoot: URL
    ) async -> MemoryV2NativeStackSnapshot {
        var snap = MemoryV2NativeStackSnapshot.empty
        snap.dataRootPath = dataRoot.path
        var spotlightEligibleCount = 0
        var storageGeneration: String?

        // Probe the canonical store; zero requires a successful read, while failure remains explicit.
        do {
            let store = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            let counts = try await store.statusCounts()
            snap.storageReadable = true
            snap.sqliteRecordCount = counts.active
            let spotlightSnapshot = try await store.spotlightSnapshot()
            spotlightEligibleCount = spotlightSnapshot.items.count
            storageGeneration = spotlightSnapshot.fingerprint
            snap.sqliteProposalCount = counts.pendingProposals
            snap.spotlightLastError = await store.spotlightProjectionFailure
        } catch {
            snap.storageReadable = false
        }

        // Use the runtime's resolver so missing and broken assets cannot appear ready.
        do {
            let installed = try CoreMLEmbeddingProvider.installedExtrasModel(root: dataRoot)
            snap.coreMLReady = true
            snap.coreMLModelLabel = installed.modelID
            snap.embedderDimensions = installed.dimensions
        } catch {
            snap.coreMLModelLabel = "bge-large-en-v1.5 unavailable"
        }

        // Disk reachability cannot prove inference works; take loaded state, load error and count from the runtime snapshot.
        snap.applyEmbeddingRuntime(await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot).embeddingRuntimeSnapshot())

        // Spotlight proof is valid only for the current canonical generation.
        let spotMarker = SwiftNativeMemoryIndexer.markerURL(dataRoot: dataRoot)
        if snap.spotlightLastError == nil, let storageGeneration,
           let markerData = try? Data(contentsOf: spotMarker),
           String(data: markerData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == storageGeneration {
            snap.spotlightReindexed = true
            snap.spotlightIndexedCount = spotlightEligibleCount
        }

        return snap
    }

    public mutating func applyEmbeddingRuntime(_ snapshot: EmbeddingRuntimeSnapshot?) {
        guard let runtime = snapshot else { return }
        runtimeEmbedderDimensions = runtime.dimensions
        embeddingMode = runtime.mode
        requestedEmbeddingBackend = runtime.requestedBackend
        effectiveEmbeddingBackend = runtime.effectiveBackend
        coreMLLoaded = runtime.coreMLLoaded
        coreMLLastLoadError = runtime.lastLoadError
        coreMLLoadCount = runtime.loadCount
    }
}

extension MemoryRecoveryReadout {
    /// Nil means the miss ledger could not be read, never zero misses.
    public static func recentMisses(dataRoot: URL) async -> [MemoryMissLesson]? {
        try? await MemoryRecoveryReadout.misses(
            dataRoot: dataRoot, weeks: [MemoryRecoveryReadout.isoWeek(), MemoryRecoveryReadout.isoWeek(ago: 1)])
    }

}
