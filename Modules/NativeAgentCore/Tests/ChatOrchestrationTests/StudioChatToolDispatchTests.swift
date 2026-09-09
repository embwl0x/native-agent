import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
// @testable for the overflow archiver's test seam (its maxLines/incoming
// parameters exist so the trim can be exercised without a hundred thousand
// entries) — the production path calls it with the registered budget.
@testable import PersistenceCore
// The trust-side registries are internal to TrustCenter; the studio lane's
// classification is part of its contract, so assert it here rather than in a
// second file that could drift from the tools it describes.
@testable import TrustCenter

// MARK: - studio_* dispatcher-surface tests (desk 903 phases 1–2)
//
// The studio chat lane: consults filed against the agent's taste, and the
// journal she writes herself. These tests drive the impls directly (the same
// surface DeskChatToolDispatchTests exercises) and are built around the design
// VETOES rather than around the happy path — a description-only consult must
// never become an encounter, an abstention must always be a valid outcome, and
// there must be no score anywhere.

@Suite("StudioChatToolDispatch")
struct StudioChatToolDispatchTests {

    @Test func shelfPrivacyAndMissingWork() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)
        let denied = await d.impl_studio_shelf(input: [:], surface: "slack", set: false)
        #expect(try object(denied, "denied")["status"] == .string("refused"))
        let empty = await d.impl_studio_shelf(input: [:], surface: "chat", set: false)
        #expect(try object(empty, "empty")["slots"] == .array([]))
        let store = SwiftNativeStudioStore(dataRoot: root)
        let entry = try await store.appendJournalEntry(
            encounteredAt: nil, work: StudioWork(title: "Pair"), reception: StudioReception(),
            artifactRefs: [root.appendingPathComponent("generated_images/absent.png").path, "designs/cafe.png"],
            origin: StudioOrigin(kind: .project), response: "The spacing holds.",
            stance: StudioStanceValue(kind: .open), relations: [], tags: [])
        let set = await d.impl_studio_shelf(input: ["slots": .array([.object([
            "entry_id": .string(entry.id), "title": .string("Chosen pair"), "selected_sentence": .string("The spacing holds.")
        ])])], surface: "chat", set: true)
        #expect(try object(set, "set")["status"] == .string("ok"))
        let read = await d.impl_studio_shelf(input: [:], surface: "codex-bridge", set: false)
        #expect(String(decoding: try read.serializedData(pretty: false), as: UTF8.self).contains("missing"))
        guard case .array(let cards)? = try object(read, "read")["slots"],
              case .object(let card)? = cards.first, case .array(let refs)? = card["work_refs"], refs.count == 2 else {
            Issue.record("Missing shelf work refs"); return
        }
        #expect(try object(refs[1], "relative")["ref"] == .string("designs/cafe.png"))
        #expect(try object(refs[1], "relative")["availability"] == .string("missing"))
        let protectedSentence = "Bearer " + String(repeating: "x", count: 32) + "."
        let protectedEntry = try await store.appendJournalEntry(
            encounteredAt: nil, work: StudioWork(title: "Protected"), reception: StudioReception(),
            artifactRefs: ["designs/protected.png"], origin: StudioOrigin(kind: .project), response: protectedSentence,
            stance: StudioStanceValue(kind: .open), relations: [], tags: [])
        _ = await d.impl_studio_shelf(input: ["slots": .array([.object([
            "entry_id": .string(protectedEntry.id), "title": .string("Protected"), "selected_sentence": .string(protectedSentence)
        ])])], surface: "chat", set: true)
        let protectedRead = await d.impl_studio_shelf(input: [:], surface: "chat", set: false)
        #expect(try object(protectedRead, "protected")["status"] == .string("refused"))
    }

    @Test func shelfDispatchAcceptsInjectedSessionAndRejectsUnknownArguments() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = SwiftToolDispatcher(dataRoot: root, enforceLazyToolLoading: true)
        let entry = try await SwiftNativeStudioStore(dataRoot: root).appendJournalEntry(
            encounteredAt: nil, work: StudioWork(title: "Work"), reception: StudioReception(),
            artifactRefs: ["designs/cafe.png"], origin: StudioOrigin(kind: .project),
            response: "The spacing holds.", stance: StudioStanceValue(kind: .open), relations: [], tags: [])
        try await ChatToolSessionContext.$verifiedSessionId.withValue("studio-shelf-test") {
            try await LLMCallContext.$turnActiveTools.withValue(["studio_shelf_read", "studio_shelf_set"]) {
                let set = try await d.dispatch(tool: "studio_shelf_set", input: ["slots": .array([.object([
                    "entry_id": .string(entry.id), "title": .string("Chosen title"),
                    "selected_sentence": .string("The spacing holds.")
                ])])], surface: "chat")
                #expect(try object(set, "set")["status"] == .string("ok"))
                let read = try await d.dispatch(tool: "studio_shelf_read", input: [:], surface: "chat")
                #expect(try object(read, "read")["status"] == .string("ok"))
                #expect(try StudioWorkingShelf(dataRoot: root).pointerLine() == "Working shelf: Chosen title; open with studio_shelf_read")
                for tool in ["studio_shelf_read", "studio_shelf_set"] {
                    let refused = try await d.dispatch(tool: tool, input: ["unexpected": .bool(true), "slots": .array([])], surface: "chat")
                    #expect(try object(refused, "unknown argument")["status"] == .string("refused"))
                }
                #expect(try StudioWorkingShelf(dataRoot: root).selections().count == 1)
            }
        }
    }

    private func hermeticRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioChatTool-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func dispatcher(_ root: URL) -> SwiftToolDispatcher {
        SwiftToolDispatcher(dataRoot: root)
    }

    private func object(_ value: JSONValue, _ label: String) throws -> [String: JSONValue] {
        guard case .object(let obj) = value else {
            Issue.record("\(label) is not an object: \(value)")
            throw CancellationError()
        }
        return obj
    }

    private func string(_ obj: [String: JSONValue], _ key: String) -> String? {
        if case .string(let s)? = obj[key] { return s }
        return nil
    }

    /// File a consult with real refs — the ordinary case the journal may build on.
    private func fileWorkConsult(_ d: SwiftToolDispatcher) async throws -> String {
        let result = try await d.impl_studio_consult(input: [
            "artifact_refs": .array([.string("/tmp/poster-v3.png")]),
            "question": .string("Does the type sit right against the photograph?"),
            "portion_available": .string("the whole poster, one size"),
            "stage": .string("near-final"),
        ])
        let obj = try object(result, "studio_consult")
        #expect(string(obj, "status") == "ok")
        return try #require(string(obj, "consult_id"))
    }

    // MARK: Registration + schema

    @Test("the four studio tools are catalog-registered, lazy, and trust-classified")
    func registration() {
        let names = ["studio_consult", "studio_consult_read", "studio_journal", "studio_recall", "studio_shelf_read", "studio_shelf_set"]
        for name in names {
            #expect(SwiftToolDispatcher.builtInToolNames.contains(name), "builtInToolNames missing \(name)")
            #expect(SwiftNativeSecurityCenter.builtinToolNames.contains(name),
                    "SecurityCenter builtinToolNames missing \(name)")
            // Lazy: consulting taste and journaling are asked for, never ambient.
            #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains(name),
                    "\(name) must stay lazy, not always-on")
            // No sieve misfire: none of these names reaches a third party, so
            // none of them belongs in the notification carve-out.
            #expect(!SwiftNativeSecurityCenter.notificationToolNames.contains(name),
                    "\(name) has no third-party side effect and must not be a notification tool")
        }
        // The classification itself, not just the registration. The two writes
        // are ledger-class (medium); the two reads are low. Anything that
        // escalated to .high would mean a sieve — external_send is the one that
        // could — had reached a tool that never leaves the machine.
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for write in ["studio_consult", "studio_journal", "studio_shelf_set"] {
            #expect(
                SwiftNativeSecurityCenter.canonicalToolRisk(tool: write, input: [:], dataRoot: root) == .medium,
                "\(write) must classify as a medium local write"
            )
        }
        for read in ["studio_consult_read", "studio_recall", "studio_shelf_read"] {
            #expect(
                SwiftNativeSecurityCenter.canonicalToolRisk(tool: read, input: [:], dataRoot: root) == .low,
                "\(read) must classify as a low-risk local read"
            )
        }
    }

    @Test("schemas are well formed and carry no score-shaped field")
    func schemasWellFormed() throws {
        let d = dispatcher(hermeticRoot())
        let schemas = d.builtInToolSchemas(includeFullMacFileTools: false)

        let consult = try #require(schemas.first { $0.name == "studio_consult" })
        let consultParsed = try JSONValue.parse(consult.parametersJSON)
        let consultObject = try object(consultParsed, "studio_consult schema")
        #expect(consultObject["required"] == .array([.string("question")]))
        let consultProperties = try object(try #require(consultObject["properties"]), "consult properties")
        for key in ["artifact_refs", "description", "portion_available", "project_context",
                    "stage", "constraints", "prior_discussion", "description_only"] {
            #expect(consultProperties[key] != nil, "studio_consult schema missing \(key)")
        }

        let journal = try #require(schemas.first { $0.name == "studio_journal" })
        let journalObject = try object(try JSONValue.parse(journal.parametersJSON), "studio_journal schema")
        #expect(journalObject["required"] == .array([.string("work"), .string("origin"), .string("stance")]),
                "response is NOT required — an abstained encounter owes no verdict")
        let journalProperties = try object(try #require(journalObject["properties"]), "journal properties")
        for key in ["work", "reception", "artifact_refs", "origin", "response",
                    "stance", "relations", "tags", "encountered_at"] {
            #expect(journalProperties[key] != nil, "studio_journal schema missing \(key)")
        }
        // The veto, checked as a property of the wire shape rather than a
        // promise in a comment.
        for banned in ["rating", "score", "sentiment", "confidence", "stars", "canon"] {
            #expect(journalProperties[banned] == nil, "studio_journal must have no \(banned) field")
        }

        let recall = try #require(schemas.first { $0.name == "studio_recall" })
        let recallObject = try object(try JSONValue.parse(recall.parametersJSON), "studio_recall schema")
        #expect(recallObject["required"] == .array([]))
        let recallProperties = try object(try #require(recallObject["properties"]), "recall properties")
        for key in ["query", "title", "creator", "medium", "tag", "relation_kind", "related_to", "limit"] {
            #expect(recallProperties[key] != nil, "studio_recall schema missing \(key)")
        }
        for banned in ["relevance", "score", "rank", "min_score"] {
            #expect(recallProperties[banned] == nil, "studio_recall must expose no \(banned)")
        }
        // EVERY recall filter must be expressible as "not filtering". A strict
        // provider schema sends every property on the wire, so optional has to
        // mean null-admitting on the type itself, not merely absent from
        // `required`.
        for key in ["query", "title", "creator", "medium", "tag", "relation_kind", "related_to", "limit"] {
            let field = try object(try #require(recallProperties[key]), "recall.\(key)")
            guard case .array(let types)? = field["type"] else {
                Issue.record("studio_recall.\(key) must admit null in its type"); continue
            }
            #expect(types.contains(.string("null")), "studio_recall.\(key) must admit null")
        }
        // An enum is exhaustive, so null has to be a MEMBER of it too — the
        // exact shape that forced a relation filter onto every live recall.
        let relationField = try object(try #require(recallProperties["relation_kind"]), "relation_kind")
        guard case .array(let relationEnum)? = relationField["enum"] else {
            Issue.record("relation_kind must carry an enum"); return
        }
        #expect(relationEnum.contains(.null), "relation_kind's enum must admit null")
    }

    @Test("the journal feed's retention is path-owned")
    func capPolicyRegistered() {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeStudioStore(dataRoot: root)
        let policy = jsonlPathOwnedCapPolicy(for: store.journalPath)
        #expect(policy != nil, "studio/journal/journal.jsonl must be registered in the path-owned cap registry")
        #expect(policy?.maxLines == JSONLLineCaps.studioJournal)
        // A curated life record, not telemetry: the budget has to be generous
        // enough that the cap is a runaway backstop, never retention.
        #expect(JSONLLineCaps.studioJournal >= 100_000)
    }

    // MARK: Consults

    @Test("a consult files and reads back verbatim under a stable id")
    func consultRoundTrips() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)

        let filed = try await d.impl_studio_consult(input: [
            "artifact_refs": .array([.string("/tmp/cover-a.png"), .string("https://example.invalid/cover-b")]),
            "question": .string("Which cover holds up at thumbnail size?"),
            "portion_available": .string("both covers, full resolution"),
            "project_context": .string("a reissue series"),
            "stage": .string("draft"),
            "constraints": .string("must work in one colour"),
            "prior_discussion": .string("we already threw out the serif version"),
        ])
        let filedObject = try object(filed, "studio_consult")
        let id = try #require(string(filedObject, "consult_id"))
        #expect(filedObject["description_only"] == .bool(false))

        // The id is stable: the same id fetches the same envelope, verbatim.
        let read = try object(
            try await d.impl_studio_consult_read(input: ["consult_id": .string(id)]),
            "studio_consult_read"
        )
        #expect(string(read, "status") == "ok")
        let envelope = try object(try #require(read["consult"]), "consult envelope")
        #expect(string(envelope, "id") == id)
        #expect(string(envelope, "question") == "Which cover holds up at thumbnail size?")
        #expect(string(envelope, "constraints") == "must work in one colour")
        #expect(string(envelope, "prior_discussion") == "we already threw out the serif version")
        #expect(envelope["artifact_refs"] == .array([
            .string("/tmp/cover-a.png"), .string("https://example.invalid/cover-b"),
        ]))
        // Filing a consult writes NOTHING to the journal.
        let store = SwiftNativeStudioStore(dataRoot: root)
        #expect(try await store.readJournal().isEmpty,
                "studio_consult must never auto-append a journal entry")

        // Reading a consult that does not exist is an honest refusal, not a guess.
        let missing = try object(
            try await d.impl_studio_consult_read(input: ["consult_id": .string("consult_20260101T000000_deadbeef")]),
            "missing consult"
        )
        #expect(string(missing, "status") == "refused")
    }

    @Test("a consult with no artifact refs must declare itself description-only")
    func consultWithoutRefsMustBeFlagged() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)

        let unflagged = try object(
            try await d.impl_studio_consult(input: [
                "description": .string("a poster idea: one big photograph, type over the sky"),
                "question": .string("is this worth making?"),
            ]),
            "unflagged consult"
        )
        #expect(string(unflagged, "status") == "refused")
        #expect(string(unflagged, "reason")?.contains("description_only") == true)

        // Flagged honestly, it files fine — concept critique is allowed.
        let flagged = try object(
            try await d.impl_studio_consult(input: [
                "description": .string("a poster idea: one big photograph, type over the sky"),
                "question": .string("is this worth making?"),
                "description_only": .bool(true),
            ]),
            "flagged consult"
        )
        #expect(string(flagged, "status") == "ok")
        #expect(flagged["description_only"] == .bool(true))

        // …but with neither refs nor a description there is nothing to judge.
        let empty = try object(
            try await d.impl_studio_consult(input: [
                "question": .string("thoughts?"),
                "description_only": .bool(true),
            ]),
            "empty consult"
        )
        #expect(string(empty, "status") == "refused")
    }

    @Test("a description-only consult can never become a journal encounter")
    func descriptionOnlyConsultIsNotAnEncounter() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)

        let flagged = try object(
            try await d.impl_studio_consult(input: [
                "description": .string("a brief: warm, editorial, no gradients"),
                "question": .string("does this direction hold?"),
                "description_only": .bool(true),
            ]),
            "description-only consult"
        )
        let descriptionOnlyId = try #require(string(flagged, "consult_id"))

        let refused = try object(
            try await d.impl_studio_journal(input: [
                "work": .object(["title": .string("the brief")]),
                "origin": .object(["kind": .string("consult"), "ref": .string(descriptionOnlyId)]),
                "stance": .object(["kind": .string("formed")]),
                "response": .string("I liked it."),
            ]),
            "journal from a description-only consult"
        )
        #expect(string(refused, "status") == "refused")
        #expect(string(refused, "reason")?.contains("description-only") == true)
        let store = SwiftNativeStudioStore(dataRoot: root)
        #expect(try await store.readJournal().isEmpty, "the refused entry must not have been written")

        // origin.kind=consult with no ref cannot be checked, so it is refused too.
        let unref = try object(
            try await d.impl_studio_journal(input: [
                "work": .object(["title": .string("something")]),
                "origin": .object(["kind": .string("consult")]),
                "stance": .object(["kind": .string("formed")]),
                "response": .string("…"),
            ]),
            "consult origin with no ref"
        )
        #expect(string(unref, "status") == "refused")

        // The same entry against a consult that carried real work is accepted.
        let workConsultId = try await fileWorkConsult(d)
        let accepted = try object(
            try await d.impl_studio_journal(input: [
                "work": .object(["title": .string("Poster v3"), "creator": .string("the studio")]),
                "origin": .object(["kind": .string("consult"), "ref": .string(workConsultId)]),
                "stance": .object(["kind": .string("formed")]),
                "response": .string("The type is fighting the horizon, not sitting on it."),
            ]),
            "journal from a real consult"
        )
        #expect(string(accepted, "status") == "ok")
    }

    @Test("relabelling the origin cannot launder a description-only consult")
    func descriptionOnlyCannotBeLaunderedByOriginKind() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)
        let store = SwiftNativeStudioStore(dataRoot: root)

        let descriptionOnlyId = try #require(string(try object(
            try await d.impl_studio_consult(input: [
                "description": .string("a brief: warm, editorial, no gradients"),
                "question": .string("does this direction hold?"),
                "description_only": .bool(true),
            ]), "description-only consult"), "consult_id"))

        // The veto keys on what the REF RESOLVES TO, not on the label. Calling
        // the origin "wandering" or "project" must not buy the entry anything.
        for kind in ["wandering", "project"] {
            let laundered = try object(
                try await d.impl_studio_journal(input: [
                    "work": .object(["title": .string("the brief")]),
                    "origin": .object(["kind": .string(kind), "ref": .string(descriptionOnlyId)]),
                    "stance": .object(["kind": .string("formed")]),
                    "response": .string("I liked it."),
                ]),
                "journal with origin.kind=\(kind)"
            )
            #expect(string(laundered, "status") == "refused",
                    "origin.kind=\(kind) must not launder a description-only consult")
            #expect(string(laundered, "reason")?.contains("description-only") == true)
        }
        #expect(try await store.readJournal().isEmpty)

        // A ref that names no consult at all is still fine — an origin ref is
        // "whatever identifies the source".
        let ordinaryRef = try object(
            try await d.impl_studio_journal(input: [
                "work": .object(["title": .string("a doorway on Rue de Seine")]),
                "origin": .object(["kind": .string("wandering"), "ref": .string("a walk, Thursday")]),
                "stance": .object(["kind": .string("formed")]),
                "response": .string("The proportion is wrong and I like it more for that."),
            ]),
            "wandering with a non-consult ref"
        )
        #expect(string(ordinaryRef, "status") == "ok")

        // …as is a ref to a consult that carried real work.
        let workConsultId = try await fileWorkConsult(d)
        let real = try object(
            try await d.impl_studio_journal(input: [
                "work": .object(["title": .string("Poster v3")]),
                "origin": .object(["kind": .string("project"), "ref": .string(workConsultId)]),
                "stance": .object(["kind": .string("formed")]),
                "response": .string("The type is fighting the horizon."),
            ]),
            "project origin naming a real consult"
        )
        #expect(string(real, "status") == "ok")
    }

    // MARK: Journal

    @Test("a journal entry round-trips the whole schema")
    func journalEntryRoundTrips() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)

        let first = try object(
            try await d.impl_studio_journal(input: [
                "work": .object(["title": .string("Le Mépris"), "medium": .string("film")]),
                "origin": .object(["kind": .string("wandering")]),
                "stance": .object(["kind": .string("open")]),
                "response": .string("The colour is doing the argument."),
            ]),
            "first entry"
        )
        let firstId = try #require(string(first, "entry_id"))

        let full = try object(
            try await d.impl_studio_journal(input: [
                "encountered_at": .string("2026-08-30T19:00:00.000000+00:00"),
                "work": .object([
                    "title": .string("Casa Malaparte"),
                    "creator": .string("Adalberto Libera"),
                    "medium": .string("architecture"),
                    "date": .string("1937"),
                    "version": .string("as built"),
                    "edition": .string("photographed 1963"),
                ]),
                "reception": .object([
                    "how": .string("reproduction"),
                    "whole_or_part": .string("a set of eleven photographs, exterior only"),
                ]),
                "artifact_refs": .array([.string("/tmp/malaparte/01.jpg")]),
                "origin": .object(["kind": .string("project"), "ref": .string("desk_1")]),
                "response": .string("The stair is the whole building; everything else is a plinth for it."),
                "stance": .object(["kind": .string("formed"), "reason": .string("no reason needed")]),
                "relations": .array([.object([
                    "kind": .string("deepens"), "entry_id": .string(firstId),
                ])]),
                "tags": .array([.string("stairs"), .string("mediterranean")]),
            ]),
            "full entry"
        )
        #expect(string(full, "status") == "ok")
        let entry = try object(try #require(full["entry"]), "entry")
        #expect(string(entry, "encountered_at") == "2026-08-30T19:00:00.000000+00:00")
        #expect(string(entry, "recorded_at") != nil, "the server stamps recorded_at")
        #expect(string(entry, "id")?.hasPrefix("entry_") == true, "the server stamps the id")
        #expect(entry["work"] == .object([
            "title": .string("Casa Malaparte"),
            "creator": .string("Adalberto Libera"),
            "medium": .string("architecture"),
            "date": .string("1937"),
            "version": .string("as built"),
            "edition": .string("photographed 1963"),
        ]))
        #expect(entry["reception"] == .object([
            "how": .string("reproduction"),
            "whole_or_part": .string("a set of eleven photographs, exterior only"),
        ]))
        #expect(entry["origin"] == .object(["kind": .string("project"), "ref": .string("desk_1")]))
        #expect(entry["stance"] == .object(["kind": .string("formed"), "reason": .string("no reason needed")]))
        #expect(entry["relations"] == .array([.object([
            "kind": .string("deepens"), "entry_id": .string(firstId),
        ])]))
        #expect(entry["tags"] == .array([.string("stairs"), .string("mediterranean")]))
        #expect(entry["artifact_refs"] == .array([.string("/tmp/malaparte/01.jpg")]))

        // It survives a re-read off disk unchanged.
        let store = SwiftNativeStudioStore(dataRoot: root)
        let onDisk = try await store.readJournal()
        #expect(onDisk.count == 2)
        #expect(onDisk.last?.toJSON() == .object(entry))
    }

    @Test("the journal is append-only: a later entry never edits an earlier one")
    func journalIsAppendOnly() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)
        let store = SwiftNativeStudioStore(dataRoot: root)

        let firstId = try #require(string(try object(
            try await d.impl_studio_journal(input: [
                "work": .object(["title": .string("Vertigo"), "creator": .string("Hitchcock")]),
                "origin": .object(["kind": .string("wandering")]),
                "stance": .object(["kind": .string("formed")]),
                "response": .string("Too cold to love."),
            ]), "first"), "entry_id"))
        let afterFirst = try String(contentsOf: store.journalPath, encoding: .utf8)

        // Changing her mind is a NEW entry that REVISES the old one. Both stay.
        let secondId = try #require(string(try object(
            try await d.impl_studio_journal(input: [
                "work": .object(["title": .string("Vertigo"), "creator": .string("Hitchcock")]),
                "origin": .object(["kind": .string("wandering")]),
                "stance": .object(["kind": .string("formed")]),
                "response": .string("Wrong the first time: the coldness IS the feeling."),
                "relations": .array([.object([
                    "kind": .string("revises"), "entry_id": .string(firstId),
                ])]),
            ]), "second"), "entry_id"))

        let afterSecond = try String(contentsOf: store.journalPath, encoding: .utf8)
        #expect(afterSecond.hasPrefix(afterFirst),
                "an append must leave every earlier byte of the journal untouched")
        let entries = try await store.readJournal()
        #expect(entries.map(\.id) == [firstId, secondId])
        #expect(entries.first?.response == "Too cold to love.",
                "the contradicted judgment is preserved, never flattened")

        // And there is no mutation surface at all: the whole studio lane is the
        // registered tools below, none of which can edit or delete an entry.
        //
        // 2026-09-06: the canon pair joined the lane (`studio_canon` reads the
        // proposals and their evidence, `studio_canon_resolve` approves or
        // denies one). Neither touches the journal — a resolution writes canon
        // standing and leaves every entry and every graph edge exactly as they
        // were — so the append-only contract this row guards is unchanged, and
        // the set is re-pinned rather than relaxed.
        let studioTools = SwiftToolDispatcher.builtInToolNames.filter { $0.hasPrefix("studio_") }
        #expect(Set(studioTools) == [
            "studio_canon", "studio_canon_resolve", "studio_consult",
            "studio_consult_read", "studio_journal", "studio_recall",
            "studio_shelf_read", "studio_shelf_set",
        ], "a studio update/delete tool would break the append-only contract")
        #expect(
            !studioTools.contains { name in
                ["update", "edit", "delete", "remove", "rewrite"].contains { name.contains($0) }
            },
            "a studio update/delete tool would break the append-only contract"
        )
    }

    @Test("abstaining is a valid outcome and needs no response")
    func abstainedStanceIsValid() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)

        let abstained = try object(
            try await d.impl_studio_journal(input: [
                "work": .object(["title": .string("Sleep"), "creator": .string("Warhol")]),
                "reception": .object(["how": .string("excerpt"), "whole_or_part": .string("four minutes of five hours")]),
                "origin": .object(["kind": .string("wandering")]),
                "stance": .object([
                    "kind": .string("abstained"),
                    "reason": .string("Four minutes of it is not enough to judge it honestly."),
                ]),
            ]),
            "abstained entry"
        )
        #expect(string(abstained, "status") == "ok")
        let entry = try object(try #require(abstained["entry"]), "entry")
        #expect(entry["response"] == nil, "an abstained entry may carry no response at all")
        #expect(entry["stance"] == .object([
            "kind": .string("abstained"),
            "reason": .string("Four minutes of it is not enough to judge it honestly."),
        ]))

        // A formed stance still owes its judgment.
        let missingResponse = try object(
            try await d.impl_studio_journal(input: [
                "work": .object(["title": .string("Sleep")]),
                "origin": .object(["kind": .string("wandering")]),
                "stance": .object(["kind": .string("formed")]),
            ]),
            "formed with no response"
        )
        #expect(string(missingResponse, "status") == "refused")
    }

    @Test("the dispatcher's injected session marker is plumbing, not payload")
    func runtimeSessionMarkerIsStrippedAtTopLevelOnly() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)

        // The lazy-tool dispatch path stamps __session_id onto every input
        // (the live regression: the first real journal write was refused for
        // the dispatcher's own marker). All three extractSessionId spellings
        // must pass at the top level.
        let written = try object(
            try await d.impl_studio_journal(input: [
                "__session_id": .string("session-abc"),
                "session_id": .string("session-abc"),
                "sessionId": .string("session-abc"),
                "work": .object(["title": .string("Chungking Express"), "creator": .string("Wong Kar-wai")]),
                "reception": .object(["how": .string("screening"), "whole_or_part": .string("whole")]),
                "origin": .object(["kind": .string("wandering")]),
                "response": .string("The clocks and the canned pineapple: longing given a shelf life."),
                "stance": .object(["kind": .string("formed")]),
            ]),
            "entry with runtime markers"
        )
        #expect(string(written, "status") == "ok")

        // Nested, the same spelling is a caller field like any other: it
        // throws as an unknown field, named by path.
        await #expect(throws: AutonomyGateError.self) {
            _ = try await d.impl_studio_journal(input: [
                "work": .object(["title": .string("Chungking Express")]),
                "origin": .object(["kind": .string("wandering")]),
                "response": .string("x"),
                "stance": .object(["kind": .string("formed"), "session_id": .string("smuggled")]),
            ])
        }
    }

    @Test("a score-shaped field is refused, never silently dropped")
    func scoreShapedFieldsAreRefused() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)

        await #expect(throws: (any Error).self, "there is no rating field, and pretending to accept one is worse than refusing") {
            _ = try await d.impl_studio_journal(input: [
                "work": .object(["title": .string("Ocean Park #129")]),
                "origin": .object(["kind": .string("wandering")]),
                "stance": .object(["kind": .string("formed")]),
                "response": .string("The pale band is doing all the work."),
                "rating": .int(4),
            ])
        }
        let store = SwiftNativeStudioStore(dataRoot: root)
        #expect(try await store.readJournal().isEmpty)
    }

    @Test("a score smuggled into a NESTED object is refused, and named")
    func nestedUnknownFieldsAreRefused() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)
        let store = SwiftNativeStudioStore(dataRoot: root)

        /// Runs the call and returns the refusal text, or nil if it was accepted.
        func refusalReason(_ input: [String: JSONValue]) async -> String? {
            do {
                _ = try await d.impl_studio_journal(input: input)
                return nil
            } catch {
                return "\(error)"
            }
        }

        // stance.confidence — the exact hole the top-level-only check left open.
        let stanceReason = await refusalReason([
            "work": .object(["title": .string("Ocean Park #129")]),
            "origin": .object(["kind": .string("wandering")]),
            "stance": .object(["kind": .string("formed"), "confidence": .double(0.9)]),
            "response": .string("The pale band is doing all the work."),
        ])
        #expect(stanceReason?.contains("stance.confidence") == true,
                "the refusal must NAME the smuggled field; got: \(stanceReason ?? "accepted")")

        // …and every other nested position: work, reception, origin, relations.
        let nestedCases: [(label: String, path: String, input: [String: JSONValue])] = [
            ("work", "work.score", [
                "work": .object(["title": .string("A"), "score": .int(9)]),
                "origin": .object(["kind": .string("wandering")]),
                "stance": .object(["kind": .string("formed")]),
                "response": .string("…"),
            ]),
            ("reception", "reception.rating", [
                "work": .object(["title": .string("A")]),
                "reception": .object(["how": .string("original"), "rating": .int(5)]),
                "origin": .object(["kind": .string("wandering")]),
                "stance": .object(["kind": .string("formed")]),
                "response": .string("…"),
            ]),
            ("origin", "origin.sentiment", [
                "work": .object(["title": .string("A")]),
                "origin": .object(["kind": .string("wandering"), "sentiment": .string("positive")]),
                "stance": .object(["kind": .string("formed")]),
                "response": .string("…"),
            ]),
            ("relations item", "relations[0].weight", [
                "work": .object(["title": .string("A")]),
                "origin": .object(["kind": .string("wandering")]),
                "stance": .object(["kind": .string("formed")]),
                "response": .string("…"),
                "relations": .array([.object([
                    "kind": .string("echoes"),
                    "entry_id": .string("entry_20260101T000000_abcdef01"),
                    "weight": .double(0.4),
                ])]),
            ]),
        ]
        for testCase in nestedCases {
            let reason = await refusalReason(testCase.input)
            #expect(reason?.contains(testCase.path) == true,
                    "a smuggled field in \(testCase.label) must be refused and named as \(testCase.path); got: \(reason ?? "accepted")")
        }
        #expect(try await store.readJournal().isEmpty, "no refused entry may have been written")

        // The legitimate nested shape still passes — the check names fields, it
        // does not forbid depth.
        let ok = try object(
            try await d.impl_studio_journal(input: [
                "work": .object(["title": .string("A"), "creator": .string("B"), "edition": .string("first")]),
                "reception": .object(["how": .string("original"), "whole_or_part": .string("whole")]),
                "origin": .object(["kind": .string("wandering"), "ref": .string("a walk")]),
                "stance": .object(["kind": .string("formed"), "reason": .string("clear enough")]),
                "response": .string("…"),
            ]),
            "well-formed nested entry"
        )
        #expect(string(ok, "status") == "ok")
    }

    // MARK: The cap must never destroy an entry

    /// Seed `count` journal lines directly, bypassing the tool layer — these
    /// tests are about what the CAP does to bytes already on disk.
    private func seedJournal(_ store: SwiftNativeStudioStore, count: Int) throws -> [String] {
        try FileManager.default.createDirectory(
            at: store.journalPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let lines = (0..<count).map { #"{"id":"entry_seed_\#($0)","response":"judgment \#($0)"}"# }
        try (lines.joined(separator: "\n") + "\n").write(to: store.journalPath, atomically: true, encoding: .utf8)
        return lines
    }

    @Test("the cap archives the oldest lines before anything can trim them")
    func overflowIsArchivedBeforeTrim() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeStudioStore(dataRoot: root)
        let seeded = try seedJournal(store, count: 5)
        let before = try String(contentsOf: store.journalPath, encoding: .utf8)

        // Cap 3, one line about to be appended: 5 + 1 - 3 = the 3 oldest go.
        try await store.archiveJournalOverflowIfNeeded(maxLines: 3, incoming: 1)

        let archives = try store.journalArchivePaths()
        #expect(archives.count == 1, "the overflow must land on exactly one archive file")
        let archived = try String(contentsOf: try #require(archives.first), encoding: .utf8)
        #expect(archived == seeded.prefix(3).joined(separator: "\n") + "\n",
                "the archive must hold the doomed lines byte for byte, oldest first")
        // The archiver moves nothing on its own — it only guarantees the lines
        // exist elsewhere before the cap gets to them.
        #expect(try String(contentsOf: store.journalPath, encoding: .utf8) == before)

        // The trim event is recorded.
        let receipts = try await store.persistence.readJSONL(store.journalTrimReceiptsPath)
        #expect(receipts.count == 1)
        let receipt = try object(try #require(receipts.first), "trim receipt")
        #expect(receipt["archived_lines"] == .int(3))
        #expect(receipt["cap"] == .int(3))
        #expect(string(receipt, "archive") == archives.first?.lastPathComponent)

        // THE ARITHMETIC MATCHES THE REAL CAP: run the actual trim the append
        // path would run, on a file at the same post-append size, and it drops
        // exactly what was archived — no more, no less.
        let scratch = root.appendingPathComponent("scratch.jsonl")
        try ((seeded + [#"{"id":"entry_seed_5"}"#]).joined(separator: "\n") + "\n")
            .write(to: scratch, atomically: true, encoding: .utf8)
        let dropped = try enforceJSONLLineCap(at: scratch, maxLines: 3)
        #expect(dropped == 3, "the archiver must archive exactly the lines enforceJSONLLineCap drops")

        // Under the cap, the check is a no-op: nothing archived, no receipt.
        let quiet = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: quiet) }
        let quietStore = SwiftNativeStudioStore(dataRoot: quiet)
        _ = try seedJournal(quietStore, count: 5)
        try await quietStore.archiveJournalOverflowIfNeeded(maxLines: 1000, incoming: 1)
        #expect(try quietStore.journalArchivePaths().isEmpty)
    }

    @Test("a failed archive blocks the trim outright")
    func failedArchiveBlocksTrim() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeStudioStore(dataRoot: root)
        _ = try seedJournal(store, count: 5)
        let before = try String(contentsOf: store.journalPath, encoding: .utf8)

        // Occupy the archive path with a DIRECTORY so the shelf cannot be
        // written. A shelf that fails is a reason to stop, never a reason to
        // drop the oldest entries quietly.
        let now = Date()
        try FileManager.default.createDirectory(
            at: store.journalArchivePath(now: now), withIntermediateDirectories: true
        )

        await #expect(throws: (any Error).self, "an unwritable archive must abort, not fall through to a trim") {
            try await store.archiveJournalOverflowIfNeeded(maxLines: 3, incoming: 1, now: now)
        }
        // Nothing lost, nothing trimmed, and no receipt claiming otherwise.
        #expect(try String(contentsOf: store.journalPath, encoding: .utf8) == before)
        #expect(!FileManager.default.fileExists(atPath: store.journalTrimReceiptsPath.path),
                "a failed archive must not leave a receipt for a trim that never happened")
    }

    @Test("the archiver runs on the real append path, before every possible trim")
    func archiverIsWiredIntoTheProductionAppendPath() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)
        let store = SwiftNativeStudioStore(dataRoot: root)

        // The registered policy carries NO byte trigger, which is what makes the
        // pre-trim hook fire on every append rather than only past some size.
        #expect(jsonlPathOwnedCapPolicy(for: store.journalPath)?.trimWhenBytesExceed == nil,
                "a byte trigger would let appends reach the cap without the hook running")

        let observed = LockedBox<[Int]>([])
        try await SwiftNativeStudioStore.$journalOverflowCheckObserver.withValue({ count in
            observed.set(observed.get() + [count])
        }) {
            for title in ["Blue", "Chroma"] {
                let result = try await d.impl_studio_journal(input: [
                    "work": .object(["title": .string(title)]),
                    "origin": .object(["kind": .string("wandering")]),
                    "stance": .object(["kind": .string("formed")]),
                    "response": .string("…"),
                ])
                #expect(string(try object(result, "journal"), "status") == "ok")
            }
        }
        let counts = observed.get()
        #expect(counts.count == 2, "the pre-trim check must run on every journal append, got \(counts.count)")
        #expect(counts.allSatisfy { $0 == 0 }, "a journal far under its cap has nothing to archive")
        #expect(try await store.readJournal().count == 2)
    }

    // MARK: Recall

    @Test("recall treats an empty relation_kind as an omitted filter")
    func emptyRelationKindIsOmittedNotRefused() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)
        _ = try await d.impl_studio_journal(input: [
            "work": .object(["title": .string("In Praise of Shadows"), "creator": .string("Tanizaki")]),
            "origin": .object(["kind": .string("wandering")]),
            "response": .string("Dimness as a material."),
            "stance": .object(["kind": .string("formed")]),
        ])
        // Caller models that serialize every optional field send "" for the
        // ones they mean to omit; a relation-less entry must stay findable.
        let result = try object(
            try await d.impl_studio_recall(input: [
                "relation_kind": .string(""),
                "title": .string("Shadows"),
            ]),
            "recall with empty relation_kind"
        )
        #expect(string(result, "status") == "ok")
        #expect(result["matched"] == .int(1))
    }

    @Test("recall finds by creator, tag and relation, and returns the response verbatim")
    func recallFindsAndReturnsVerbatim() async throws {
        let root = hermeticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = dispatcher(root)

        let judgment = "The blue is not a colour here, it is a distance — and it keeps moving away."
        let firstId = try #require(string(try object(
            try await d.impl_studio_journal(input: [
                "work": .object([
                    "title": .string("Blue"), "creator": .string("Derek Jarman"), "medium": .string("film"),
                ]),
                "origin": .object(["kind": .string("wandering")]),
                "stance": .object(["kind": .string("formed")]),
                "response": .string(judgment),
                "tags": .array([.string("colour"), .string("absence")]),
            ]), "first"), "entry_id"))

        let secondId = try #require(string(try object(
            try await d.impl_studio_journal(input: [
                "work": .object([
                    "title": .string("Chroma"), "creator": .string("Derek Jarman"), "medium": .string("book"),
                ]),
                "origin": .object(["kind": .string("wandering")]),
                "stance": .object(["kind": .string("open")]),
                "response": .string("Reads like the notes for the film."),
                "relations": .array([.object([
                    "kind": .string("deepens"), "entry_id": .string(firstId),
                ])]),
            ]), "second"), "entry_id"))

        _ = try await d.impl_studio_journal(input: [
            "work": .object(["title": .string("Seagram Building"), "creator": .string("Mies")]),
            "origin": .object(["kind": .string("wandering")]),
            "stance": .object(["kind": .string("formed")]),
            "response": .string("Bronze that refuses to be shiny."),
        ])

        // By creator, newest first.
        let byCreator = try object(
            try await d.impl_studio_recall(input: ["creator": .string("jarman")]),
            "recall by creator"
        )
        #expect(byCreator["matched"] == .int(2))
        #expect(byCreator["has_more"] == .bool(false))
        guard case .array(let rows)? = byCreator["entries"] else {
            Issue.record("recall returned no entries array"); return
        }
        #expect(rows.count == 2)
        let newest = try object(rows[0], "newest entry")
        #expect(string(newest, "id") == secondId, "newest first")

        // By tag, and the response comes back VERBATIM — the writing is the point.
        let byTag = try object(
            try await d.impl_studio_recall(input: ["tag": .string("Absence")]),
            "recall by tag"
        )
        guard case .array(let tagged)? = byTag["entries"], tagged.count == 1 else {
            Issue.record("tag recall should match exactly one entry"); return
        }
        #expect(string(try object(tagged[0], "tagged entry"), "response") == judgment)

        // By relation kind and by target entry.
        let byRelation = try object(
            try await d.impl_studio_recall(input: ["relation_kind": .string("deepens")]),
            "recall by relation kind"
        )
        #expect(byRelation["matched"] == .int(1))
        let related = try object(
            try await d.impl_studio_recall(input: ["related_to": .string(firstId)]),
            "recall by related_to"
        )
        #expect(related["matched"] == .int(1))

        // Free text reaches into the response itself.
        let byText = try object(
            try await d.impl_studio_recall(input: ["query": .string("keeps moving away")]),
            "recall by free text"
        )
        #expect(byText["matched"] == .int(1))

        // Bounded, with has_more stated outright rather than implied.
        let bounded = try object(
            try await d.impl_studio_recall(input: ["limit": .int(1)]),
            "bounded recall"
        )
        #expect(bounded["returned"] == .int(1))
        #expect(bounded["matched"] == .int(3))
        #expect(bounded["has_more"] == .bool(true))
        // No score is exposed anywhere in a result.
        for key in ["score", "relevance", "rank"] {
            #expect(bounded[key] == nil, "recall must expose no \(key)")
        }

        // The live 2026-08-31 shape: a strict provider sends every property,
        // null for the ones that are not filtering. An entry with NO relations
        // must still come back.
        let unfiltered = try object(
            try await d.impl_studio_recall(input: [
                "query": .null, "title": .null, "creator": .null, "medium": .null,
                "tag": .null, "relation_kind": .null, "related_to": .null, "limit": .null,
            ]),
            "all-null recall"
        )
        #expect(unfiltered["matched"] == .int(3), "null filters must filter nothing")

        // AND semantics survive: only the supplied filter narrows.
        let onlyTitle = try object(
            try await d.impl_studio_recall(input: [
                "query": .null, "creator": .null, "medium": .null, "tag": .null,
                "relation_kind": .null, "related_to": .null,
                "title": .string("Seagram"),
            ]),
            "one supplied filter"
        )
        #expect(onlyTitle["matched"] == .int(1))
    }
}
