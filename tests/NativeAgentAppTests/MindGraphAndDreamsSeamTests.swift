// EVAL COVERAGE — fence `app.mind`, wave A (2026-08-23).
//
// Knowledge Graph + Dreams. Both surfaces fail the same way: a WRITER changes
// shape and the reader quietly drops rows, leaving a filter-shaped empty state
// ("No entities match these filters") in place of a parse bug. So these evals
// run the real chain — MemoryV2 store → the real KG indexer → the real checked
// reader envelope → the app's own `KGEntityResponse` decoder → the view's own
// `parseKGDate` / time-window filter — against a temp data root.
import Foundation
import KnowledgeGraph
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

// MARK: - helpers

private func graphTempRoot(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MindGraph-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Seed a real memory store + real KG index, then read it back through the same
/// checked-reader envelope `NativeClient.getKnowledgeGraph(page:)` decodes.
private func seededGraphResponse(
    root: URL,
    facts: [(id: String, content: String)]
) async throws -> KGEntityResponse {
    let storage = try MemoryStorage(dataRoot: root)
    let indexer = try SwiftNativeKnowledgeGraphIndexer(memorySQLitePath: await storage.path)
    for fact in facts {
        _ = try await storage.insertMemory(StoredMemory(id: fact.id, content: fact.content))
        try await indexer.indexMemory(KnowledgeGraphMemoryFact(
            id: fact.id,
            content: fact.content,
            createdAt: "2026-08-20T00:00:00Z",
            updatedAt: "2026-08-20T00:00:00Z"
        ))
    }
    let reader = makeKnowledgeGraphReader(
        graphPath: root
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("knowledge_graph.json")
    )
    let envelope = try await reader.allEntitiesChecked(page: 0)
    let data = try envelope.serializedData(pretty: false)
    return try JSONDecoder.nativeAgent.decode(KGEntityResponse.self, from: data)
}

/// Read one nested boolean straight out of the persisted trust policy. The app's
/// `TrustPolicy` model does not decode `personalityPolicy` at all, so the dream
/// kill switch is only observable on disk — which is also where the deep merge
/// either landed or did not.
private func storedBool(_ root: URL, _ section: String, _ key: String) throws -> Bool? {
    let url = root
        .appendingPathComponent("trust", isDirectory: true)
        .appendingPathComponent("policy.json")
    let raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
    guard let object = raw as? [String: Any],
          let block = object[section] as? [String: Any] else { return nil }
    return block[key] as? Bool
}

// MARK: - parseKGDate ↔ the writer's real stamps
//        (logic.kg.parseKGDate / api.KnowledgeGraphView.parseKGDate /
//         ui.kg.filter.timeWindow)

@Suite("Mind KG — timestamp parse seam")
struct MindKGTimestampTests {

    /// `displayEntities` excludes any entity whose `last_seen` AND `first_seen`
    /// both fail to parse (KnowledgeGraphView.swift:139), and the view then shows
    /// "No entities match these filters" — a filter-shaped explanation for a parse
    /// bug. This is the writer↔reader seam: every stamp the REAL indexer emits
    /// must parse, and an entity written seconds ago must survive the narrowest
    /// time window.
    @MainActor
    @Test func everyStampTheRealIndexerWritesParsesAndSurvivesTheNarrowestWindow() async throws {
        let root = try graphTempRoot("stamps")
        defer { try? FileManager.default.removeItem(at: root) }
        let response = try await seededGraphResponse(root: root, facts: [
            ("mem-1", "NativeAgent ships tonight."),
            ("mem-2", "TradingView dashboards inside NativeAgent."),
        ])
        try #require(!response.entities.isEmpty, "the indexer produced no entities to check")

        for entity in response.entities {
            let last = KnowledgeGraphView.parseKGDate(entity.last_seen)
            let first = KnowledgeGraphView.parseKGDate(entity.first_seen)
            #expect(last != nil || first != nil,
                    "\(entity.name): neither stamp parses (last_seen=\(entity.last_seen ?? "nil"), first_seen=\(entity.first_seen ?? "nil"))")
        }

        // The whole filter, end to end: nothing written just now may drop out of
        // "Last day".
        let cutoff = try #require(KGTimeWindow.day.cutoff)
        let survivors = response.entities.filter { entity in
            guard let stamp = KnowledgeGraphView.parseKGDate(entity.last_seen)
                ?? KnowledgeGraphView.parseKGDate(entity.first_seen) else { return false }
            return stamp >= cutoff
        }
        #expect(survivors.count == response.entities.count,
                "freshly indexed entities vanished under the Last-day window")
    }

    /// The three formats the parser claims to handle, plus the shapes that must
    /// return nil. Mutation-proof: drop any branch and one of these fails.
    @MainActor
    @Test func parseKGDateHandlesEveryDeclaredFormatAndRefusesGarbage() throws {
        #expect(KnowledgeGraphView.parseKGDate("2026-08-20T12:34:56.789Z") != nil,
                "ISO-8601 with fractional seconds must parse")
        #expect(KnowledgeGraphView.parseKGDate("2026-08-20T12:34:56Z") != nil,
                "ISO-8601 without fractional seconds must parse")
        #expect(KnowledgeGraphView.parseKGDate("2026-08-20") != nil,
                "the legacy date-only shape must parse")
        // Date-only is parsed from the PREFIX, so a long non-ISO string that
        // happens to start with a date still resolves rather than dropping a row.
        #expect(KnowledgeGraphView.parseKGDate("2026-08-20 12:34:56 +0000") != nil)

        #expect(KnowledgeGraphView.parseKGDate(nil) == nil)
        #expect(KnowledgeGraphView.parseKGDate("") == nil)
        #expect(KnowledgeGraphView.parseKGDate("not a date") == nil)
        #expect(KnowledgeGraphView.parseKGDate("1755648000") == nil,
                "an epoch-seconds writer change must NOT silently parse as something else")

        // The three windows must order strictly, or "Last week" could include
        // less than "Last day".
        let day = try #require(KGTimeWindow.day.cutoff)
        let week = try #require(KGTimeWindow.week.cutoff)
        let month = try #require(KGTimeWindow.month.cutoff)
        #expect(month < week && week < day)
        #expect(KGTimeWindow.all.cutoff == nil, "All time must apply no filter at all")
    }
}

// MARK: - Kind filters vs the kinds the indexer really emits
//        (ui.kg.filter.kindMultiSelect / ui.kg.filters / ui.kg.searchAndTypeFilter)

@Suite("Mind KG — kind filter catalog")
struct MindKGKindCatalogTests {

    /// Two overlapping filters (`filterType` single-select AND `selectedKinds`
    /// multi-select) are ANDed at KnowledgeGraphView.swift:131-134, and both
    /// catalogs are hand-maintained lists of literals. `KGEntityRow.typeIcon` /
    /// `typeColor` are a third list. All three must agree with what the INDEXER
    /// actually writes, or an entity kind becomes unselectable and vanishes under
    /// any kind filter with only the generic "No entities match these filters" to
    /// explain it.
    ///
    /// KNOWN GAPS pinned here (found by this eval, 2026-08-23):
    ///  * `fact` — `upsertMemoryFactEntity` writes `type = 'fact'` for EVERY
    ///    MemoryV2 row (KnowledgeGraph+MemoryIndexing.swift:583), so it is the
    ///    dominant kind in a real graph. It is in neither filter catalog and has
    ///    no icon/colour case, so it renders as an untyped circle and disappears
    ///    the moment any kind filter is applied.
    ///  * `organization` — emitted by `inferType` (:1319) and the knownTerms
    ///    table; the row renderer handles it, neither catalog lists it.
    ///
    /// Both assertions are SUBSET checks: they stay green when either gap is
    /// closed and fail the moment a THIRD unselectable/unrenderable kind appears.
    @MainActor
    @Test func everyKindTheIndexerEmitsIsRenderableAndSelectable() async throws {
        let root = try graphTempRoot("kinds")
        defer { try? FileManager.default.removeItem(at: root) }
        let response = try await seededGraphResponse(root: root, facts: [
            ("mem-org", "Apple shipped the CoreML runtime the assistant uses."),
            ("mem-proj", "NativeAgent ships tonight."),
            ("mem-person", "The user asked for the release notes."),
        ])
        let emitted = Set(response.entities.map(\.type))
        try #require(!emitted.isEmpty)
        try #require(emitted.contains("organization"),
                     "fixture must exercise the organization branch: got \(emitted.sorted())")
        try #require(emitted.contains("fact"),
                     "fixture must exercise the per-memory fact node: got \(emitted.sorted())")

        let knownGaps: Set<String> = ["fact", "organization"]

        let unrenderable = emitted.filter { KGEntityRow.typeIcon($0) == "circle" }
        #expect(Set(unrenderable).isSubset(of: knownGaps),
                "kinds the row renderer has no icon for: \(unrenderable.sorted())")

        let view = KnowledgeGraphView()
        let selectable = Set(view.kindCatalog).union(view.entityTypes)
        let unselectable = emitted.subtracting(selectable)
        #expect(unselectable.isSubset(of: knownGaps),
                "kinds the indexer emits but no filter can select: \(unselectable.sorted())")

        // Every catalog entry must at least be RENDERABLE — a filter offering a
        // kind the row cannot draw is a dead option in the other direction.
        for kind in view.kindCatalog {
            #expect(KGEntityRow.typeIcon(kind) != "circle",
                    "filter offers kind \"\(kind)\" that the row renderer cannot draw")
        }
    }
}

// MARK: - loadGraph termination + footer counts
//        (api.KnowledgeGraphView.loadGraph / logic.kg.loadGraph.pagination /
//         ui.kg.footer.counts)

@Suite("Mind KG — pagination envelope")
struct MindKGPaginationTests {

    /// `loadGraph` terminates on `all.count >= total` where `total` comes from
    /// PAGE 0 ONLY, and the footer prints that same number. The decoder silently
    /// falls back to `entities.count` when `total_entities` is missing
    /// (KnowledgeGraphModels.swift:52-56), which is exactly how a partial fetch
    /// gets confirmed by its own footer. Pin both: the live envelope really
    /// carries `total_entities`, and the fallback is the documented one.
    @Test func theCheckedEnvelopeCarriesTheServerTotalTheLoopTerminatesOn() async throws {
        let root = try graphTempRoot("pagination")
        defer { try? FileManager.default.removeItem(at: root) }
        let response = try await seededGraphResponse(root: root, facts: [
            ("mem-1", "NativeAgent ships tonight."),
            ("mem-2", "TradingView dashboards inside NativeAgent."),
            ("mem-3", "Apple shipped the CoreML runtime."),
        ])
        #expect(response.totalEntities > 0,
                "total_entities is the loop's only server-authoritative stop condition")
        #expect(response.totalEntities >= response.entities.count)
        #expect(response.page == 0)

        // A page BEYOND the data must come back empty — the loop's other stop
        // condition. Without it the 500-page cap would be the only bound.
        let reader = makeKnowledgeGraphReader(
            graphPath: root
                .appendingPathComponent("memory", isDirectory: true)
                .appendingPathComponent("knowledge_graph.json")
        )
        let far = try await reader.allEntitiesChecked(page: 400)
        let farPage = try JSONDecoder.nativeAgent.decode(
            KGEntityResponse.self, from: try far.serializedData(pretty: false))
        #expect(farPage.entities.isEmpty, "an out-of-range page must terminate the walk")
    }

    /// The silent-truncation shape: an envelope with no `total_entities` decodes
    /// to `entities.count`, so the footer agrees with whatever partial set was
    /// fetched. Pinned so the fallback stays a KNOWN, testable behaviour rather
    /// than an accident, and so `total_edges` staying optional is explicit.
    @Test func aMissingServerTotalFallsBackToTheFetchedCountAndNeverThrows() throws {
        let partial = Data("""
        {"entities":[{"id":"a","name":"A","type":"concept"},
                     {"id":"b","name":"B","type":"concept"}]}
        """.utf8)
        let decoded = try JSONDecoder.nativeAgent.decode(KGEntityResponse.self, from: partial)
        #expect(decoded.totalEntities == 2, "the documented fallback is entities.count")
        #expect(decoded.totalEdges == nil, "a nil edge total must stay nil, not become 0")

        let authoritative = Data("""
        {"entities":[{"id":"a","name":"A","type":"concept"}],
         "total_entities":887,"total_edges":42,"page":3}
        """.utf8)
        let server = try JSONDecoder.nativeAgent.decode(KGEntityResponse.self, from: authoritative)
        #expect(server.totalEntities == 887, "the server total must win over the fetched count")
        #expect(server.totalEdges == 42)
        #expect(server.page == 3)
    }
}

// MARK: - KG header claim (ui.kg.header)

@Suite("Mind KG — status header claims")
struct MindKGHeaderTests {

    /// `KGNativeStackStatus.load` used to assign `embeddingDim = 384` as a
    /// CONSTANT and render it as "384d MiniLM" as if it were measured, so a
    /// changed embedder made the header lie with no other signal. 2026-09-06:
    /// cba66673 lets an installed extras model win over the bundled MiniLM, so
    /// the header now READS the live embedder's dimension and names no model.
    /// The lie is gone by construction — pin the construction, then pin the
    /// bundled epoch a stock install therefore measures.
    @Test func theHeadersEmbeddingDimensionMatchesTheBundledMiniLMEpoch() throws {
        let header = try AppSourceScraping.appSource("KnowledgeGraphStatusHeader.swift")
        #expect(header.contains("(await SwiftNativeMemoryV2.shared.embedderDimensions())"),
                "the header must measure the live embedder, never hard-code a dimension")
        #expect(!header.contains("status.embeddingDim = 384"),
                "the hard-coded dimension is back — the header can lie again")
        #expect(!header.contains("MiniLM"),
                "the header must not name a model it no longer knows is loaded")

        let repo = try AppSourceScraping.repositoryRoot()
        let embedding = try String(
            contentsOf: repo.appendingPathComponent(
                "Modules/NativeAgentCore/Sources/MemoryV2/MemoryV2+Embedding.swift"),
            encoding: .utf8
        )
        // The bundled epoch is the one the memory store stamps onto stored
        // vectors on a stock install — the value the measured header therefore
        // shows when no extras model is present: 384 dims, all-MiniLM-L6-v2.
        #expect(embedding.contains("dimensions: 384,"),
                "the bundled embedder no longer declares 384 dimensions")
        #expect(embedding.contains("\"all-MiniLM-L6-v2\""),
                "the bundled embedder is no longer MiniLM")
    }
}

// MARK: - Dream + REM kill switches
//        (ui.dreams.toggle.dreamCycle / ui.dreams.toggle.remCycle)

@Suite("Mind dreams — kill-switch patches")
struct MindDreamsToggleTests {

    /// The "Dream cycle" toggle is a TWO-GATE composite: it must move
    /// `personalityPolicy.dream_cycle_enabled` AND `trainingPolicy.dream_scheduler`
    /// together, and it reads back ONE composite boolean. If only one write lands,
    /// the switch reads ON while dreams never run. The REM toggle must move only
    /// its own gate — its doc comment promises it "preserves dream_scheduler".
    @Test func theDreamToggleMovesBothGatesAndTheRemToggleMovesOnlyItsOwn() throws {
        let source = try AppSourceScraping.appSource("NativeClient+DreamActions.swift")
        let dreamBody = try AppSourceScraping.functionBody(
            named: "patchDreamCycleEnabled", in: source)
        #expect(dreamBody.contains("dream_cycle_enabled"),
                "the dream toggle stopped writing the personality gate")
        #expect(dreamBody.contains("dream_scheduler"),
                "the dream toggle stopped writing the scheduler gate — the switch would read ON while dreams never run")

        let remBody = try AppSourceScraping.functionBody(
            named: "patchRemCycleEnabled", in: source)
        #expect(remBody.contains("rem_cycle_enabled"))
        #expect(!remBody.contains("dream_scheduler"),
                "the REM toggle must not touch the dream scheduler gate")
    }

    /// The behavioural half, through the app's single trust-write chokepoint
    /// against a temp root: a REM patch must DEEP-merge, leaving the dream gates
    /// exactly as they were. A shallow write here is the partial-write failure the
    /// composite toggle can never see.
    @Test func theRemPatchDeepMergesAndNeverClobbersTheDreamGates() async throws {
        let root = try graphTempRoot("trust")
        defer { try? FileManager.default.removeItem(at: root) }

        let dreamsOn = try await NativeClient.applyTrustPolicyPatch(
            body: [
                "personalityPolicy": ["dream_cycle_enabled": true],
                "trainingPolicy": ["dream_scheduler": true],
            ],
            dataRoot: root
        )
        #expect(dreamsOn.trainingPolicy?.dream_scheduler == true)
        #expect(try storedBool(root, "personalityPolicy", "dream_cycle_enabled") == true)

        let remOff = try await NativeClient.applyTrustPolicyPatch(
            body: ["trainingPolicy": ["rem_cycle_enabled": false]],
            dataRoot: root
        )
        #expect(remOff.trainingPolicy?.rem_cycle_enabled == false)
        #expect(remOff.trainingPolicy?.dream_scheduler == true,
                "the REM patch clobbered dream_scheduler — the Dream toggle would silently read ON while the scheduler is off")
        #expect(try storedBool(root, "personalityPolicy", "dream_cycle_enabled") == true,
                "the REM patch clobbered the personality dream gate")
    }

    /// DreamsView reads `trustPolicy?.trainingPolicy?.rem_cycle_enabled ?? true`
    /// (DreamsView.swift:48) — an UNLOADED policy therefore renders REM as enabled
    /// and Run REM as clickable. The only thing that keeps that optimistic default
    /// from being wrong in practice is the persisted policy carrying the key
    /// explicitly once it has ever been written. Pin the round trip: after a write,
    /// the read is the stored value and never the `?? true` fallback.
    @Test func aWrittenRemGateIsReadBackExplicitlyRatherThanFallingBackToTrue() async throws {
        let root = try graphTempRoot("rem-default")
        defer { try? FileManager.default.removeItem(at: root) }

        let off = try await NativeClient.applyTrustPolicyPatch(
            body: ["trainingPolicy": ["rem_cycle_enabled": false]], dataRoot: root)
        #expect(off.trainingPolicy?.rem_cycle_enabled == false,
                "a stored false must not decode to nil and then read as the `?? true` default")

        let on = try await NativeClient.applyTrustPolicyPatch(
            body: ["trainingPolicy": ["rem_cycle_enabled": true]], dataRoot: root)
        #expect(on.trainingPolicy?.rem_cycle_enabled == true)

        // The optimistic default is DOUBLE-layered and both layers say ON: the
        // model defaults `rem_cycle_enabled` to true when the key is absent
        // (TrustPolicyModels.swift:257) AND the view falls back to true when the
        // whole policy is nil (DreamsView.swift:48). So an unwritten gate paints
        // REM as enabled with Run REM clickable. Pinned — an explicit `false`
        // must still win over both, which is the half that actually protects her.
        let bare = try JSONDecoder.nativeAgent.decode(
            TrustPolicy.self,
            from: Data(#"{"permissionLevel":"balanced","trainingPolicy":{"dream_scheduler":false}}"#.utf8)
        )
        #expect(bare.trainingPolicy?.rem_cycle_enabled == true,
                "known: an absent REM key reads as enabled — if this flips, the Dreams toggle default changed")
        let explicitlyOff = try JSONDecoder.nativeAgent.decode(
            TrustPolicy.self,
            from: Data(#"{"permissionLevel":"balanced","trainingPolicy":{"rem_cycle_enabled":false}}"#.utf8)
        )
        #expect(explicitlyOff.trainingPolicy?.rem_cycle_enabled == false,
                "an explicit REM kill switch must never be overridden by the optimistic default")
    }
}
