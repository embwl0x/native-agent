import CognitiveSubstrate
import Foundation
import KnowledgeGraph
import MemoryV2
import NativeAgentCore
import PersistenceCore

// MARK: - Studio chat lane (studio_*) — desk 903 phases 1–2
//
// Four chat tools over SwiftNativeStudioStore: the agent's aesthetic journal and
// the consults filed against her taste.
//
//   studio_consult      — file a consult. Writes ONE envelope and nothing else.
//   studio_consult_read — pull that envelope back when answering.
//   studio_journal      — write ONE encounter entry. Append-only.
//   studio_recall       — read-only search over the journal.
//
// WIRING CANON: same as the desk / task-ledger lanes — catalog-visible,
// LAZY-LOADED (in builtInToolNames, NOT alwaysOnCoreNames). The store is
// obtained exactly like SwiftNativeDeskStore(dataRoot:) — pointed at THIS
// dispatcher's data root.
//
// WHAT THESE TOOLS DELIBERATELY DO NOT DO (design vetoes, binding):
//   • studio_consult does NOT append to the journal, does NOT retrieve journal
//     entries, and does NOT suggest a verdict. Consults are ELIGIBLE material;
//     turning one into an entry is a separate, deliberate call.
//   • studio_recall is never invoked on the agent's behalf. It has no preload
//     group, no auto-injection, and no caller inside the runtime.
//   • Neither the entry shape nor any result carries a rating, score,
//     confidence, or sentiment. studio_journal REFUSES an unknown field rather
//     than dropping it, so a caller can never believe one was recorded.
//   • There is no update tool and no delete tool. Revision is a later entry
//     linked with `relations` — the contradiction is kept, never flattened.
//
// WHAT A FILED ENTRY NOW SETS IN MOTION (desk 903 phases 2, 3, 5) — all three
// in `studioJournalDidAppend`, all three after the append is already durable,
// none of them able to fail the write:
//   1. a context-index wake-up, so the entry's POINTER is reachable next turn;
//   2. a knowledge-graph re-derive, so her typed links become real edges that
//      cite the entry as provenance;
//   3. a publish onto the cognitive bus, so the entry is FELT — sized by the
//      judgment she wrote, not by the act of filing.

/// The EXACT field tree `studio_journal` accepts, to any depth.
///
/// Top-level-only checking was a hole: `stance: {kind: "formed", confidence:
/// 0.9}` sailed through and the confidence was silently dropped, which is
/// precisely the smuggled score the veto forbids (gpt-5.5 review). The refusal
/// now walks the whole payload, so there is nowhere in an entry to hide one.
private indirect enum StudioFieldSpec {
    /// A value whose interior is the caller's own content (a string, a list of
    /// strings) — nothing to police inside it.
    case leaf
    case object([String: StudioFieldSpec])
    case arrayOfObjects([String: StudioFieldSpec])

    static let journalEntry = StudioFieldSpec.object([
        "encountered_at": .leaf,
        "work": .object([
            "title": .leaf, "creator": .leaf, "medium": .leaf,
            "date": .leaf, "version": .leaf, "edition": .leaf,
        ]),
        "reception": .object(["how": .leaf, "whole_or_part": .leaf]),
        "artifact_refs": .leaf,
        "origin": .object(["kind": .leaf, "ref": .leaf]),
        "response": .leaf,
        "stance": .object(["kind": .leaf, "reason": .leaf]),
        "relations": .arrayOfObjects(["kind": .leaf, "entry_id": .leaf]),
        "tags": .leaf,
    ])

    /// Dotted paths of every field this spec does not name, e.g.
    /// `stance.confidence`, `relations[0].weight`. Sorted, so the refusal reads
    /// the same way twice.
    func unknownPaths(in value: JSONValue, prefix: String = "") -> [String] {
        switch self {
        case .leaf:
            return []
        case .object(let fields):
            guard case .object(let obj) = value else { return [] }
            var found: [String] = []
            for key in obj.keys.sorted() {
                guard let child = fields[key] else {
                    found.append(prefix + key)
                    continue
                }
                guard let nested = obj[key] else { continue }
                found.append(contentsOf: child.unknownPaths(in: nested, prefix: prefix + key + "."))
            }
            return found
        case .arrayOfObjects(let fields):
            guard case .array(let elements) = value else { return [] }
            var found: [String] = []
            for (index, element) in elements.enumerated() {
                found.append(contentsOf: StudioFieldSpec.object(fields).unknownPaths(
                    in: element,
                    prefix: "\(prefix.dropLast())[\(index)]."
                ))
            }
            return found
        }
    }
}

extension SwiftToolDispatcher {

    func impl_studio_shelf(input: [String: JSONValue], surface: String, set: Bool) async -> JSONValue {
        // Only the dispatcher's own injected session key is tolerated; any other
        // unknown argument, dunder or not, is rejected by the strict checks below.
        let input = input.filter { $0.key != "__session_id" }
        guard MemoryRecordDisclosurePolicy.localPrivateSurfaces.contains(MemoryRecordDisclosurePolicy.canonicalSurface(surface)) else {
            return .object(["status": .string("refused"), "reason": .string("The working shelf is available only on private surfaces.")])
        }
        do {
            let shelf = StudioWorkingShelf(dataRoot: dataRoot)
            if set {
                guard Set(input.keys) == ["slots"], let slots = input["slots"] else {
                    throw StudioWorkingShelf.Refusal(message: "Supply only slots: the complete ordered list, or [] to empty the shelf.")
                }
                try await shelf.replace(slots)
                // Refresh only the existing titles-only Studio pointer.
                await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
                    namespace: "studio", stableID: "working_shelf", operation: .changed,
                    canonicalLocator: studioStore().journalPath.standardizedFileURL.path,
                    reason: "studio_working_shelf_replaced"
                ))
                return .object(["status": .string("ok")])
            }
            guard input.isEmpty else { throw StudioWorkingShelf.Refusal(message: "studio_shelf_read accepts no arguments.") }
            let result = try await shelf.read { ref in
                if let scheme = URL(string: ref)?.scheme, scheme.lowercased() != "file" {
                    return "Availability not checked; open explicitly"
                }
                let path = ref.hasPrefix("file://") ? URL(string: ref)?.path : ref
                guard let path else { return "unresolved" }
                do {
                    let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                    let generated = self.dataRoot.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("generated_images")
                    let url = candidate.path.hasPrefix(generated.path + "/") ? candidate : try await self.resolveTrustedFilePath(path)
                    try self.requireNonSensitiveReadPath(url, tool: "studio_shelf_read")
                    guard FileManager.default.fileExists(atPath: url.path) else { return "missing" }
                    return FileManager.default.isReadableFile(atPath: url.path) ? "local-present" : "inaccessible"
                } catch { return "inaccessible" }
            }
            let text = String(decoding: try result.serializedData(pretty: false), as: UTF8.self)
            guard ChatSecretRedactor.redactText(text) == text else {
                throw StudioWorkingShelf.Refusal(message: "The shelf contains protected content and cannot be returned verbatim. The selection is unchanged.")
            }
            return result
        } catch {
            return .object(["status": .string("refused"), "reason": .string(error.localizedDescription)])
        }
    }

    /// Stateless returned-result garnish. Receipts and all warning fields remain unchanged.
    static func studioImageInvitation(_ result: JSONValue) -> JSONValue {
        guard case .object(var response) = result, response["status"] == .string("ok"),
              case .array(let images)? = response["images"], !images.isEmpty else { return result }
        let paths = images.compactMap { image -> JSONValue? in
            guard case .object(let row) = image, case .string(let path)? = row["path"] else { return nil }
            return .string(path)
        }
        guard paths.count == images.count else { return result }
        response["studio_invitation"] = .object([
            "message": .string("Keep this in Studio? Open the work, then add your sentence."),
            "tool": .string("studio_journal"), "artifact_refs": .array(paths),
            "origin": .object(["kind": .string("project")]),
        ])
        return .object(response)
    }

    private func studioStore() -> SwiftNativeStudioStore {
        SwiftNativeStudioStore(dataRoot: dataRoot)
    }

    /// An honest refusal reaches the model as a RESULT, not an exception, so it
    /// reads the reason and can adjust — the same shape desk_open_pursuit uses.
    private func studioRefusal(_ error: StudioError) -> JSONValue {
        .object([
            "status": .string("refused"),
            "reason": .string(error.errorDescription ?? "\(error)"),
        ])
    }

    /// A string array argument, tolerant of the single-string form a model
    /// reaches for naturally. Blanks are dropped; a non-string entry is refused
    /// loudly rather than silently skipped.
    private func studioStringArray(_ input: [String: JSONValue], _ key: String, tool: String) throws -> [String] {
        switch input[key] {
        case .none, .some(.null):
            return []
        case .some(.string(let single)):
            let trimmed = single.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        case .some(.array(let arr)):
            var out: [String] = []
            for entry in arr {
                guard case .string(let s) = entry else {
                    throw AutonomyGateError.toolDenied(
                        reason: "\(tool): \(key) must be an array of strings"
                    )
                }
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
            }
            return out
        default:
            throw AutonomyGateError.toolDenied(
                reason: "\(tool): \(key) must be an array of strings"
            )
        }
    }

    private func studioBool(_ input: [String: JSONValue], _ key: String) -> Bool {
        switch input[key] {
        case .some(.bool(let b)): return b
        case .some(.string(let s)): return ["true", "1", "yes", "y", "on"].contains(s.lowercased())
        default: return false
        }
    }

    /// A nested object argument, or nil when absent.
    private func studioObject(_ input: [String: JSONValue], _ key: String, tool: String) throws -> [String: JSONValue]? {
        switch input[key] {
        case .none, .some(.null): return nil
        case .some(.object(let obj)): return obj
        default:
            throw AutonomyGateError.toolDenied(reason: "\(tool): \(key) must be an object")
        }
    }

    private func studioNestedString(_ obj: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let s)? = obj[key] else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - studio_consult

    /// studio_consult — file one consult against the agent's taste.
    ///
    /// It persists an envelope and returns its id. It does NOT inject anything
    /// into the journal, does NOT retrieve journal entries, and does NOT carry
    /// or suggest a verdict: the judgment is hers, live, when she answers.
    func impl_studio_consult(input: [String: JSONValue]) async throws -> JSONValue {
        await ensureStudioGraphIndexed()
        let refs = try studioStringArray(input, "artifact_refs", tool: "studio_consult")
        let question = optionalString(input, "question")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !question.isEmpty else {
            return studioRefusal(.consultQuestionMissing)
        }
        do {
            let consult = try await studioStore().fileConsult(
                artifactRefs: refs,
                description: optionalString(input, "description"),
                portionAvailable: optionalString(input, "portion_available"),
                question: question,
                projectContext: optionalString(input, "project_context"),
                stage: optionalString(input, "stage"),
                constraints: optionalString(input, "constraints"),
                priorDiscussion: optionalString(input, "prior_discussion"),
                descriptionOnly: studioBool(input, "description_only")
            )
            return .object([
                "status": .string("ok"),
                "consult_id": .string(consult.id),
                "description_only": .bool(consult.descriptionOnly),
                "artifact_ref_count": .int(Int64(consult.artifactRefs.count)),
                "note": .string(consult.descriptionOnly
                    ? "Filed as description-only: it can be critiqued, but it can never enter the journal as an encounter."
                    : "Filed. Nothing was written to the journal — journal it separately if it is worth keeping."),
            ])
        } catch let error as StudioError {
            return studioRefusal(error)
        }
    }

    // MARK: - studio_consult_read

    /// studio_consult_read — pull one consult envelope back, verbatim, so the
    /// full bundle is in front of her when she answers.
    func impl_studio_consult_read(input: [String: JSONValue]) async throws -> JSONValue {
        await ensureStudioGraphIndexed()
        let id = try requireString(input, "consult_id")
        do {
            let consult = try await studioStore().readConsult(id: id)
            return .object([
                "status": .string("ok"),
                "consult": consult.toJSON(),
            ])
        } catch let error as StudioError {
            return studioRefusal(error)
        }
    }

    // MARK: - studio_journal

    /// studio_journal — write ONE journal entry. The server stamps `id` and
    /// `recorded_at`; everything else is hers.
    ///
    /// Unknown top-level fields are REFUSED, not ignored. That is what makes
    /// "there is no rating field" true rather than merely undocumented: a
    /// `rating`/`score`/`sentiment` argument fails loudly instead of being
    /// silently dropped while the caller believes it was recorded.
    func impl_studio_journal(input: [String: JSONValue]) async throws -> JSONValue {
        // The dispatcher injects its session marker into every lazy tool call
        // (extractSessionId's key set). That is runtime plumbing, not caller
        // payload — strip it at the TOP level only, so a nested
        // `stance.session_id` is still refused like any other unknown field.
        await ensureStudioGraphIndexed()
        var input = input
        for key in ["__session_id", "session_id", "sessionId"] {
            input.removeValue(forKey: key)
        }
        // Recursive, not just top-level: a score hidden one level down inside
        // `stance` or a `relations` item is the same veto violation as one at
        // the top, and dropping it silently would let the caller believe it was
        // recorded.
        let unknown = StudioFieldSpec.journalEntry.unknownPaths(in: .object(input))
        guard unknown.isEmpty else {
            throw AutonomyGateError.toolDenied(
                reason: "studio_journal: unknown field(s) \(unknown.joined(separator: ", ")) — no field by that name exists on a journal entry at that position. There is no rating, score, confidence, or sentiment field anywhere in an entry, at any depth, by design; the judgment lives in `response` and the stance in `stance.kind`."
            )
        }

        guard let workObject = try studioObject(input, "work", tool: "studio_journal"),
              let title = studioNestedString(workObject, "title") else {
            return studioRefusal(.journalWorkTitleMissing)
        }
        let work = StudioWork(
            title: title,
            creator: studioNestedString(workObject, "creator"),
            medium: studioNestedString(workObject, "medium"),
            date: studioNestedString(workObject, "date"),
            version: studioNestedString(workObject, "version"),
            edition: studioNestedString(workObject, "edition")
        )

        let reception: StudioReception
        if let receptionObject = try studioObject(input, "reception", tool: "studio_journal") {
            reception = StudioReception(
                how: studioNestedString(receptionObject, "how"),
                wholeOrPart: studioNestedString(receptionObject, "whole_or_part")
            )
        } else {
            reception = StudioReception()
        }

        guard let originObject = try studioObject(input, "origin", tool: "studio_journal"),
              let originKindRaw = studioNestedString(originObject, "kind") else {
            throw AutonomyGateError.toolDenied(
                reason: "studio_journal: origin is required — {kind: wandering|consult|project, ref?}"
            )
        }
        guard let originKind = StudioOriginKind(rawValue: originKindRaw.lowercased()) else {
            return studioRefusal(.unknownOriginKind(originKindRaw))
        }
        let origin = StudioOrigin(kind: originKind, ref: studioNestedString(originObject, "ref"))

        guard let stanceObject = try studioObject(input, "stance", tool: "studio_journal"),
              let stanceKindRaw = studioNestedString(stanceObject, "kind") else {
            throw AutonomyGateError.toolDenied(
                reason: "studio_journal: stance is required — {kind: open|formed|abstained, reason?}"
            )
        }
        guard let stanceKind = StudioStance(rawValue: stanceKindRaw.lowercased()) else {
            return studioRefusal(.unknownStanceKind(stanceKindRaw))
        }
        let stance = StudioStanceValue(kind: stanceKind, reason: studioNestedString(stanceObject, "reason"))

        var relations: [StudioRelation] = []
        if case .array(let rawRelations)? = input["relations"] {
            for raw in rawRelations {
                guard case .object(let relationObject) = raw,
                      let kindRaw = studioNestedString(relationObject, "kind") else {
                    throw AutonomyGateError.toolDenied(
                        reason: "studio_journal: each relation must be {kind, entry_id}"
                    )
                }
                guard let kind = StudioRelationKind(rawValue: kindRaw.lowercased()) else {
                    return studioRefusal(.unknownRelationKind(kindRaw))
                }
                guard let entryId = studioNestedString(relationObject, "entry_id") else {
                    return studioRefusal(.relationMissingEntryId)
                }
                relations.append(StudioRelation(kind: kind, entryId: entryId))
            }
        } else if input["relations"] != nil, input["relations"] != .null {
            throw AutonomyGateError.toolDenied(reason: "studio_journal: relations must be an array")
        }

        do {
            let entry = try await studioStore().appendJournalEntry(
                encounteredAt: optionalString(input, "encountered_at"),
                work: work,
                reception: reception,
                artifactRefs: try studioStringArray(input, "artifact_refs", tool: "studio_journal"),
                origin: origin,
                response: optionalString(input, "response"),
                stance: stance,
                relations: relations,
                tags: try studioStringArray(input, "tags", tool: "studio_journal")
            )
            let graph = await studioJournalDidAppend(entry)
            var result: JSONValue = .object([
                "status": .string("ok"),
                "entry_id": .string(entry.id),
                "recorded_at": .string(entry.recordedAt),
                "entry": entry.toJSON(),
            ])
            // The edges this entry's relations became, said out loud rather than
            // asserted. Each one names this entry as its provenance in the
            // graph, so the claim can be traced back to the judgment.
            if case .object(var obj) = result, let graph, graph.graphAvailable {
                obj["graph"] = .object([
                    "works": .int(Int64(graph.worksIndexed)),
                    "creators": .int(Int64(graph.creatorsIndexed)),
                    "edges": .int(Int64(graph.edgesWritten)),
                    "unresolved_relations": .int(Int64(graph.unresolvedRelations)),
                ])
                result = .object(obj)
            }
            return result
        } catch let error as StudioError {
            return studioRefusal(error)
        }
    }

    // MARK: - After an entry lands

    /// Everything a FILED entry sets in motion, in one place.
    ///
    /// The append itself is already durable when this runs. Nothing here may
    /// throw back into the tool: a graph that will not open or a coordinator
    /// that is not installed is a reason for a quieter system, never a reason
    /// for the journal write to look like it failed. The entry is the canonical
    /// record; these are derived consumers waking up.
    @discardableResult
    private func studioJournalDidAppend(_ entry: StudioJournalEntry) async -> StudioGraphIndexReport? {
        // 1. Wake the resident context index so the pointer for this entry is
        //    reachable on the NEXT turn instead of after the next launch.
        //    `NativeStudioContextProjection` consumes exactly this namespace and
        //    this locator; it rereads the journal itself, as the contract
        //    requires — the event is a wake-up, never source data.
        await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
            namespace: "studio",
            stableID: entry.id,
            operation: .changed,
            canonicalLocator: studioStore().journalPath.standardizedFileURL.path,
            reason: "studio_journal_entry_filed"
        ))
        // 2. Her relations become graph edges (desk 903 phase 3). The pass
        //    re-derives the WHOLE journal and is idempotent, so this single call
        //    also completes any history that predates the graph — which is why
        //    there is no separate backfill code path, only a first-run trigger
        //    (`ensureStudioGraphIndexed`) for the case where she never files
        //    again.
        let report = await indexStudioJournalIntoGraph(reason: "entry_filed")
        // 3. The entry rides the cognitive bus (desk 903 phase 2). The delta
        //    comes from the ENTRY — sign and size from the judgment she wrote,
        //    zero for an abstention — and it is derived on the cognition side,
        //    which owns the appraisal. This lane only says that an entry landed.
        await StudioJournalCognitiveBus.publish(entry)
        return report
    }

    /// The knowledge-graph half. Never throws back into the tool: a graph that
    /// will not open is a quieter system, not a failed journal write. The entry
    /// is already durable when this runs.
    @discardableResult
    private func indexStudioJournalIntoGraph(reason: String) async -> StudioGraphIndexReport? {
        do {
            // 2026-09-06: hot PLUS shelf — an archived entry still names its
            // work and its relations, and indexing only the hot file dropped
            // those edges out of the graph on the first cap trim.
            let entries = try await studioStore().journalEntriesIncludingArchive()
            guard !entries.isEmpty else { return nil }
            let indexer = try SwiftNativeKnowledgeGraphIndexer(
                // The SAME store `NativeKnowledgeGraphContextProjection` reads,
                // so a studio edge is selectable exactly like the other 94.
                memorySQLitePath: dataRoot
                    .appendingPathComponent("memory/memory.sqlite")
                    .standardizedFileURL
            )
            let report = try await indexer.indexStudioJournal(entries)
            // Agent's addendum (2026-09-01): relations stay provenance-only and
            // accepted, WITH a guard — every relation must have a graph edge
            // citing that entry id back. Same trigger as the backfill. Fail
            // loud, never repair, never block recall.
            await StudioCanonTending.recordAudit(
                (try? await indexer.auditStudioRelations(entries)) ?? .unavailable,
                dataRoot: dataRoot
            )
            return report
        } catch {
            NSLog("[studio] knowledge-graph index skipped (%@): %@",
                  reason, String(describing: error))
            return nil
        }
    }

    /// ONE-SHOT BACKFILL. The journal predates the graph, so the entries already
    /// on disk have to arrive once even if she never files another. Guarded by a
    /// receipt beside the journal, so it runs once per install and not once per
    /// call; a run that finds no graph writes NO receipt and is retried later.
    func ensureStudioGraphIndexed() async {
        let receipt = studioStore().studioRoot
            .appendingPathComponent("journal", isDirectory: true)
            .appendingPathComponent("kg_backfill_receipt.json")
        guard !FileManager.default.fileExists(atPath: receipt.path) else { return }
        guard let report = await indexStudioJournalIntoGraph(reason: "backfill"),
              report.graphAvailable else { return }
        try? await SwiftNativePersistenceCore().writeJSON(
            .object([
                "ran_at": .string(StudioClock.nowISO()),
                "works": .int(Int64(report.worksIndexed)),
                "creators": .int(Int64(report.creatorsIndexed)),
                "edges": .int(Int64(report.edgesWritten)),
                "unresolved_relations": .int(Int64(report.unresolvedRelations)),
            ]),
            to: receipt
        )
    }

    // MARK: - studio_recall

    /// studio_recall — read-only search over the journal. Returns entries
    /// VERBATIM (the response text is the point), newest first, bounded, with an
    /// explicit has_more. No relevance score is computed or exposed.
    func impl_studio_recall(input: [String: JSONValue]) async throws -> JSONValue {
        await ensureStudioGraphIndexed()
        var relationKind: StudioRelationKind?
        if let raw = optionalString(input, "relation_kind") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Some caller models serialize every optional field, sending ""
            // for the ones they mean to omit (the conversation_id precedent).
            // An empty relation_kind is an omitted filter, not an error.
            if !trimmed.isEmpty {
                guard let kind = StudioRelationKind(rawValue: trimmed) else {
                    return studioRefusal(.unknownRelationKind(raw))
                }
                relationKind = kind
            }
        }
        let query = StudioRecallQuery(
            text: optionalString(input, "query"),
            title: optionalString(input, "title"),
            creator: optionalString(input, "creator"),
            medium: optionalString(input, "medium"),
            tag: optionalString(input, "tag"),
            relationKind: relationKind,
            relatedTo: optionalString(input, "related_to"),
            limit: optionalInt(input, "limit") ?? StudioRecallQuery.defaultLimit
        )
        let result = try await studioStore().recall(query)
        // Desk 903 phase 4: the "used in a REAL PRODUCTION JUDGMENT" evidence
        // door for the canon. Deliberately NOT "any successful recall" — she
        // browses her own journal, the tending pass reads it, and a bridge can
        // query it, and none of those are a work proving itself in use. Two
        // runtime-derived conditions, both required, neither from tool input:
        //   1. the SAME live-local-turn provenance the canon seat demands, so a
        //      bridge tool run or a replay counts nothing;
        //   2. the turn is a taste judgment by the projection's OWN admission
        //      rule, so "pulled in production" means the same thing here as it
        //      does where the pointer gets selected.
        // Anything else reads the journal and records nothing.
        if !result.entries.isEmpty,
           case .success = StudioCanonSeatGate.liveTurnProvenance(),
           StudioCanonSeatGate.isProductionTasteJudgment() {
            await studioStore().noteRecallPulls(
                titles: result.entries.map { ($0.work.title, $0.work.creator) }
            )
        }
        return .object([
            "status": .string("ok"),
            "entries": .array(result.entries.map { $0.toJSON() }),
            "returned": .int(Int64(result.entries.count)),
            "matched": .int(Int64(result.matchedCount)),
            "has_more": .bool(result.hasMore),
        ])
    }
}
