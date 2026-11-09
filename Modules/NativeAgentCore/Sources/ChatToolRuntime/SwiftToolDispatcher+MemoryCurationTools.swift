import AgentConversations
import ChatTurnContracts
import Foundation
import Context
import MemoryV2
import NativeAgentCore
import PersistenceCore
// Blueprint: | `SwiftToolDispatcher+MemoryCurationTools.swift` | `MemoryCuration`: `listMemories`, `rewriteMemory` restates roots and writes nothing when the memory already reads that way (a read steers nothing); `rewriteTarget` shares read-only preview validation; `SwiftToolDispatcher`: `impl_forget_memory`, `impl_rebuild_knowledge_graph` |


/// Share the Memories page’s owner and store so curation cannot diverge across doors.
public struct MemoryCuration: Sendable {
    static func missingMemoryFailure() -> ToolFailureError {
        ToolFailureError("No memory has that id.", effects: .none,
            nextCall: ToolFailureError.call("app", ["action": .string("memory.list")]),
            code: "memory_not_found", status: .refused,
            instruction: "Choose an existing id from memory.list.", recovery: .inspect)
    }

    let memoryV2: SwiftNativeMemoryV2
    let dataRoot: URL

    public init(memoryV2: SwiftNativeMemoryV2, dataRoot: URL) {
        self.memoryV2 = memoryV2
        self.dataRoot = dataRoot
    }

    /// How the agent knows a memory, restated whole: one telling per root, each {how, by?, since?}. The agent's unsteered roots become these; roots
    /// a principal the person does not trust steered stay as they are.
    func statedRoots(_ input: [String: JSONValue]) throws -> [MemoryRoot.Telling]? {
        let accepted = "roots: [{how: \(MemoryRoot.How.stated.map(\.rawValue).joined(separator: "|")), by?, since?}], at least one"
        switch input["roots"] {
        case nil, .null?: return nil
        case .array(let items)? where !items.isEmpty:
            return try items.enumerated().map { index, item in
                let path = "roots[\(index)]"
                guard case .object(let fields) = item, Set(fields.keys).isSubset(of: ["how", "by", "since"]) else {
                    throw ToolFailureError("\(path) must be an object with how, and by and since if they apply.", argumentPath: path,
                        accepted: accepted, effects: .none, code: "memory_roots_invalid", status: .refused,
                        instruction: "Correct \(path) in memory.rewrite.", recovery: .correctArguments)
                }
                guard let telling = try SwiftToolDispatcher.telling(how: fields["how"], by: fields["by"], since: fields["since"],
                    names: (path + ".how", path + ".by", path + ".since")), telling.how != .kept else {
                    throw ToolFailureError("\(path) needs how.", argumentPath: path + ".how", accepted: accepted, effects: .none,
                        code: "memory_provenance_required", status: .refused, instruction: "Name how you know it in \(path).how.",
                        recovery: .correctArguments)
                }
                return telling
            }
        default:
            throw ToolFailureError("roots must be a nonempty list.", argumentPath: "roots", accepted: accepted, effects: .none,
                code: "memory_roots_invalid", status: .refused, instruction: "Correct roots in memory.rewrite, or omit it.",
                recovery: .correctArguments)
        }
    }

    /// Why a rewrite wrote nothing, in words that match what is stored. A restatement leaves every root a door carried as it is (so a change of
    /// trust can bring its steer back), and a telling from the same source on the same day is the root already held.
    static func unchangedNote(_ metadata: JSONValue?, restated: Bool, trust: PeerDataTaint.TrustRead) -> String {
        guard restated, case .held(let roots) = MemoryRoot.reading(metadata) else { return "It already reads this way; nothing was written." }
        let doors = Array(Set(roots.flatMap(\.through))).sorted().map { trust.sourceName($0) ?? $0 }
        guard !doors.isEmpty else {
            return "Nothing was written: each root you stated is one this memory already holds, from the same source on the same day."
        }
        return "Nothing was written: roots carried through " + doors.joined(separator: ", ") + " stay as they are whatever a rewrite states, so a "
            + "change of trust can bring their steer back, and a telling from the same source on the same day is the root already held."
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
            // Int(d) traps on NaN, infinity and values outside Int's range.
            guard d.isFinite, abs(d) < 1e15 else { return nil }
            return Int(d)
        default: return nil
        }
    }

    /// The paging cursor carries its sort direction and the ordering key of the last row handed out. Opaque to the caller; returned as `after_id`.
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
        .object(["status": .string("refused"), "reason": .string(reason),
            "execution": .string("not_run"), "effects": .string("none")])
    }

    public func listMemories(input: [String: JSONValue], surface: String, persona: String?) async throws -> JSONValue {
        for key in ["sort", "status", "after_id"] {
            if let value = input[key], value != .null {
                guard case .string(let raw) = value, !raw.isEmpty,
                      raw == raw.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return curationRefusal("\(key) must be a nonempty current string; omit after_id to start a fresh page.")
                }
            }
        }
        let offset = max(0, curationInt(input, "offset") ?? 0)
        let limit = min(100, max(1, curationInt(input, "limit") ?? 50))
        let sort = curationString(input, "sort") ?? "newest_first"
        guard ["newest_first", "oldest_first"].contains(sort) else {
            return curationRefusal("sort must be newest_first or oldest_first; keep the same sort when following next_after_id.")
        }
        let status = curationString(input, "status") ?? "active"
        guard ["active", "archived"].contains(status) else {
            return curationRefusal("status must be active or archived.")
        }
        let afterID = curationString(input, "after_id")
        let cursor = afterID.flatMap { Self.curationCursorKey($0) }
        if afterID != nil {
            guard let cursor else {
                return curationRefusal("""
                    after_id is not a memory.list cursor: it lacks a recognized sort direction. Restart memory.list without after_id and with \
                    offset 0, choosing newest_first or oldest_first in sort.
                    """)
            }
            guard cursor.sort == sort else {
                return curationRefusal("""
                    after_id was issued with sort \(cursor.sort). Retry with sort \(cursor.sort), or restart without after_id and with offset 0 \
                    to change direction.
                    """)
            }
        }
        let listing: (records: [MemoryRecord], total: Int, nextOffset: Int)
        do {
            listing = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot).curationPage(
                archived: status == "archived", kind: curationString(input, "kind"), surface: surface, persona: persona,
                newestFirst: sort == "newest_first", afterKey: cursor?.key, offset: offset, limit: limit
            )
        } catch {
            return SwiftToolDispatcher.memoryFailure(error)
        }
        let page = listing.records
        let trust = MemoryDataProvenance.reading(page.map(\.extras))
        let rows: [JSONValue] = page.map { record in
            var row: [String: JSONValue] = [
                "id": .string(record.id),
                "text": .string(record.text),
                "created_at": .string(record.createdAt),
            ]
            row.merge(MemoryDataProvenance.fields(in: record.extras, trust: trust)) { _, value in value }
            row["roots"] = MemoryDataProvenance.rootsJSON(record.extras, trust: trust)
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
                // Show retirement evidence: a corrected row can still have active status and otherwise read as current.
                let corrected = MemoryLifecycle.normalized(record.lifecycle) == MemoryLifecycle.corrected
                row["status"] = .string(corrected ? MemoryLifecycle.corrected : "archived")
                if case .object(let meta)? = record.extras {
                    if case .string(let v)? = meta["superseded_by"] {
                        row["replaced_by"] = .string(v)
                        row["superseded_by"] = .string(v)
                    }
                    if case .string(let v)? = meta["correction_reason"] { row["archived_because"] = .string(v) }
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
            "has_more": .bool(next < listing.total),
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
            throw ToolFailureError("memory.rewrite needs a memory id.", argumentPath: "id", accepted: "an id from memory.list",
                effects: .none, nextCall: ToolFailureError.call("app", ["action": .string("memory.list")]),
                code: "memory_id_required", status: .refused, instruction: "Choose the id to rewrite.", recovery: .correctArguments)
        }
        let text = curationString(input, "text")
        let pinned = curationBool(input, "pinned")
        let restore = curationBool(input, "restore") == true
        let roots = try statedRoots(input)
        guard text != nil || pinned != nil || restore || roots != nil else {
            throw ToolFailureError("memory.rewrite needs a change.", argumentPath: "text / pinned / restore / roots",
                accepted: "text: nonempty string; pinned: true or false; restore: true; roots: [{how, by?, since?}]",
                effects: .none, nextCall: ToolFailureError.call("app", ["find": .string("memory.rewrite")]),
                code: "memory_rewrite_change_required", status: .refused,
                instruction: "Supply text, pinned, restore or roots in memory.rewrite.", recovery: .correctArguments)
        }
        let row: MemoryRecord?
        do {
            row = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
                .memory(id: id).map(MemoryRecord.init(stored:))
        } catch let error as CancellationError {
            throw error
        } catch let error as ToolFailureError {
            throw error
        } catch let error as MemoryStorageError {
            throw error.failure
        } catch let error as MemoryV2Error {
            throw error.failure
        } catch {
            throw ToolFailureError("Memory store read failed: \(error.localizedDescription)", effects: .none,
                owner: "memory store", nextCall: ToolFailureError.call("app", ["page": .string("memories")]),
                code: "memory_store_read_failed",
                instruction: "Inspect memory diagnostics and repair the reported read error; this is not an absent record.")
        }
        guard let row else {
            throw Self.missingMemoryFailure()
        }
        guard let disclosure = MemoryRecordDisclosurePolicy.classify(
            personaID: row.personaId, status: MemoryStorage.isRecoverable(row) ? "active" : row.status,
            lifecycle: MemoryStorage.isRecoverable(row) ? nil : row.lifecycle,
            tags: row.tags, metadata: row.extras
        ) else {
            throw ToolFailureError("This memory is not eligible for disclosure.", effects: .none,
                code: "memory_disclosure_unavailable", status: .refused,
                instruction: "Leave this record unchanged; its lifecycle or disclosure metadata excludes it.", recovery: .terminal)
        }
        if !disclosure.permits(surface: surface, personaID: persona) {
            throw ToolFailureError("This memory is not allowed for this conversation's surface or identity.", effects: .none,
                code: "memory_disclosure_denied", status: .refused,
                instruction: "Leave this record unchanged; do not bypass its disclosure policy.", recovery: .terminal)
        }
        if restore, !MemoryStorage.isRecoverable(row) {
            throw ToolFailureError("This memory is not archived, corrected or graduated; there is nothing to restore.", effects: .none,
                nextCall: ToolFailureError.call("app", ["action": .string("memory.list"), "args": .object(["status": .string("archived")])]),
                code: "memory_restore_ineligible", status: .refused,
                instruction: "Choose a recoverable memory from memory.list status archived.", recovery: .inspect)
        }
        // The pin writer refuses the same way; asking first lets a preview say so.
        if pinned == true, let refusal = UserMDGenerator.pinFailure(kind: row.memoryKind) {
            throw refusal
        }
        return row
    }

    /// Rewrite through the owner to preserve identity/provenance and recompute embeddings in one update.
    public func rewriteMemory(turn: Turn, invocation: ChatToolInvocation, input: [String: JSONValue], surface: String,
        persona: String?) async throws -> JSONValue {
        let row: MemoryRecord
        do { row = try await rewriteTarget(input: input, surface: surface, persona: persona) }
        catch {
            guard case .object(var failure) = SwiftToolDispatcher.memoryFailure(error) else { throw error }
            failure["execution"] = .string("not_run")
            failure["effects"] = .string("none")
            return .object(failure)
        }
        let text = curationString(input, "text")
        let pinned = curationBool(input, "pinned")
        let restore = curationBool(input, "restore") == true
        let roots: [MemoryRoot.Telling]?
        do { roots = try statedRoots(input) } catch { return SwiftToolDispatcher.memoryFailure(error) }
        // The teller of words a peer steered is the door that carried them, the one rule memory.commit keeps; the agent's own turn names any teller.
        if roots != nil, let refusal = PeerDataTaintDispatcher.provenanceRefusal(
            tool: "rewrite_memory", input: input, surface: surface, turn: turn, peerStore: AgentPeerStore(dataRoot: dataRoot)) {
            return SwiftToolDispatcher.memoryFailure(ToolFailureError(refusal, argumentPath: "roots", effects: .none,
                code: "memory_teller_steered", status: .refused,
                instruction: "Restate each root as told by the door that started this turn, without since, or leave how you know it as it is.",
                recovery: .correctArguments))
        }
        // The steer is the one fact outside the agent's say: words an untrusted agent steered, in this turn or in the memory's own roots, are never
        // restated as the agent's own past.
        // New wording is the agent's observation. The store's one root constructor attributes untrusted steering to its teller, as on commit;
        // trusted principals remain recorded without turning the agent's own words into their telling. Unchanged words and metadata edits add none.
        let context = MemoryWriteContext(turn: turn, senseReads: invocation.senseRead?.senseReads ?? invocation.senseReads,
                                         telling: text == nil ? nil : MemoryRoot.Telling(how: .noticed))
        let trust = MemoryDataProvenance.reading([row.extras], principals: context.through)
        let steer = MemoryDataProvenance.steering(context.through, trust: trust) + MemoryDataProvenance.sources(in: row.extras, trust: trust)
        if !steer.isEmpty, let restating = roots?.firstIndex(where: \.restatesOwnPast) {
            let who = Array(Set(steer)).sorted().joined(separator: ", ")
            return SwiftToolDispatcher.memoryFailure(ToolFailureError("""
                These words came through \(who), so they stay its telling, dated when it told you. How and since when you know your own past is \
                restated only for words no untrusted agent steered, in a turn none started.
                """, argumentPath: "roots[\(restating)]", effects: .none,
                code: "memory_restatement_steered", status: .refused,
                instruction: "Leave this memory as it is, or restate that root as told by \(steer[0]) without since.", recovery: .correctArguments))
        }
        var update: [String: JSONValue] = [:]
        if let text { update["text"] = .string(text) }
        if let pinned { update["pinned"] = .bool(pinned) }
        if restore {
            update["status"] = .string("active")
            if !MemoryLifecycle.isRecallEligible(row.lifecycle) {
                update["lifecycle"] = .string(MemoryLifecycle.confirmed)
            }
            // Restore passes the text back through the gates a rewrite runs: re-embedded, and refused when it matches something forgotten or let go (an
            // archived twin of a forgotten fact stays archived).
            if text == nil { update["text"] = .string(row.text) }
        }
        do {
            let (updated, changed) = try await memoryV2.updateMemory(id: row.id, update: .object(update), restating: roots, context: context)
            // A write may introduce principals: read the committed row afresh, independently of its effect-time gate.
            let resultTrust = MemoryDataProvenance.reading([updated.extras])
            var result: [String: JSONValue] = [
                "status": .string("ok"),
                // A rewrite whose words and roots end as stored writes nothing and adds no root.
                "changed": .bool(changed),
                "id": .string(updated.id),
                "text": .string(updated.text),
                "pinned": .bool(updated.pinned == true),
                "memory_status": .string(updated.status ?? "active"),
                "since": MemoryDataProvenance.firstKnown(updated.extras, trust: resultTrust).map(JSONValue.string) ?? .null,
                "provenance": .string(MemoryDataProvenance.lead(updated.extras, trust: resultTrust)),
                "roots": MemoryDataProvenance.rootsJSON(updated.extras, trust: resultTrust),
            ]
            if !changed { result["note"] = .string(Self.unchangedNote(updated.extras, restated: roots != nil, trust: resultTrust)) }
            result.merge(MemoryDataProvenance.fields(in: updated.extras, trust: resultTrust)) { _, value in value }
            return .object(result)
        } catch MemoryV2Error.recordNotFound {
            return ChatToolOutcome.failure(error: ToolFailureError(
                "The memory disappeared before the rewrite.", effects: .none,
                nextCall: ToolFailureError.call("app", ["action": .string("memory.list")]),
                code: "memory_not_found", instruction: "Read memory.list before choosing another id.", recovery: .inspect))
        } catch {
            return SwiftToolDispatcher.memoryFailure(error)
        }
    }
}

extension SwiftToolDispatcher {
    private var curation: MemoryCuration { MemoryCuration(memoryV2: memoryV2, dataRoot: dataRoot) }

    /// Drop one memory for good. A tombstone keeps the same thing from being re-proposed.
    func impl_forget_memory(input: [String: JSONValue]) async throws -> JSONValue {
        guard let id = curation.curationString(input, "id") else {
            return curation.curationRefusal("forget_memory needs the memory 'id' from app memory.list or recall_memory.")
        }
        do {
            let deleted = try await memoryV2.deleteMemoryIfPresent(id: id)
            guard deleted else {
                return Self.memoryFailure(MemoryCuration.missingMemoryFailure())
            }
            return .object(["status": .string("ok"), "id": .string(id)])
        } catch {
            return Self.memoryFailure(error)
        }
    }

    /// Re-derive after curation so entities from rewritten or forgotten rows cannot linger.
    func impl_rebuild_knowledge_graph(input: [String: JSONValue]) async throws -> JSONValue {
        // Disabled graph and damaged Trust are distinct checked causes.
        if let failure = MemoryPolicyGate.knowledgeGraphFailure(dataRoot: dataRoot) {
            return ChatToolOutcome.failure(error: failure)
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
            return Self.memoryFailure(error)
        }
    }

    /// Preview removes nothing; confirmation must still match the live orphan set the page would confirm.
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
                return Self.memoryFailure(error)
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
                    "reason": .string("""
                        The orphan set changed since the preview, so nothing was removed. Review these candidates and confirm again with exactly \
                        their ids.
                        """),
                    "candidates": candidateRows(current),
                    "count": .int(Int64(current.count)),
                ])
            }
        } catch {
            return Self.memoryFailure(error)
        }
    }
}
