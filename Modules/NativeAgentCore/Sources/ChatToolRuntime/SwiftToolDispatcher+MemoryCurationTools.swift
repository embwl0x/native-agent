import Foundation
import KnowledgeGraph
import MemoryV2
import NativeAgentCore
import PersistenceCore

// User, 2026-09-05: "make it so she can do it." The agent's memory tools were
// recall, commit and moment review; there was no way to walk the whole store,
// rewrite a row to what it means, or drop one, short of the Memories page's
// buttons. These three ride the same owner calls that page uses
// (SwiftNativeMemoryV2.updateMemory re-embeds when the text changes and gates
// against tombstones; deleteMemoryIfPresent tombstones and republishes the
// derived state). They touch only the agent's own store.
//
// User, 2026-10-01: Agent's ruling, anything a merge or correction replaces
// must stay recoverable. A merge or a newer fact ARCHIVES the old row (status
// archived, with duplicate_of / superseded_by in its metadata); a correction
// DEMOTES it (lifecycle corrected, corrected_by). `memory.list status:
// archived` shows both and `memory.rewrite restore` brings one back through
// the same updateMemory, so a bad merge or correction undoes in one call.
// `memory.rewrite pinned` is the page's pin (MemoryFacade.setPinned's patch).

/// What the app door's memory.list and memory.rewrite run, in process, over
/// one store.
public struct MemoryCuration: Sendable {
    let memoryV2: SwiftNativeMemoryV2
    let dataRoot: URL

    public init(memoryV2: SwiftNativeMemoryV2, dataRoot: URL) {
        self.memoryV2 = memoryV2
        self.dataRoot = dataRoot
    }

    func curationString(_ input: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let s)? = input[key] else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func curationInt(_ input: [String: JSONValue], _ key: String) -> Int? {
        switch input[key] {
        case .int(let i)?: return Int(i)
        case .double(let d)?:
            // Int(d) traps on NaN, infinity and anything past Int's range
            // (Codex review 2026-09-05: an offset of 1e100 crashed
            // the app instead of refusing).
            guard d.isFinite, abs(d) < 1e15 else { return nil }
            return Int(d)
        default: return nil
        }
    }

    /// The paging cursor carries its sort direction and the ordering key of
    /// the last row handed out. Opaque to the caller; returned as `after_id`.
    static func curationCursor(sort: String, createdAt: String, id: String) -> String {
        "\(sort)|\(createdAt)|\(id)"
    }

    static func curationCursorKey(_ raw: String) -> (sort: String, key: (String, String))? {
        let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, ["newest_first", "oldest_first"].contains(String(parts[0])),
              !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return (String(parts[0]), (String(parts[1]), String(parts[2])))
    }

    func curationBool(_ input: [String: JSONValue], _ key: String) -> Bool? {
        guard case .bool(let b)? = input[key] else { return nil }
        return b
    }

    func curationRefusal(_ reason: String) -> JSONValue {
        .object(["status": .string("refused"), "reason": .string(reason)])
    }

    /// Every active memory, newest first by default, in pages. The walk
    /// starts at offset 0 and ends when `remaining` is 0.
    public func listMemories(input: [String: JSONValue], surface: String, persona: String?) async throws -> JSONValue {
        let offset = max(0, curationInt(input, "offset") ?? 0)
        let limit = min(100, max(1, curationInt(input, "limit") ?? 50))
        let requestedSort = curationString(input, "sort")?.lowercased() ?? "newest_first"
        let sort = ["newest": "newest_first", "latest": "newest_first", "oldest": "oldest_first"][requestedSort] ?? requestedSort
        guard ["newest_first", "oldest_first"].contains(sort) else {
            return curationRefusal("sort must be newest_first or oldest_first; keep the same sort when following next_after_id.")
        }
        let requestedStatus = curationString(input, "status")?.lowercased() ?? "active"
        let status = ["kept": "active", "saved": "active", "current": "active"][requestedStatus] ?? requestedStatus
        guard ["active", "archived"].contains(status) else {
            return curationRefusal("status must be active or archived.")
        }
        let afterID = curationString(input, "after_id")
        let cursor = afterID.flatMap { Self.curationCursorKey($0) }
        if let afterID, afterID.contains("|") {
            guard let cursor else {
                return curationRefusal("after_id is a legacy or invalid cursor without a recognized sort direction. Restart memory.list without after_id and with offset 0, choosing newest_first or oldest_first in sort.")
            }
            guard cursor.sort == sort else {
                return curationRefusal("after_id was issued with sort \(cursor.sort). Retry with sort \(cursor.sort), or restart without after_id and with offset 0 to change direction.")
            }
        }
        let listing: (records: [MemoryRecord], total: Int, nextOffset: Int)
        do {
            listing = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot).curationPage(
                archived: status == "archived", kind: curationString(input, "kind"), surface: surface, persona: persona,
                newestFirst: sort == "newest_first", afterKey: cursor?.key, afterID: afterID, offset: offset, limit: limit
            )
        } catch {
            return .object(["status": .string("failed"), "reason": .string("\(error)")])
        }
        let page = listing.records
        let rows: [JSONValue] = page.map { record in
            MemoryDataProvenance.consume(record.extras, dataRoot: dataRoot)
            var row: [String: JSONValue] = [
                "id": .string(record.id),
                "text": .string(record.text),
                "created_at": .string(record.createdAt),
            ]
            row.merge(MemoryDataProvenance.fields(in: record.extras, dataRoot: dataRoot)) { _, value in value }
            if let kind = record.memoryKind { row["kind"] = .string(kind) }
            if let warning = MemorySenseProvenance.warning(in: record.extras) {
                row["sense_warning"] = .string(warning)
            }
            if case .object(let metadata)? = record.extras, let versions = metadata["sense_versions"] {
                row["sense_versions"] = versions
            }
            if let status = record.status { row["status"] = .string(status) }
            if let source = record.sourceRunId { row["source"] = .string(source) }
            if record.pinned == true { row["pinned"] = .bool(true) }
            if status == "archived" {
                // What retired it, in plain words, so a bad merge is visible.
                // Where it is in its life: a corrected row still carries
                // status active, which would read as current.
                let corrected = MemoryLifecycle.normalized(record.lifecycle) == MemoryLifecycle.corrected
                row["status"] = .string(corrected ? MemoryLifecycle.corrected : "archived")
                if case .object(let meta)? = record.extras {
                    if case .string(let v)? = meta["duplicate_of"] { row["merged_into"] = .string(v) }
                    if case .string(let v)? = meta["superseded_by"] ?? meta["corrected_by"] { row["replaced_by"] = .string(v) }
                    if case .string(let v)? = meta["superseded_by"] { row["superseded_by"] = .string(v) }
                    if case .string(let v)? = meta["hygiene_archive_reason"] ?? meta["correction_reason"] { row["archived_because"] = .string(v) }
                }
                if let at = record.updatedAt { row["archived_at"] = .string(at) }
            }
            return .object(row)
        }
        let next = listing.nextOffset
        var out: [String: JSONValue] = [
            "status": .string("ok"),
            "sort": .string(sort),
            "memories": .array(rows),
            "count": .int(Int64(rows.count)),
            "total": .int(Int64(listing.total)),
            "next_offset": .int(Int64(next)),
            "remaining": .int(Int64(max(0, listing.total - next))),
        ]
        if let last = page.last {
            out["next_after_id"] = .string(Self.curationCursor(sort: sort, createdAt: last.createdAt, id: last.id))
        }
        return .object(out)
    }

    public func rewriteTarget(input: [String: JSONValue], surface: String, persona: String?) async throws -> MemoryRecord {
        guard let id = curationString(input, "id") else {
            throw ToolFailureError("memory.rewrite needs the memory 'id' from memory.list or recall_memory.", effects: .none)
        }
        let text = curationString(input, "text")
        let pinned = curationBool(input, "pinned")
        let restore = curationBool(input, "restore") == true
        guard text != nil || pinned != nil || restore else {
            throw ToolFailureError("memory.rewrite needs 'text' (the thing itself, one or two sentences), 'pinned' (true or false), or 'restore': true.", effects: .none)
        }
        let row = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            .memory(id: id).map(MemoryRecord.init(stored:))
        guard let row, MemoryRecordDisclosurePolicy.classify(
            personaID: row.personaId, status: MemoryStorage.isRecoverable(row) ? "active" : row.status,
            lifecycle: MemoryStorage.isRecoverable(row) ? nil : row.lifecycle,
            tags: row.tags, metadata: row.extras
        )?.permits(surface: surface, personaID: persona) == true else {
            throw ToolFailureError("No memory with that id is available on this surface; nothing changed.", effects: .none)
        }
        if restore, !MemoryStorage.isRecoverable(row) {
            throw ToolFailureError("No archived, corrected or graduated memory with that id, so there is nothing to restore. memory.list status archived shows the ones that can come back.", effects: .none)
        }
        // The pin writer refuses the same way; asking first lets a preview say so.
        if pinned == true, let refusal = UserMDGenerator.pinRefusal(kind: row.memoryKind) {
            throw ToolFailureError(refusal, effects: .none)
        }
        return row
    }

    /// Change one memory in one update: its text (same row, same id, same
    /// provenance; the embedding is recomputed by the owner), its pin, and/or
    /// restore it from archived to active.
    public func rewriteMemory(input: [String: JSONValue], surface: String, persona: String?) async throws -> JSONValue {
        let row: MemoryRecord
        do { row = try await rewriteTarget(input: input, surface: surface, persona: persona) }
        catch let error as ToolFailureError { return curationRefusal(error.localizedDescription) }
        catch { return .object(["status": .string("failed"), "reason": .string("\(error)")]) }
        let text = curationString(input, "text")
        let pinned = curationBool(input, "pinned")
        let restore = curationBool(input, "restore") == true
        var update: [String: JSONValue] = [:]
        MemoryDataProvenance.consume(row.extras, dataRoot: dataRoot)
        if case .object(let stamped)? = MemoryDataProvenance.stamping(.object(update)) { update = stamped }
        if let text { update["text"] = .string(text) }
        if let pinned { update["pinned"] = .bool(pinned) }
        if restore {
            update["status"] = .string("active")
            if !MemoryLifecycle.isRecallEligible(row.lifecycle) {
                update["lifecycle"] = .string(MemoryLifecycle.confirmed)
            }
            // The hygiene duplicate pass skips a row carrying this, so a
            // restored merge is not merged again on the next pass.
            update["owner_restored"] = .string(ISO8601DateFormatter().string(from: Date()))
            // Restore passes the text back through the gates a rewrite runs:
            // re-embedded, and refused when it matches something forgotten or
            // let go (an archived twin of a forgotten fact stays archived).
            if text == nil { update["text"] = .string(row.text) }
        }
        do {
            let updated = try await memoryV2.updateMemory(id: row.id, update: .object(update))
            var result: [String: JSONValue] = [
                "status": .string("ok"),
                "id": .string(updated.id),
                "text": .string(updated.text),
                "pinned": .bool(updated.pinned == true),
                "memory_status": .string(updated.status ?? "active"),
            ]
            result.merge(MemoryDataProvenance.fields(in: updated.extras, dataRoot: dataRoot)) { _, value in value }
            return .object(result)
        } catch MemoryV2Error.recordNotFound {
            return .object(["status": .string("failed"), "reason": .string("No memory with that id.")])
        } catch MemoryV2Error.underlying(let reason) where reason.hasPrefix("tombstoned") {
            return curationRefusal("\(reason). It matches something forgotten or let go, so it stays as it was; nothing changed.")
        } catch {
            return .object(["status": .string("failed"), "reason": .string("\(error)")])
        }
    }
}

extension SwiftToolDispatcher {
    private var curation: MemoryCuration { MemoryCuration(memoryV2: memoryV2, dataRoot: dataRoot) }

    /// Drop one memory for good. A tombstone keeps the same thing from being
    /// re-proposed.
    func impl_forget_memory(input: [String: JSONValue]) async throws -> JSONValue {
        guard let id = curation.curationString(input, "id") else {
            return curation.curationRefusal("forget_memory needs the memory 'id' from app memory.list or recall_memory.")
        }
        do {
            let deleted = try await memoryV2.deleteMemoryIfPresent(id: id)
            guard deleted else {
                return .object(["status": .string("failed"), "reason": .string("No memory with that id.")])
            }
            return .object(["status": .string("ok"), "id": .string(id)])
        } catch {
            return .object(["status": .string("failed"), "reason": .string("\(error)")])
        }
    }

    /// Re-derive the knowledge graph from the memory store as it is now. The
    /// pass to run once a curation is through: entities from rows that were
    /// rewritten or forgotten do not linger.
    func impl_rebuild_knowledge_graph(input: [String: JSONValue]) async throws -> JSONValue {
        // Settings ▸ "Knowledge graph": off means no graph is produced, and a
        // rebuild is production. Same words search_kg refuses with.
        guard MemoryPolicyGate.knowledgeGraphEnabled(dataRoot: dataRoot) else {
            return .object([
                "status": .string("disabled"),
                "reason": .string(MemoryPolicyGate.knowledgeGraphOffMessage),
            ])
        }
        let mode = curation.curationString(input, "mode") ?? "rebuild"
        guard ["rebuild", "sweep_orphans"].contains(mode) else {
            return curation.curationRefusal("mode must be rebuild or sweep_orphans.")
        }
        if mode == "sweep_orphans" {
            return await sweepKnowledgeGraphOrphans(input: input)
        }
        do {
            let report = try await memoryV2.reconcileKnowledgeGraphProjection()
            return .object([
                "status": .string("ok"),
                "report": .string(String(describing: report)),
            ])
        } catch {
            return .object(["status": .string("failed"), "reason": .string("\(error)")])
        }
    }

    /// The Knowledge Graph page's "Sweep orphans…": entities whose source
    /// memories are gone. No confirm_ids previews and removes nothing;
    /// confirm_ids removes only when it is still exactly the live candidate
    /// set, the same check the page's confirmation dialog makes.
    private func sweepKnowledgeGraphOrphans(input: [String: JSONValue]) async -> JSONValue {
        let actions = KnowledgeGraphMaintenanceActions(dataRoot: dataRoot)
        func candidateRows(_ candidates: [KnowledgeGraphGCCandidate]) -> JSONValue {
            .array(candidates.map {
                .object([
                    "id": .string($0.id),
                    "name": .string($0.name),
                    "type": .string($0.type),
                    "mentions": .int(Int64($0.mentionCount)),
                ])
            })
        }
        guard case .array(let rawIDs)? = input["confirm_ids"], !rawIDs.isEmpty else {
            do {
                let report = try await actions.previewOrphanSweep()
                return .object([
                    "status": .string("preview"),
                    "candidates": candidateRows(report.candidates),
                    "count": .int(Int64(report.candidates.count)),
                    "next": .string(report.candidates.isEmpty
                        ? "No orphaned entities; nothing to remove."
                        : "Nothing removed yet. To remove these, call rebuild_knowledge_graph mode sweep_orphans with confirm_ids set to all of these ids."),
                ])
            } catch {
                return .object(["status": .string("failed"), "reason": .string("Orphan sweep failed: \(error.localizedDescription)")])
            }
        }
        let ids = Set(rawIDs.compactMap { value -> String? in
            guard case .string(let id) = value else { return nil }
            return id
        })
        do {
            switch try await actions.applyOrphanSweep(expectedCandidateIDs: ids) {
            case let .applied(report):
                return .object([
                    "status": .string("ok"),
                    "entities_removed": .int(Int64(report.entitiesDeleted)),
                    "edges_removed": .int(Int64(report.edgesDeleted)),
                ])
            case let .previewDiverged(current):
                return .object([
                    "status": .string("refused"),
                    "reason": .string("The orphan set changed since the preview, so nothing was removed. Review these candidates and confirm again with exactly their ids."),
                    "candidates": candidateRows(current),
                    "count": .int(Int64(current.count)),
                ])
            }
        } catch {
            return .object(["status": .string("failed"), "reason": .string("Orphan sweep failed: \(error.localizedDescription)")])
        }
    }
}
