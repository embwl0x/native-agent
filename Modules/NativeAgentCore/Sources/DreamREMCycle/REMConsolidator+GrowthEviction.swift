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
    func runGrowthEviction() async throws -> Int {
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
            try await self.evictGrowthUnderLock(growth: growth)
        }
    }

    /// The locked critical section of `runGrowthEviction`. Must only be
    /// called while holding the GROWTH.md flock.
    private func evictGrowthUnderLock(growth: URL) async throws -> Int {
        let body = (try? String(contentsOf: growth, encoding: .utf8)) ?? ""
        if body.count <= REMConstants._REM_GROWTH_CHAR_CAP { return 0 }

        // Find the preamble boundary: the start of the first "evictable"
        // entry. Preamble sections (the file title `# ...`, intro paragraphs,
        // and the static `## Conventions` block) MUST survive eviction.
        let preambleEnd = Self.preambleEndIndex(in: body)
        // Headingless lessons carry no delimiter distinguishing them from an
        // authored introduction. Use the approved feed (including its base)
        // as evidence of entry boundaries instead of guessing from blank lines.
        let approvedLessons = REMProposalStore(dataRoot: dataRoot).loadAll()
            .filter { $0.status == "approved" && REMProposalStore.supportsProposalTarget($0.targetDoc) }
            .map(\.proposalText)
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
        // this pass's eviction (propagates out of `runWeeklyREM`, whose
        // marker-restore defer makes the next weekly tick retry) with the
        // content still intact in GROWTH.md.
        let kgNode = try await distillToKGNode(evictedSlice)
        // A cancel during the distill above (its own LLM call) must not fall
        // through to the KG+GROWTH commit pair below. One guard here covers both
        // writes: the KG-first ordering means a throw leaves GROWTH.md intact and
        // the KG untouched, and it propagates to the marker-restore `catch` so the
        // eviction retries on the next tick.
        try Task.checkCancellation()
        // KG-FIRST ORDERING. The GROWTH splice and the KG merge must succeed
        // TOGETHER or NEITHER. Previously the KG append was best-effort and the
        // GROWTH splice unconditionally followed, so a missing/malformed KG file
        // could leave the slice gone from GROWTH and never landed in KG —
        // PERMANENT DATA LOSS. Now `appendKGNode` THROWS on any fail-closed
        // skip (file missing, wrong top-level shape, broken sub-shape, encode
        // failure), and we let that throw propagate out of `runWeeklyREM`. The
        // GROWTH eviction RETRIES on the next REM tick. Worst case: the cap
        // pressure stays high until the operator fixes the KG file. That is
        // strictly better than silently shredding the user's growth notes.
        try await appendKGNode(kgNode)

        // Splice the evicted section out, leaving the preamble + remainder.
        // ONLY reached when the KG merge above succeeded.
        var rebuilt = String(body[..<evictableStart])
        rebuilt += String(body[cursor...])
        try rebuilt.data(using: .utf8)!.write(to: growth, options: .atomic)
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

    private func distillToKGNode(_ text: String) async throws -> KGNode {
        let prompt = """
        Distill the following evicted GROWTH-doc slice into ONE compressed
        knowledge-graph node summary (<=400 chars). Return plain text only.

        ---
        \(text)
        """
        // Per-surface picker: use the model picked for the "training" surface
        // (GROWTH-doc distillation is a training-tier task). nil falls back
        // to the surface seed inside SwiftNativeLLMClient.
        let pickedModel = await router.modelStringForSurface("training")
        let raw = try await llm.complete(
            prompt: prompt, system: nil, model: pickedModel, surface: "training"
        )
        let summary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // User, 2026-09-06: an empty model response is a FAILURE, not a node.
        // The old `summary.isEmpty ? "empty distillation" : summary` minted a
        // content-free node that passed the KG writer's nonempty check, so the
        // caller went on to splice the source slice out of GROWTH.md — the
        // user's growth text destroyed and replaced by the literal string
        // "empty distillation". Reachable whenever the adapter returns ""
        // (OpenAIAdapter.parseCompletion does, for an empty completion).
        // Throwing here aborts the eviction with GROWTH.md intact; the
        // marker-restore defer makes the next weekly tick retry.
        guard !summary.isEmpty else {
            throw NSError(
                domain: "REMConsolidator",
                code: -210,
                userInfo: [NSLocalizedDescriptionKey:
                    "GROWTH distillation returned an empty summary; refusing to "
                    + "evict the source slice. Retrying on the next REM tick."]
            )
        }
        return KGNode(
            // Stable over the source slice, not the model summary. If the KG
            // commit succeeds but the following GROWTH.md splice fails, the
            // next pass upserts this same entity instead of minting a duplicate.
            id: Self.growthDistillationID(text),
            summary: summary,
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

    /// Merge a GROWTH-eviction distillation node through the canonical graph
    /// owner. `memory.sqlite` is authoritative whenever it exists. The JSON
    /// mutation below is retained only for a true pre-SQLite install/fixture.
    ///
    /// LEGACY COMPATIBILITY SHAPE — DO NOT BREAK. The pre-SQLite KG file is a dict:
    /// ```
    /// {
    ///   "_commit_seq": <int>,
    ///   "version":     <int>,
    ///   "entities":    { "<id>": { id, name, type, first_seen,
    ///                              last_seen, mention_count, aliases, summary }, ... },
    ///   "edges":       [ {...}, ... ]
    /// }
    /// ```
    /// The earlier version of
    /// this method decoded as `[KGNode]` (a top-level array), defaulted to
    /// `[]` on any failure, then wrote the array back. The first time REM
    /// fired a GROWTH eviction it would have silently OVERWRITTEN the
    /// compatibility file with an array, deleting the user's whole knowledge graph.
    /// That bug is the entire reason this function looks the way it does now.
    ///
    /// FAIL-CLOSED CONTRACT: any unexpected condition (file missing, read
    /// failure, top-level not a dict, `entities` present but not a dict)
    /// THROWS and we leave the file untouched. The caller (`runGrowthEviction`)
    /// must NOT splice the GROWTH.md slice unless this call succeeded —
    /// otherwise the slice would be gone from both GROWTH and KG.
    ///
    /// CROSS-PROCESS LOCK: the whole read → validate → mutate → encode →
    /// atomic-write sequence runs under `withFileLock` on the KG file path so
    /// a concurrent writer (daemon merge, manual edit, sibling tool) can't
    /// race us. The lock matches the convention `PersistenceCore` documents
    /// for any read-modify-write of a daemon-shared JSON file.
    private func appendKGNode(_ node: KGNode) async throws {
        let kgDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
        let kgURL = kgDir.appendingPathComponent("knowledge_graph.json")
        let sqliteURL = kgDir.appendingPathComponent("memory.sqlite")
        if FileManager.default.fileExists(atPath: sqliteURL.path) {
            let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: sqliteURL)
            try await indexer.upsertGrowthDistillation(
                id: node.id,
                summary: node.summary,
                sourceLines: node.sourceLines,
                createdAt: node.createdAt,
                legacyJSONPath: kgURL
            )
            return
        }

        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(kgURL) {
            try Self.mergeKGNodeUnderLock(node, kgURL: kgURL)
        }
    }

    /// The locked critical section. Static so it can be passed into the
    /// `@Sendable` closure of `withFileLock` without capturing actor state.
    /// Every fail-closed branch throws — the on-disk file is read into memory,
    /// validated, mutated, encoded, and then atomically rewritten; if any
    /// step is wrong we bail out BEFORE the write.
    private static func mergeKGNodeUnderLock(_ node: KGNode, kgURL: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: kgURL.path) else {
            throw NSError(
                domain: "REMConsolidator",
                code: -201,
                userInfo: [NSLocalizedDescriptionKey:
                    "knowledge_graph.json missing at \(kgURL.path); refusing to "
                    + "create a fresh file because the canonical shape (dict with "
                    + "entities/edges/version/_commit_seq) must be authored by the "
                    + "KG owner, not by GROWTH eviction."]
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: kgURL)
        } catch {
            throw NSError(
                domain: "REMConsolidator",
                code: -202,
                userInfo: [NSLocalizedDescriptionKey:
                    "failed to read knowledge_graph.json: \(error)"]
            )
        }
        guard var graph = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NSError(
                domain: "REMConsolidator",
                code: -203,
                userInfo: [NSLocalizedDescriptionKey:
                    "knowledge_graph.json top level is not a dict — refusing to "
                    + "overwrite. The canonical shape is "
                    + "{_commit_seq, version, entities:{...}, edges:[...]}."]
            )
        }

        // Validate sub-shape BEFORE mutating. `entities` MUST be present and
        // must be a dict; if it's absent or wrong-typed we refuse rather than
        // silently default-to-empty and clobber a non-canonical file the user
        // is mid-migration on. Same for `edges`: if present it must be an
        // array. Missing edges is tolerated (older variants may omit it) but
        // we won't overwrite a non-array edges.
        guard let existingEntities = graph["entities"] as? [String: Any] else {
            throw NSError(
                domain: "REMConsolidator",
                code: -204,
                userInfo: [NSLocalizedDescriptionKey:
                    "knowledge_graph.json `entities` field is missing or not a "
                    + "dict — refusing to overwrite. Live KG has 793 entities "
                    + "keyed by id; defaulting to empty here would erase them."]
            )
        }
        if let edges = graph["edges"], !(edges is [Any]) {
            throw NSError(
                domain: "REMConsolidator",
                code: -205,
                userInfo: [NSLocalizedDescriptionKey:
                    "knowledge_graph.json `edges` field is present but not an "
                    + "array — refusing to overwrite. Canonical shape is "
                    + "edges:[...]."]
            )
        }

        // Adapter shape: a distilled GROWTH-eviction node lives under entities
        // as a single record with type="growth_distillation". This keeps the
        // file's contract (entities is a dict keyed by id) intact and lets
        // downstream consumers query/render these nodes the same way they do
        // any other entity. Name = summary truncated; first_seen/last_seen =
        // createdAt; mention_count = sourceLines.
        var entities = existingEntities
        let nameTruncated: String = {
            let summary = node.summary
            if summary.count <= 80 { return summary }
            let idx = summary.index(summary.startIndex, offsetBy: 80)
            return String(summary[..<idx])
        }()
        let entity: [String: Any] = [
            "id": node.id,
            "name": nameTruncated,
            "type": "growth_distillation",
            "first_seen": node.createdAt,
            "last_seen": node.createdAt,
            "mention_count": node.sourceLines,
            "aliases": [String](),
            "summary": node.summary,
        ]
        entities[node.id] = entity
        graph["entities"] = entities

        // Bump _commit_seq so any consumer watching for changes sees a fresh
        // version. Treat the value defensively — older files may carry it as
        // a NSNumber or be missing entirely.
        let currentSeq: Int = {
            if let n = graph["_commit_seq"] as? Int { return n }
            if let n = graph["_commit_seq"] as? NSNumber { return n.intValue }
            return 0
        }()
        graph["_commit_seq"] = currentSeq + 1

        let out: Data
        do {
            out = try JSONSerialization.data(
                withJSONObject: graph,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw NSError(
                domain: "REMConsolidator",
                code: -206,
                userInfo: [NSLocalizedDescriptionKey:
                    "failed to encode merged KG: \(error)"]
            )
        }
        try out.write(to: kgURL, options: .atomic)
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: clock())
    }
}
