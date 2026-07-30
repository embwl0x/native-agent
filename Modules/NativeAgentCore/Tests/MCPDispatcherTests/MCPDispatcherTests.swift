import Testing
import Foundation
@testable import MCPDispatcher
import NativeAgentCore
import PersistenceCore
import NativeAgentTestSupport

// MARK: - Helpers

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MCPDispatcherTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Seed a servers.json file in a temp root's mcp/ directory.
private func seedServers(_ servers: [JSONValue], root: URL) throws {
    let dir = root.appendingPathComponent("mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("servers.json")
    let data = try JSONValue.array(servers).serializedData(pretty: true)
    try data.write(to: path)
}

/// Seed a tools cache entry for a given server in mcp/cache/tools.json.
private func seedToolsCache(_ entries: [String: JSONValue], root: URL) throws {
    let dir = root
        .appendingPathComponent("mcp", isDirectory: true)
        .appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("tools.json")
    let data = try JSONValue.object(entries).serializedData(pretty: true)
    try data.write(to: path)
}

/// Seed the consent ledger with a list of consent JSONValues.
private func seedConsentLedger(_ consents: [JSONValue], root: URL) throws {
    let dir = root
        .appendingPathComponent("mcp", isDirectory: true)
        .appendingPathComponent("consent", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("ledger.json")
    let data = try JSONValue.array(consents).serializedData(pretty: true)
    try data.write(to: path)
}

/// Build a minimal valid server JSONValue.
private func makeServerJSON(
    id: String,
    name: String,
    transport: String = "native",
    endpoint: String = "nativeagent://internal",
    status: String = "ready",
    healthStatus: String = "ok",
    toolCount: Int = 1,
    resourceCount: Int = 0,
    riskClass: String = "app_data_read",
    createdAt: String = "2026-05-01T00:00:00+00:00",
    updatedAt: String = "2026-05-01T00:00:01+00:00"
) -> JSONValue {
    .object([
        "id": .string(id),
        "name": .string(name),
        "transport": .string(transport),
        "endpoint": .string(endpoint),
        "status": .string(status),
        "healthStatus": .string(healthStatus),
        "toolCount": .int(Int64(toolCount)),
        "resourceCount": .int(Int64(resourceCount)),
        "riskClass": .string(riskClass),
        "createdAt": .string(createdAt),
        "updatedAt": .string(updatedAt),
    ])
}

/// Build a minimal valid consent JSONValue.
private func makeConsentJSON(
    serverId: String,
    toolName: String,
    status: String = "granted",
    risk: String = "app_data_read",
    grantedAt: String = "2026-05-01T00:00:00+00:00",
    updatedAt: String = "2026-05-01T00:00:01+00:00",
    revokedAt: JSONValue = .null,
    permissions: [String] = [],
    argumentSummary: String = "test grant",
    extraKey: String? = nil,
    extraValue: JSONValue? = nil
) -> JSONValue {
    var obj: [String: JSONValue] = [
        "id": .string("\(serverId):\(toolName)"),
        "serverId": .string(serverId),
        "toolName": .string(toolName),
        "scope": .string("server_tool"),
        "risk": .string(risk),
        "status": .string(status),
        "permissions": .array(permissions.map(JSONValue.string)),
        "argumentSummary": .string(argumentSummary),
        "grantedAt": .string(grantedAt),
        "updatedAt": .string(updatedAt),
        "revokedAt": revokedAt,
    ]
    if let k = extraKey, let v = extraValue {
        obj[k] = v
    }
    return .object(obj)
}

// MARK: - Factory

@Test func factoryReturnsSwiftNative() async throws {
    let impl = makeMCPDispatcher()
    #expect(impl is SwiftNativeMCPDispatcher)
}

@Test func sharedAcrossTasks() async throws {
    // A single SwiftNativeMCPDispatcher actor shared across 5+ concurrent Tasks
    // must remain the same identity reference throughout (actor isolation keeps
    // state coherent).
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = SwiftNativeMCPDispatcher(root: root)
    // 5 concurrent reads — each should see the 2 auto-merged defaults
    // (nativeagent-internal + searxng-local) and a stable id set.
    await withTaskGroup(of: [MCPServer].self) { group in
        for _ in 0..<5 {
            group.addTask {
                (try? await dispatcher.listServers()) ?? []
            }
        }
        for await result in group {
            #expect(Set(result.map(\.id)) == ["nativeagent-internal", "searxng-local"])
        }
    }
}

// MARK: - Reads: servers

@Test func listServers_emptyRegistry_returnsDefaultsOnly() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let d = SwiftNativeMCPDispatcher(root: root)
    // No servers.json + no config.json → auto-merge injects the two
    // built-in defaults.
    let servers = try await d.listServers()
    #expect(servers.count == 2)
    #expect(Set(servers.map(\.id)) == ["nativeagent-internal", "searxng-local"])
    let internalSrv = servers.first { $0.id == "nativeagent-internal" }!
    #expect(internalSrv.name == "NativeAgent Internal MCP")
    #expect(internalSrv.transport == "native")
    #expect(internalSrv.endpoint == "nativeagent://internal")
    #expect(internalSrv.status == "ready")
    #expect(internalSrv.healthStatus == "ok")
    #expect(internalSrv.toolCount == 3)
    #expect(internalSrv.resourceCount == 3)
    #expect(internalSrv.riskClass == "app_data_read")
    let searx = servers.first { $0.id == "searxng-local" }!
    #expect(searx.name == "SearXNG Local Search")
    #expect(searx.transport == "http")
    // No searxng_base_url configured → needs_setup branch.
    #expect(searx.endpoint == "")
    #expect(searx.status == "needs_setup")
    #expect(searx.healthStatus == "needs_setup")
    #expect(searx.toolCount == 0)
    #expect(searx.riskClass == "network_read")
}

@Test func listServers_searxngBaseURL_promotesSearxToReady() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // 2026-06-06 daemon-config retirement: searxng_base_url now lives at
    // <dataRoot>/research/config.json (Swift-native), not the daemon's
    // <dataRoot>/config/config.json.
    let researchDir = root.appendingPathComponent("research", isDirectory: true)
    try FileManager.default.createDirectory(at: researchDir, withIntermediateDirectories: true)
    try JSONValue.object(["searxng_base_url": .string("http://localhost:8080")])
        .serializedData(pretty: false)
        .write(to: researchDir.appendingPathComponent("config.json"))
    let d = SwiftNativeMCPDispatcher(root: root)
    let servers = try await d.listServers()
    let searx = servers.first { $0.id == "searxng-local" }!
    #expect(searx.endpoint == "http://localhost:8080")
    #expect(searx.status == "ready")
    #expect(searx.healthStatus == "ok")
    #expect(searx.toolCount == 2)
}

@Test func listServers_validRegistry_returnsAllPlusDefaults() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedServers([
        makeServerJSON(id: "srv-b", name: "Beta Server"),
        makeServerJSON(id: "srv-a", name: "Alpha Server"),
        makeServerJSON(id: "srv-c", name: "Gamma Server"),
    ], root: root)
    let d = SwiftNativeMCPDispatcher(root: root)
    let servers = try await d.listServers()
    // 3 user-saved + 2 auto-merged defaults.
    #expect(servers.count == 5)
    #expect(Set(servers.map(\.id)) == [
        "srv-a", "srv-b", "srv-c", "nativeagent-internal", "searxng-local",
    ])
}

@Test func listServers_overrideDefaultPreservesFieldsExceptStatus() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // User has saved a record with id=nativeagent-internal carrying a
    // custom name + custom status. Per the retired daemon, healthStatus,
    // status, and updatedAt must NOT be overridden by saved values; other
    // fields (like name) must take the saved value.
    try seedServers([
        makeServerJSON(
            id: "nativeagent-internal",
            name: "Custom Internal Name",
            status: "needs_setup",
            healthStatus: "fail",
            toolCount: 99
        ),
    ], root: root)
    let d = SwiftNativeMCPDispatcher(root: root)
    let servers = try await d.listServers()
    let internalSrv = servers.first { $0.id == "nativeagent-internal" }!
    #expect(internalSrv.name == "Custom Internal Name")  // saved override wins
    #expect(internalSrv.toolCount == 99)                 // saved override wins
    #expect(internalSrv.status == "ready")               // default wins (skip)
    #expect(internalSrv.healthStatus == "ok")            // default wins (skip)
    // Default id set is deduped — no double entry.
    #expect(servers.filter { $0.id == "nativeagent-internal" }.count == 1)
}

@Test func listServers_malformedRegistry_returnsDefaultsOnly() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let mcpDir = root.appendingPathComponent("mcp", isDirectory: true)
    try FileManager.default.createDirectory(at: mcpDir, withIntermediateDirectories: true)
    // Garbage JSON → persistence layer returns defaultValue ([]) → only
    // the auto-merged defaults survive.
    try Data("not json at all !!!".utf8).write(
        to: mcpDir.appendingPathComponent("servers.json"))
    let d = SwiftNativeMCPDispatcher(root: root)
    let servers = try await d.listServers()
    #expect(Set(servers.map(\.id)) == ["nativeagent-internal", "searxng-local"])
}

// MARK: - Reads: tools

@Test func listTools_unknownServer_returnsEmpty() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Seed a cache entry for "srv-x" but query for "does-not-exist".
    try seedToolsCache([
        "srv-x": .object([
            "createdAt": .string("2026-05-01T00:00:00+00:00"),
            "tools": .array([
                .object(["name": .string("tool.one"), "description": .string("d")])
            ])
        ])
    ], root: root)
    let d = SwiftNativeMCPDispatcher(root: root)
    let tools = try await d.listTools(forServer: "does-not-exist")
    #expect(tools.isEmpty)
}

@Test func listTools_validCache_returnsAll() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let cachedAt = "2026-05-30T12:00:00+00:00"
    try seedToolsCache([
        "nativeagent-internal": .object([
            "createdAt": .string(cachedAt),
            "tools": .array([
                .object([
                    "name": .string("agent.operating_map"),
                    "description": .string("Return the live NativeAgent operating map."),
                    "inputSchema": .object(["type": .string("object"), "properties": .object([:])]),
                ]),
                .object([
                    "name": .string("capabilities.summary"),
                    "description": .string("Return capability counts."),
                    "inputSchema": .object(["type": .string("object"), "properties": .object([:])]),
                ]),
            ])
        ])
    ], root: root)
    let d = SwiftNativeMCPDispatcher(root: root)
    let tools = try await d.listTools(forServer: "nativeagent-internal")
    #expect(tools.count == 2)
    // Sorted by name.
    #expect(tools[0].name == "agent.operating_map")
    #expect(tools[1].name == "capabilities.summary")
    // cachedAt stamped from server entry's createdAt.
    #expect(tools[0].cachedAt == cachedAt)
    // serverId propagated.
    #expect(tools[0].serverId == "nativeagent-internal")
}

// MARK: - Reads: consents

@Test func listConsents_empty_returnsEmpty() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let d = SwiftNativeMCPDispatcher(root: root)
    let consents = try await d.listConsents()
    #expect(consents.isEmpty)
}

@Test func listConsents_seededLedger_returnsAll() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedConsentLedger([
        makeConsentJSON(serverId: "srv-a", toolName: "tool.one",
                        updatedAt: "2026-05-30T10:00:00+00:00"),
        makeConsentJSON(serverId: "srv-b", toolName: "tool.two",
                        updatedAt: "2026-05-30T12:00:00+00:00"),
        makeConsentJSON(serverId: "srv-c", toolName: "tool.three",
                        updatedAt: "2026-05-30T11:00:00+00:00"),
    ], root: root)
    let d = SwiftNativeMCPDispatcher(root: root)
    let consents = try await d.listConsents()
    #expect(consents.count == 3)
    // Sorted by updatedAt DESC.
    #expect(consents[0].toolName == "tool.two")
    #expect(consents[1].toolName == "tool.three")
    #expect(consents[2].toolName == "tool.one")
}

@Test func consentAuthorityFailsClosedAndPreservesMalformedLedgerBytes() async throws {
    let malformedRow: JSONValue = .array([.object([
        "id": .string("srv-a:tool.one"),
        "serverId": .string(""),
        "toolName": .string("tool.one"),
    ])])
    let duplicate = makeConsentJSON(serverId: "srv-a", toolName: "tool.one")
    let fixtures: [Data] = [
        Data("{not-json".utf8),
        try JSONValue.object(["consents": .array([])]).serializedData(pretty: false),
        try malformedRow.serializedData(pretty: false),
        try JSONValue.array([duplicate, duplicate]).serializedData(pretty: false),
    ]

    for (index, bytes) in fixtures.enumerated() {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = root.appendingPathComponent("mcp/consent/ledger.json")
        try FileManager.default.createDirectory(
            at: ledger.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: ledger)
        let dispatcher = SwiftNativeMCPDispatcher(root: root)

        await #expect(throws: MCPDispatcherError.self) {
            _ = try await dispatcher.listConsents()
        }
        await #expect(throws: MCPDispatcherError.self) {
            _ = try await dispatcher.grantConsent(MCPConsentGrant(
                serverId: "srv-new",
                toolName: "tool.new",
                risk: "app_data_read"
            ))
        }
        await #expect(throws: MCPDispatcherError.self) {
            try await dispatcher.revokeConsent(serverId: "srv-a", toolName: "tool.one")
        }
        #expect(try Data(contentsOf: ledger) == bytes, "fixture \(index) was rewritten")
    }
}

@Test func consentAuthorityAcceptsLegacyMissingPermissionsAsEmpty() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    guard case .object(var legacy) = makeConsentJSON(
        serverId: "legacy",
        toolName: "read"
    ) else { return }
    legacy["permissions"] = nil
    try seedConsentLedger([.object(legacy)], root: root)

    let records = try await SwiftNativeMCPDispatcher(root: root).listConsents()
    #expect(records.count == 1)
    #expect(records.first?.permissions == [])
}

// MARK: - Mutations: grantConsent

@Test func grantConsent_createsRecord() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixed = Date(timeIntervalSince1970: 1_748_600_000)
    let d = SwiftNativeMCPDispatcher(root: root, clock: { fixed })
    let grant = MCPConsentGrant(
        serverId: "nativeagent-internal",
        toolName: "agent.operating_map",
        risk: "app_data_read",
        permissions: ["read"],
        argumentSummary: "Test grant."
    )
    let rec = try await d.grantConsent(grant)
    #expect(rec.id == "nativeagent-internal:agent.operating_map")
    #expect(rec.serverId == "nativeagent-internal")
    #expect(rec.toolName == "agent.operating_map")
    #expect(rec.status == "granted")
    #expect(rec.revokedAt == nil)
    #expect(rec.permissions == ["read"])  // sorted/deduped
    // Round-trip: listConsents must see the record.
    let consents = try await d.listConsents()
    #expect(consents.count == 1)
    #expect(consents[0].id == rec.id)
}

@Test func grantConsent_overwritesExisting() async throws {
    // The impl does an upsert (drops prior record with matching id, inserts new
    // at front). Two grants on same (serverId, toolName) → still 1 record.
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let d = SwiftNativeMCPDispatcher(root: root)
    let base = MCPConsentGrant(
        serverId: "srv-x", toolName: "t.one",
        risk: "app_data_read", permissions: ["read"]
    )
    _ = try await d.grantConsent(base)
    let updated = MCPConsentGrant(
        serverId: "srv-x", toolName: "t.one",
        risk: "network_read", permissions: ["read", "write"],
        argumentSummary: "Updated grant."
    )
    let rec2 = try await d.grantConsent(updated)
    let consents = try await d.listConsents()
    // Upsert → single record.
    #expect(consents.count == 1)
    // New record reflects the second grant's values.
    #expect(rec2.risk == "network_read")
    #expect(rec2.permissions == ["read", "write"])
    #expect(rec2.argumentSummary == "Updated grant.")
}

@Test func revokeConsent_setsRevokedAt() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixed = Date(timeIntervalSince1970: 1_748_700_000)
    let d = SwiftNativeMCPDispatcher(root: root, clock: { fixed })
    // Seed an existing granted consent.
    try seedConsentLedger([
        makeConsentJSON(serverId: "srv-z", toolName: "tool.revoke",
                        status: "granted",
                        grantedAt: "2026-05-01T00:00:00+00:00",
                        updatedAt: "2026-05-01T00:00:01+00:00")
    ], root: root)
    try await d.revokeConsent(serverId: "srv-z", toolName: "tool.revoke")
    let consents = try await d.listConsents()
    #expect(consents.count == 1)
    let r = consents[0]
    #expect(r.status == "revoked")
    #expect(r.revokedAt != nil)
    // updatedAt should be the clock's stamp.
    let expected = SwiftNativeMCPDispatcher.isoTimestamp(fixed)
    #expect(r.updatedAt == expected)
    #expect(r.revokedAt == expected)
}

@Test func revokeConsent_throwsConsentNotFound() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let d = SwiftNativeMCPDispatcher(root: root)
    await #expect(throws: MCPDispatcherError.self) {
        try await d.revokeConsent(serverId: "no-such-server", toolName: "no-such-tool")
    }
}

// MARK: - Concurrency

@Test func concurrentGrantsDoNotClobber() async throws {
    // 5 parallel grants on distinct (serverId, toolName) pairs.
    // All must land — no record must be silently dropped.
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let d = SwiftNativeMCPDispatcher(root: root)
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<5 {
            group.addTask {
                let g = MCPConsentGrant(
                    serverId: "srv-concurrent",
                    toolName: "tool.\(i)",
                    risk: "app_data_read"
                )
                _ = try? await d.grantConsent(g)
            }
        }
        await group.waitForAll()
    }
    let consents = try await d.listConsents()
    #expect(consents.count == 5)
    let toolNames = Set(consents.map(\.toolName))
    for i in 0..<5 {
        #expect(toolNames.contains("tool.\(i)"))
    }
}

// MARK: - Native JSON round-trip

@Test func grantConsentWritesReadableLedgerJSON() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let d = SwiftNativeMCPDispatcher(root: root)
    let grant = MCPConsentGrant(
        serverId: "nativeagent-internal",
        toolName: "capabilities.summary",
        risk: "app_data_read",
        permissions: [],
        argumentSummary: "Auto-granted for low-risk app-local MCP call."
    )
    _ = try await d.grantConsent(grant)
    let ledgerPath = await d.consentLedgerPath
    let ledgerData = try Data(contentsOf: ledgerPath)
    let parsed = try JSONValue.parse(ledgerData)
    guard case .array(let arr) = parsed, !arr.isEmpty,
          case .object(let obj) = arr[0],
          case .string(let sid) = obj["serverId"] ?? .null,
          case .string(let tn) = obj["toolName"] ?? .null else {
        Issue.record("ledger JSON has unexpected shape: \(String(data: ledgerData, encoding: .utf8) ?? "")")
        return
    }
    #expect(sid == "nativeagent-internal")
    #expect(tn == "capabilities.summary")
    // Verify status=granted round-trips.
    if case .string(let st) = obj["status"] ?? .null {
        #expect(st == "granted")
    } else {
        Issue.record("status field missing in ledger output")
    }
}

@Test func consentWithUnknownExtraReadBySwift() async throws {
    // Seed ledger.json with an extra unknown key to verify extras round-trip.
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedConsentLedger([
        makeConsentJSON(
            serverId: "nativeagent-internal",
            toolName: "agent.operating_map",
            status: "granted",
            grantedAt: "2026-05-18T22:16:39.978015+00:00",
            updatedAt: "2026-05-18T22:16:39.978018+00:00",
            argumentSummary: "Auto-granted for low-risk app-local MCP call (no risky permissions).",
            extraKey: "_daemonVersion",
            extraValue: .string("1.42.0")
        )
    ], root: root)
    let d = SwiftNativeMCPDispatcher(root: root)
    let consents = try await d.listConsents()
    #expect(consents.count == 1)
    let c = consents[0]
    #expect(c.id == "nativeagent-internal:agent.operating_map")
    // extras must preserve the unknown key.
    guard case .object(let extra)? = c.extras else {
        Issue.record("extras nil — unknown key was dropped instead of preserved")
        return
    }
    if case .string(let ver) = extra["_daemonVersion"] ?? .null {
        #expect(ver == "1.42.0")
    } else {
        Issue.record("_daemonVersion key missing from extras")
    }
}

// MARK: - Replay-baseline

@Test func replayBaselineConsentsMatchCapture() async throws {
    // Capture: output.consents has 2 records (see 3309a1a8-4e21-4cec-9e7c-817dc596d345.json).
    // ignore_fields: grantedAt, updatedAt, revokedAt → compare only structural fields.
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Seed with the capture's consent records (timestamps normalised).
    try seedConsentLedger([
        makeConsentJSON(
            serverId: "nativeagent-internal",
            toolName: "agent.operating_map",
            status: "granted",
            risk: "app_data_read",
            grantedAt: "2026-05-18T22:16:39.978015+00:00",
            updatedAt: "2026-05-18T22:16:39.978018+00:00",
            argumentSummary: "Auto-granted for low-risk app-local MCP call (no risky permissions)."
        ),
        makeConsentJSON(
            serverId: "nativeagent-internal",
            toolName: "capabilities.summary",
            status: "granted",
            risk: "app_data_read",
            grantedAt: "2026-05-06T17:43:47.679714+00:00",
            updatedAt: "2026-05-06T17:43:47.679716+00:00",
            argumentSummary: "Auto-granted for low-risk app-local MCP call."
        ),
    ], root: root)
    let d = SwiftNativeMCPDispatcher(root: root)
    let consents = try await d.listConsents()
    // Capture has 2 consents — match count.
    #expect(consents.count == 2)
    // require_present_fields: id, serverId, toolName, status.
    for c in consents {
        #expect(!c.id.isEmpty)
        #expect(!c.serverId.isEmpty)
        #expect(!c.toolName.isEmpty)
        #expect(!c.status.isEmpty)
    }
    // Structural match: both from nativeagent-internal, both granted.
    let ids = Set(consents.map(\.id))
    #expect(ids.contains("nativeagent-internal:agent.operating_map"))
    #expect(ids.contains("nativeagent-internal:capabilities.summary"))
    for c in consents {
        #expect(c.status == "granted")
        #expect(c.serverId == "nativeagent-internal")
        #expect(c.scope == "server_tool")
    }
    // NOTE: The capture also shows `permissions` key absent on the
    // capabilities.summary record. The Swift MCPConsent.init(json:) correctly defaults to [].
    // The parser handles this gracefully — no issue filed.
}

// MARK: - Extras round-trip on MCPServer

@Test func serverExtrasRoundTrip() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Seed a server with an extra unknown key.
    var obj = makeServerJSON(id: "srv-extras", name: "Extras Server")
    guard case .object(var dict) = obj else {
        Issue.record("expected object"); return
    }
    dict["_customField"] = .string("custom-value")
    obj = .object(dict)
    try seedServers([obj], root: root)
    let d = SwiftNativeMCPDispatcher(root: root)
    let servers = try await d.listServers()
    // listServers now auto-merges the 2 default servers; the seeded
    // srv-extras is the 3rd. Pull it out by id.
    #expect(servers.count == 3)
    guard let extrasSrv = servers.first(where: { $0.id == "srv-extras" }) else {
        Issue.record("seeded srv-extras missing from listServers"); return
    }
    guard case .object(let extra)? = extrasSrv.extras else {
        Issue.record("extras nil — unknown key was dropped")
        return
    }
    if case .string(let v) = extra["_customField"] ?? .null {
        #expect(v == "custom-value")
    } else {
        Issue.record("_customField missing from extras")
    }
    // toJSON must preserve the extra key.
    let json = extrasSrv.toJSON()
    guard case .object(let outDict) = json else {
        Issue.record("toJSON returned non-object"); return
    }
    #expect(outDict["_customField"] != nil)
}

// MARK: - isoTimestamp format

@Test func isoTimestampUsesOffsetSuffix() async throws {
    // Native MCP timestamps use "+00:00" suffix, not "Z".
    let t = Date(timeIntervalSince1970: 1_748_600_000)
    let stamp = SwiftNativeMCPDispatcher.isoTimestamp(t)
    #expect(stamp.hasSuffix("+00:00"))
    #expect(!stamp.hasSuffix("Z"))
    // Basic ISO-8601 structure: contains "T".
    #expect(stamp.contains("T"))
}

// MARK: - defaultDataRoot / libraryAppSupportFallback

@Test func defaultDataRootHonorsEnvVar() async throws {
    let prior = ProcessInfo.processInfo.environment["NATIVE_AGENT_DATA_ROOT"]
    setenv("NATIVE_AGENT_DATA_ROOT", "/tmp/mcp-test-root-xyz", 1)
    defer {
        if let prior {
            setenv("NATIVE_AGENT_DATA_ROOT", prior, 1)
        } else {
            unsetenv("NATIVE_AGENT_DATA_ROOT")
        }
    }
    let root = SwiftNativeMCPDispatcher.defaultDataRoot()
    #expect(root.path == "/tmp/mcp-test-root-xyz")
}

@Test func libraryAppSupportFallbackHasNoDataSuffix() async throws {
    let url = libraryAppSupportFallback()
    #expect(url.lastPathComponent == "NativeAgent")
    #expect(url.lastPathComponent != "data")
}

// MARK: - MCPServer.command byte round-trip

/// FAIL 1 (post-review): MCPServer.command is presence-preserving Optional.
/// Missing key → nil → omit on re-emit. Explicit "" → Some("") → re-emit
/// as `"command": ""`. Both forms round-trip byte-identically through the
/// native JSON serializer.
@Test func serverWithMissingCommandKeyOmitsCommandOnRoundTrip() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp-roundtrip-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let serverPath = dir.appendingPathComponent("server.json")
    let fixture: JSONValue = .object([
        "createdAt": .string("2026-05-30T12:00:00+00:00"),
        "endpoint": .string("http://example/sse"),
        "healthStatus": .string("ok"),
        "id": .string("server-a"),
        "name": .string("server-a"),
        "resourceCount": .int(0),
        "riskClass": .string("network_localhost"),
        "status": .string("ready"),
        "toolCount": .int(0),
        "transport": .string("http"),
        "updatedAt": .string("2026-05-30T12:00:00+00:00"),
    ])
    let fixtureBytes = try fixture.serializedData(pretty: true)
    try fixtureBytes.write(to: serverPath)
    let parsed = try JSONValue.parse(fixtureBytes)
    guard let server = MCPServer(json: parsed) else {
        Issue.record("MCPServer.init(json:) returned nil"); return
    }
    #expect(server.command == nil)  // not Some("")
    let rebuilt = try server.toJSON().serializedData(pretty: true)
    #expect(rebuilt == fixtureBytes,
            "byte round-trip drift.\nRebuilt: \(String(data: rebuilt, encoding: .utf8) ?? "")\nFixture: \(String(data: fixtureBytes, encoding: .utf8) ?? "")")
}

@Test func serverWithExplicitEmptyCommandIsByteRoundTripSafe() async throws {
    // Some registries write command as a possibly empty string. Swift
    // round-trips Some("") as `"command": ""` -- key present, value empty.
    let fixtureJSON = #"""
{
  "command": "",
  "createdAt": "2026-05-30T12:00:00+00:00",
  "endpoint": "http://example/sse",
  "healthStatus": "ok",
  "id": "server-b",
  "name": "server-b",
  "resourceCount": 0,
  "riskClass": "network_localhost",
  "status": "ready",
  "toolCount": 0,
  "transport": "http",
  "updatedAt": "2026-05-30T12:00:00+00:00"
}
"""#
    let parsed = try JSONValue.parse(Data(fixtureJSON.utf8))
    guard let server = MCPServer(json: parsed) else {
        Issue.record("MCPServer.init(json:) returned nil"); return
    }
    #expect(server.command == "")
    let rebuilt = try server.toJSON().serialize(pretty: true)
    #expect(rebuilt == fixtureJSON,
            "byte round-trip drift.\nRebuilt: \(rebuilt)\nFixture: \(fixtureJSON)")
}

// MARK: - Concurrent grant + revoke on the SAME key

/// WARN 5 (post-review): the mutationTail serializes grant/revoke even when
/// they race on the same (serverId, toolName). After 20 alternating ops
/// every single one must succeed (no spurious errors), the ledger must
/// contain exactly one record for the key, and that record's
/// status/revokedAt fields must be internally consistent.
@Test func concurrentGrantRevokeSameKeyConverges() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let dispatcher = SwiftNativeMCPDispatcher(root: root)
    let server = "test-server"
    let tool = "test-tool"
    // Seed an initial grant so revokes have something to act on.
    _ = try await dispatcher.grantConsent(MCPConsentGrant(
        serverId: server, toolName: tool, risk: "network_localhost"
    ))
    let iterations = 20
    let outcomes = await withTaskGroup(of: Result<String, Error>.self) { group -> [Result<String, Error>] in
        for i in 0..<iterations {
            if i.isMultiple(of: 2) {
                group.addTask {
                    do {
                        _ = try await dispatcher.grantConsent(MCPConsentGrant(
                            serverId: server, toolName: tool, risk: "network_localhost"
                        ))
                        return .success("grant")
                    } catch { return .failure(error) }
                }
            } else {
                group.addTask {
                    do {
                        try await dispatcher.revokeConsent(serverId: server, toolName: tool)
                        return .success("revoke")
                    } catch { return .failure(error) }
                }
            }
        }
        var collected: [Result<String, Error>] = []
        for await result in group { collected.append(result) }
        return collected
    }
    // Every op should succeed — no errors expected since the seed grant
    // means every revoke finds something to revoke, and grants overwrite.
    for result in outcomes {
        switch result {
        case .success: continue
        case .failure(let err):
            Issue.record("unexpected error from concurrent op: \(err)")
        }
    }
    let consents = try await dispatcher.listConsents()
    let matching = consents.filter { $0.serverId == server && $0.toolName == tool }
    #expect(matching.count == 1,
            "expected exactly one record for the racing key, got \(matching.count)")
    // Internal consistency: revoked iff revokedAt is set.
    if let rec = matching.first {
        #expect((rec.status == "revoked") == (rec.revokedAt != nil))
    }
}

// MARK: - W31 W02: cross-process + cross-instance flock (the prereq this closes)

/// THE regression test for the wave-30 W09 revert. Two FRESH
/// SwiftNativeMCPDispatcher instances (each with its own `mutationTail` actor,
/// so the in-actor serialization does NOT cover them) plus a Swift subprocess writer
/// contend on the SAME mcp/consent/ledger.json at once. Every writer does the
/// same read-prepend-write flow, each inside the SAME cross-process flock on
/// the `<path>.lock` sibling. With the lock, NO row is lost. Before W31
/// -- only the in-actor mutationTail serialized, and only within ONE instance --
/// the interleaved R-M-W silently clobbered rows.
///
/// Determinism notes (gpt-5.5 review hardening):
///   - The helper writer is SELF-CONTAINED (raw `flock` on the exact
///     `<path>.lock` sibling), NOT an import from an external checkout; it
///     proves the lock CONVENTION the Swift side uses, independent of any repo.
///   - Both Swift instances loop many R-M-W cycles and the helper writer holds
///     the lock with an in-critical-section sleep, so the contention window is
///     wide and repeated. The negative control (lock stripped from the impl)
///     reliably drops rows — a lucky all-serial schedule across this many
///     interleaved cycles is not realistically reachable.
@Test func crossProcessConcurrentWritersNoLostUpdates() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // Seed 3 pre-existing granted rows. They must SURVIVE every concurrent
    // writer's rewrite — a lost-update bug would drop them.
    try seedConsentLedger([
        makeConsentJSON(serverId: "seed", toolName: "keep.0"),
        makeConsentJSON(serverId: "seed", toolName: "keep.1"),
        makeConsentJSON(serverId: "seed", toolName: "keep.2"),
    ], root: root)

    let ledgerPath = root
        .appendingPathComponent("mcp", isDirectory: true)
        .appendingPathComponent("consent", isDirectory: true)
        .appendingPathComponent("ledger.json")

    // Two FRESH instances — distinct actors, distinct mutationTail. Only the
    // file lock can serialize their writes against each other AND against the
    // subprocess helper.
    let instanceA = SwiftNativeMCPDispatcher(root: root)
    let instanceB = SwiftNativeMCPDispatcher(root: root)

    let nHelper = 6, nSwift = 6
    // TWO-WAY barrier (gpt-5.5 review: a one-way latched sentinel could be
    // observed STALE after the helper released the lock). Hard handshake:
    //   1. The helper, INSIDE its first locked critical section, touches `ready`.
    //   2. Swift observes `ready`, touches `ack`, then launches its grants.
    //   3. The helper BLOCKS inside that same critical section (still holding the
    //      lock) until it sees `ack` (bounded), THEN does its in-lock work.
    // So when Swift's grants start, the helper is PROVABLY still holding the lock —
    // no "Swift noticed too late" escape. Without the flock, the Swift writers
    // race the helper's in-flight RMW and clobber it (deterministic failure).
    let readyPath = root.appendingPathComponent("helper_ready.flag")
    let ackPath = root.appendingPathComponent("swift_ack.flag")

    // External helper: nHelper grants, each a read-prepend-write under a flock
    // on the same `<path>.lock` sibling the Swift side opens. The in-lock sleep
    // widens the window so an unlocked Swift writer interleaves.
    let helper = try NativeAgentFlockChild.mcpConsentWriter(
        ledger: ledgerPath,
        ready: readyPath,
        ack: ackPath,
        count: nHelper
    )
    defer { helper.terminate() }

    // Wait until the helper announces it holds the lock (ready), then ack so it
    // stays in the critical section until it sees our ack — provable overlap.
    let barrierDeadline = Date().addingTimeInterval(30.0)
    while !FileManager.default.fileExists(atPath: readyPath.path) {
        if Date() > barrierDeadline {
            Issue.record("helper never reached its critical section (ready timeout)")
            break
        }
        try await Task.sleep(nanoseconds: 2_000_000)  // 2ms poll
    }
    // Ack: tells the helper (still holding the lock) that we're about to race it.
    FileManager.default.createFile(atPath: ackPath.path, contents: Data())

    await withTaskGroup(of: Void.self) { group in
        for i in 0..<nSwift {
            group.addTask {
                let g = MCPConsentGrant(
                    serverId: "swiftA", toolName: "tool.\(i)", risk: "app_data_read"
                )
                _ = try? await instanceA.grantConsent(g)
            }
            group.addTask {
                let g = MCPConsentGrant(
                    serverId: "swiftB", toolName: "tool.\(i)", risk: "app_data_read"
                )
                _ = try? await instanceB.grantConsent(g)
            }
        }
        await group.waitForAll()
    }

    let helperStatus = helper.wait(timeout: 60)
    if helperStatus == nil { helper.terminate() }
    #expect(helperStatus == 0,
            "subprocess writer did not finish cleanly: \(String(describing: helperStatus))")

    // Final ledger must contain EVERY writer's rows AND every seed row.
    // 3 seed + nSwift swiftA + nSwift swiftB + nHelper helper distinct ids, none lost.
    let consents = try await instanceA.listConsents()
    let ids = Set(consents.map(\.id))
    for i in 0..<3 { #expect(ids.contains("seed:keep.\(i)"), "lost seed row keep.\(i)") }
    for i in 0..<nSwift { #expect(ids.contains("swiftA:tool.\(i)"), "lost swiftA row tool.\(i)") }
    for i in 0..<nSwift { #expect(ids.contains("swiftB:tool.\(i)"), "lost swiftB row tool.\(i)") }
    for i in 0..<nHelper { #expect(ids.contains("helper:tool.\(i)"), "lost helper row tool.\(i)") }
    let expected = 3 + nSwift + nSwift + nHelper
    #expect(consents.count == expected,
            "expected \(expected) distinct rows with no lost updates, got \(consents.count): \(ids.sorted())")
}

// MARK: - W31 W02: trace parity (gpt-5.5 review MAJOR fix)

/// grant/revoke must emit an `mcp.consent.grant` / `mcp.consent.revoke` event
/// to `<root>/traces/events.jsonl` so the SwiftNative-gated path keeps trace
/// parity with the daemon's record_trace. Without
/// this, the re-enabled Mac gate would silently drop the activity/trace entries
/// the HTTP path produces (the exact class of side-effect gap that got wave-30
/// W17 reverted). Envelope shape mirrors record_trace: {id, kind, title,
/// status, payload, createdAt}.
@Test func grantAndRevoke_emitConsentTracesForParity() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let d = SwiftNativeMCPDispatcher(root: root)

    let grant = MCPConsentGrant(
        serverId: "srv-trace", toolName: "tool.trace",
        risk: "app_data_read", permissions: ["read"]
    )
    _ = try await d.grantConsent(grant)
    try await d.revokeConsent(serverId: "srv-trace", toolName: "tool.trace")

    // Read traces/events.jsonl back.
    let tracesURL = root
        .appendingPathComponent("traces", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    let raw = try String(contentsOf: tracesURL, encoding: .utf8)
    let lines = raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    let events = lines.compactMap { try? JSONValue.parse(Data($0.utf8)) }

    func event(kind: String) -> [String: JSONValue]? {
        for e in events {
            guard case .object(let obj) = e,
                  case .string(let k)? = obj["kind"], k == kind else { continue }
            return obj
        }
        return nil
    }

    // grant trace
    guard let g = event(kind: "mcp.consent.grant") else {
        Issue.record("no mcp.consent.grant trace; lines=\(lines)"); return
    }
    if case .string(let title)? = g["title"] { #expect(title == "srv-trace:tool.trace") }
    if case .string(let status)? = g["status"] { #expect(status == "granted") }
    if case .object(let p)? = g["payload"] {
        if case .string(let sid)? = p["serverId"] { #expect(sid == "srv-trace") }
        if case .string(let tn)? = p["toolName"] { #expect(tn == "tool.trace") }
        if case .array(let perms)? = p["permissions"] { #expect(perms == [.string("read")]) }
    } else { Issue.record("grant trace missing payload object") }

    // revoke trace
    guard let r = event(kind: "mcp.consent.revoke") else {
        Issue.record("no mcp.consent.revoke trace; lines=\(lines)"); return
    }
    if case .string(let title)? = r["title"] { #expect(title == "srv-trace:tool.trace") }
    if case .string(let status)? = r["status"] { #expect(status == "revoked") }
    if case .object(let p)? = r["payload"] {
        if case .string(let cid)? = p["consentId"] { #expect(cid == "srv-trace:tool.trace") }
    } else { Issue.record("revoke trace missing payload object") }
}

/// A revoke that throws .consentNotFound must NOT emit a trace — matching the
/// daemon, which raises ValueError BEFORE record_trace. Guards against a
/// spurious "revoked" trace for a row that was never revoked.
@Test func revoke_notFound_emitsNoTrace() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let d = SwiftNativeMCPDispatcher(root: root)
    await #expect(throws: MCPDispatcherError.self) {
        try await d.revokeConsent(serverId: "nope", toolName: "nope")
    }
    let tracesURL = root
        .appendingPathComponent("traces", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    // Either the file doesn't exist, or it has no revoke event.
    if let raw = try? String(contentsOf: tracesURL, encoding: .utf8) {
        #expect(!raw.contains("mcp.consent.revoke"),
                "a failed revoke must not emit a revoke trace")
    }
}

// MARK: - A3 fail-closed MCP auto-grant gate (loop-A 2026-06-13)

/// The canonical gate auto-grants ONLY explicit read tiers; every other class —
/// including ones the old denylist never anticipated — requires approval.
@Test func mcpRiskGateFailsClosed() {
    // Explicit read tiers auto-grant (no approval).
    for r in ["app_data_read", "network_read", "read", "read_only", "none", "low", "safe", " App_Data_Read "] {
        #expect(MCPToolBridge.riskRequiresApproval(r) == false, "read tier '\(r)' should auto-grant")
    }
    // The classes the old denylist MISSED — must now require approval.
    for r in ["network_localhost", "external", "network_public", "trade", "order", "brokerage"] {
        #expect(MCPToolBridge.riskRequiresApproval(r) == true, "side-effecting class '\(r)' must require approval")
    }
    // Classes the old denylist already caught — still require approval.
    for r in ["app_data_write", "network_write", "write", "send", "delete", "admin", "money", "high", "critical"] {
        #expect(MCPToolBridge.riskRequiresApproval(r) == true)
    }
    // The missing-tool-risk sentinel and any unknown/garbage class fail closed.
    for r in ["approval_gated_missing_tool_risk", "", "garbage", "weird_future_class"] {
        #expect(MCPToolBridge.riskRequiresApproval(r) == true, "unknown class '\(r)' must fail closed")
    }
}
