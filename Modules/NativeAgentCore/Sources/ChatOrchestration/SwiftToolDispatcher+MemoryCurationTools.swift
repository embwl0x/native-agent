import Foundation
import MemoryV2
import PersistenceCore

// User, 2026-09-05: "make it so she can do it." The agent's memory tools were
// recall, commit and moment review; there was no way to walk the whole store,
// rewrite a row to what it means, or drop one, short of the Memories page's
// buttons. These three ride the same owner calls that page uses
// (SwiftNativeMemoryV2.updateMemory re-embeds when the text changes and gates
// against tombstones; deleteMemoryIfPresent tombstones and republishes the
// derived state). They touch only the agent's own store.
extension SwiftToolDispatcher {
    private func curationString(_ input: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let s)? = input[key] else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func curationInt(_ input: [String: JSONValue], _ key: String) -> Int? {
        switch input[key] {
        case .int(let i)?: return Int(i)
        case .double(let d)?:
            // Int(d) traps on NaN, infinity and anything past Int's range
            // (Codex review 2026-09-05: list_memories offset 1e100 crashed
            // the app instead of refusing).
            guard d.isFinite, abs(d) < 1e15 else { return nil }
            return Int(d)
        default: return nil
        }
    }

    /// The paging cursor: the ordering key of the last row handed out,
    /// `created_at` and id joined by the one character an ISO-8601 timestamp
    /// cannot contain. Opaque to the caller — it only ever comes back as
    /// `after_id`.
    private static func curationCursor(createdAt: String, id: String) -> String {
        "\(createdAt)|\(id)"
    }

    /// Split a cursor back into its ordering key; nil when the value is a bare
    /// memory id rather than a cursor.
    private static func curationCursorKey(_ raw: String) -> (String, String)? {
        guard let separator = raw.firstIndex(of: "|") else { return nil }
        let createdAt = String(raw[raw.startIndex..<separator])
        let id = String(raw[raw.index(after: separator)...])
        guard !createdAt.isEmpty, !id.isEmpty else { return nil }
        return (createdAt, id)
    }

    private func curationRefusal(_ reason: String) -> JSONValue {
        .object(["status": .string("refused"), "reason": .string(reason)])
    }

    /// Every active memory, oldest first, in pages. The walk User asked for
    /// starts at offset 0 and ends when `remaining` is 0.
    func impl_list_memories(input: [String: JSONValue]) async throws -> JSONValue {
        let offset = max(0, curationInt(input, "offset") ?? 0)
        let limit = min(100, max(1, curationInt(input, "limit") ?? 50))
        let all: [MemoryRecord]
        do {
            all = try await memoryV2.listMemory(kind: curationString(input, "kind"))
        } catch {
            return .object(["status": .string("failed"), "reason": .string("\(error)")])
        }
        // "Every active memory": the owner's list includes archived rows, so
        // filter here (reviewer, 2026-09-05).
        // (created_at, id) is the ordering key: created_at alone is not
        // unique, and the cursor below compares against it.
        let ordered = all
            .filter { ($0.status ?? "active") == "active" }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        // A cursor is safer than an offset while the agent forgets rows as it
        // walks: rows shift under an offset, never behind an id (Codex review
        // 2026-09-05). `after_id` wins when both are given.
        //
        // 2026-09-06: the cursor is a POSITION, not a row that must still be
        // there. Resolving it by presence meant forgetting the last row of a
        // page silently dropped back to `offset` (0), so a walk that curated as
        // it went restarted at the top forever. `next_after_id` now hands back
        // the ordering key, and a page resumes after the position that key
        // occupies whether or not its row survives.
        let afterID = curationString(input, "after_id")
        let start: Int = {
            guard let afterID else { return offset }
            if let key = Self.curationCursorKey(afterID) {
                return ordered.prefix(while: { ($0.createdAt, $0.id) <= key }).count
            }
            // A bare id (from recall_memory, or a cursor minted before this
            // change) still resumes while its row is there.
            if let idx = ordered.firstIndex(where: { $0.id == afterID }) { return idx + 1 }
            return offset
        }()
        let page = ordered.dropFirst(start).prefix(limit)
        let rows: [JSONValue] = page.map { record in
            var row: [String: JSONValue] = [
                "id": .string(record.id),
                "text": .string(record.text),
                "created_at": .string(record.createdAt),
            ]
            if let kind = record.memoryKind { row["kind"] = .string(kind) }
            if let status = record.status { row["status"] = .string(status) }
            if let source = record.sourceRunId { row["source"] = .string(source) }
            if record.pinned == true { row["pinned"] = .bool(true) }
            return .object(row)
        }
        let next = start + rows.count
        var out: [String: JSONValue] = [
            "status": .string("ok"),
            "memories": .array(rows),
            "count": .int(Int64(rows.count)),
            "total": .int(Int64(ordered.count)),
            "next_offset": .int(Int64(next)),
            "remaining": .int(Int64(max(0, ordered.count - next))),
        ]
        if let last = page.last {
            out["next_after_id"] = .string(Self.curationCursor(createdAt: last.createdAt, id: last.id))
        }
        return .object(out)
    }

    /// Replace one memory's text with what it means. Same row, same id, same
    /// provenance; the embedding is recomputed by the owner.
    func impl_rewrite_memory(input: [String: JSONValue]) async throws -> JSONValue {
        guard let id = curationString(input, "id") else {
            return curationRefusal("rewrite_memory needs the memory 'id' from list_memories or recall_memory.")
        }
        guard let text = curationString(input, "text") else {
            return curationRefusal("rewrite_memory needs 'text': the thing itself, one or two sentences.")
        }
        do {
            let updated = try await memoryV2.updateMemory(id: id, update: .object(["text": .string(text)]))
            return .object([
                "status": .string("ok"),
                "id": .string(updated.id),
                "text": .string(updated.text),
            ])
        } catch MemoryV2Error.recordNotFound {
            return .object(["status": .string("failed"), "reason": .string("No memory with that id.")])
        } catch {
            return .object(["status": .string("failed"), "reason": .string("\(error)")])
        }
    }

    /// Drop one memory for good. A tombstone keeps the same thing from being
    /// re-proposed.
    func impl_forget_memory(input: [String: JSONValue]) async throws -> JSONValue {
        guard let id = curationString(input, "id") else {
            return curationRefusal("forget_memory needs the memory 'id' from list_memories or recall_memory.")
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
}
