import Foundation
import PersistenceCore

/// Read-only status and hygiene projections using the existing stores and runtime.
public enum MemoryStatusProjection {
    public static func afterTurnRecovery(dataRoot: URL) -> AfterTurnMemoryRecoveryStatus {
        do {
            let held = try AdaptiveMemoryPromoter.readHeld(dataRoot: dataRoot)
            let latest = held.compactMap(\.failure).max { $0.at < $1.at }
            return AfterTurnMemoryRecoveryStatus(status: held.isEmpty ? "ready" : "held",
                                                heldCount: held.count, failure: latest)
        } catch {
            return AfterTurnMemoryRecoveryStatus(status: "unavailable", heldCount: nil, failure: nil)
        }
    }

    public static func getMemoryVectorStatus(dataRoot: URL) async throws -> MemoryVectorStatus {
        // An absent feed is unmeasured. A present-but-unreadable feed is
        // unavailable; neither state may impersonate a ready zero-count store.
        let path = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("vector_status.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            return MemoryVectorStatus(
                status: "unmeasured",
                provider: nil,
                providerModel: nil,
                providerConfigured: nil,
                providerReason: "vector status has not been recorded for this data root",
                dimensions: nil,
                nodeCount: nil,
                entityCount: nil,
                updatedAt: nil,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
        }
        if let data = try? Data(contentsOf: path),
           let decoded = try? statusDecoder().decode(MemoryVectorStatus.self, from: data) {
            return decoded
        }
        return MemoryVectorStatus(
            status: "unavailable",
            provider: nil,
            providerModel: nil,
            providerConfigured: false,
            providerReason: "vector status not available",
            dimensions: nil,
            nodeCount: nil,
            entityCount: nil,
            updatedAt: nil,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    public static func getMemoryV2Status(dataRoot: URL) async throws -> MemoryV2Status {
        // fix3/F2: route truthfully through SwiftNativeMemoryV2.shared. Counts
        // come from MemoryStorage; pinned reads metadata.pinned; pending
        // proposals reads storage.listProposals(status: "pending"); embedding
        // backend reflects the live runtime snapshot — CoreML when MiniLM
        // loaded, mock when the user explicitly opted in (config or env),
        // fail-closed otherwise.
        var memCount = 0
        var activeCount = 0
        var pinnedCount = 0
        var pendingProposals: Int? = nil
        var storageReadable = false
        do {
            let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            let all = try await storage.listMemories(persona: nil, status: nil, limit: nil)
            storageReadable = true
            memCount = all.count
            for m in all {
                // ONE MEANING OF "active" (Astra comb 4, lane4 finding 6). The
                // count read `status` alone while the browser also excludes the
                // corrected/contradicted/deleted lifecycles, so the summary said
                // "190 active" over a list that could only ever show 169: the 21
                // `status=active, lifecycle=corrected` rows (`FDF6A630-…` and
                // `BF12BC92-…`, both superseded sleep-schedule statements) were
                // counted by one surface and excluded by the other. Same
                // predicate as `listMemories(status: "active")`.
                if m.status == "active", MemoryLifecycle.isRecallEligible(m.lifecycle) {
                    activeCount += 1
                }
                // SQLite schema has no `pinned` column; updateMemory()
                // encodes the flag under metadata.pinned. Surface the
                // real count by inspecting the metadata blob.
                if case .object(let obj)? = m.metadata,
                   case .bool(true)? = obj["pinned"] {
                    pinnedCount += 1
                }
            }
            if let pending = try? await storage.listProposals(status: "pending") {
                pendingProposals = pending.count
            }
        } catch {
            storageReadable = false
        }
        let modelId = await SwiftNativeMemoryV2.shared.embedderModelId()
        let dims = await SwiftNativeMemoryV2.shared.embedderDimensions()
        // gpt-5.5 review-4 STILL-NEEDS-FIX: `embedderModelId()` returns
        // "all-MiniLM-L6-v2" whenever config requests CoreML — even when the
        // effective runtime is fail-closed (resources missing, embed() throws).
        // Deriving `isReal` from `modelId != "mock"` therefore lied to the UI:
        // a broken install surfaced as `realSemanticAvailable: true` with
        // `fallbackReason: nil`. Drive off the runtime snapshot's
        // `effectiveBackend` instead, which is the single source of truth
        // computed inside ManagedEmbeddingProvider with all the branch logic.
        let runtimeSnapshot = await SwiftNativeMemoryV2.shared.embeddingRuntimeSnapshot()
        let effective = runtimeSnapshot?.effectiveBackend
        let isReal = (effective == ManagedEmbeddingProvider.coreMLBackend)
        let backend = modelId.map { "\($0)\(dims.map { "/d\($0)" } ?? "")" }
        let fallback: String? = {
            guard !isReal else { return nil }
            switch effective {
            case ManagedEmbeddingProvider.mockBackend:
                return "Semantic embeddings are explicitly set to mock (config or NATIVE_AGENT_EMBEDDING_MOCK)"
            case ManagedEmbeddingProvider.failClosedBackend:
                return "CoreML semantic embeddings unavailable; recall is fail-closed until the MiniLM bundle is installed"
            default:
                // Snapshot was nil (runtime not yet wired) — surface that honestly.
                return "Semantic embedding runtime is unavailable"
            }
        }()
        // F2: surface hygiene_last_run.json so the UI can show "last run at X /
        // next ~24h" instead of an empty hygiene slot that reads as "never".
        let hygieneReport = Self.readHygieneLastRun(dataRoot: dataRoot)
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
            hygiene: hygieneReport,
            vault: nil,
            afterTurn: afterTurnRecovery(dataRoot: dataRoot),
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    public static func readHygieneLastRun(dataRoot: URL = PersistenceCore.defaultDataRoot()) -> MemoryHygieneReport? {
        let path = dataRoot
            .appendingPathComponent("memory")
            .appendingPathComponent("hygiene_last_run.json")
        guard let data = try? Data(contentsOf: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let createdAt = (obj["createdAt"] as? String)
            ?? (obj["created_at"] as? String)
            ?? (obj["lastRun"] as? String)
            ?? (obj["last_run"] as? String)
        // Prefer the report's own nextScheduled; derive lastRun + 7d only when
        // absent. The cadence is WEEKLY (MemoryConsolidationHygieneRunner
        // stages one approval card per week) — the old derived +24h made the
        // Memory tab claim hygiene was overdue six days out of seven.
        var nextScheduled: String? = (obj["nextScheduled"] as? String)
            ?? (obj["next_scheduled"] as? String)
        // Honest-status (2026-07-24): a staged/refused run completed nothing —
        // its receipt intentionally carries no "next" stamp, and deriving one
        // here would recreate the false cadence boundary the runner just
        // stopped writing.
        let statusValue = (obj["status"] as? String) ?? "idle"
        if nextScheduled == nil,
           statusValue != "staged", statusValue != "refused",
           let createdAt, let dt = ISO8601DateFormatter().date(from: createdAt) {
            nextScheduled = ISO8601DateFormatter().string(from: dt.addingTimeInterval(7 * 24 * 3600))
        }
        return MemoryHygieneReport(
            id: obj["id"] as? String,
            status: (obj["status"] as? String) ?? "idle",
            reason: obj["reason"] as? String,
            version: obj["version"] as? String,
            createdAt: createdAt,
            beforeCount: obj["beforeCount"] as? Int,
            afterCount: obj["afterCount"] as? Int,
            normalized: obj["normalized"] as? Int,
            archivedDuplicates: obj["archivedDuplicates"] as? Int,
            archivedReflections: obj["archivedReflections"] as? Int,
            distilledFactsAdded: obj["distilledFactsAdded"] as? Int,
            decayedMemories: obj["decayedMemories"] as? Int,
            proposalHygiene: nil,
            consolidationRunId: (obj["consolidationRunId"] as? String)
                ?? (obj["consolidation_run_id"] as? String),
            nextScheduled: nextScheduled
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
        var lessons: [MemoryMissLesson] = []
        for m in try await storage.listMemories(persona: nil, status: nil, limit: nil)
        where m.status != "deleted" && MemoryMoments.metadataString(m.metadata, "kind") == "correction" {
            let session = MemoryMoments.metadataString(m.metadata, "session_id")
            // Dated by the turn that gave it (a held or recovered correction is
            // kept later); rows kept before turns were stamped, by their insert.
            var occurrences = [(at: MemoryMoments.metadataString(m.metadata, "turn_at") ?? m.createdAt, session: session,
                                history: MemoryMoments.metadataString(m.metadata, "history"))]
            if case .object(let meta)? = m.metadata, case .array(let repeats)? = meta["duplicate_occurrences"] {
                for case .object(let repeated) in repeats {
                    guard case .string(let at)? = repeated["turn_at"] else { continue }
                    // A key the repeat shares with the row is left out of it.
                    occurrences.append((at, MemoryMoments.metadataString(.object(repeated), "session_id") ?? session,
                                        MemoryMoments.metadataString(.object(repeated), "history")))
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
                : MemoryMoments.metadataString(m.metadata, "lesson") ?? lesson(metadata: m.metadata, text: m.content)
            let text = shown ? m.content : ""
            for occurrence in occurrences {
                let week = isoWeek(MemoryMoments.parseTimestamp(occurrence.at) ?? .distantPast)
                guard weeks.contains(week) else { continue }
                let miss = MemoryMiss(memoryId: m.id, text: text, at: occurrence.at, week: week,
                                      sessionId: occurrence.session, history: occurrence.history)
                if let index = lessons.firstIndex(where: { $0.lesson == name }) {
                    lessons[index].misses.append(miss)
                } else {
                    lessons.append(MemoryMissLesson(lesson: name, misses: [miss]))
                }
            }
        }
        // Newest first, each lesson's misses and the lessons themselves.
        func newest(_ miss: MemoryMiss) -> Date { MemoryMoments.parseTimestamp(miss.at) ?? .distantPast }
        for index in lessons.indices { lessons[index].misses.sort { newest($0) > newest($1) } }
        return lessons.sorted { newest($0.misses[0]) > newest($1.misses[0]) }
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
        var labels = [MemoryMoments.metadataString(metadata, "correction_subject")].compactMap { $0 }
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

    private static func statusDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
