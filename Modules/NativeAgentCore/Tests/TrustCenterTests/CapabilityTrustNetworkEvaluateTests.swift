import Testing
import Foundation
@testable import TrustCenter
import MCPDispatcher
import PersistenceCore

// Eval coverage ledger — fence core.trust
//   • core.trust.capabilityTrust.network
//   • core.trust.capabilityTrust.evaluate
//   • core.trust.capabilityRecords.listMCPServersAsDicts
//   • core.trust.connectorAction.riskVocabulary
//
// The Capabilities trust panel's whole data path. The existing tests pinned the
// WIRE TYPES' Codable decoding and the pure scorer — never the actor's
// assembly. A `network()` that starts returning empty roots/sources/records
// renders an empty panel with no failure, and `evaluate(capabilityId:)` — the
// "Evaluate Trust" button — matches ids by exact scan, so any id-vocabulary
// drift between the summary projection and `capabilityRecordsFull` turns the
// button into a permanent no-op error.

private func capabilityTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CapabilityTrust-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let capabilityClock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_760_000_000) }

@Test func CapabilityTrust_network_assemblesNonEmptyRootsSourcesAndABalancedSummary() async throws {
    let root = try capabilityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let actor = SwiftNativeCapabilityTrust(dataRoot: root, clock: capabilityClock)
    let network = try await actor.network()

    #expect(network.status == "ready")
    #expect(!network.records.isEmpty,
            "the capability trust panel would render EMPTY — silent zero")
    #expect(network.records.count <= 200, "the 200-record slice stopped applying")
    // The bootstrap trust root is always synthesized, so an empty roots array
    // means the roots reader broke rather than "this install has no roots".
    #expect(!network.roots.isEmpty, "no trust roots — the panel's Roots card is blank")
    #expect(network.roots.allSatisfy { !$0.id.isEmpty })

    guard let summary = network.summary else {
        Issue.record("network() returned no summary — the panel's counters are blank")
        return
    }
    #expect(summary.trusted + summary.review + summary.untrusted == network.records.count,
            "summary counters (\(summary.trusted)/\(summary.review)/\(summary.untrusted)) do not account for \(network.records.count) records")

    // Every record must carry the fields the panel renders and a tier that
    // matches its own score — a tier computed from a different score is the
    // "wrong value on the panel" failure.
    for record in network.records {
        #expect(!record.id.isEmpty, "a record reached the panel with a blank id")
        guard let score = record.trustScore else {
            Issue.record("\(record.id) reached the panel with no trust score")
            continue
        }
        #expect(score >= 0.0 && score <= 1.0, "\(record.id) scored outside [0,1]: \(score)")
        #expect(record.trustTier == capabilityTrustTier(forScore: score),
                "\(record.id) tier \(record.trustTier ?? "nil") disagrees with score \(score)")
        #expect(!(record.reasons ?? []).isEmpty, "\(record.id) carries no trust reasons")
    }
    #expect(Set(network.records.map(\.id)).count == network.records.count,
            "duplicate record ids reached the panel — evaluate() would resolve the wrong one")
}

/// Every id the panel can DISPLAY must be an id `evaluate()` can RESOLVE, and
/// the score it returns must be the same one the panel showed. The button
/// passes `records.first`, so the head of the list is driven explicitly.
@Test func CapabilityTrust_evaluate_resolvesTheIdsThePanelDisplays() async throws {
    let root = try capabilityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let actor = SwiftNativeCapabilityTrust(dataRoot: root, clock: capabilityClock)
    let network = try await actor.network()
    let full = await capabilityRecordsFull(
        dataRoot: root,
        nowISO: SwiftNativeManifestSigner.isoTimestamp(capabilityClock()))

    // Exhaustive, cheap half: the aggregator's ids and the panel's ids are the
    // same vocabulary, so no displayed id can be unknown to the matcher.
    var resolvableIds: Set<String> = []
    for record in full {
        if case .string(let id)? = record["id"], !id.isEmpty { resolvableIds.insert(id) }
        if case .string(let sid)? = record["sourceId"], !sid.isEmpty { resolvableIds.insert(sid) }
    }
    let displayed = Set(network.records.map(\.id))
    #expect(displayed.subtracting(resolvableIds).isEmpty,
            "ids the panel displays that evaluate() cannot match: \(displayed.subtracting(resolvableIds).sorted().prefix(10))")

    // Real-path half: actually drive evaluate() on a spread of them, including
    // the FIRST record (the id the 'Evaluate Trust' button sends).
    let sampled = stride(from: 0, to: network.records.count, by: max(1, network.records.count / 8))
        .map { network.records[$0] }
    #expect(sampled.count >= 2)
    for record in sampled {
        let evaluation = try await actor.evaluate(capabilityId: record.id)
        #expect(evaluation.id == record.id)
        #expect(evaluation.trustScore == record.trustScore,
                "\(record.id): panel showed \(record.trustScore ?? -1), evaluate returned \(evaluation.trustScore)")
        #expect(evaluation.trustTier == record.trustTier)
    }

    // A sourceId — the other spelling the matcher accepts — must resolve too.
    if let connector = full.first(where: {
        if case .string(let id)? = $0["id"] { return id.hasPrefix("connector_action:") }
        return false
    }), case .string(let sourceId)? = connector["sourceId"] {
        let bySource = try await actor.evaluate(capabilityId: sourceId)
        #expect(!bySource.id.isEmpty)
    }

    // And an id nobody emits must FAIL loudly rather than resolving to something.
    await #expect(throws: (any Error).self) {
        _ = try await actor.evaluate(capabilityId: "capability-that-does-not-exist")
    }
}

/// `listMCPServersAsDicts` is the only sub-reader of `capabilityRecordsFull`
/// with no suite of its own. If the store path or shape changes, MCP servers
/// silently vanish from the Capabilities surface while the aggregate still
/// returns a plausible list.
@Test func CapabilityRecords_listMCPServersAsDicts_survivesAMalformedRowAndReachesTheAggregate() async throws {
    let root = try capabilityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SwiftNativePersistenceCore()

    try await persistence.writeJSON(
        .array([
            .object([
                "id": .string("eval-server-a"),
                "name": .string("Eval Server A"),
                "transport": .string("stdio"),
                "status": .string("ready"),
                "toolCount": .int(2),
            ]),
            .object([
                "id": .string("eval-server-b"),
                "name": .string("Eval Server B"),
                "transport": .string("http"),
                "endpoint": .string("http://127.0.0.1:9/"),
                "status": .string("needs_setup"),
            ]),
            // Malformed row: must not abort the read.
            .string("not-a-server-record"),
        ]),
        to: root.appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("servers.json"))

    let servers = await listMCPServersAsDicts(dataRoot: root, persistence: persistence)
    var ids: Set<String> = []
    for server in servers {
        if case .string(let id)? = server["id"] { ids.insert(id) }
    }
    #expect(ids.contains("eval-server-a"), "a well-formed server vanished: \(ids.sorted())")
    #expect(ids.contains("eval-server-b"), "a well-formed server vanished: \(ids.sorted())")
    #expect(!ids.contains(""), "a record reached the surface with a blank id")
    #expect(servers.allSatisfy { $0["id"] != nil }, "a record has no id at all")

    // They must also reach the aggregate the panel actually reads, under the
    // `mcp:` id vocabulary.
    let full = await capabilityRecordsFull(
        dataRoot: root,
        nowISO: SwiftNativeManifestSigner.isoTimestamp(capabilityClock()),
        persistence: persistence)
    var aggregateIds: Set<String> = []
    for record in full {
        if case .string(let id)? = record["id"] { aggregateIds.insert(id) }
    }
    #expect(aggregateIds.contains("mcp:eval-server-a"),
            "the MCP source dropped out of capabilityRecordsFull — silent zero on the panel")
    #expect(aggregateIds.contains("mcp:eval-server-b"))
}

/// A missing store must be an empty read, not a throw and not a collapse of the
/// always-present defaults.
@Test func CapabilityRecords_listMCPServersAsDicts_missingStoreStillReturnsTheBuiltInDefaults() async throws {
    let root = try capabilityTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let servers = await listMCPServersAsDicts(dataRoot: root)
    var ids: Set<String> = []
    for server in servers {
        if case .string(let id)? = server["id"] { ids.insert(id) }
    }
    #expect(!servers.isEmpty, "a missing store collapsed the built-in MCP defaults to nothing")
    #expect(ids.contains("nativeagent-internal"),
            "the internal MCP default disappeared: \(ids.sorted())")
    #expect(!ids.contains("eval-server-a"), "a server leaked in from another root")
}

/// TWO VOCABULARIES IN ONE FIELD. `ConnectorActionDescriptor.risk` mixes a
/// SEVERITY vocabulary {low, medium, high, critical} with a CAPABILITY
/// vocabulary {external_send, external_write, app_data_write} in one free-text
/// field, and `staticCapabilityRecordsFromManifests` copies it straight into
/// `riskClass`, which `scoreCapabilityRecord` penalises by CAPABILITY names
/// only. So the severity half receives no penalty at all.
///
/// The drift half is pinned here: an unrecognised risk string — a new spelling,
/// a typo, a third vocabulary — fails immediately instead of scoring silently.
/// Making the severity half actually penalise needs a production change; see
/// the wave report.
@Test func ConnectorActions_riskVocabulary_isClosedAndCopiedFaithfully() {
    let severityVocabulary: Set<String> = ["low", "medium", "high", "critical"]
    let capabilityVocabulary: Set<String> = ["external_send", "external_write", "app_data_write"]
    let known = severityVocabulary.union(capabilityVocabulary)

    let descriptors = connectorActionDescriptors()
    #expect(descriptors.count > 50, "the connector registry collapsed to \(descriptors.count) actions")

    let emitted = Set(descriptors.map(\.risk))
    #expect(emitted.subtracting(known).isEmpty, """
        connector actions emit risk values outside the declared vocabulary: \
        \(emitted.subtracting(known).sorted()).
        `riskClass` feeds scoreCapabilityRecord's penalty set directly — an
        unrecognised value scores as if it were harmless.
        """)
    #expect(emitted.intersection(severityVocabulary).count >= 2,
            "the severity half of the vocabulary vanished — this test stopped measuring the mix")
    #expect(!emitted.intersection(capabilityVocabulary).isEmpty,
            "the capability half of the vocabulary vanished")

    // The copy into the trust record must be faithful in BOTH fields — a
    // rename here silently re-tiers the Capabilities panel.
    let records = staticCapabilityRecordsFromManifests(
        nowISO: SwiftNativeManifestSigner.isoTimestamp(capabilityClock()))
    let bySourceId = Dictionary(
        records.compactMap { rec -> (String, CapabilityRecord)? in
            guard let sid = rec.sourceId else { return nil }
            return (sid, rec)
        },
        uniquingKeysWith: { first, _ in first })
    var checked = 0
    for descriptor in descriptors {
        guard let record = bySourceId[descriptor.id] else { continue }
        #expect(record.riskClass == descriptor.risk,
                "\(descriptor.id): riskClass '\(record.riskClass ?? "nil")' diverged from descriptor risk '\(descriptor.risk)'")
        #expect(record.permissions == [descriptor.risk],
                "\(descriptor.id): permissions no longer mirror the risk field")
        checked += 1
    }
    #expect(checked >= 50, "only \(checked) connector actions were matched into records")

    // The scorer's penalty set is the OTHER half of the seam. Pin BOTH halves so
    // the two vocabularies cannot drift apart unnoticed.
    let base = scoreCapabilityRecord(["id": .string("probe")])
    let penalisedVocabulary = ["risky_tool", "external_write", "external_send"]
    for risk in penalisedVocabulary {
        let scored = scoreCapabilityRecord([
            "id": .string("probe"), "riskClass": .string(risk),
        ])
        #expect(scored.score < base.score, "riskClass '\(risk)' no longer costs anything")
    }

    // THE GAP, measured: every risk value the registry emits that the scorer
    // does NOT recognise — the whole severity half plus `app_data_write` —
    // scores exactly as if it were harmless. So the single `critical` connector
    // action and all the `high` ones sit at or above a mundane `external_write`.
    let unrecognised = emitted.subtracting(Set(penalisedVocabulary)).sorted()
    #expect(unrecognised.contains("high") && unrecognised.contains("critical"),
            "the severity half is no longer unrecognised: \(unrecognised)")
    for risk in unrecognised {
        let scored = scoreCapabilityRecord([
            "id": .string("probe"), "riskClass": .string(risk),
        ])
        #expect(scored.score == base.score, """
            riskClass '\(risk)' now changes the trust score — a risk value the
            registry emits has been wired into scoreCapabilityRecord. That is the
            fix: re-check the Capabilities panel ranking and flip ledger row
            core.trust.connectorAction.riskVocabulary.
            """)
        #expect(scored.score >= scoreCapabilityRecord([
            "id": .string("probe"), "riskClass": .string("external_write"),
        ]).score, "the ranking inversion moved for '\(risk)' — re-check the panel")
    }
}
