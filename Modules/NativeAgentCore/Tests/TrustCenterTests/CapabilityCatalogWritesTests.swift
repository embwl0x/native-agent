import Testing
import Foundation
@testable import TrustCenter
import NativeAgentCore
import PersistenceCore

// MARK: - Wave 31 W15: catalog write-side port parity tests
//
// Covers the four routes ported in CapabilityCatalog.swift:
//   - swiftCatalogSlugify parity with Python slugify()
//   - SwiftNativeCapabilityPackSigner.signature cross-runtime HMAC golden vector
//     (must equal capability_pack_signature() byte-for-byte)
//   - sign → validate round-trip ("valid"); tamper → "Signature mismatch."
//   - validate missing-field / items-shape / untrusted-identity branches
//   - SwiftNativeCatalogWrites.upsertCatalogSource shape + status switch
//   - checkCapabilityUpdates "checked" shape + lastCheckedAt stamp
//   - listCapabilityPackInstalls stable-reverse sort

private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("catalogWrites-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Write a fixed signing key so HMAC golden vectors are deterministic.
private func writeSigningKey(_ root: URL, _ key: String) throws {
    let dir = root.appendingPathComponent("catalog", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent(".pack_signing_key")
    try Data(key.utf8).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
}

private func jstr(_ o: [String: JSONValue], _ k: String) -> String {
    if case .string(let s)? = o[k] { return s }
    return ""
}

private func jbool(_ o: [String: JSONValue], _ k: String) -> Bool {
    if case .bool(let b)? = o[k] { return b }
    return false
}

private func jarr(_ o: [String: JSONValue], _ k: String) -> [JSONValue] {
    if case .array(let a)? = o[k] { return a }
    return []
}

// Wave 33 W01: persistence mock that delegates everything to a real core but
// makes appendJSONL always fail. In SwiftNativeCatalogWrites.upsertCatalogSource
// the ONLY appendJSONL call is the audit-trace emission, so the sources
// writeJSON still succeeds while the trace append (and the whole call) fails —
// exactly the disk-full/permission scenario record_trace surfaces in Python.
private struct TraceAppendFailingPersistence: PersistenceCoreProtocol {
    let delegate: SwiftNativePersistenceCore
    struct TraceAppendError: Error {}

    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        await delegate.readJSON(path, defaultValue: defaultValue)
    }
    func writeJSON(_ value: JSONValue, to path: URL) async throws {
        try await delegate.writeJSON(value, to: path)
    }
    func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        throw TraceAppendError()
    }
    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        try await delegate.tailJSONL(path, limit: limit, maxBytes: maxBytes)
    }
    func readJSONL(_ path: URL) async throws -> [JSONValue] {
        try await delegate.readJSONL(path)
    }
}

private actor WriteCountingPersistence: PersistenceCoreProtocol {
    let delegate = SwiftNativePersistenceCore()
    private var jsonWriteCount = 0

    func readJSON(_ path: URL, defaultValue: JSONValue) async -> JSONValue {
        await delegate.readJSON(path, defaultValue: defaultValue)
    }

    func writeJSON(_ value: JSONValue, to path: URL) async throws {
        jsonWriteCount += 1
        try await delegate.writeJSON(value, to: path)
    }

    func appendJSONL(_ record: JSONValue, to path: URL) async throws {
        try await delegate.appendJSONL(record, to: path)
    }

    func tailJSONL(_ path: URL, limit: Int, maxBytes: Int?) async throws -> [JSONValue] {
        try await delegate.tailJSONL(path, limit: limit, maxBytes: maxBytes)
    }

    func readJSONL(_ path: URL) async throws -> [JSONValue] {
        try await delegate.readJSONL(path)
    }

    func writes() -> Int { jsonWriteCount }
}

// MARK: - slugify parity

@Suite(.serialized)
struct CatalogSlugifyParityTests {
    @Test func test_matchesPythonGoldenVectors() {
        // Golden pairs computed from Python slugify().
        let cases: [(String, String)] = [
            ("My Source!!", "my-source"),
            ("  Trim--Me  ", "trim-me"),
            ("UPPER_case 123", "upper-case-123"),
            ("https://example.com/foo", "https-example-com-foo"),
            ("café münchen", "caf-m-nchen"),
        ]
        for (input, expected) in cases {
            #expect(swiftCatalogSlugify(input) == expected, "slugify(\(input))")
        }
    }

    @Test func test_emptyInputFallsBackToUUID() {
        // All-separator input strips to "" → Python returns str(uuid4()).
        let out = swiftCatalogSlugify("!!!---   ")
        #expect(!out.isEmpty)
        #expect(out.contains("-")) // uuid form
        #expect(out.count == 36) // lowercased uuid string
    }

    @Test func test_capsAt80Chars() {
        let long = String(repeating: "a", count: 200)
        #expect(swiftCatalogSlugify(long).count == 80)
    }
}

// MARK: - HMAC signature cross-runtime golden vector

@Suite(.serialized)
struct CapabilityPackSignatureGoldenTests {
    @Test func test_signatureMatchesPythonGoldenVector() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = String(repeating: "deadbeef", count: 8) // 64 hex chars
        try writeSigningKey(root, key)

        let signer = SwiftNativeCapabilityPackSigner(
            dataRoot: root, persistence: SwiftNativePersistenceCore()
        )
        let pack: [String: JSONValue] = [
            "id": .string("demo-pack"),
            "name": .string("Demo Pack"),
            "version": .string("1.0.0"),
            "items": .object(["catalog": .array([.object(["id": .string("x"), "name": .string("X")])])]),
            "signingIdentity": .string("local-trusted"),
            "signedAt": .string("2026-06-01T00:00:00+00:00"),
        ]
        let sig = try await signer.signature(for: pack)
        // Golden value computed from capability_pack_signature() in Python with
        // the same key + pack (separators=(",",":") sort_keys=True).
        #expect(sig == "c30d09e9d4573f00f11b1351800f6ffc89caf23f968936ca762f587a7a0f5765")
    }

    @Test func test_secondGoldenVectorWithNestedItems() async throws {
        // Independent cross-impl vector: a different key + a pack with a nested
        // items.skills list. Golden computed from Python capability_pack_signature.
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = String(repeating: "abad1dea", count: 8)
        try writeSigningKey(root, key)
        let signer = SwiftNativeCapabilityPackSigner(
            dataRoot: root, persistence: SwiftNativePersistenceCore()
        )
        let pack: [String: JSONValue] = [
            "id": .string("xpack"),
            "name": .string("X Pack"),
            "version": .string("2.1.0"),
            "items": .object(["skills": .array([.object(["id": .string("s1"), "name": .string("Skill 1")])])]),
            "signingIdentity": .string("local-trusted"),
            "signedAt": .string("2026-06-01T12:34:56+00:00"),
        ]
        let sig = try await signer.signature(for: pack)
        #expect(sig == "ad0de732c67fda2f3091ecf53a51ad06de29e5db40fdf53a87c9e3e8133a58b9")
    }

    @Test func test_signatureIgnoresExistingSignatureField() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSigningKey(root, String(repeating: "deadbeef", count: 8))
        let signer = SwiftNativeCapabilityPackSigner(
            dataRoot: root, persistence: SwiftNativePersistenceCore()
        )
        var pack: [String: JSONValue] = [
            "id": .string("demo-pack"),
            "name": .string("Demo Pack"),
            "version": .string("1.0.0"),
            "items": .object(["catalog": .array([.object(["id": .string("x"), "name": .string("X")])])]),
            "signingIdentity": .string("local-trusted"),
            "signedAt": .string("2026-06-01T00:00:00+00:00"),
        ]
        let bare = try await signer.signature(for: pack)
        pack["signature"] = .string("garbage-that-must-be-stripped")
        let withSig = try await signer.signature(for: pack)
        #expect(bare == withSig) // signature field excluded from payload
    }
}

// MARK: - validate parity

@Suite(.serialized)
struct CapabilityPackValidateTests {
    private func makeSigner() throws -> (URL, SwiftNativeCapabilityPackSigner) {
        let root = try tempRoot()
        try writeSigningKey(root, String(repeating: "feedface", count: 8))
        return (root, SwiftNativeCapabilityPackSigner(
            dataRoot: root, persistence: SwiftNativePersistenceCore()
        ))
    }

    @Test func test_signThenValidateRoundTripsValid() async throws {
        let (root, signer) = try makeSigner()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack: [String: JSONValue] = [
            "id": .string("demo-pack"),
            "name": .string("Demo Pack"),
            "version": .string("1.0.0"),
            "items": .object(["catalog": .array([])]),
        ]
        let signed = try await signer.sign(pack)
        let report = try await signer.validate(signed)
        #expect(jstr(report, "status") == "valid")
        #expect(jbool(report, "valid") == true)
        #expect(jarr(report, "errors").isEmpty)
        #expect(jstr(report, "trustTier") == "local")
        #expect(jstr(report, "signingIdentity") == "local-trusted")
    }

    @Test func test_tamperedSignatureFlagsMismatch() async throws {
        let (root, signer) = try makeSigner()
        defer { try? FileManager.default.removeItem(at: root) }
        var signed = try await signer.sign([
            "id": .string("p"), "name": .string("P"), "version": .string("1"),
            "items": .object([:]),
        ])
        signed["signature"] = .string("0000")
        let report = try await signer.validate(signed)
        #expect(jbool(report, "valid") == false)
        let errs = jarr(report, "errors").compactMap { if case .string(let s) = $0 { return s }; return nil }
        #expect(errs.contains("Signature mismatch."))
    }

    @Test func test_missingKeyCannotReturnEphemeralSecretWhenPersistenceFails() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A file where the catalog directory must be makes durable key creation
        // impossible. The signer must throw, not return a random in-memory key.
        try Data("directory collision".utf8)
            .write(to: root.appendingPathComponent("catalog"))
        let signer = SwiftNativeCapabilityPackSigner(
            dataRoot: root,
            persistence: SwiftNativePersistenceCore()
        )

        await #expect(throws: (any Error).self) {
            _ = try await signer.signature(for: ["id": .string("x")])
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("catalog/.pack_signing_key").path
        ))
    }

    @Test func test_missingRequiredFields() async throws {
        let (root, signer) = try makeSigner()
        defer { try? FileManager.default.removeItem(at: root) }
        // Missing version + items + signature.
        let report = try await signer.validate(["id": .string("p"), "name": .string("P")])
        #expect(jbool(report, "valid") == false)
        let errs = jarr(report, "errors").compactMap { if case .string(let s) = $0 { return s }; return nil }
        #expect(errs.contains { $0.hasPrefix("Missing required field(s): ") })
        // Order follows the required[] list: version, items, signature.
        #expect(errs.contains("Missing required field(s): version, items, signature"))
    }

    @Test func test_itemsMustBeObjectAndChildrenLists() async throws {
        let (root, signer) = try makeSigner()
        defer { try? FileManager.default.removeItem(at: root) }
        // items present but a string → "items must be an object."
        let r1 = try await signer.validate([
            "id": .string("p"), "name": .string("P"), "version": .string("1"),
            "items": .string("nope"), "signature": .string("x"),
        ])
        let e1 = jarr(r1, "errors").compactMap { if case .string(let s) = $0 { return s }; return nil }
        #expect(e1.contains("items must be an object."))

        // items.skills present but a string → "items.skills must be a list."
        let r2 = try await signer.validate([
            "id": .string("p"), "name": .string("P"), "version": .string("1"),
            "items": .object(["skills": .string("bad")]), "signature": .string("x"),
        ])
        let e2 = jarr(r2, "errors").compactMap { if case .string(let s) = $0 { return s }; return nil }
        #expect(e2.contains("items.skills must be a list."))
    }

    @Test func test_nonStringFieldsStringifyAndProvenanceFallback() async throws {
        let (root, signer) = try makeSigner()
        defer { try? FileManager.default.removeItem(at: root) }
        // version is an int (123), provenance is an empty object (falsy in Python).
        var pack: [String: JSONValue] = [
            "id": .string("p"),
            "name": .string("P"),
            "version": .int(123),
            "items": .object([:]),
            "provenance": .object([:]),
        ]
        pack["signature"] = .string(try await signer.signature(for: pack))
        let report = try await signer.validate(pack)
        // str(123) -> "123").
        #expect(jstr(report, "version") == "123")
        // empty-object provenance falls back to {"source":"local"}.
        if case .object(let prov)? = report["provenance"] {
            #expect(jstr(prov, "source") == "local")
        } else {
            #expect(Bool(false))
        }
    }

    @Test func test_unwrapPackBodyHandlesEnvelopeAndBare() async throws {
        let inner: [String: JSONValue] = ["id": .string("inner")]
        let enveloped: [String: JSONValue] = ["pack": .object(inner)]
        #expect(jstr(SwiftNativeCapabilityPackSigner.unwrapPackBody(enveloped), "id") == "inner")
        // Bare pack (no "pack" key) passes through unchanged.
        let bare: [String: JSONValue] = ["id": .string("bare")]
        #expect(jstr(SwiftNativeCapabilityPackSigner.unwrapPackBody(bare), "id") == "bare")
    }

    @Test func test_untrustedSigningIdentity() async throws {
        let (root, signer) = try makeSigner()
        defer { try? FileManager.default.removeItem(at: root) }
        var pack: [String: JSONValue] = [
            "id": .string("p"), "name": .string("P"), "version": .string("1"),
            "items": .object([:]),
            "signingIdentity": .string("evil-corp"),
        ]
        pack["signature"] = .string(try await signer.signature(for: pack))
        let report = try await signer.validate(pack)
        #expect(jstr(report, "trustTier") == "unknown")
        #expect(jbool(report, "valid") == false)
        let errs = jarr(report, "errors").compactMap { if case .string(let s) = $0 { return s }; return nil }
        #expect(errs.contains("Signing identity is not in trusted roots."))
    }
}

// MARK: - SwiftNativeCatalogWrites: upsert / updates-check / installs

@Suite(.serialized)
struct CatalogWritesTests {
    @Test func test_sourceMutationsCommitExactlyOnce() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let upsertPersistence = WriteCountingPersistence()
        let upsert = SwiftNativeCatalogWrites(
            dataRoot: root,
            persistence: upsertPersistence
        )
        _ = try await upsert.upsertCatalogSource([
            "id": .string("one-write"),
            "name": .string("One Write"),
            "url": .string("https://example.test/catalog"),
        ])
        #expect(await upsertPersistence.writes() == 1)

        let checkPersistence = WriteCountingPersistence()
        let check = SwiftNativeCatalogWrites(
            dataRoot: root,
            persistence: checkPersistence
        )
        _ = try await check.checkCapabilityUpdates()
        #expect(await checkPersistence.writes() == 1)
    }

    @Test func test_corruptSourceStoreBlocksMutationAndPreservesBytes() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("catalog/sources/sources.json")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let corrupt = Data("[null]".utf8)
        try corrupt.write(to: path)
        let writes = SwiftNativeCatalogWrites(
            dataRoot: root,
            persistence: SwiftNativePersistenceCore()
        )

        await #expect(throws: (any Error).self) {
            _ = try await writes.upsertCatalogSource([
                "id": .string("must-not-land"),
                "name": .string("Must Not Land"),
            ])
        }
        #expect(try Data(contentsOf: path) == corrupt)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("traces/events.jsonl").path
        ))
    }

    @Test func test_upsertCatalogSourceShapeAndStatus() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = SwiftNativeCatalogWrites(
            dataRoot: root, persistence: SwiftNativePersistenceCore()
        )
        // url present → status "ready"; id slugified from name.
        let rec = try await writes.upsertCatalogSource([
            "name": .string("My Remote!!"),
            "url": .string("https://x.example/catalog"),
            "kind": .string("remote"),
        ])
        #expect(jstr(rec, "id") == "my-remote")
        #expect(jstr(rec, "name") == "My Remote!!")
        #expect(jstr(rec, "kind") == "remote")
        #expect(jstr(rec, "status") == "ready")
        #expect(jstr(rec, "trustedRootId") == "local-trusted")
        #expect(rec["lastCheckedAt"] == .null)

        // empty url → status "needs_setup"; default kind "local".
        let rec2 = try await writes.upsertCatalogSource(["name": .string("No URL")])
        #expect(jstr(rec2, "status") == "needs_setup")
        #expect(jstr(rec2, "kind") == "local")
    }

    // Wave 32 W02: closes the parity gap that reverted W31-W15. The daemon's
    // upsert_catalog_source emits record_trace("catalog.source.save", name,
    // {"sourceId", "status"}) -> traces/events.jsonl;
    // the Swift port must emit the same envelope or the /v1/activity + /v1/traces
    // audit feeds diverge when the write flows through Swift.
    @Test func test_upsertEmitsCatalogSourceSaveTrace() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = SwiftNativeCatalogWrites(
            dataRoot: root, persistence: SwiftNativePersistenceCore()
        )
        // url present → record status "ready"; that string also becomes the
        // trace envelope status (Python: str(_payload.get("status") or "ok")).
        _ = try await writes.upsertCatalogSource([
            "name": .string("My Remote!!"),
            "url": .string("https://x.example/catalog"),
            "kind": .string("remote"),
        ])

        // Read traces/events.jsonl back: exactly one catalog.source.save event.
        let tracesURL = root
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        let text = (try? String(contentsOf: tracesURL, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        #expect(lines.count == 1)
        guard let lineData = lines.first?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
        else { #expect(Bool(false)); return }
        // Envelope shape parity with record_trace.
        #expect(obj["kind"] as? String == "catalog.source.save")
        #expect(obj["title"] as? String == "My Remote!!")
        // status pulled from payload (record's "ready"), NOT defaulted to "ok".
        #expect(obj["status"] as? String == "ready")
        #expect((obj["id"] as? String)?.isEmpty == false)
        // id must be lowercase to match Python's str(uuid.uuid4()); Darwin's
        // UUID().uuidString is UPPERCASE, so a missing .lowercased() drifts the
        // trace-envelope case from the daemon's (W32 W02 gpt-5.5 review catch).
        let idStr = obj["id"] as? String ?? ""
        #expect(idStr == idStr.lowercased())
        #expect((obj["createdAt"] as? String)?.isEmpty == false)
        let payload = obj["payload"] as? [String: Any]
        #expect(payload?["sourceId"] as? String == "my-remote")
        #expect(payload?["status"] as? String == "ready")

        // needs_setup branch: empty url → envelope + payload status "needs_setup".
        _ = try await writes.upsertCatalogSource(["name": .string("No URL")])
        let text2 = (try? String(contentsOf: tracesURL, encoding: .utf8)) ?? ""
        let lines2 = text2.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        #expect(lines2.count == 2)
        guard let last = lines2.last?.data(using: .utf8),
              let obj2 = try? JSONSerialization.jsonObject(with: last) as? [String: Any]
        else { #expect(Bool(false)); return }
        #expect(obj2["status"] as? String == "needs_setup")
        #expect((obj2["payload"] as? [String: Any])?["status"] as? String == "needs_setup")
    }

    // Wave 33 W01 (closes CUTOVER_PLAN §6.95 #1): a trace-append failure must
    // PROPAGATE out of upsertCatalogSource, matching the daemon. Python's
    // record_trace calls the UNWRAPPED append_jsonl (the retired daemon/
    // 8652), so a write failure raises straight out of upsert_catalog_source and
    // the HTTP route returns an error — even though the source record is already
    // on disk. Wave 32 W02 swallowed it Swift-side; this pins the corrected
    // behaviour so a future edit can't silently re-swallow.
    @Test func test_upsertTraceAppendErrorPropagates() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Delegate every persistence call to a real core EXCEPT appendJSONL,
        // which always throws — simulating a disk-full / permission failure on
        // the trace ledger. Using a protocol-conforming mock (NOT the concrete
        // SwiftNativePersistenceCore) also exercises emitCatalogTrace's no-lock
        // `else` branch, so the propagation is independent of the flock path.
        let mock = TraceAppendFailingPersistence(delegate: SwiftNativePersistenceCore())
        let writes = SwiftNativeCatalogWrites(dataRoot: root, persistence: mock)

        await #expect(throws: (any Error).self) {
            _ = try await writes.upsertCatalogSource([
                "name": .string("Will Save Then Fail Trace"),
                "url": .string("https://x.example/catalog"),
            ])
        }

        // Python parity: the source write happens BEFORE record_trace, so the
        // record is durably on disk even though the trace append (and thus the
        // whole call) failed. Confirm the sources.json row landed.
        let p = SwiftNativePersistenceCore()
        let raw = await p.readJSON(
            root.appendingPathComponent("catalog/sources/sources.json"),
            defaultValue: .array([])
        )
        guard case .array(let items) = raw else { #expect(Bool(false)); return }
        let saved = items.contains { v in
            if case .object(let o) = v { return jstr(o, "id") == "will-save-then-fail-trace" }
            return false
        }
        #expect(saved, "source record must persist before the propagated trace failure")
    }

    // check_capability_updates() emits NO record_trace in the daemon
    //, so the Swift port must NOT
    // write a trace either — guarding against an over-eager future edit.
    @Test func test_checkUpdatesEmitsNoTrace() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = SwiftNativeCatalogWrites(dataRoot: root, persistence: SwiftNativePersistenceCore())
        _ = try await writes.checkCapabilityUpdates()
        let tracesURL = root
            .appendingPathComponent("traces", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        // No traces file (or an empty one) — the updates-check path is silent.
        let text = (try? String(contentsOf: tracesURL, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        #expect(lines.isEmpty)
    }

    @Test func test_upsertReplacesSameID() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = SwiftNativeCatalogWrites(
            dataRoot: root, persistence: SwiftNativePersistenceCore()
        )
        _ = try await writes.upsertCatalogSource(["id": .string("dup"), "name": .string("First"), "url": .string("u1")])
        _ = try await writes.upsertCatalogSource(["id": .string("dup"), "name": .string("Second"), "url": .string("u2")])

        // Read sources.json back: exactly one "dup" row, with name "Second".
        let p = SwiftNativePersistenceCore()
        let raw = await p.readJSON(
            root.appendingPathComponent("catalog/sources/sources.json"),
            defaultValue: .array([])
        )
        guard case .array(let items) = raw else { #expect(Bool(false)); return }
        let dups = items.compactMap { v -> [String: JSONValue]? in
            if case .object(let o) = v, jstr(o, "id") == "dup" { return o }
            return nil
        }
        #expect(dups.count == 1)
        #expect(jstr(dups[0], "name") == "Second")
    }

    @Test func test_checkCapabilityUpdatesShape() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Seed one install.
        let installsPath = root.appendingPathComponent("catalog/installs.json")
        try FileManager.default.createDirectory(
            at: installsPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let install: [Any] = [[
            "id": "install-1", "packId": "demo-pack", "version": "2.0.0",
            "installedAt": "2026-06-01T01:00:00+00:00",
        ]]
        try JSONSerialization.data(withJSONObject: install).write(to: installsPath)

        let writes = SwiftNativeCatalogWrites(
            dataRoot: root, persistence: SwiftNativePersistenceCore()
        )
        let result = try await writes.checkCapabilityUpdates()
        #expect(jstr(result, "status") == "checked")
        let updates = jarr(result, "updates")
        #expect(updates.count == 1)
        if case .object(let u)? = updates.first {
            #expect(jstr(u, "id") == "update:demo-pack")
            #expect(jstr(u, "status") == "current")
            #expect(jstr(u, "installedVersion") == "2.0.0")
            #expect(jstr(u, "availableVersion") == "2.0.0")
            #expect(jstr(u, "sourceId") == "local-catalog")
        } else {
            #expect(Bool(false))
        }
        if case .int(let n)? = result["sourceCount"] {
            #expect(n >= 1) // at least the default local-catalog source
        } else {
            #expect(Bool(false))
        }

        // lastCheckedAt stamped on the default source.
        let p = SwiftNativePersistenceCore()
        let raw = await p.readJSON(root.appendingPathComponent("catalog/sources/sources.json"), defaultValue: .array([]))
        guard case .array(let items) = raw, case .object(let src)? = items.first else {
            #expect(Bool(false)); return
        }
        #expect(jstr(src, "lastCheckedAt").isEmpty == false)
    }

    @Test func test_updateIdWithMissingPackIdIsNone() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installsPath = root.appendingPathComponent("catalog/installs.json")
        try FileManager.default.createDirectory(
            at: installsPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // install with NO packId key → Python f"update:{None}" == "update:None".
        let installs: [Any] = [["id": "x", "version": "1.0"]]
        try JSONSerialization.data(withJSONObject: installs).write(to: installsPath)
        let writes = SwiftNativeCatalogWrites(dataRoot: root, persistence: SwiftNativePersistenceCore())
        let result = try await writes.checkCapabilityUpdates()
        let updates = jarr(result, "updates")
        if case .object(let u)? = updates.first {
            #expect(jstr(u, "id") == "update:None")
        } else {
            #expect(Bool(false))
        }
    }

    @Test func test_listInstallsStableReverseSort() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let installsPath = root.appendingPathComponent("catalog/installs.json")
        try FileManager.default.createDirectory(
            at: installsPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Two share a timestamp (stable order preserved), one is newer, one older.
        let installs: [Any] = [
            ["id": "a", "installedAt": "2026-06-01T00:00:00+00:00"],
            ["id": "b", "installedAt": "2026-06-03T00:00:00+00:00"],
            ["id": "c", "installedAt": "2026-06-02T00:00:00+00:00"],
            ["id": "d", "installedAt": "2026-06-02T00:00:00+00:00"],
        ]
        try JSONSerialization.data(withJSONObject: installs).write(to: installsPath)
        let writes = SwiftNativeCatalogWrites(
            dataRoot: root, persistence: SwiftNativePersistenceCore()
        )
        let rows = try await writes.listCapabilityPackInstalls()
        let ids = rows.map { jstr($0, "id") }
        // Descending by installedAt; c before d on the tie (original order).
        #expect(ids == ["b", "c", "d", "a"])
    }
}
