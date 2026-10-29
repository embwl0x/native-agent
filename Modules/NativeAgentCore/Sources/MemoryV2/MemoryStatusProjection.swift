import Foundation
import PersistenceCore
// Blueprint: | `MemoryStatusProjection.swift` | MemoryV2 and embedding runtime status projections and recent misses; embedding settings act through MemoryFacade's canonical owner; `MemoryV2NativeStackSnapshot` reads native stack health |

/// Read-only status projections using the existing stores and runtime.
public enum MemoryRecoveryReadout {
    /// The journal's owed turns (recorded, not yet lived).
    public static func afterTurnRecovery(dataRoot: URL) async -> AfterTurnMemoryRecoveryStatus {
        let owed = await AdaptiveMemoryPromoter.shared.owedMomentCount(dataRoot: dataRoot)
        return AfterTurnMemoryRecoveryStatus(status: owed.map { $0 == 0 ? "ready" : "owed" } ?? "unavailable",
                                             owedCount: owed)
    }

    public static func getMemoryV2Status(dataRoot: URL) async throws -> MemoryV2Status {
        // Counts stay in SQLite; embedding fields share one runtime snapshot.
        var memCount = 0
        var activeCount = 0
        var pinnedCount = 0
        var pendingProposals: Int? = nil
        var storageReadable = false
        do {
            let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            let counts = try await storage.statusCounts()
            storageReadable = true
            memCount = counts.memories
            activeCount = counts.active
            pinnedCount = counts.pinned
            pendingProposals = counts.pendingProposals
        } catch {
            storageReadable = false
        }
        let runtimeSnapshot = await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot).embeddingRuntimeSnapshot()
        let effective = runtimeSnapshot?.effectiveBackend
        let isReal = (effective == ManagedEmbeddingProvider.coreMLBackend)
        let backend = runtimeSnapshot.map { "\($0.modelId)/d\($0.dimensions)" }
        let fallback: String? = {
            guard !isReal else { return nil }
            switch effective {
            case ManagedEmbeddingProvider.mockBackend:
                return "Semantic embeddings are explicitly set to mock (config or NATIVE_AGENT_EMBEDDING_MOCK)"
            case ManagedEmbeddingProvider.failClosedBackend:
                return "bge-large-en-v1.5 semantic embeddings unavailable; recall is fail-closed. \(runtimeSnapshot?.lastLoadError ?? "Read Doctor for the model file and failure.")"
            default:
                // Snapshot was nil (runtime not yet wired) — surface that honestly.
                return "Semantic embedding runtime is unavailable"
            }
        }()
        return MemoryV2Status(
            // An unreadable store is not an empty store. The Memory screen
            // uses this provenance to avoid claiming no memories are saved
            // when the real reader could not establish a count.
            status: storageReadable ? (memCount > 0 ? "ready" : "empty") : "unavailable",
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
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    /// The miss ledger for the ISO `weeks` asked: every time she was given a
    /// correction in them (graduated ones too — a lesson now kept in GROWTH was
    /// still missed), grouped by the lesson it teaches, the most recently
    /// missed lesson first. Weekly counts per lesson are the growth metric.
    /// A correction given again collapses into its row; each turn-stamped
    /// repeat in `duplicate_occurrences` is a miss of its own, at its turn.
    /// Read for a `surface`, a row its disclosure keeps from that surface still
    /// counts but shows no text (nil: the Mac's own page, which sees all).
    public static func misses(dataRoot: URL, weeks: [String], surface: String? = nil) async throws -> [MemoryMissLesson] {
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        var lessons: [String: (firstSeen: Int, misses: [(date: Date, miss: MemoryMiss)])] = [:]
        for m in try await storage.listMemories(persona: nil, status: nil, limit: nil)
        where m.status != "deleted" && m.metadata?.objectValue?["kind"]?.stringValue == "correction" {
            let session = m.metadata?.objectValue?["session_id"]?.stringValue
            // Dated by the turn that gave it (a held or recovered correction is
            // kept later); rows kept before turns were stamped, by their insert.
            var occurrences = [(at: m.metadata?.objectValue?["turn_at"]?.stringValue ?? m.createdAt, session: session,
                                history: m.metadata?.objectValue?["history"]?.stringValue)]
            if case .object(let meta)? = m.metadata, case .array(let repeats)? = meta["duplicate_occurrences"] {
                for case .object(let repeated) in repeats {
                    guard case .string(let at)? = repeated["turn_at"] else { continue }
                    // A key the repeat shares with the row is left out of it.
                    occurrences.append((at, repeated["session_id"]?.stringValue ?? session,
                                        repeated["history"]?.stringValue))
                }
            }
            // Scope only: a graduated or archived miss is history, not hidden.
            // A hidden one counts under one name and shows neither its words
            // nor the lesson named from them.
            let record = MemoryRecord(stored: m)
            let shown = surface == nil || MemoryRecordDisclosurePolicy.classify(
                personaID: record.personaId, status: "active", lifecycle: nil, tags: record.tags, metadata: record.extras
            )?.permits(surface: surface, personaID: nil) == true
            let name = !shown ? "not shown on this surface"
                : m.metadata?.objectValue?["lesson"]?.stringValue ?? lesson(metadata: m.metadata, text: m.content)
            let text = shown ? m.content : ""
            for occurrence in occurrences {
                let date = MemoryMoments.parseTimestamp(occurrence.at) ?? .distantPast
                let week = isoWeek(date)
                guard weeks.contains(week) else { continue }
                let miss = MemoryMiss(memoryId: m.id, text: text, at: occurrence.at, week: week,
                                      sessionId: occurrence.session, history: occurrence.history)
                let firstSeen = lessons.count
                lessons[name, default: (firstSeen, [])].misses.append((date, miss))
            }
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
        return groups.map { group in MemoryMissLesson(lesson: group.name, misses: group.misses.map(\.miss)) }
    }

    /// "2026-W41": the ISO week `date` falls in, on this Mac's clock. `ago`
    /// whole weeks back from it.
    public static func isoWeek(_ date: Date = Date(), ago: Int = 0) -> String {
        let date = date.addingTimeInterval(-Double(ago) * 7 * 86_400)
        let parts = Calendar(identifier: .iso8601).dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
    }

    /// Labels too broad to say what an agreement or a correction is about.
    public static let genericSubjects: Set<String> = [
        "instruction", "correction", "preference", "policy", "user", "agent", "claude", "codex", "nativeagent",
    ]

    /// The lesson a correction teaches, as one short tag, stamped once when it
    /// is kept (`lesson`): the memory manager's subject, else her first
    /// specific tag or topic, else the first words of its first clause. Rows
    /// kept before the stamp are named the same way when read.
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

    /// Visual + textual status derived from the runtime fields above.
    /// Distinguishes real-model readiness from disabled or mock search.
    public enum EmbedderHealth {
        case working(loadCount: Int)   // green
        case ready                      // orange — resources present, never loaded
        case broken(reason: String)     // red — lastLoadError set
        case missing                    // red — bundled resources not reachable
        case disabled
        case mock

        public var needsAttention: Bool {
            switch self {
            case .broken, .missing: return true
            default: return false
            }
        }
    }

    /// Derive the at-a-glance health state. Caller decides how to
    /// render — typical: green for working, orange for ready, red for
    /// broken/missing.
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

        // SQLite probe — open the same store MemoryV2+Storage.swift uses and
        // count active rows. A clean empty store is 0; a failed read remains
        // explicit so the panel cannot present it as an empty memory profile.
        do {
            let store = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            let counts = try await store.statusCounts()
            snap.storageReadable = true
            snap.sqliteRecordCount = counts.active
            spotlightEligibleCount = counts.active
            storageGeneration = try await store.spotlightSnapshot().fingerprint
            snap.sqliteProposalCount = counts.pendingProposals
            snap.spotlightLastError = await store.spotlightProjectionFailure
        } catch {
            snap.storageReadable = false
        }

        // Ask the runtime's resolver; missing or broken bge assets are never
        // ready. applyEmbeddingRuntime() below carries the named load error.
        do {
            let installed = try CoreMLEmbeddingProvider.installedExtrasModel(root: dataRoot)
            snap.coreMLReady = true
            snap.coreMLModelLabel = installed.modelID
            snap.embedderDimensions = installed.dimensions
        } catch {
            snap.coreMLModelLabel = "bge-large-en-v1.5 unavailable"
        }

        // Runtime truth fields — the disk probe above tells us if
        // resources are reachable, but only the runtime knows whether
        // the model actually loaded and inference works. Pull
        // coreMLLoaded / lastLoadError / loadCount from
        // SwiftNativeMemoryV2's snapshot.
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
    /// This ISO week's and last week's misses by lesson; nil when the ledger
    /// could not be read.
    public static func recentMisses(dataRoot: URL) async -> [MemoryMissLesson]? {
        try? await MemoryRecoveryReadout.misses(
            dataRoot: dataRoot, weeks: [MemoryRecoveryReadout.isoWeek(), MemoryRecoveryReadout.isoWeek(ago: 1)])
    }

}
