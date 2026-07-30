import Testing
import Foundation
@testable import CapabilityFoundry
import NativeAgentCore
import PersistenceCore

// MARK: - Subsystem #29 wave 41 W10 — CapabilityFoundry seam tests
//
// Audit fix 2026-06-10: the SwiftNative impl now does PARTIAL native
// aggregation — skill/tool/workflow/mcp lane counts come from the on-disk
// registries; unwired lanes stay 0 and the envelope says so via
// status="partial" + detail. These tests pin the factory routing, the
// structural contract the Mac panel renders, and the count aggregation.

private func objectField(_ json: JSONValue, _ key: String) -> JSONValue? {
    if case .object(let obj) = json { return obj[key] }
    return nil
}

private func stringField(_ json: JSONValue?, _ key: String) -> String? {
    if case .object(let obj)? = json, case .string(let s)? = obj[key] { return s }
    return nil
}

private func tempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("foundry-test-\(UUID().uuidString.lowercased())", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeStore(_ root: URL, _ relative: String, _ json: String) throws {
    let path = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data(json.utf8).write(to: path)
}

// MARK: - Factory routing

@Test func makeCapabilityFoundryClientRoutesSwiftNative() async throws {
    let client = makeCapabilityFoundryClient()
    #expect(client is SwiftNativeCapabilityFoundryClient)
}

// MARK: - SwiftNative static contract

@Test func swiftNativeReturnsHonestStructuralContract() async throws {
    // Empty root: every native count is 0 and the envelope is honest about
    // the partial scope (status "partial", never an all-green "ready" stub).
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = SwiftNativeCapabilityFoundryClient(now: { Date(timeIntervalSince1970: 0) }, root: root)
    let result = try await client.capabilityFoundrySummary()
    #expect(result.status == "partial")
    #expect(result.detail.contains("not yet wired"))
    #expect(result.principle.hasPrefix("Tiny core runtime"))
    #expect(result.summary.total == 0)
    #expect(result.summary.review == 0)
    #expect(result.reviewQueue.isEmpty)
    #expect(result.recentArtifacts.isEmpty)
    // Lane skeleton present with the canonical 7 lanes.
    #expect(result.lanes.count == 7)
    #expect(result.lanes.map { $0.id } == ["skill", "tool", "workflow", "mcp", "panel", "plugin", "catalog"])
    #expect(result.lanes.allSatisfy { $0.count == 0 && $0.reviewCount == 0 })
    // Readouts the Mac panel surfaces.
    #expect(result.readouts.map { $0.id } == ["capabilities", "panels", "activity", "trust"])
    // hotPathContract policy strings present.
    #expect(result.hotPathContract.reviewRequiredFor.contains("shell"))
    #expect(result.hotPathContract.riskyPermissionsPresent.isEmpty)
}

@Test func swiftNativeAggregatesNativeLaneCounts() async throws {
    // Seeded stores: skill/tool/workflow/mcp lane counts must reflect disk.
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeStore(root, "skills/registry.json",
        #"[{"id":"s1","status":"active"},{"id":"s2","status":"active"}]"#)
    try writeStore(root, "tools/registry.json",
        #"[{"id":"t1","status":"active"},{"id":"t2","status":"active"},{"id":"t3","status":"proposed"}]"#)
    try writeStore(root, "workflows/registry.json",
        #"[{"id":"w1","status":"active"},{"id":"w2","status":"template"},{"id":"w3","status":"active"},{"id":"w4","status":"template"}]"#)
    try writeStore(root, "mcp/servers.json",
        #"[{"id":"m1","status":"ready"}]"#)

    let client = SwiftNativeCapabilityFoundryClient(now: { Date(timeIntervalSince1970: 0) }, root: root)
    let result = try await client.capabilityFoundrySummary()

    let laneCounts = Dictionary(uniqueKeysWithValues: result.lanes.map { ($0.id, $0.count) })
    #expect(laneCounts["skill"] == 2)
    // 2026-07-21 audit: lane counts agree with summary.byKind — per-store
    // totals, not an active-only subset that contradicts the summary.
    #expect(laneCounts["tool"] == 3)       // whole store, matching byKind
    #expect(laneCounts["workflow"] == 4)   // ALL definitions, templates included
    #expect(laneCounts["mcp"] == 1)
    #expect(laneCounts["panel"] == 0)
    #expect(laneCounts["plugin"] == 0)
    #expect(laneCounts["catalog"] == 0)

    // Top summary: total = all entries; byKind mirrors per-store totals;
    // active = status in {active, ready} across the four stores.
    #expect(result.summary.total == 10)
    #expect(result.summary.byKind == ["skill": 2, "tool": 3, "workflow": 4, "mcp": 1])
    #expect(result.summary.active == 7)    // 2 skills + 2 tools + 2 workflows + 1 mcp
    // Lanes and summary never disagree: wired lane counts sum to the total.
    let wiredLaneTotal = ["skill", "tool", "workflow", "mcp"]
        .compactMap { laneCounts[$0] }.reduce(0, +)
    #expect(wiredLaneTotal == result.summary.total)
    #expect(result.status == "partial")
}

@Test func lanesNeverAdvertiseRetiredDaemonRoutes() async throws {
    // 2026-07-21 audit: lane endpoints used to name dead /v1 daemon routes.
    // Wired lanes point at the Swift-native store; unwired lanes carry nil.
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = SwiftNativeCapabilityFoundryClient(now: { Date(timeIntervalSince1970: 0) }, root: root)
    let result = try await client.capabilityFoundrySummary()
    for lane in result.lanes {
        if let endpoint = lane.endpoint {
            #expect(!endpoint.hasPrefix("/v1/"),
                    "lane \(lane.id) advertises retired daemon route \(endpoint)")
            #expect(endpoint.hasPrefix("native:"),
                    "lane \(lane.id) endpoint should name the native store, got \(endpoint)")
        }
    }
    #expect(result.lanes.first { $0.id == "panel" }?.endpoint == nil)
    #expect(result.lanes.first { $0.id == "plugin" }?.endpoint == nil)
    #expect(result.lanes.first { $0.id == "catalog" }?.endpoint == nil)
}

@Test func swiftNativeCountsInstalledSkillBodiesFromSharedInventory() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeStore(root, "skills/registry.json",
        #"[{"id":"registered","name":"registered","status":"active"}]"#)
    try writeStore(root, "skills/bodies/registered.md",
        "# Registered\nUse this when testing registered skill discovery.\n")
    try writeStore(root, "skills/bodies/body-only.md",
        "# Body Only\nUse this when testing body-only skill discovery.\n")

    let client = SwiftNativeCapabilityFoundryClient(
        now: { Date(timeIntervalSince1970: 0) },
        root: root
    )
    let result = try await client.capabilityFoundrySummary()

    #expect(result.summary.byKind["skill"] == 2)
    #expect(result.summary.active == 2)
    #expect(result.lanes.first { $0.id == "skill" }?.count == 2)
}

@Test func swiftNativeIgnoresMalformedStores() async throws {
    // A garbage store must not break the panel — it just counts as 0.
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeStore(root, "skills/registry.json", "{not json")
    try writeStore(root, "tools/registry.json", #"{"id":"not-a-list"}"#)
    let client = SwiftNativeCapabilityFoundryClient(now: { Date(timeIntervalSince1970: 0) }, root: root)
    let result = try await client.capabilityFoundrySummary()
    #expect(result.summary.total == 0)
    #expect(result.lanes.allSatisfy { $0.count == 0 })
}

@Test func swiftNativeJSONShapeMatchesMacDecoderContract() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let client = SwiftNativeCapabilityFoundryClient(now: { Date(timeIntervalSince1970: 0) }, root: root)
    let result = try await client.capabilityFoundrySummary()
    let json = result.toJSON()
    // Top-level keys the Mac `CapabilityFoundrySummary` Codable decoder reads
    // (plus `detail`, which the decoder ignores — unknown keys are safe).
    #expect(stringField(json, "status") == "partial")
    #expect(objectField(json, "detail") != nil)
    #expect(objectField(json, "principle") != nil)
    #expect(objectField(json, "hotPathContract") != nil)
    #expect(objectField(json, "summary") != nil)
    #expect(objectField(json, "lanes") != nil)
    #expect(objectField(json, "reviewQueue") != nil)
    #expect(objectField(json, "recentArtifacts") != nil)
    #expect(objectField(json, "readouts") != nil)
    #expect(objectField(json, "createdAt") != nil)
    // summary nested counts serialize as ints; byKind always names the four
    // natively-wired kinds.
    if case .object(let summaryObj)? = objectField(json, "summary") {
        #expect(summaryObj["total"] == .int(0))
        #expect(summaryObj["autoCreated"] == .int(0))
        #expect(summaryObj["byKind"] == .object([
            "skill": .int(0), "tool": .int(0), "workflow": .int(0), "mcp": .int(0),
        ]))
    } else {
        Issue.record("summary did not serialize as an object")
    }
    // A lane round-trips its full field set.
    if case .array(let lanes)? = objectField(json, "lanes"), case .object(let first)? = lanes.first {
        #expect(first["id"] == .string("skill"))
        #expect(first["count"] == .int(0))
        #expect(first["policyGate"] == .string("skillBuilderPolicy.v2_enabled"))
    } else {
        Issue.record("lanes did not serialize as a non-empty array of objects")
    }
}
