import Foundation
import CryptoKit
import KnowledgeGraph
import NativeAgentCore
import PersistenceCore
import ProviderRouting

extension REMConsolidator {
    // MARK: GROWTH.md eviction-to-KG

    /// Char-based eviction. When GROWTH.md exceeds `_REM_GROWTH_CHAR_CAP`,
    /// distil ~`_REM_GROWTH_EVICT_CHARS` of the oldest entries to a KG node
    /// and remove them from disk. The static preamble (everything before
    /// the first non-preamble `## ` heading or evidenced approved lesson) is
    /// ALWAYS preserved — without
    /// that guard we'd chop the file's title + intro. Returns the number
    /// of characters actually evicted (0 when the cap doesn't fire).
    func runGrowthEviction(proposalRows: [REMProposalRow]? = nil) async throws -> Int {
        let proposalRows = try proposalRows ?? REMProposalStore(dataRoot: dataRoot).loadAllForGrowthEviction()
        let growth = personaRoot.appendingPathComponent("GROWTH.md")
        guard FileManager.default.fileExists(atPath: growth.path) else { return 0 }

        // CROSS-PROCESS LOCK. Every other GROWTH writer (PersonaEngine
        // growth-journal appends, the daemon routes) serializes under the
        // same `<GROWTH.md>.lock` flock — but this read→splice→write used to
        // run bare, so an append landing mid-eviction was silently erased by
        // our atomic rewrite of the stale body. The whole read → compute →
        // (LLM distill) → KG merge → write now runs under withFileLock on
        // the GROWTH path. Holding the flock across the distill is fine:
        // eviction fires at most weekly and writers just wait on the lock.
        let persistence = SwiftNativePersistenceCore()
        return try await persistence.withFileLock(growth) {
            try await self.evictGrowthUnderLock(growth: growth, proposalRows: proposalRows)
        }
    }

    /// The locked critical section of `runGrowthEviction`. Must only be
    /// called while holding the GROWTH.md flock.
    private func evictGrowthUnderLock(growth: URL, proposalRows: [REMProposalRow]) async throws -> Int {
        // A FAILED READ IS NOT AN EMPTY FILE. The old `try?` turned an
        // unreadable GROWTH.md into "", and reconciliation below then found
        // every pending passage "missing from the body" and marked the lot
        // committed — permanent false rows in an append-only file. Let the read
        // throw: the pass aborts with nothing touched and the next tick retries.
        let body = try String(contentsOf: growth, encoding: .utf8)
        // REPAIR FIRST, BEFORE THE CAP CHECK. The splice below removes the
        // passage and only then appends the `committed` row; a crash between
        // the two leaves a pending row for a passage that is already gone, and
        // the cap check returns early on most passes, so nothing would ever fix
        // it. Reconciliation runs on every pass, under the GROWTH lock, against
        // the body we just read — the only moment the file's true contents and
        // the history are both in hand.
        await REMGrowthEvictionHistory.reconcilePending(
            growthBody: body,
            dataRoot: dataRoot,
            kgNodeExists: { [dataRoot] id in
                await Self.growthDistillationNodeExists(id: id, dataRoot: dataRoot)
            }
        )
        if body.count <= REMConstants._REM_GROWTH_CHAR_CAP { return 0 }

        // Find the preamble boundary: the start of the first "evictable"
        // entry. Preamble sections (the file title `# ...`, intro paragraphs,
        // and the static `## Conventions` block) MUST survive eviction.
        let preambleEnd = Self.preambleEndIndex(in: body)
        // Headingless lessons carry no delimiter distinguishing them from an
        // authored introduction. Use the approved feed (including its base)
        // as evidence of entry boundaries instead of guessing from blank lines.
        let approvedRows = proposalRows
            .filter { $0.status == "approved" && REMProposalStore.supportsProposalTarget($0.targetDoc) }
        let approvedLessons = approvedRows.map(\.proposalText)
        let lessonStarts = Self.approvedLessonStarts(in: body, lessons: approvedLessons)
        let evictableStart = min(preambleEnd, lessonStarts.first ?? body.endIndex)
        guard evictableStart < body.endIndex else { return 0 }

        // Walk headings and approved lesson starts from the evictable region until we
        // pass `_REM_GROWTH_EVICT_CHARS` worth of content. Evict everything
        // up to the next entry after the threshold so we never cut an
        // entry mid-paragraph. `nextEntryHeading` is INCLUSIVE — it would
        // re-return the current cursor — so we advance past it first.
        let target = REMConstants._REM_GROWTH_EVICT_CHARS
        var cursor = evictableStart
        var evicted = 0
        while evicted < target && cursor < body.endIndex {
            let searchFrom = body.index(after: cursor)
            // OVERSHOOT BOUND. When no further `## ` heading exists, the old
            // walk set cursor = endIndex and evicted the ENTIRE remaining
            // body in one pass. Cap the slice instead: cut at the first
            // newline AFTER the evict-chars target so the pass stays near
            // the configured size while still ending on a line boundary.
            if searchFrom >= body.endIndex {
                cursor = Self.boundedTailCut(in: body, from: evictableStart, target: target)
                break
            }
            let nextEntry = [
                Self.nextEntryHeading(in: body, after: searchFrom),
                lessonStarts.first(where: { $0 >= searchFrom }),
            ].compactMap { $0 }.min()
            guard let nextHeading = nextEntry else {
                cursor = Self.boundedTailCut(in: body, from: evictableStart, target: target)
                break
            }
            cursor = nextHeading
            evicted = body.distance(from: evictableStart, to: cursor)
        }
        if cursor == evictableStart { return 0 }

        let evictedSlice = String(body[evictableStart..<cursor])

        // FAIL CLOSED on distillation failure. The old shape was
        // `(try? distill) ?? stub-node`: the splice below still ran, so an
        // LLM outage permanently destroyed user-approved persona content into
        // a content-free "LLM unavailable" stub. A distill throw now aborts
        // this pass's eviction with the content still intact in GROWTH.md.
        let kgNode = try await distillToKGNode(evictedSlice)
        // ITEM 5 — KEEP THE EXACT PASSAGE. Written BEFORE the KG merge and the
        // GROWTH splice, under the same fail-closed rule as everything else in
        // this function: if the original cannot be retained, nothing is
        // destroyed. Same shape as the studio journal amendment — an append-only
        // sidecar holding the original beside what now stands — and it lives
        // under the DATA root, never the persona root, so the retained passage
        // cannot re-enter GROWTH.md or the compiled packet.
        //
        // PENDING FIRST, COMMITTED AFTER (2026-09-13). The record must be
        // written first — retention fails closed — but at this point nothing
        // has been evicted yet, and the cancellation check, the KG insert and
        // the splice below can all still abort the pass. This file is
        // append-only and id-deduped, so a row that says "evicted" here and
        // then doesn't happen is a permanent lie about her past. The row goes
        // down as `pending`; the `committed` row is appended only after the
        // splice actually lands, and a reader treats pending-without-committed
        // as RETAINED, NOT EVICTED.
        let historyRecord = REMGrowthEvictionRecord(
            id: kgNode.id,
            evictedAt: kgNode.createdAt,
            summary: kgNode.summary,
            passage: evictedSlice,
            sourceLines: kgNode.sourceLines,
            proposalRefs: Self.proposalRefs(in: evictedSlice, rows: approvedRows),
            state: .pending
        )
        try await REMGrowthEvictionHistory.append(historyRecord, dataRoot: dataRoot)
        // A cancel during the distill above (its own LLM call) must not fall
        // through to the KG+GROWTH commit pair below. One guard here covers both
        // writes: the KG-first ordering means a throw leaves GROWTH.md intact and
        // the KG untouched.
        try Task.checkCancellation()
        // KG-FIRST ORDERING. The GROWTH splice and the KG merge must succeed
        // TOGETHER or NEITHER. Previously the KG append was best-effort and the
        // GROWTH splice unconditionally followed, so a missing/malformed KG file
        // could leave the slice gone from GROWTH and never landed in KG —
        // PERMANENT DATA LOSS. Now `appendKGNode` THROWS on any failure (no
        // store, unreadable store, write failure), and we let that throw
        // propagate out of `runWeeklyREM`. The cap pressure stays high until the
        // store is healthy again. That is
        // strictly better than silently shredding the user's growth notes.
        try await appendKGNode(kgNode)

        // Splice the evicted section out, leaving the preamble + remainder.
        // ONLY reached when the KG merge above succeeded.
        var rebuilt = String(body[..<evictableStart])
        rebuilt += String(body[cursor...])
        try rebuilt.data(using: .utf8)!.write(to: growth, options: .atomic)
        // The splice landed: NOW the eviction is true, and the history may say
        // so. A failure here leaves the pending row standing — the passage is
        // retained and the record still doesn't overclaim.
        var committed = historyRecord
        committed.state = .committed
        try await REMGrowthEvictionHistory.append(committed, dataRoot: dataRoot)
        return evictedSlice.count
    }

    /// Bounded cut for the no-more-headings tail: the first index AFTER the
    /// first newline past `start + target` characters. Falls back to
    /// `endIndex` when the remaining body is shorter than the target or
    /// carries no trailing newline (evicting it all is within the bound).
    fileprivate static func boundedTailCut(
        in body: String,
        from start: String.Index,
        target: Int
    ) -> String.Index {
        guard let targetIdx = body.index(start, offsetBy: target, limitedBy: body.endIndex),
              targetIdx < body.endIndex else {
            return body.endIndex
        }
        guard let newline = body[targetIdx...].firstIndex(of: "\n") else {
            return body.endIndex
        }
        return body.index(after: newline)
    }

    /// Returns the index where the static preamble ends and the first
    /// evictable entry begins. The preamble convention (see persona/GROWTH.md):
    ///   `# GROWTH.md ...` title
    ///   one or more intro paragraphs
    ///   `## Conventions` block
    /// Everything from the FIRST `## ` heading whose title is NOT
    /// "Conventions" onward is evictable.
    fileprivate static func preambleEndIndex(in body: String) -> String.Index {
        var cursor = body.startIndex
        while cursor < body.endIndex {
            guard let heading = nextEntryHeading(in: body, after: cursor) else {
                return body.endIndex
            }
            let lineEnd = body[heading...].firstIndex(of: "\n") ?? body.endIndex
            let title = body[heading..<lineEnd]
                .replacingOccurrences(of: "## ", with: "")
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            if title == "conventions" {
                cursor = lineEnd
                continue
            }
            return heading
        }
        return body.endIndex
    }

    /// Exact standalone paragraphs, using the writer's line-boundary contract.
    /// Text without approval evidence remains part of the authored preamble.
    private static func approvedLessonStarts(in body: String, lessons: [String]) -> [String.Index] {
        var starts = Set<String.Index>()
        for lesson in lessons {
            let text = lesson.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var searchFrom = body.startIndex
            while let range = body.range(of: text, range: searchFrom..<body.endIndex) {
                let startsLine = range.lowerBound == body.startIndex
                    || body[body.index(before: range.lowerBound)] == "\n"
                let endsLine = range.upperBound == body.endIndex || body[range.upperBound] == "\n"
                if startsLine && endsLine { starts.insert(range.lowerBound) }
                searchFrom = range.upperBound
            }
        }
        return starts.sorted()
    }

    /// Find the start index of the next `## ` heading at or after `from`.
    /// Matches at column 0 only (not inside code blocks or quoted text).
    fileprivate static func nextEntryHeading(
        in body: String,
        after from: String.Index
    ) -> String.Index? {
        var cursor = from
        while cursor < body.endIndex {
            // Headings start at column 0. Find the next newline, then
            // check whether the line after it begins with "## ".
            if cursor == body.startIndex || body[body.index(before: cursor)] == "\n" {
                let tail = body[cursor...]
                if tail.hasPrefix("## ") && !tail.hasPrefix("### ") {
                    return cursor
                }
            }
            cursor = body.index(after: cursor)
        }
        return nil
    }

    private struct KGNode: Codable {
        let id: String
        let summary: String
        let sourceLines: Int
        let createdAt: String
    }

    /// The approved proposals whose text sits inside this evicted slice — the
    /// approvals the retained passage came in by. Read-only over rows the store
    /// already holds; nothing new is persisted here.
    fileprivate static func proposalRefs(
        in slice: String,
        rows: [REMProposalRow]
    ) -> [REMGrowthEvictionProposalRef] {
        rows.compactMap { row in
            let text = row.proposalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, slice.contains(text) else { return nil }
            return REMGrowthEvictionProposalRef(
                proposalId: row.id,
                targetDoc: row.targetDoc,
                createdAt: row.createdAt,
                approvalId: row.approvalId,
                evidenceDates: row.evidenceDates
            )
        }
    }

    private func distillToKGNode(_ text: String) async throws -> KGNode {
        let prompt = """
        Distill the following evicted GROWTH-doc slice into ONE compressed
        knowledge-graph node summary (<=400 chars). Return plain text only.

        ---
        \(text)
        """
        // This IS REM work — weekly GROWTH eviction runs inside the REM cycle —
        // so it resolves through `rem` (Memory and mind), the same surface the
        // rest of this consolidator uses. It was asking `training` (Work), which
        // spent the Work group's account on a memory task (2026-09-13 review).
        let pickedModel = await router.modelStringForSurface("rem")
        let raw = try await llm.complete(
            prompt: prompt, system: nil, model: pickedModel, surface: "rem"
        )
        let summary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // User, 2026-09-06: an empty model response is a FAILURE, not a node.
        // The old `summary.isEmpty ? "empty distillation" : summary` minted a
        // content-free node that passed the KG writer's nonempty check, so the
        // caller went on to splice the source slice out of GROWTH.md — the
        // user's growth text destroyed and replaced by the literal string
        // "empty distillation". Reachable whenever the adapter returns ""
        // (OpenAIAdapter.parseCompletion does, for an empty completion).
        // Throwing here aborts the eviction with GROWTH.md intact.
        guard !summary.isEmpty else {
            throw NSError(
                domain: "REMConsolidator",
                code: -210,
                userInfo: [NSLocalizedDescriptionKey:
                    "GROWTH distillation returned an empty summary; refusing to "
                    + "evict the source slice."]
            )
        }
        let id = Self.growthDistillationID(text)
        return KGNode(
            // Stable over the source slice, not the model summary. If the KG
            // commit succeeds but the following GROWTH.md splice fails, the
            // next pass upserts this same entity instead of minting a duplicate.
            id: id,
            // THE NODE POINTS AT THE ORIGINAL. The id is already shared with the
            // retained-passage record, but a compressed node whose pointer is an
            // unwritten convention is a node nobody expands — so it says where
            // the full passage is, in both the SQLite and legacy-JSON paths.
            summary: summary + "\n\n" + REMGrowthEvictionHistory.pointer(id: id),
            sourceLines: text.split(separator: "\n").count,
            createdAt: isoNow()
        )
    }

    private static func growthDistillationID(_ source: String) -> String {
        let digest = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "growth_\(digest)"
    }

    /// Corroborating identity for a reconciled eviction: the distilled node
    /// carrying the record's id in the graph (memory.sqlite). Any failure
    /// reads as "not present" — reconciliation then leaves the row pending,
    /// which is the safe side.
    fileprivate static func growthDistillationNodeExists(id: String, dataRoot: URL) async -> Bool {
        let sqliteURL = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("memory.sqlite")
        guard let indexer = try? SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqliteURL),
              let exists = try? await indexer.growthDistillationExists(id: id) else {
            return false
        }
        return exists
    }

    /// Merge a GROWTH-eviction distillation node into the graph in
    /// memory.sqlite. THROWS on any failure (no store yet included), and the
    /// caller (`runGrowthEviction`) must NOT splice the GROWTH.md slice unless
    /// this call succeeded — otherwise the slice would be gone from both
    /// GROWTH and the graph.
    private func appendKGNode(_ node: KGNode) async throws {
        let kgDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
        let indexer = try SwiftNativeKnowledgeGraphIndexer(
            memorySQLitePath: kgDir.appendingPathComponent("memory.sqlite")
        )
        try await indexer.upsertGrowthDistillation(
            id: node.id,
            summary: node.summary,
            sourceLines: node.sourceLines,
            createdAt: node.createdAt,
            // The graph's own one-time legacy import source; a no-op once
            // `.kg_migrated_to_sqlite_v1` stands.
            legacyJSONPath: kgDir.appendingPathComponent("knowledge_graph.json")
        )
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: clock())
    }
}
