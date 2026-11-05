import CognitiveSubstrate
import ChatToolParsing
import Foundation
import NativeAgentShared
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Studio
// Blueprint: | `SwiftToolDispatcher+StudioTools.swift` | `SwiftToolDispatcher`; durable journal; derived failures |

// MARK: - Studio chat lane (studio_*)
// Consults are eligible material, never automatic journal entries or suggested verdicts. Recall is an explicit pull: no preload or injection may substitute for
// the agent's judgment. Unknown journal fields must fail so callers cannot mistake discarded ratings for recorded ones. Entries stay append-only: relations
// revise judgments; separate amendments correct facts without inventing encounters. Context, graph and cognition consume an already durable append; derived
// failures cannot undo it.

extension SwiftToolDispatcher {

    func impl_studio_shelf(turn: Turn, input: [String: JSONValue], surface: String, set: Bool, preview: Bool = false) async -> JSONValue {
        // Only the dispatcher's own injected session key is tolerated; any other unknown argument, dunder or not, is rejected by the strict checks below.
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
                if preview {
                    try await shelf.validateReplacement(StudioWorkingShelf.decodeSlots(slots))
                    return .object(["status": .string("would")])
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
                    let tail = NativeAgentWorkspaceRoot.relativePath(candidate.path, under: generated.path)
                    let url = tail != nil && tail != "" ? candidate : try await self.resolveTrustedFilePath(turn: turn, path)
                    try self.requireNonSensitiveReadPath(turn: turn, url, tool: "studio_shelf_read")
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

    /// Presentation changes must preserve receipts and every warning field.
    static func studioImageInvitation(_ result: JSONValue) -> JSONValue {
        let reply = ToolResult(result)
        guard case .object(var response) = result, reply.said("ok"), reply.status == response["status"]?.stringValue,
              case .array(let images)? = response["images"], !images.isEmpty else { return result }
        let paths = images.compactMap { image -> String? in
            guard case .object(let row) = image, case .string(let path)? = row["path"] else { return nil }
            return path
        }
        guard paths.count == images.count else { return result }
        response["message"] = .string(
            "Saved \(images.count) generated image(s) at:\n\(paths.joined(separator: "\n"))\nOffer to show the saved work in the Make pane.")
        if let ref = response["make_ref"] {
            response["next_call"] = .object(["action": .string("pane.show"),
                "args": .object(["view": .string("make"), "ref": ref])])
        }
        response["studio_invitation"] = .object([
            "message": .string("Keep this in Studio? Open the work, then add your sentence."),
            "tool": .string("studio_journal"), "artifact_refs": .array(paths.map(JSONValue.string)),
            "origin": .object(["kind": .string("project")]),
        ])
        return .object(response)
    }

    private func studioStore() -> SwiftNativeStudioStore {
        SwiftNativeStudioStore(dataRoot: dataRoot)
    }

    /// Return refusal reasons as results so the caller can adjust the request.
    private func studioRefusal(_ error: StudioError) -> JSONValue {
        .object([
            "status": .string("refused"),
            "reason": .string(error.errorDescription ?? "\(error)"),
        ])
    }

    /// Accept a single string as one array entry; refuse non-string entries rather than silently dropping them.
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

    // MARK: - studio_consult

    /// A consult is material for live judgment; filing it must neither retrieve nor append journal entries or suggest a verdict.
    func impl_studio_consult(input: [String: JSONValue]) async throws -> JSONValue {
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
                descriptionOnly: flag(input, "description_only")
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

    /// Return the full consult verbatim so judgment sees the original material.
    func impl_studio_consult_read(input: [String: JSONValue]) async throws -> JSONValue {
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

    /// The owner stamps id and recorded_at; unknown fields must fail rather than falsely appear recorded.
    func impl_studio_journal(turn: Turn, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        // Strip only the injected top-level session marker; nested stance.session_id remains an unknown field.
        var input = input
        for key in ["__session_id", "session_id", "sessionId"] {
            input.removeValue(forKey: key)
        }
        guard let schema = try await listAvailableToolSchemas(named: ["studio_journal"], turn: turn, surface: surface).first else {
            throw ToolFailureError("Studio journal schema is unavailable.", effects: .none)
        }
        if let problem = JSONValue.object(input).schemaProblem(schema: try JSONValue.parse(schema.parametersJSON)) {
            throw ToolFailureError(
                "Journal: \(problem.words). No rating, score, confidence or sentiment field exists at any depth.",
                argumentPath: problem.path, effects: .none,
                nextCall: ToolFailureError.call("app", ["find": .string("studio.journal")]),
                code: "studio_journal_unknown_fields", status: .refused,
                instruction: "Remove unknown fields; put judgment in response and stance in stance.kind. Read accepted fields with next_call.",
                recovery: .correctArguments)
        }

        // Normalize validated tool fields here; stored journal reads remain verbatim. A blank field is unstated (the writer never stores one), so it leaves the
        // arguments here.
        func normalized(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let text): return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case .object(let object): return .object(stated(object))
            case .array(let array): return .array(array.map(normalized))
            default: return value
            }
        }
        func stated(_ object: [String: JSONValue]) -> [String: JSONValue] {
            object.compactMapValues { value in
                let next = normalized(value)
                return next == .string("") ? nil : next
            }
        }
        let fields = stated(input)
        guard let work = fields["work"].flatMap(StudioWork.fromJSON), !work.title.isEmpty else {
            return studioRefusal(.journalWorkTitleMissing)
        }
        let reception: StudioReception
        if let value = fields["reception"] {
            guard let decoded = StudioReception.fromJSON(value) else {
                throw AutonomyGateError.toolDenied(reason: "studio_journal: reception must contain only valid supplied reception text.")
            }
            reception = decoded
        } else { reception = StudioReception() }

        guard case .object(var originObject)? = fields["origin"],
              case .string(let originKindRaw)? = originObject["kind"], !originKindRaw.isEmpty else {
            throw AutonomyGateError.toolDenied(
                reason: "studio_journal: origin is required — {kind: wandering|consult|project, ref?}"
            )
        }
        originObject["kind"] = .string(originKindRaw.lowercased())
        guard let origin = StudioOrigin.fromJSON(.object(originObject)) else {
            return studioRefusal(.unknownOriginKind(originKindRaw))
        }

        guard case .object(var stanceObject)? = fields["stance"],
              case .string(let stanceKindRaw)? = stanceObject["kind"], !stanceKindRaw.isEmpty else {
            throw AutonomyGateError.toolDenied(
                reason: "studio_journal: stance is required — {kind: open|formed|abstained, reason?}"
            )
        }
        stanceObject["kind"] = .string(stanceKindRaw.lowercased())
        guard let stance = StudioStanceValue.fromJSON(.object(stanceObject)) else {
            return studioRefusal(.unknownStanceKind(stanceKindRaw))
        }

        var relations: [StudioRelation] = []
        if case .array(let rawRelations)? = fields["relations"] {
            for raw in rawRelations {
                guard case .object(var relationObject) = raw,
                      case .string(let kindRaw)? = relationObject["kind"], !kindRaw.isEmpty else {
                    throw AutonomyGateError.toolDenied(
                        reason: "studio_journal: each relation must be {kind, entry_id}"
                    )
                }
                relationObject["kind"] = .string(kindRaw.lowercased())
                guard let relation = StudioRelation.fromJSON(.object(relationObject)) else {
                    if StudioRelationKind(rawValue: kindRaw.lowercased()) == nil {
                        return studioRefusal(.unknownRelationKind(kindRaw))
                    }
                    return studioRefusal(.relationMissingEntryId)
                }
                relations.append(relation)
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
            // Return actual graph edges with entry provenance so claims remain traceable to the judgment.
            if case .object(var obj) = result {
                obj["derived_failures"] = .array(graph.failures.map(JSONValue.string))
                if let graph = graph.report, graph.graphAvailable {
                    obj["graph"] = .object([
                        "works": .int(Int64(graph.worksIndexed)),
                        "creators": .int(Int64(graph.creatorsIndexed)),
                        "edges": .int(Int64(graph.edgesWritten)),
                        "unresolved_relations": .int(Int64(graph.unresolvedRelations)),
                    ])
                }
                result = .object(obj)
            }
            return result
        } catch let error as StudioError {
            return studioRefusal(error)
        }
    }

    // MARK: - studio_journal_amend

    /// Amendments correct facts without claiming new encounters; keep the original passage and dated reason visible.
    func impl_studio_journal_amend(turn: Turn, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        var input = input
        for key in ["__session_id", "session_id", "sessionId"] {
            input.removeValue(forKey: key)
        }
        guard let schema = try await listAvailableToolSchemas(named: ["studio_journal_amend"], turn: turn, surface: surface).first else {
            throw ToolFailureError("Studio amendment schema is unavailable.", effects: .none)
        }
        if let problem = JSONValue.object(input).schemaProblem(schema: try JSONValue.parse(schema.parametersJSON)) {
            throw ToolFailureError(
                "Amendment: \(problem.words). Amendments cannot change work, stance, refs or entry date.",
                argumentPath: problem.path, effects: .none,
                nextCall: ToolFailureError.call("app", ["find": .string("studio.amend")]),
                code: "studio_amend_unknown_fields", status: .refused,
                instruction: """
                    Use studio.journal with relations for a later encounter; use studio.amend only for factual corrections. Read accepted fields \
                    with next_call.
                    """,
                recovery: .correctArguments)
        }
        let entryId = try requireString(input, "entry_id")
        do {
            let (amendment, entry) = try await studioStore().appendJournalAmendment(
                entryId: entryId,
                reason: optionalString(input, "reason") ?? "",
                supersedes: optionalString(input, "supersedes"),
                correction: optionalString(input, "correction") ?? ""
            )
            // Wake context for the corrected pointer; a factual amendment is neither a new felt encounter nor a graph relation.
            await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
                namespace: "studio",
                stableID: entry.id,
                operation: .changed,
                canonicalLocator: studioStore().journalPath.standardizedFileURL.path,
                reason: "studio_journal_entry_amended"
            ))
            return .object([
                "status": .string("ok"),
                "amendment_id": .string(amendment.id),
                "entry_id": .string(entry.id),
                "amended_at": .string(amendment.amendedAt),
                "entry": entry.toJSON(),
                "note": .string(amendment.supersedes == nil
                    ? "Correction appended. The entry is unchanged on disk; it now reads with a dated correction block at the end."
                    : "Passage superseded. The original wording is kept and struck through, with your correction, its date and its reason beside it."),
            ])
        } catch let error as StudioError {
            return studioRefusal(error)
        }
    }

    // MARK: - After an entry lands

    /// The entry is already durable; derived consumer failures must not make the canonical write appear failed.
    @discardableResult
    private func studioJournalDidAppend(_ entry: StudioJournalEntry) async -> (report: StudioGraphIndexReport?, failures: [String]) {
        // Wake StudioContext with its namespace and locator; it rereads the journal, never treating the event as source data.
        await DerivedStateInvalidationCenter.shared.publish(DerivedSourceChange(
            namespace: "studio",
            stableID: entry.id,
            operation: .changed,
            canonicalLocator: studioStore().journalPath.standardizedFileURL.path,
            reason: "studio_journal_entry_filed"
        ))
        // Re-derive the whole journal idempotently so every append retains all current relation history.
        var report = await indexStudioJournalIntoGraph(reason: "entry_filed")
        // Cognition owns appraisal from the entry’s judgment (zero for abstention); publish only that an entry landed.
        if let studioJournalBus {
            await studioJournalBus.publish(entry)
        } else {
            report.failures.append("""
                Studio entry \(entry.id) is durable, but this dispatcher has no cognitive journal bus. Wire the owning runtime's studioJournalBus \
                at dispatcher assembly.
                """)
        }
        return report
    }

    /// A graph failure cannot negate the already durable journal write.
    @discardableResult
    private func indexStudioJournalIntoGraph(reason: String) async -> (report: StudioGraphIndexReport?, failures: [String]) {
        do {
            // Keep the journal's existing flock through the graph commit. A later refresh must read after this one writes, never replace newer citations with a
            // snapshot read before their append.
            return try await SwiftNativePersistenceCore.withFileLock(studioStore().journalPath) {
                // Index hot and archived entries so work and relation edges survive shelf trimming.
                let entries = try await studioStore().journalEntriesIncludingArchive()
                guard !entries.isEmpty else { return (nil, []) }
                let indexer = try SwiftNativeKnowledgeGraphIndexer(
                    // Share KnowledgeGraphContext’s store so Studio edges remain selectable through the same owner.
                    memorySQLitePath: dataRoot
                        .appendingPathComponent("memory/memory.sqlite")
                        .standardizedFileURL
                )
                let report = try await indexer.indexStudioJournal(entries)
                // Keep relations provenance-only; report missing citing graph edges without repair or blocking recall.
                let audit: StudioRelationAuditReport
                var failures: [String] = []
                var auditFailure: String?
                do {
                    audit = try await indexer.auditStudioRelations(entries)
                    if !audit.graphAvailable { auditFailure = "Studio relation audit unavailable: memory graph does not exist." }
                } catch {
                    audit = .unavailable
                    auditFailure = "Studio relation audit read failed: \(error.localizedDescription)"
                }
                if let auditFailure { failures.append(auditFailure) }
                do { try await StudioCanonTending.recordAudit(audit, failure: auditFailure, dataRoot: dataRoot) }
                catch { failures.append("""
                    Studio relation audit persistence failed at \(StudioCanonTending.auditHealthPath(dataRoot: dataRoot).path): \
                    \(error.localizedDescription)
                    """) }
                return (report, failures)
            }
        } catch {
            nativeLog("[studio] knowledge-graph index skipped (%@): %@",
                  reason, String(describing: error))
            return (nil, ["Studio graph projection \(reason) failed: \(error.localizedDescription)"])
        }
    }

    // MARK: - studio_recall

    /// Return journal words verbatim, newest first, with explicit pagination and no invented relevance score.
    func impl_studio_recall(turn: Turn, invocation: ChatToolInvocation, input: [String: JSONValue]) async throws -> JSONValue {
        var relationKind: StudioRelationKind?
        if let raw = optionalString(input, "relation_kind") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Strict caller schemas may send empty optional filters; an empty relation_kind is omitted.
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
            limit: Self.jsonInt(input["limit"]) ?? StudioRecallQuery.defaultLimit
        )
        let result = try await studioStore().recall(query)
        // Only a live local taste-judgment turn proves production use; share the canon seat and projection’s admission rules. Browsing, tending, bridge reads
        // and replays record no such use; tool input cannot grant that provenance.
        var countingFailure: JSONValue?
        if !result.entries.isEmpty,
           case .success = StudioCanonSeatGate.liveTurnProvenance(turn: turn),
           StudioCanonSeatGate.isProductionTasteJudgment(invocation: invocation) {
            countingFailure = await studioStore().noteRecallPulls(
                titles: result.entries.map { ($0.work.title, $0.work.creator) }
            )
        }
        var payload: [String: JSONValue] = [
            "status": .string("ok"),
            "entries": .array(result.entries.map { $0.toJSON() }),
            "returned": .int(Int64(result.entries.count)),
            "matched": .int(Int64(result.matchedCount)),
            "has_more": .bool(result.hasMore),
        ]
        if let countingFailure { payload["recall_counting"] = countingFailure }
        // Matches and counts cover only what was read: holes qualify them.
        if !result.historyUnreadable.isEmpty {
            payload["coverage"] = .string("partial")
            payload["history_unreadable"] = .array(result.historyUnreadable.map(JSONValue.string))
        }
        // An unreadable amendment may hide a correction on any returned entry; report that gap beside the results.
        if result.correctionsUnreadable {
            payload["corrections_unreadable"] = .bool(true)
            payload["corrections_note"] = .string(
                "journal/amendments.jsonl is damaged — corrections could not be read, so an entry here may already have been corrected in ways not shown")
        }
        return .object(payload)
    }
}
