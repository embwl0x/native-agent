import Testing
import Foundation
@testable import TrustCenter
import NativeAgentCore
import PersistenceCore

// MARK: - URLProtocol mock

@MainActor
private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private func mockSession(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MockURLProtocol.self]
    MockURLProtocol.handler = handler
    return URLSession(configuration: cfg)
}

private func makeResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

private let mockBaseURL = URL(string: "http://127.0.0.1:9999")!

private func readBody(_ req: URLRequest) -> Data {
    if let body = req.httpBody { return body }
    guard let stream = req.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var collected = Data()
    var buf = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let n = stream.read(&buf, maxLength: buf.count)
        if n <= 0 { break }
        collected.append(buf, count: n)
    }
    return collected
}

// MARK: - Recording inner

private final class RecordingTrustCenter: TrustCenterProtocol, @unchecked Sendable {
    var getCalls = 0
    var autonomyCalls = 0
    var lastUpdate: JSONValue?
    var lastSimulate: JSONValue?
    let policy: TrustPolicy
    let autonomy: AutonomyPolicy
    let simulation: TrustSimulationResult

    init(
        policy: TrustPolicy = TrustPolicy(permissionLevel: "full_mac_os"),
        autonomy: AutonomyPolicy = AutonomyPolicy(status: "ready", rawResponse: .object([:])),
        simulation: TrustSimulationResult = TrustSimulationResult(
            rawResponse: .object(["allowed": .bool(true)])
        )
    ) {
        self.policy = policy
        self.autonomy = autonomy
        self.simulation = simulation
    }

    func getTrust() async throws -> TrustPolicy {
        getCalls += 1
        return policy
    }
    func updateTrust(_ update: JSONValue) async throws -> TrustPolicy {
        lastUpdate = update
        return policy
    }
    func simulateTrust(_ scenario: JSONValue) async throws -> TrustSimulationResult {
        lastSimulate = scenario
        return simulation
    }
    func getAutonomyPolicy() async throws -> AutonomyPolicy {
        autonomyCalls += 1
        return autonomy
    }
}

// MARK: - Factory

@Test func factoryReturnsSwiftNativeByDefault() async throws {
    let impl = makeTrustCenter()
    #expect(impl is SwiftNativeTrustCenter)
}

@Test func placeholderFactoryReturnsSwiftNativeWhenEnabled() async throws {
    let impl = makeTrustCenter()
    #expect(impl is SwiftNativeTrustCenter)
}

// MARK: - Codable shape

@Test func TrustPolicy_round_trips_via_Codable_with_extras() throws {
    let p = TrustPolicy(
        permissionLevel: "full_mac_os",
        autonomyDefault: "workspace_autonomous",
        updatedAt: "2026-05-30T06:40:19Z",
        appDataRoot: "/var/native",
        extras: .object([
            "toolAutonomy": .object(["search.*": .string("auto")]),
            "macControlPolicy": .object(["remote_from_ios_allowed": .bool(true)]),
            "missionPolicy": .object(["enabled": .bool(true)]),
            "novelKey": .int(42),
        ])
    )
    let data = try JSONEncoder().encode(p)
    let back = try JSONDecoder().decode(TrustPolicy.self, from: data)
    #expect(back == p)
    let s = String(data: data, encoding: .utf8) ?? ""
    #expect(s.contains("\"permissionLevel\""))
    #expect(s.contains("\"toolAutonomy\""))
    #expect(s.contains("\"novelKey\""))
}

@Test func TrustPolicy_decodes_unknown_keys_into_extras() throws {
    let raw = Data("""
    {"permissionLevel":"full_mac_os","autonomyDefault":"manual",
     "updatedAt":"2026-05-30T00:00:00Z","appDataRoot":"/x",
     "telegramPolicy":{"enabled":true},"filePolicy":{"outside_workspace":"allow"},
     "weirdo":99}
    """.utf8)
    let p = try JSONDecoder().decode(TrustPolicy.self, from: raw)
    #expect(p.permissionLevel == "full_mac_os")
    #expect(p.autonomyDefault == "manual")
    guard case .object(let extras)? = p.extras else {
        Issue.record("extras should be object"); return
    }
    #expect(extras["telegramPolicy"] != nil)
    #expect(extras["filePolicy"] != nil)
    #expect(extras["weirdo"] != nil)
}

@Test func AutonomyPolicy_preserves_rawResponse() throws {
    let raw: JSONValue = .object([
        "status": .string("ready"),
        "permissionLevel": .string("full_mac_os"),
        "fullMacMode": .string("workspace"),
        "gates": .array([
            .object([
                "id": .string("permissionLevel"),
                "title": .string("Access mode"),
                "enabled": .bool(true),
                "value": .string("full_mac_os"),
                "status": .string("ready"),
            ])
        ]),
        "harnessAnnex": .object(["x": .int(1)]),
    ])
    let p = AutonomyPolicy(
        status: "ready",
        permissionLevel: "full_mac_os",
        fullMacMode: "workspace",
        gates: nil,
        rawResponse: raw
    )
    let data = try JSONEncoder().encode(p)
    let back = try JSONDecoder().decode(AutonomyPolicy.self, from: data)
    #expect(back.status == p.status)
    #expect(back.permissionLevel == p.permissionLevel)
    #expect(back.fullMacMode == p.fullMacMode)
    #expect(back.rawResponse == raw)
}

@Test func TrustSimulationResult_preserves_rawResponse() throws {
    let raw: JSONValue = .object([
        "allowed": .bool(true),
        "requiresApproval": .bool(false),
        "risk": .string("low"),
        "action": .string("calendar.list_events"),
        "reasons": .array([.string("fits policy")]),
        "policy": .object(["permissionLevel": .string("full_mac_os")]),
    ])
    let r = TrustSimulationResult(rawResponse: raw)
    let data = try JSONEncoder().encode(r)
    let back = try JSONDecoder().decode(TrustSimulationResult.self, from: data)
    #expect(back == r)
    #expect(back.rawResponse == raw)
}

// MARK: - SwiftNativeManifestSigner tests
//
// These tests pin Swift's canonicalization, timestamp formatting, and
// signature behavior so tool manifests stay stable inside the native runtime.

private func makeTempDataRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MSigner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func stageSigningKey(at root: URL, bytes: Data) throws {
    let dir = root.appendingPathComponent("tools", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent(".manifest_signing_key")
    try bytes.write(to: path, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
}

@Suite(.serialized)
struct ManifestSignerTests {

@Test func canonicalBytes_strips_signature_and_signedAt() throws {
    let m: [String: JSONValue] = [
        "id": .string("tool.x"),
        "manifestSignature": .string("DEADBEEF"),
        "signedAt": .string("2026-05-30T00:00:00.000000+00:00"),
    ]
    let bytes = try SwiftNativeManifestSigner.canonicalBytes(m)
    let s = String(data: bytes, encoding: .utf8) ?? ""
    #expect(!s.contains("manifestSignature"))
    #expect(!s.contains("signedAt"))
    #expect(s.contains("\"id\":\"tool.x\""))
}

@Test func canonicalBytes_forces_signatureVersion_to_2() throws {
    let m: [String: JSONValue] = ["id": .string("t"), "signatureVersion": .int(99)]
    let bytes = try SwiftNativeManifestSigner.canonicalBytes(m)
    let s = String(data: bytes, encoding: .utf8) ?? ""
    #expect(s.contains("\"signatureVersion\":2"))
    #expect(!s.contains("99"))
}

@Test func canonicalBytes_sorts_keys_lexically() throws {
    let m: [String: JSONValue] = [
        "zzz": .int(1),
        "aaa": .int(2),
        "mmm": .int(3),
    ]
    let bytes = try SwiftNativeManifestSigner.canonicalBytes(m)
    let s = String(data: bytes, encoding: .utf8) ?? ""
    let ia = s.range(of: "aaa")!.lowerBound
    let im = s.range(of: "mmm")!.lowerBound
    let iz = s.range(of: "zzz")!.lowerBound
    #expect(ia < im)
    #expect(im < iz)
}

@Test func canonicalBytes_compact_no_whitespace() throws {
    let m: [String: JSONValue] = ["a": .int(1), "b": .int(2)]
    let bytes = try SwiftNativeManifestSigner.canonicalBytes(m)
    let s = String(data: bytes, encoding: .utf8) ?? ""
    #expect(!s.contains(" "))
    #expect(!s.contains("\n"))
    #expect(!s.contains("\t"))
}

@Test func canonicalBytes_nested_objects_and_arrays() throws {
    let m: [String: JSONValue] = [
        "arr": .array([.int(1), .int(2), .object(["k": .string("v")])]),
        "obj": .object(["z": .bool(false), "a": .bool(true)]),
    ]
    let bytes = try SwiftNativeManifestSigner.canonicalBytes(m)
    let s = String(data: bytes, encoding: .utf8) ?? ""
    #expect(s.contains("\"arr\":[1,2,{\"k\":\"v\"}]"))
    // Inner object keys also sorted
    #expect(s.contains("\"obj\":{\"a\":true,\"z\":false}"))
}

@Test func canonicalBytes_escapes_non_ASCII_as_uXXXX_for_stable_wire_bytes() throws {
    let m: [String: JSONValue] = ["s": .string("caf\u{00E9}")]
    let bytes = try SwiftNativeManifestSigner.canonicalBytes(m)
    let s = String(data: bytes, encoding: .utf8) ?? ""
    #expect(s.contains("\"caf\\u00e9\""))
    #expect(!s.contains("caf\u{00E9}"))
}

@Test func canonicalBytes_escapes_control_chars() throws {
    let m: [String: JSONValue] = ["s": .string("a\u{0001}b\nc\td")]
    let bytes = try SwiftNativeManifestSigner.canonicalBytes(m)
    let s = String(data: bytes, encoding: .utf8) ?? ""
    #expect(s.contains("\\u0001"))
    #expect(s.contains("\\n"))
    #expect(s.contains("\\t"))
}

@Test func canonicalBytes_handles_null_and_bools() throws {
    let m: [String: JSONValue] = ["n": .null, "t": .bool(true), "f": .bool(false)]
    let bytes = try SwiftNativeManifestSigner.canonicalBytes(m)
    let s = String(data: bytes, encoding: .utf8) ?? ""
    #expect(s.contains("\"f\":false"))
    #expect(s.contains("\"n\":null"))
    #expect(s.contains("\"t\":true"))
}

@Test func loadOrCreateSigningKey_creates_with_0o600_perms() async throws {
    let root = try makeTempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let signer = SwiftNativeManifestSigner(dataRoot: root)
    let key = try await signer.loadOrCreateSigningKey()
    #expect(key.count == 32)
    let keyPath = root.appendingPathComponent("tools/.manifest_signing_key")
    let attrs = try FileManager.default.attributesOfItem(atPath: keyPath.path)
    let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
    #expect(perms == 0o600)
}

@Test func loadOrCreateSigningKey_loads_existing_32_bytes() async throws {
    let root = try makeTempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stored = Data(repeating: 0x42, count: 32)
    try stageSigningKey(at: root, bytes: stored)
    let signer = SwiftNativeManifestSigner(dataRoot: root)
    let key = try await signer.loadOrCreateSigningKey()
    #expect(key == stored)
}

@Test func loadOrCreateSigningKey_regenerates_if_short() async throws {
    let root = try makeTempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSigningKey(at: root, bytes: Data(repeating: 0x01, count: 8))
    let signer = SwiftNativeManifestSigner(dataRoot: root)
    let key = try await signer.loadOrCreateSigningKey()
    #expect(key.count == 32)
    #expect(key != Data(repeating: 0x01, count: 32))
}

@Test func sign_produces_signatureVersion_2() async throws {
    let root = try makeTempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSigningKey(at: root, bytes: Data(repeating: 0x42, count: 32))
    let signer = SwiftNativeManifestSigner(dataRoot: root)
    let signed = try await signer.sign(["id": .string("t")])
    if case .int(let v) = signed["signatureVersion"] ?? .null {
        #expect(v == 2)
    } else {
        Issue.record("signatureVersion missing or not int")
    }
}

@Test func sign_produces_64_hex_signature() async throws {
    let root = try makeTempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSigningKey(at: root, bytes: Data(repeating: 0x42, count: 32))
    let signer = SwiftNativeManifestSigner(dataRoot: root)
    let signed = try await signer.sign(["id": .string("t")])
    if case .string(let sig) = signed["manifestSignature"] ?? .null {
        #expect(sig.count == 64)
        #expect(sig.allSatisfy { c in c.isHexDigit && (c.isLowercase || c.isNumber) })
    } else {
        Issue.record("manifestSignature missing or not string")
    }
}

@Test func sign_then_verify_returns_no_errors() async throws {
    let root = try makeTempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSigningKey(at: root, bytes: Data(repeating: 0x42, count: 32))
    let signer = SwiftNativeManifestSigner(dataRoot: root)
    let signed = try await signer.sign(["id": .string("t"), "n": .int(7)])
    let errs = try await signer.verify(signed)
    #expect(errs.isEmpty)
}

@Test func verify_unsigned_returns_unsigned_error_text() async throws {
    let root = try makeTempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSigningKey(at: root, bytes: Data(repeating: 0x42, count: 32))
    let signer = SwiftNativeManifestSigner(dataRoot: root)
    let errs = try await signer.verify(["id": .string("t")])
    #expect(errs.count == 1)
    #expect(errs[0].contains("Manifest is unsigned"))
}

@Test func verify_wrong_version_returns_version_error_text() async throws {
    let root = try makeTempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSigningKey(at: root, bytes: Data(repeating: 0x42, count: 32))
    let signer = SwiftNativeManifestSigner(dataRoot: root)
    let m: [String: JSONValue] = [
        "id": .string("t"),
        "manifestSignature": .string(String(repeating: "0", count: 64)),
        "signatureVersion": .int(1),
    ]
    let errs = try await signer.verify(m)
    #expect(errs.count == 1)
    #expect(errs[0].contains("signatureVersion must be 2"))
}

@Test func verify_tampered_field_returns_mismatch_error_text() async throws {
    let root = try makeTempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSigningKey(at: root, bytes: Data(repeating: 0x42, count: 32))
    let signer = SwiftNativeManifestSigner(dataRoot: root)
    var signed = try await signer.sign(["id": .string("t"), "n": .int(7)])
    signed["n"] = .int(8)  // tamper
    let errs = try await signer.verify(signed)
    #expect(errs.count == 1)
    #expect(errs[0].contains("signature mismatch"))
}

@Test func isoTimestamp_uses_no_fraction_for_zero_subsecond() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let comps = DateComponents(
        year: 2026, month: 5, day: 30,
        hour: 12, minute: 0, second: 0, nanosecond: 0
    )
    let date = cal.date(from: comps)!
    let out = SwiftNativeManifestSigner.isoTimestamp(date)
    #expect(out == "2026-05-30T12:00:00+00:00",
            "got \(out); expected no-fractional ISO form")
}

@Test func isoTimestamp_uses_six_digit_microsecond_fraction() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let comps = DateComponents(
        year: 2026, month: 5, day: 30,
        hour: 12, minute: 0, second: 0,
        nanosecond: 123_456_000  // 123456 microseconds
    )
    let date = cal.date(from: comps)!
    let out = SwiftNativeManifestSigner.isoTimestamp(date)
    #expect(out == "2026-05-30T12:00:00.123456+00:00",
            "got \(out); expected six-digit microsecond fractional form")
}

@Test func signer_does_NOT_use_JSONEncoder_or_alternate_serialization() throws {
    // Scoped carve: prove SwiftNativeManifestSigner's source slice has
    // no JSONEncoder / serializedData / alternate JSON path. The source
    // file contains other JSON paths, so keep this scan actor-local.
    let testFile = URL(fileURLWithPath: #filePath)
    // Tests/TrustCenterTests/TrustCenterTests.swift -> package root
    let pkgRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let srcPath = pkgRoot.appendingPathComponent("Sources/TrustCenter/SwiftNativeManifestSigner.swift")
    let source = try String(contentsOf: srcPath, encoding: .utf8)
    let lines = source.components(separatedBy: "\n")
    var startIdx = -1
    for (i, l) in lines.enumerated() {
        if l.contains("public actor SwiftNativeManifestSigner") {
            startIdx = i
            break
        }
    }
    #expect(startIdx >= 0, "could not locate SwiftNativeManifestSigner in source")
    guard startIdx >= 0 else { return }
    // Walk forward to the matching closing brace at column 0 (line == "}").
    var endIdx = lines.count - 1
    for i in (startIdx + 1)..<lines.count {
        if lines[i] == "}" {
            endIdx = i
            break
        }
    }
    let slice = lines[startIdx...endIdx].joined(separator: "\n")
    #expect(!slice.contains("JSONEncoder"),
            "SwiftNativeManifestSigner must not use JSONEncoder (canonical bytes only)")
    #expect(!slice.contains("JSONSerialization"),
            "SwiftNativeManifestSigner must not use JSONSerialization")
    #expect(!slice.contains("serializedData"),
            "SwiftNativeManifestSigner must not use serializedData")
    #expect(!slice.contains("PropertyListEncoder"),
            "SwiftNativeManifestSigner must not use PropertyListEncoder")
}

}  // end ManifestSignerTests

// MARK: - Phase C: SwiftNative policy evaluation tests

private func makeTempPolicyRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TrustPolicy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func stageSavedPolicy(at root: URL, _ value: JSONValue) throws {
    let dir = root.appendingPathComponent("trust", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("policy.json")
    let data = try value.serializedData(pretty: false)
    try data.write(to: path, options: [.atomic])
}

@Test func updateTrust_preservesMalformedExistingPolicy() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("trust/policy.json")
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let damaged = Data("{not-json".utf8)
    try damaged.write(to: path)

    let trust = SwiftNativeTrustCenter(dataRoot: root)
    await #expect(throws: (any Error).self) {
        _ = try await trust.updateTrust(.object(["enableAutonomy": .bool(true)]))
    }
    #expect(try Data(contentsOf: path) == damaged)
}

@Test func updateTrust_preservesWrongShapedExistingAuthorityPolicy() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("trust/policy.json")
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let damaged = Data(#"{"securityPolicy":"damaged"}"#.utf8)
    try damaged.write(to: path)

    let trust = SwiftNativeTrustCenter(dataRoot: root)
    await #expect(throws: (any Error).self) {
        _ = try await trust.updateTrust(.object(["enableAutonomy": .bool(true)]))
    }
    #expect(try Data(contentsOf: path) == damaged)
}

@Test func updateTrust_rejectsWrongShapedAuthorityPatchBeforeWriting() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("trust/policy.json")
    let trust = SwiftNativeTrustCenter(dataRoot: root)

    await #expect(throws: (any Error).self) {
        _ = try await trust.updateTrust(.object(["securityPolicy": .string("damaged")]))
    }
    #expect(!FileManager.default.fileExists(atPath: path.path))
}

@Test func updateTrust_rejectsWrongTypedKnownAuthorityFieldBeforeWriting() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("trust/policy.json")
    let trust = SwiftNativeTrustCenter(dataRoot: root)

    await #expect(throws: (any Error).self) {
        _ = try await trust.updateTrust(.object([
            "securityPolicy": .object(["killSwitchEnabled": .string("false")]),
        ]))
    }
    #expect(!FileManager.default.fileExists(atPath: path.path))
}

@Test func nonthrowingTrustReadProjectsCorruptionAsClosedNotBootstrapDefaults() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("trust/policy.json")
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let damaged = Data("{not-json".utf8)
    try damaged.write(to: path)
    let trust = SwiftNativeTrustCenter(dataRoot: root)

    let policy = await trust.loadTrustPolicy()
    #expect(policy["enableAutonomy"] == .bool(false))
    guard case .object(let security)? = policy["securityPolicy"] else {
        Issue.record("missing fail-closed security policy")
        return
    }
    #expect(security["killSwitchEnabled"] == .bool(true))
    guard case .object(let execution)? = policy["missionPolicy"] else {
        Issue.record("missing fail-closed execution policy")
        return
    }
    #expect(execution["allowBackgroundMissions"] == .bool(false))
    #expect(try Data(contentsOf: path) == damaged)
}

@Test func checkedTrustRead_rejectsNonObjectPolicy() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("trust/policy.json")
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let damaged = Data("[]".utf8)
    try damaged.write(to: path)

    let trust = SwiftNativeTrustCenter(dataRoot: root)
    await #expect(throws: (any Error).self) {
        _ = try await trust.getTrust()
    }
    #expect(try Data(contentsOf: path) == damaged)
}

@Suite(.serialized)
struct SwiftNativeTrustPolicyTests {

@Test func defaultTrustPolicy_autonomyDefault_is_supervised() async throws {
    let tc = hermeticTrust()
    let p = tc.defaultTrustPolicy()
    if case .string(let s)? = p["autonomyDefault"] {
        #expect(s == "supervised")
    } else {
        Issue.record("autonomyDefault missing or not string")
    }
}

@Test func defaultTrustPolicy_filePolicy_outsideWorkspaceDefault_is_deny() async throws {
    let tc = hermeticTrust()
    let p = tc.defaultTrustPolicy()
    guard case .object(let fp)? = p["filePolicy"],
          case .string(let v)? = fp["outsideWorkspaceDefault"] else {
        Issue.record("filePolicy.outsideWorkspaceDefault missing")
        return
    }
    #expect(v == "deny")
}

@Test func loadTrustPolicy_merges_saved_with_defaults_per_key() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Saved file has a partial filePolicy (just one key). Merge must
    // preserve the other default filePolicy keys.
    try stageSavedPolicy(at: root, .object([
        "permissionLevel": .string("workspace"),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        "toolAutonomy": .object(["custom.tool": .string("auto")]),
    ]))
    let tc = SwiftNativeTrustCenter(dataRoot: root)
    let merged = await tc.loadTrustPolicy()

    // Top-level scalar from saved wins.
    if case .string(let s)? = merged["permissionLevel"] {
        #expect(s == "workspace")
    } else { Issue.record("permissionLevel") }

    // Nested filePolicy merged: saved key wins, default siblings preserved.
    guard case .object(let fp)? = merged["filePolicy"] else {
        Issue.record("filePolicy"); return
    }
    if case .string(let v)? = fp["outsideWorkspaceDefault"] {
        #expect(v == "allow")
    } else { Issue.record("outsideWorkspaceDefault") }
    #expect(fp["requireBackupBeforeWrite"] != nil,
            "default sibling must survive nested merge")
    #expect(fp["allowDestructiveActions"] != nil)

    // toolAutonomy nested merge: custom override added, default entries
    // preserved.
    guard case .object(let ta)? = merged["toolAutonomy"] else {
        Issue.record("toolAutonomy"); return
    }
    #expect(ta["custom.tool"] != nil)
    #expect(ta["mac.shell"] != nil, "default tool autonomy entry must survive merge")
    #expect(ta["search.*"] != nil)
}

@Test func loadTrustPolicy_agentBridgeTools_areEasyWorkspaceHelpers() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let tc = SwiftNativeTrustCenter(dataRoot: root)
    let merged = await tc.loadTrustPolicy()
    guard case .object(let ta)? = merged["toolAutonomy"] else {
        Issue.record("toolAutonomy"); return
    }

    #expect(ta["claude_message"] == .string("auto"))
    #expect(ta["codex_message"] == .string("auto"))
    #expect(ta["invoke_claude"] == .string("auto"))
    #expect(ta["invoke_codex"] == .string("auto"))
    #expect(ta["mac.shell"] == .string("send_approval"))
}

@Test func loadTrustPolicy_normalizes_invalid_autonomyDefault_to_supervised() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSavedPolicy(at: root, .object([
        "autonomyDefault": .string("garbage_value"),
    ]))
    let tc = SwiftNativeTrustCenter(dataRoot: root)
    let merged = await tc.loadTrustPolicy()
    if case .string(let s)? = merged["autonomyDefault"] {
        #expect(s == "supervised")
    } else {
        Issue.record("autonomyDefault missing after normalize")
    }
}

@Test func loadTrustPolicy_keeps_valid_autonomyDefault() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSavedPolicy(at: root, .object([
        "autonomyDefault": .string("workspace_autonomous"),
    ]))
    let tc = SwiftNativeTrustCenter(dataRoot: root)
    let merged = await tc.loadTrustPolicy()
    if case .string(let s)? = merged["autonomyDefault"] {
        #expect(s == "workspace_autonomous")
    } else { Issue.record("autonomyDefault") }
}

// MARK: - autonomyForTool resolution

private func bundle(default d: String, overrides: [String: JSONValue]) -> [String: JSONValue] {
    [
        "autonomyDefault": .string(d),
        "autonomyOverrides": .object(overrides),
    ]
}

@Test func autonomyForTool_exact_match_wins_over_glob() async throws {
    let tc = hermeticTrust()
    let b = bundle(default: "auto", overrides: [
        "mac.shell": .string("send_approval"),
        "mac.*": .string("auto"),
    ])
    #expect(tc.autonomyForTool("mac.shell", policy: b) == "send_approval")
}

@Test func autonomyForTool_evolution_tools_default_confirm_from_shipped_defaults() async throws {
    // U4 Wave D (gpt-5.5 review-2 NEW-BLOCKER): the self-evolution tools' `confirm`
    // posture must ship in CODE (missionsDefaultToolAutonomy), not only in the
    // git-ignored live policy.json. Simulate the load-time backfill + a saved
    // `default:"auto"` (the builder-tools auto-fire situation) with NO explicit
    // evolution key, and prove the shipped default still resolves to confirm —
    // the exact match wins over the auto default fallback.
    let tc = hermeticTrust()
    var overrides = SwiftNativeTrustCenter.workshopExecutionsDefaultToolAutonomy
    overrides["default"] = .string("auto")   // saved default = auto
    let b = bundle(default: "supervised", overrides: overrides)
    #expect(tc.autonomyForTool("evolution_propose", policy: b) == "confirm")
    #expect(tc.autonomyForTool("evolution_status", policy: b) == "confirm")
    #expect(tc.autonomyForTool("self_install", policy: b) == "confirm")
    // And the shipped default dict literally carries them.
    #expect(SwiftNativeTrustCenter.workshopExecutionsDefaultToolAutonomy["self_install"] == .string("confirm"))
}

@Test func autonomyForTool_github_mutations_stay_confirm_when_default_is_auto() async throws {
    let tc = hermeticTrust()
    var overrides = SwiftNativeTrustCenter.workshopExecutionsDefaultToolAutonomy
    overrides["default"] = .string("auto")
    let b = bundle(default: "supervised", overrides: overrides)
    #expect(tc.autonomyForTool("github_mutate", policy: b) == "confirm")
    #expect(tc.autonomyForTool("github.mutate", policy: b) == "confirm")
    #expect(SwiftNativeTrustCenter.workshopExecutionsDefaultToolAutonomy["github_mutate"] == .string("confirm"))
}

@Test func autonomyForTool_readOnlyResidentInspection_isAutoOnExistingAndFreshInstalls() async throws {
    let tc = hermeticTrust()
    var overrides = SwiftNativeTrustCenter.workshopExecutionsDefaultToolAutonomy
    overrides["default"] = .string("send_approval")
    let b = bundle(default: "supervised", overrides: overrides)
    for tool in ["agent_introspect", "daemon_introspect", "time_now"] {
        #expect(tc.autonomyForTool(tool, policy: b) == "auto")
        #expect(SwiftNativeTrustCenter.workshopExecutionsDefaultToolAutonomy[tool] == .string("auto"))
    }
}

@Test func autonomyForTool_glob_match_more_specific_wins() async throws {
    let tc = hermeticTrust()
    // fewer wildcards beats more wildcards.
    let b = bundle(default: "auto", overrides: [
        "mac.*": .string("send_approval"),
        "*": .string("blocked"),
    ])
    #expect(tc.autonomyForTool("mac.foo", policy: b) == "send_approval")
}

@Test func autonomyForTool_glob_longer_beats_shorter() async throws {
    let tc = hermeticTrust()
    // Same wildcard count → longer pattern wins.
    let b = bundle(default: "auto", overrides: [
        "mac.shell.*": .string("destructive_strong"),
        "mac.*": .string("send_approval"),
    ])
    #expect(tc.autonomyForTool("mac.shell.run", policy: b) == "destructive_strong")
}

@Test func autonomyForTool_alphabetical_tiebreak() async throws {
    let tc = hermeticTrust()
    // Same wildcard count + same length → alphabetical (smaller string wins).
    let b = bundle(default: "auto", overrides: [
        "b.*": .string("send_approval"),
        "a.*": .string("draft_auto"),
    ])
    #expect(tc.autonomyForTool("a.x", policy: b) == "draft_auto")
    #expect(tc.autonomyForTool("b.x", policy: b) == "send_approval")
}

@Test func autonomyForTool_falls_back_to_default_key() async throws {
    let tc = hermeticTrust()
    let b = bundle(default: "auto", overrides: [
        "default": .string("send_approval"),
    ])
    #expect(tc.autonomyForTool("unknown.tool", policy: b) == "send_approval")
}

@Test func autonomyForTool_falls_back_to_autonomyDefault() async throws {
    let tc = hermeticTrust()
    let b = bundle(default: "confirm", overrides: [:])
    #expect(tc.autonomyForTool("anything.at_all", policy: b) == "confirm")
}

@Test func autonomyForTool_invalid_levels_are_skipped() async throws {
    let tc = hermeticTrust()
    let b = bundle(default: "auto", overrides: [
        "exact.tool": .string("bogus_level"),
        "exact.*": .string("send_approval"),
    ])
    // Invalid exact match skipped; glob picks up.
    #expect(tc.autonomyForTool("exact.tool", policy: b) == "send_approval")
}

@Test func autonomyForTool_empty_name_returns_autonomyDefault() async throws {
    let tc = hermeticTrust()
    let b = bundle(default: "blocked", overrides: ["*": .string("auto")])
    #expect(tc.autonomyForTool("", policy: b) == "blocked")
    #expect(tc.autonomyForTool("   ", policy: b) == "blocked")
}

@Test func autonomyForTool_default_key_never_glob_matches() async throws {
    let tc = hermeticTrust()
    // "default" is a literal key, never a glob — so a tool literally named
    // "default" should NOT match it as a glob; rather, exact-match rule
    // applies. Confirm a non-"default" tool falls through to the special key.
    let b = bundle(default: "auto", overrides: [
        "default": .string("send_approval"),
    ])
    #expect(tc.autonomyForTool("foo", policy: b) == "send_approval")
}

// A1.4 (prerelease-upgrade-campaign): a bundle with NO `autonomyDefault` at
// all must fail CLOSED. The literal used to be "auto" — a partial/rewritten
// policy bundle silently bought unattended tool fire for every unlisted tool.
// The normal loader backfills "supervised" (TrustCenter+PolicyLoading), so this
// pins the defense-in-depth literal for callers that hand-build a bundle —
// notably ChatOrchestration+AutonomyGate, which only sets `autonomyDefault`
// when the policy carries a string value for it.
@Test func autonomyForTool_absent_autonomyDefault_fails_closed_to_send_approval() async throws {
    let tc = hermeticTrust()
    // No `autonomyDefault` key whatsoever.
    let noDefault: [String: JSONValue] = [
        "autonomyOverrides": .object(["mac.shell": .string("blocked")]),
    ]
    #expect(tc.autonomyForTool("some.unlisted.tool", policy: noDefault) == "send_approval")
    // Empty tool name takes the same fallback.
    #expect(tc.autonomyForTool("", policy: noDefault) == "send_approval")
    // Totally empty bundle too.
    #expect(tc.autonomyForTool("anything", policy: [:]) == "send_approval")
    // An explicit entry still wins over the fail-closed fallback.
    #expect(tc.autonomyForTool("mac.shell", policy: noDefault) == "blocked")
}

@Test func defaultTrustPolicy_includes_swarmPolicy() async throws {
    let tc = hermeticTrust()
    let p = tc.defaultTrustPolicy()
    guard case .object(let sp)? = p["swarmPolicy"] else {
        Issue.record("swarmPolicy missing"); return
    }
    if case .bool(let enabled)? = sp["enabled"] {
        #expect(enabled == true)
    } else { Issue.record("swarmPolicy.enabled missing") }
    if case .int(let n)? = sp["maxAgents"] {
        #expect(n == 20)
    } else { Issue.record("swarmPolicy.maxAgents missing") }
    #expect(sp["defaultProvider"] == nil)
    #expect(sp["allowedProviders"] == nil)
    #expect(sp["defaultModel"] == nil)
    #expect(sp["defaultReasoningEffort"] == nil)
    #expect(sp["readOnlyOnly"] == nil)
}

@Test func loadTrustPolicy_backfills_DEFAULT_TOOL_AUTONOMY_keys() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Saved file has just one custom tool autonomy entry. After load, both
    // saved entries AND Workshop executions defaults should be present.
    try stageSavedPolicy(at: root, .object([
        "toolAutonomy": .object([
            "my.custom_tool": .string("auto"),
            "gmail.send": .string("auto"),  // saved override beats default
            "browser.open_url": .string("draft_auto"), // stale saved browser policy is migrated
        ]),
    ]))
    let tc = SwiftNativeTrustCenter(dataRoot: root)
    let merged = await tc.loadTrustPolicy()
    guard case .object(let ta)? = merged["toolAutonomy"] else {
        Issue.record("toolAutonomy missing"); return
    }
    // Saved override wins.
    if case .string(let v)? = ta["gmail.send"] {
        #expect(v == "auto", "saved value must beat default")
    } else { Issue.record("gmail.send missing") }
    // Custom entry survives.
    #expect(ta["my.custom_tool"] != nil)
    #expect(ta["browser.open_url"] == .string("auto"))
    // Workshop executions.DEFAULT_TOOL_AUTONOMY keys backfilled.
    #expect(ta["local_files.search"] != nil)
    #expect(ta["searxng.search"] != nil)
    #expect(ta["browser.navigate"] == .string("auto"))
    #expect(ta["notion.search"] != nil)
    #expect(ta["calendar.find_availability"] != nil)
    #expect(ta["slack.post_message"] != nil)
    #expect(ta["gh.get_issue"] != nil)
}

@Test func fnmatch_matches_newlines_DOTALL() async throws {
    // Pin native glob semantics: * and ? match newlines so multiline tool
    // names do not bypass policy patterns.
    #expect(SwiftNativeTrustCenter.fnmatch(name: "foo\nbar", pattern: "foo*"))
    #expect(SwiftNativeTrustCenter.fnmatch(name: "a\nb", pattern: "a?b"))
    #expect(SwiftNativeTrustCenter.fnmatch(name: "x\ny\nz", pattern: "*"))
}

// MARK: - Native trust policy normalization
//
// Each test seeds a saved policy missing one backfilled field, calls
// loadTrustPolicy, and asserts the native default lands. These pin each
// backfill branch independently so a regression surfaces a targeted failure.

// ---- Full-Mac stamps ----

@Test func normalize_fullMac_developerMode_true_preserved() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSavedPolicy(at: root, .object([
        "permissionLevel": .string("full_mac_os"),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        "developerMode": .bool(true),
    ]))
    let tc = SwiftNativeTrustCenter(dataRoot: root)
    let merged = await tc.loadTrustPolicy()
    if case .bool(let dm)? = merged["developerMode"] {
        #expect(dm == true, "Full Mac must preserve explicit operator-enabled Developer Mode")
    } else {
        Issue.record("developerMode missing or wrong type")
    }
    if case .object(let fp)? = merged["filePolicy"] {
        #expect(fp["allowDestructiveActions"] == .bool(true))
    } else {
        Issue.record("filePolicy missing or wrong type")
    }
}

@Test func normalize_fullMac_developerMode_missing_backfilled_to_false() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSavedPolicy(at: root, .object([
        "permissionLevel": .string("full_mac_os"),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
    ]))
    let tc = SwiftNativeTrustCenter(dataRoot: root)
    let merged = await tc.loadTrustPolicy()
    if case .bool(let dm)? = merged["developerMode"] {
        #expect(dm == false)
    } else {
        Issue.record("Full Mac must backfill developerMode → false when missing")
    }
}

@Test func normalize_fullMac_developerMode_false_clears_destructive_mac_flags() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSavedPolicy(at: root, .object([
        "permissionLevel": .string("full_mac_os"),
        "filePolicy": .object([
            "outsideWorkspaceDefault": .string("allow"),
            "allowDestructiveActions": .bool(true),
        ]),
        "developerMode": .bool(false),
        "macControlPolicy": .object([
            "enabled": .bool(true),
            "shell_allowed": .bool(true),
            "system_control_allowed": .bool(true),
            "riskGatePolicy": .object(["critical": .string("auto")]),
        ]),
    ]))
    let tc = SwiftNativeTrustCenter(dataRoot: root)
    let merged = await tc.loadTrustPolicy()
    guard case .object(let fp)? = merged["filePolicy"],
          case .object(let mac)? = merged["macControlPolicy"] else {
        Issue.record("expected normalized filePolicy/macControlPolicy")
        return
    }
    #expect(fp["allowDestructiveActions"] == .bool(false))
    #expect(mac["shell_allowed"] == .bool(false))
    #expect(mac["system_control_allowed"] == .bool(false))
    if case .object(let risk)? = mac["riskGatePolicy"] {
        #expect(risk["critical"] == .string("deny"))
    } else {
        Issue.record("expected riskGatePolicy")
    }
}

@Test func normalize_fullMac_expiresAt_never_syncs_neverExpires() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSavedPolicy(at: root, .object([
        "permissionLevel": .string("full_mac_os"),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        "fullMacExpiresAt": .string(" NEVER "),  // trimmed + lowercased = "never"
    ]))
    let tc = SwiftNativeTrustCenter(dataRoot: root)
    let merged = await tc.loadTrustPolicy()
    if case .bool(let ne)? = merged["fullMacNeverExpires"] {
        #expect(ne == true)
    } else {
        Issue.record("fullMacNeverExpires must flip true when expiresAt == 'never'")
    }
    // And expiresAt is forced to the canonical literal "never".
    if case .string(let exp)? = merged["fullMacExpiresAt"] {
        #expect(exp == "never")
    } else {
        Issue.record("fullMacExpiresAt must be canonicalized to 'never'")
    }
}

@Test func normalize_fullMac_neverExpires_true_forces_expiresAt_never() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSavedPolicy(at: root, .object([
        "permissionLevel": .string("full_mac_os"),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        "fullMacNeverExpires": .bool(true),
        "fullMacExpiresAt": .string("2027-01-01T00:00:00+00:00"),
    ]))
    let tc = SwiftNativeTrustCenter(dataRoot: root)
    let merged = await tc.loadTrustPolicy()
    if case .string(let exp)? = merged["fullMacExpiresAt"] {
        #expect(exp == "never")
    } else {
        Issue.record("fullMacExpiresAt must be set to 'never' when neverExpires==true")
    }
}

@Test func normalize_fullMac_confirmedAt_backfilled_when_missing() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSavedPolicy(at: root, .object([
        "permissionLevel": .string("full_mac_os"),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
    ]))
    let fixed = Date(timeIntervalSince1970: 1_700_000_000)
    let tc = SwiftNativeTrustCenter(dataRoot: root, clock: { fixed })
    let merged = await tc.loadTrustPolicy()
    if case .string(let cat)? = merged["fullMacConfirmedAt"] {
        #expect(cat.hasPrefix("2023-11-14T"),
                "fullMacConfirmedAt must backfill from clock; got \(cat)")
    } else {
        Issue.record("fullMacConfirmedAt must be backfilled")
    }
}

@Test func normalize_non_fullMac_clears_neverExpires_and_drops_expiresAt() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSavedPolicy(at: root, .object([
        "permissionLevel": .string("balanced"),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("deny")]),
        "fullMacNeverExpires": .bool(true),
        "fullMacExpiresAt": .string("never"),
    ]))
    let tc = SwiftNativeTrustCenter(dataRoot: root)
    let merged = await tc.loadTrustPolicy()
    if case .bool(let ne)? = merged["fullMacNeverExpires"] {
        #expect(ne == false, "non-Full-Mac must force fullMacNeverExpires → false")
    } else {
        Issue.record("fullMacNeverExpires missing")
    }
    #expect(merged["fullMacExpiresAt"] == nil,
            "non-Full-Mac must drop fullMacExpiresAt entirely")
}

// ---- providerPolicy fallback chain ----

@Test func normalize_providerPolicy_inserts_anthropic_oauth_direct_when_missing() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Save a policy whose chat chain lacks anthropic_oauth_direct and has
    // openai_oauth_direct at index 0 → insertion goes at index 1.
    try stageSavedPolicy(at: root, .object([
        "providerPolicy": .object([
            "fallback_chain": .object([
                "chat": .array([
                    .string("openai_oauth_direct"),
                    .string("codex"),
                    .string("anthropic"),
                    .string("local"),
                ]),
            ]),
        ]),
    ]))
    let tc = SwiftNativeTrustCenter(dataRoot: root)
    let merged = await tc.loadTrustPolicy()
    guard case .object(let pp)? = merged["providerPolicy"],
          case .object(let fb)? = pp["fallback_chain"],
          case .array(let chat)? = fb["chat"] else {
        Issue.record("providerPolicy/fallback_chain/chat shape lost")
        return
    }
    let names: [String] = chat.compactMap {
        if case .string(let s) = $0 { return s }
        return nil
    }
    #expect(names.contains("anthropic_oauth_direct"),
            "anthropic_oauth_direct must be inserted")
    // openai_oauth_direct is at index 0, so insertion goes to index 1, but the
    // existing 'anthropic' at index 2 pulls the min down → insertAt = min(2, 1) = 1.
    if let idx = names.firstIndex(of: "anthropic_oauth_direct") {
        #expect(idx == 1, "anthropic_oauth_direct must land at index 1; got \(idx)")
    }
}

@Test func normalize_providerPolicy_active_per_surface_default_backfill() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Saved policy has only one surface active; defaults must fill the rest.
    try stageSavedPolicy(at: root, .object([
        "providerPolicy": .object([
            "active_per_surface": .object([
                "chat": .string("local"),
            ]),
        ]),
    ]))
    let tc = SwiftNativeTrustCenter(dataRoot: root)
    let merged = await tc.loadTrustPolicy()
    guard case .object(let pp)? = merged["providerPolicy"],
          case .object(let ap)? = pp["active_per_surface"] else {
        Issue.record("providerPolicy/active_per_surface shape lost")
        return
    }
    // Saved value wins.
    if case .string(let v)? = ap["chat"] { #expect(v == "local") }
    else { Issue.record("chat override lost") }
    // Default surfaces backfilled.
    #expect(ap["ios"] != nil, "ios active must backfill from defaults")
    #expect(ap["telegram"] != nil)
    #expect(ap["missions"] != nil)
    #expect(ap["training"] != nil)
    #expect(ap["dream"] != nil)
    #expect(ap["autonomy"] != nil)
}

@Test func normalize_providerPolicy_inserts_at_0_when_no_openai_oauth() async throws {
    // Direct unit-style call on the static normalize entry-point: no
    // openai_oauth_direct in the chain → insert at index 0.
    let policy: [String: JSONValue] = [
        "providerPolicy": .object([
            "fallback_chain": .object([
                "chat": .array([.string("codex"), .string("local")]),
            ]),
        ]),
    ]
    let defaultPP: [String: JSONValue] = [
        "active_per_surface": .object(["chat": .string("openai_oauth_direct")]),
        "fallback_chain": .object([
            "chat": .array([.string("openai_oauth_direct"), .string("codex")]),
        ]),
    ]
    let out = SwiftNativeTrustCenter.normalizeTrustPolicy(
        policy, defaultProviderPolicy: defaultPP, nowISO: ""
    )
    guard case .object(let pp)? = out["providerPolicy"],
          case .object(let fb)? = pp["fallback_chain"],
          case .array(let chat)? = fb["chat"] else {
        Issue.record("chain lost"); return
    }
    let names: [String] = chat.compactMap {
        if case .string(let s) = $0 { return s }
        return nil
    }
    #expect(names.first == "anthropic_oauth_direct",
            "must insert at index 0 when no openai_oauth_direct present")
}

// ---- personalityPolicy completion_guard_max_repairs ----

@Test func normalize_completion_guard_floor_when_enabled() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSavedPolicy(at: root, .object([
        "personalityPolicy": .object([
            "completion_guard_enabled": .bool(true),
            "completion_guard_max_repairs": .int(1),
        ]),
    ]))
    let tc = SwiftNativeTrustCenter(dataRoot: root)
    let merged = await tc.loadTrustPolicy()
    guard case .object(let pp)? = merged["personalityPolicy"] else {
        Issue.record("personalityPolicy missing"); return
    }
    if case .int(let n)? = pp["completion_guard_max_repairs"] {
        #expect(n == 2, "enabled guard floors max_repairs to 2; got \(n)")
    } else {
        Issue.record("completion_guard_max_repairs missing or wrong type")
    }
}

@Test func normalize_completion_guard_disabled_keeps_below_floor() async throws {
    // Direct call to bypass loadTrustPolicy default-merge (defaults set
    // enabled=true, which would re-enable the floor).
    let policy: [String: JSONValue] = [
        "personalityPolicy": .object([
            "completion_guard_enabled": .bool(false),
            "completion_guard_max_repairs": .int(0),
        ]),
    ]
    let out = SwiftNativeTrustCenter.normalizeTrustPolicy(policy)
    guard case .object(let pp)? = out["personalityPolicy"] else {
        Issue.record("personalityPolicy missing"); return
    }
    if case .int(let n)? = pp["completion_guard_max_repairs"] {
        #expect(n == 0, "disabled guard keeps explicit 0; got \(n)")
    } else {
        Issue.record("completion_guard_max_repairs missing")
    }
}

@Test func normalize_completion_guard_clamps_above_2() async throws {
    let policy: [String: JSONValue] = [
        "personalityPolicy": .object([
            "completion_guard_max_repairs": .int(99),
        ]),
    ]
    let out = SwiftNativeTrustCenter.normalizeTrustPolicy(policy)
    guard case .object(let pp)? = out["personalityPolicy"] else {
        Issue.record("personalityPolicy missing"); return
    }
    if case .int(let n)? = pp["completion_guard_max_repairs"] {
        #expect(n == 2, "max_repairs must clamp to 2; got \(n)")
    } else {
        Issue.record("completion_guard_max_repairs missing")
    }
}

@Test func normalize_completion_guard_nonint_coerces_to_2() async throws {
    let policy: [String: JSONValue] = [
        "personalityPolicy": .object([
            "completion_guard_max_repairs": .string("not_a_number"),
        ]),
    ]
    let out = SwiftNativeTrustCenter.normalizeTrustPolicy(policy)
    guard case .object(let pp)? = out["personalityPolicy"] else {
        Issue.record("personalityPolicy missing"); return
    }
    if case .int(let n)? = pp["completion_guard_max_repairs"] {
        #expect(n == 2, "non-int value defaults to 2; got \(n)")
    } else {
        Issue.record("completion_guard_max_repairs missing")
    }
}

// ---- filePolicy backfill (Wave-3 carryover; verify still works) ----

@Test func normalize_filePolicy_outsideWorkspaceDefault_still_backfilled() async throws {
    let policy: [String: JSONValue] = [
        "filePolicy": .object([:]),  // empty; default sibling has nothing.
    ]
    let out = SwiftNativeTrustCenter.normalizeTrustPolicy(policy)
    guard case .object(let fp)? = out["filePolicy"] else {
        Issue.record("filePolicy missing"); return
    }
    if case .string(let v)? = fp["outsideWorkspaceDefault"] {
        #expect(v == "deny")
    } else {
        Issue.record("outsideWorkspaceDefault not backfilled")
    }
}

// ---- idempotence ----

@Test func normalize_is_idempotent() async throws {
    let root = try makeTempPolicyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSavedPolicy(at: root, .object([
        "permissionLevel": .string("full_mac_os"),
        "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
        "fullMacNeverExpires": .bool(true),
        "fullMacExpiresAt": .string("never"),
        "developerMode": .bool(false),
        "fullMacConfirmedAt": .string("2026-01-01T00:00:00+00:00"),
    ]))
    let fixed = Date(timeIntervalSince1970: 1_700_000_000)
    let tc = SwiftNativeTrustCenter(dataRoot: root, clock: { fixed })
    let once = await tc.loadTrustPolicy()
    // Re-apply normalize directly to the once-loaded result. With identical
    // clock + defaults, the second pass must be a no-op.
    let defaults = tc.defaultTrustPolicy()
    let defaultPP: [String: JSONValue] = {
        if case .object(let p)? = defaults["providerPolicy"] { return p }
        return [:]
    }()
    let nowISO = SwiftNativeTrustCenter.isoTimestamp(fixed)
    let twice = SwiftNativeTrustCenter.normalizeTrustPolicy(
        once, defaultProviderPolicy: defaultPP, nowISO: nowISO
    )
    // Compare JSON bytes for byte-equivalence (most robust comparison given
    // dict ordering doesn't matter for the wire encoder).
    let onceBytes = try JSONValue.object(once).serializedData(pretty: false)
    let twiceBytes = try JSONValue.object(twice).serializedData(pretty: false)
    #expect(onceBytes == twiceBytes, "normalize must be idempotent")
}

}  // end SwiftNativeTrustPolicyTests

// MARK: - App-adapter JSON-bytes round-trip
//
// Pins SwiftNativeTrustCenter.loadTrustPolicyJSON() to the daemon's
// /v1/trust wire shape so NativeClient can decode the bytes into its
// app-side TrustPolicy struct without a cross-module type translation.

/// Mirror of the headline keys on Sources/NativeAgentApp Models.swift
/// `TrustPolicy`. The app struct uses `decodeIfPresent` everywhere, so a
/// subset-Codable suffices to prove decode-compatibility on the wire bytes.
private struct AppTrustPolicyMirror: Codable {
    var permissionLevel: String?
    var autonomyDefault: String?
    var updatedAt: String?
    var appDataRoot: String?
}

@Suite(.serialized)
struct TrustPolicyAppAdapterTests {

@Test func trustPolicy_json_adapter_rejects_corrupt_authority_bytes() async throws {
    let root = try makeTempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("trust/policy.json")
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let damaged = Data("{not-json".utf8)
    try damaged.write(to: path)
    let trust = SwiftNativeTrustCenter(dataRoot: root)

    await #expect(throws: (any Error).self) {
        _ = try await trust.loadTrustPolicyJSON()
    }
    #expect(try Data(contentsOf: path) == damaged)
}

@Test func trustPolicy_json_bytes_round_trip_into_app_mirror() async throws {
    let root = try makeTempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixed = Date(timeIntervalSince1970: 1_700_000_000)
    let sn = SwiftNativeTrustCenter(dataRoot: root, clock: { fixed })

    let data = try await sn.loadTrustPolicyJSON()
    #expect(!data.isEmpty)

    // 1) Wire bytes must be valid JSON and round-trip through JSONValue.parse.
    let parsed = try JSONValue.parse(data)
    guard case .object(let obj) = parsed else {
        Issue.record("expected top-level object, got \(parsed)")
        return
    }
    // 2) Headline scalars present + normalized.
    #expect(obj["permissionLevel"] == .string("balanced"))
    #expect(obj["autonomyDefault"] == .string("supervised"))
    #expect(obj["appDataRoot"] == .string(root.path))
    if case .string(let ts)? = obj["updatedAt"] {
        #expect(ts.hasPrefix("2023-11-14T"))
    } else {
        Issue.record("expected updatedAt string")
    }
    // 3) Nested wire blocks present at the top level (NOT nested under "extras").
    #expect(obj["missionPolicy"] != nil)
    #expect(obj["filePolicy"] != nil)
    #expect(obj["multimodalPolicy"] != nil)
    #expect(obj["macControlPolicy"] != nil)
    #expect(obj["toolAutonomy"] != nil)

    // 4) Decode into the app-side TrustPolicy mirror via the SAME path
    //    NativeClient uses against an HTTP /v1/trust response.
    let mirror = try JSONDecoder().decode(AppTrustPolicyMirror.self, from: data)
    #expect(mirror.permissionLevel == "balanced")
    #expect(mirror.autonomyDefault == "supervised")
    #expect(mirror.appDataRoot == root.path)
    #expect(mirror.updatedAt?.hasPrefix("2023-11-14T") == true)

    // 5) filePolicy.outsideWorkspaceDefault backfill survives encode.
    if case .object(let fp)? = obj["filePolicy"] {
        #expect(fp["outsideWorkspaceDefault"] == .string("deny"))
    } else {
        Issue.record("expected filePolicy object")
    }
}

@Test func trustPolicy_json_bytes_match_jsonvalue_serializer() async throws {
    // Byte-equivalence pin: the adapter must produce bytes byte-identical to
    // JSONValue.object(dict).serializedData(pretty: false). That's the same
    // canonical compact-JSON encoder the wire path uses end-to-end.
    let root = try makeTempDataRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sn = SwiftNativeTrustCenter(dataRoot: root, clock: { Date(timeIntervalSince1970: 1_700_000_000) })

    let dict = await sn.loadTrustPolicy()
    let expected = try JSONValue.object(dict).serializedData(pretty: false)
    let actual = try await sn.loadTrustPolicyJSON()
    #expect(actual == expected)
}

}  // end TrustPolicyAppAdapterTests
