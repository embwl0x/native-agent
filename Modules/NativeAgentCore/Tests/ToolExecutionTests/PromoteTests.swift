import Testing
import Foundation
import CryptoKit
@testable import ToolExecution
import NativeAgentCore
import PersistenceCore
import TrustCenter

// MARK: - Helpers

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecutionPromoteTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func seedProposal(
    root: URL,
    id: String,
    permissions: [String] = [],
    entrypointName: String = "tool.swift",
    entrypointBody: String = "import Foundation\nprint(\"{}\")\n",
    extraManifest: [String: JSONValue] = [:],
    includeTests: Bool = true
) throws {
    let dir = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("proposals", isDirectory: true)
        .appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    var manifest: [String: JSONValue] = [
        "id": .string(id),
        "name": .string(id),
        "createdAt": .string("2026-05-01T00:00:00+00:00"),
        "entrypoint": .string(entrypointName),
        "permissions": .array(permissions.map { .string($0) }),
    ]
    for (k, v) in extraManifest { manifest[k] = v }

    let manifestData = try JSONValue.object(manifest).serializedData(pretty: true)
    try manifestData.write(to: dir.appendingPathComponent("manifest.json"))
    try Data(entrypointBody.utf8).write(to: dir.appendingPathComponent(entrypointName))
    if includeTests {
        // Real test case so the fixture passes SwiftToolValidator's
        // "tests.json present + non-empty" gate. The body is shape-only;
        // the engine doesn't execute it (sandbox is a sibling subsystem).
        let testsBody = "[{\"name\":\"smoke\",\"input\":{}}]"
        try Data(testsBody.utf8).write(to: dir.appendingPathComponent("tests.json"))
    }
}

private func readRegistry(_ root: URL) throws -> [[String: JSONValue]] {
    let path = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("registry.json")
    guard FileManager.default.fileExists(atPath: path.path) else { return [] }
    let data = try Data(contentsOf: path)
    let parsed = try JSONValue.parse(data)
    guard case .array(let items) = parsed else { return [] }
    return items.compactMap { item in
        if case .object(let o) = item { return o }
        return nil
    }
}

private func makeEngine(root: URL, autoPromotable: Bool = true) -> ToolPromoteEngine {
    let signer = SwiftNativeManifestSigner(dataRoot: root)
    let validator: ToolValidator = { _ in
        ToolValidationResult(valid: true, errors: [], autoPromotable: autoPromotable)
    }
    return ToolPromoteEngine(
        signer: signer,
        dataRoot: root,
        validator: validator
    )
}

private func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Tests

@Test
func promote_unknown_proposal_throws_unknownProposal() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = makeEngine(root: root)
    do {
        _ = try await engine.promote(proposalId: "does-not-exist")
        Issue.record("expected unknownProposal")
    } catch ToolPromoteError.unknownProposal {
        // ok
    }
}

@Test
func promote_valid_safe_tool_writes_active_dir_and_signed_manifest() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedProposal(root: root, id: "tool_safe")
    let engine = makeEngine(root: root)
    _ = try await engine.promote(proposalId: "tool_safe")

    let activeDir = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("active", isDirectory: true)
        .appendingPathComponent("tool_safe", isDirectory: true)
    #expect(FileManager.default.fileExists(atPath: activeDir.path))
    #expect(FileManager.default.fileExists(atPath: activeDir.appendingPathComponent("tool.swift").path))

    let manifestData = try Data(contentsOf: activeDir.appendingPathComponent("manifest.json"))
    guard case .object(let manifest) = try JSONValue.parse(manifestData) else {
        Issue.record("manifest not an object"); return
    }
    if case .string(let sig) = manifest["manifestSignature"] ?? .null {
        #expect(!sig.isEmpty)
    } else {
        Issue.record("manifestSignature missing")
    }
    if case .int(let ver) = manifest["signatureVersion"] ?? .null {
        #expect(ver == 2)
    } else {
        Issue.record("signatureVersion missing or wrong type")
    }
}

@Test
func promote_valid_safe_tool_writes_registry_record_with_correct_fields() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedProposal(root: root, id: "tool_fields")
    let engine = makeEngine(root: root)
    _ = try await engine.promote(proposalId: "tool_fields")

    let records = try readRegistry(root)
    #expect(records.count == 1)
    let r = records[0]
    if case .string(let s) = r["status"] ?? .null { #expect(s == "active") } else { Issue.record("missing status") }
    if case .string(let s) = r["phase"] ?? .null { #expect(s == "active") } else { Issue.record("missing phase") }
    if case .string(let s) = r["promotedAt"] ?? .null { #expect(!s.isEmpty) } else { Issue.record("missing promotedAt") }
    if case .string(let s) = r["codeFingerprint"] ?? .null { #expect(s.count == 64) } else { Issue.record("missing codeFingerprint") }
    if case .string(let s) = r["validationStatus"] ?? .null { #expect(s == "valid") } else { Issue.record("missing validationStatus") }
    #expect(r["quarantinePath"] == .null)
    #expect(r["quarantineReason"] == .null)
}

@Test
func promote_risky_without_allowRisky_throws_riskyWithoutAllowRisky() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedProposal(root: root, id: "tool_risky", permissions: ["shell"])
    // autoPromotable=false so the gate trips on risky.
    let engine = makeEngine(root: root, autoPromotable: false)
    do {
        _ = try await engine.promote(proposalId: "tool_risky", allowRisky: false)
        Issue.record("expected riskyWithoutAllowRisky")
    } catch ToolPromoteError.riskyWithoutAllowRisky(let perms) {
        #expect(perms.contains("shell"))
    }
}

@Test
func promote_risky_with_allowRisky_succeeds_with_risk_acknowledged_fields_set() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedProposal(root: root, id: "tool_risky_ok", permissions: ["app_data_write"])
    let engine = makeEngine(root: root, autoPromotable: false)
    let promoted = try await engine.promote(
        proposalId: "tool_risky_ok",
        allowRisky: true,
        approvedBy: "user_requested"
    )
    if case .bool(let b) = promoted["autoRun"] ?? .null { #expect(b == false) } else { Issue.record("autoRun missing") }
    if case .bool(let b) = promoted["autoPromote"] ?? .null { #expect(b == false) } else { Issue.record("autoPromote missing") }
    if case .bool(let b) = promoted["manualApprovalRequired"] ?? .null { #expect(b == false) } else { Issue.record("manualApprovalRequired missing") }
    if case .string(let s) = promoted["riskAcknowledgedAt"] ?? .null { #expect(!s.isEmpty) } else { Issue.record("riskAcknowledgedAt missing") }
    if case .string(let s) = promoted["riskAcknowledgedBy"] ?? .null { #expect(s == "user_requested") } else { Issue.record("riskAcknowledgedBy wrong") }
    if case .bool(let b) = promoted["userRequestedActivation"] ?? .null { #expect(b == true) } else { Issue.record("userRequestedActivation wrong") }
}

@Test
func promote_existing_active_dir_is_replaced() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedProposal(root: root, id: "tool_replace")

    // Pre-seed a stale active dir with a sentinel file.
    let activeDir = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("active", isDirectory: true)
        .appendingPathComponent("tool_replace", isDirectory: true)
    try FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)
    try Data("stale".utf8).write(to: activeDir.appendingPathComponent("STALE_MARKER"))

    let engine = makeEngine(root: root)
    _ = try await engine.promote(proposalId: "tool_replace")

    #expect(!FileManager.default.fileExists(atPath: activeDir.appendingPathComponent("STALE_MARKER").path))
    #expect(FileManager.default.fileExists(atPath: activeDir.appendingPathComponent("tool.swift").path))
}

@Test
func promote_codeFingerprint_matches_helper() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedProposal(root: root, id: "tool_fp")
    let engine = makeEngine(root: root)
    let promoted = try await engine.promote(proposalId: "tool_fp")
    guard case .string(let storedFp) = promoted["codeFingerprint"] ?? .null else {
        Issue.record("no fingerprint in promoted record"); return
    }
    let activeDir = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("active", isDirectory: true)
        .appendingPathComponent("tool_fp", isDirectory: true)
    let manifestData = try Data(contentsOf: activeDir.appendingPathComponent("manifest.json"))
    guard case .object(let manifest) = try JSONValue.parse(manifestData) else {
        Issue.record("manifest not object"); return
    }
    let recomputed = try ToolPromoteEngine.computeToolCodeFingerprintForPromote(
        toolDir: activeDir, manifest: manifest
    )
    #expect(storedFp == recomputed)
}

@Test
func promote_signed_manifest_verifies_via_signer() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedProposal(root: root, id: "tool_verify")
    let signer = SwiftNativeManifestSigner(dataRoot: root)
    let engine = ToolPromoteEngine(
        signer: signer,
        dataRoot: root,
        validator: permissivePromoteValidatorForTesting
    )
    _ = try await engine.promote(proposalId: "tool_verify")

    let activeManifestURL = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("active", isDirectory: true)
        .appendingPathComponent("tool_verify", isDirectory: true)
        .appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: activeManifestURL)
    guard case .object(let manifest) = try JSONValue.parse(data) else {
        Issue.record("manifest not object"); return
    }
    let errs = try await signer.verify(manifest)
    #expect(errs.isEmpty)
}

@Test
func promote_atomic_under_concurrent_callers_no_corruption() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedProposal(root: root, id: "tool_par_a")
    try seedProposal(root: root, id: "tool_par_b")
    let engine = makeEngine(root: root)

    async let a: [String: JSONValue] = engine.promote(proposalId: "tool_par_a")
    async let b: [String: JSONValue] = engine.promote(proposalId: "tool_par_b")
    _ = try await (a, b)

    let records = try readRegistry(root)
    let ids = records.compactMap { r -> String? in
        if case .string(let s) = r["id"] ?? .null { return s }
        return nil
    }
    #expect(Set(ids) == Set(["tool_par_a", "tool_par_b"]))
}

@Test
func promote_quarantineReason_quarantinePath_are_cleared() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedProposal(root: root, id: "tool_was_quar")

    // Pre-seed a registry record that's currently quarantined.
    let registryDir = root.appendingPathComponent("tools", isDirectory: true)
    try FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
    let stale: [String: JSONValue] = [
        "id": .string("tool_was_quar"),
        "name": .string("tool_was_quar"),
        "status": .string("quarantined"),
        "phase": .string("quarantined"),
        "createdAt": .string("2026-05-01T00:00:00+00:00"),
        "quarantinePath": .string("/tmp/old/quar"),
        "quarantineReason": .string("smelled bad"),
    ]
    let initial = try JSONValue.array([.object(stale)]).serializedData(pretty: true)
    try initial.write(to: registryDir.appendingPathComponent("registry.json"))

    let engine = makeEngine(root: root)
    let promoted = try await engine.promote(proposalId: "tool_was_quar")
    #expect(promoted["quarantinePath"] == .null)
    #expect(promoted["quarantineReason"] == .null)

    let records = try readRegistry(root)
    #expect(records.count == 1)
    #expect(records[0]["quarantinePath"] == .null)
    #expect(records[0]["quarantineReason"] == .null)
    if case .string(let s) = records[0]["status"] ?? .null {
        #expect(s == "active")
    }
}

// MARK: - U5 W-B — staged-dir atomic swap + rollback

private func activeRootURL(_ root: URL) -> URL {
    root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("active", isDirectory: true)
}

/// Names of swap-machinery litter (.staging-* / .retired-*) under active/.
private func litterNames(_ root: URL) -> [String] {
    let entries = (try? FileManager.default.contentsOfDirectory(
        at: activeRootURL(root), includingPropertiesForKeys: nil
    )) ?? []
    return entries.map(\.lastPathComponent).filter {
        $0.hasPrefix(".staging-") || $0.hasPrefix(".retired-")
    }
}

/// Backdate a path's mtime past the sweep's age gate.
private func backdate(_ url: URL, by seconds: TimeInterval = 3600) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-seconds)],
        ofItemAtPath: url.path
    )
}

private func writeProposalManifest(_ root: URL, id: String, manifest: [String: JSONValue]) throws {
    let url = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("proposals", isDirectory: true)
        .appendingPathComponent(id, isDirectory: true)
        .appendingPathComponent("manifest.json")
    try JSONValue.object(manifest).serializedData(pretty: true).write(to: url)
}

// The load-bearing window: failure AFTER the staging copy + signing but
// BEFORE the registry upsert. Pre-U5, the active dir had already been
// remove+copy'd by this point — the failure destroyed the live tool.
@Test
func promote_failure_after_staging_preserves_previous_active_and_registry() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedProposal(root: root, id: "tool_swap")
    let engine = makeEngine(root: root)
    let first = try await engine.promote(proposalId: "tool_swap")
    guard case .string(let fp1) = first["codeFingerprint"] ?? .null else {
        Issue.record("no fingerprint from first promote"); return
    }
    let activeDir = activeRootURL(root).appendingPathComponent("tool_swap", isDirectory: true)
    let v1Body = try Data(contentsOf: activeDir.appendingPathComponent("tool.swift"))

    // Sabotage round 2: absolute entrypoint in the PROPOSAL manifest. The
    // permissive test validator lets it through; the fingerprint step
    // (running against the STAGED copy) throws. Also change the proposal
    // body so any accidental replacement would be visible.
    try writeProposalManifest(root, id: "tool_swap", manifest: [
        "id": .string("tool_swap"),
        "name": .string("tool_swap"),
        "createdAt": .string("2026-05-01T00:00:00+00:00"),
        "entrypoint": .string("/etc/evil"),
        "permissions": .array([]),
    ])
    let proposalBody = root
        .appendingPathComponent("tools/proposals/tool_swap/tool.swift")
    try Data("SABOTAGED".utf8).write(to: proposalBody)

    do {
        _ = try await engine.promote(proposalId: "tool_swap")
        Issue.record("expected fingerprint failure")
    } catch ToolPromoteError.persistenceFailed(let m) {
        #expect(m.contains("fingerprint"))
    }

    // Previously-active tool untouched, still signed, registry still v1.
    #expect(try Data(contentsOf: activeDir.appendingPathComponent("tool.swift")) == v1Body)
    let activeManifest = try JSONValue.parse(Data(contentsOf: activeDir.appendingPathComponent("manifest.json")))
    guard case .object(let manifestObj) = activeManifest else {
        Issue.record("active manifest unreadable"); return
    }
    let signer = SwiftNativeManifestSigner(dataRoot: root)
    let verifyErrors = try await signer.verify(manifestObj)
    #expect(verifyErrors.isEmpty)
    let records = try readRegistry(root)
    #expect(records.count == 1)
    if case .string(let fp) = records[0]["codeFingerprint"] ?? .null {
        #expect(fp == fp1)
    } else { Issue.record("registry fingerprint missing") }
    #expect(litterNames(root).isEmpty)
}

@Test
func promote_signing_failure_leaves_previous_active_untouched() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedProposal(root: root, id: "tool_sign_fail")
    let engine = makeEngine(root: root)
    _ = try await engine.promote(proposalId: "tool_sign_fail")
    let activeDir = activeRootURL(root).appendingPathComponent("tool_sign_fail", isDirectory: true)
    let v1Body = try Data(contentsOf: activeDir.appendingPathComponent("tool.swift"))

    // Break the signer: replace the key FILE with a DIRECTORY. Read fails
    // (it's a dir), key regeneration write fails (path occupied) → sign
    // throws ioFailed → promote surfaces signingFailed.
    let keyPath = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent(".manifest_signing_key")
    try FileManager.default.removeItem(at: keyPath)
    try FileManager.default.createDirectory(at: keyPath, withIntermediateDirectories: true)

    try Data("print(\"v2\")\n".utf8).write(
        to: root.appendingPathComponent("tools/proposals/tool_sign_fail/tool.swift")
    )
    do {
        _ = try await engine.promote(proposalId: "tool_sign_fail")
        Issue.record("expected signingFailed")
    } catch ToolPromoteError.signingFailed {
        // ok
    }
    #expect(try Data(contentsOf: activeDir.appendingPathComponent("tool.swift")) == v1Body)
    #expect(litterNames(root).isEmpty)
}

@Test
func promote_registry_write_failure_restores_previous_active() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedProposal(root: root, id: "tool_reg_fail")

    // Hand-seed a previously-active dir with a sentinel the new copy would
    // never contain.
    let activeDir = activeRootURL(root).appendingPathComponent("tool_reg_fail", isDirectory: true)
    try FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)
    try Data("OLD".utf8).write(to: activeDir.appendingPathComponent("SENTINEL"))

    // registry.json as a DIRECTORY → upsert's atomic write throws after the
    // swap already happened → promote must roll the swap back.
    let registryPath = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("registry.json")
    try FileManager.default.createDirectory(at: registryPath, withIntermediateDirectories: true)

    let engine = makeEngine(root: root)
    do {
        _ = try await engine.promote(proposalId: "tool_reg_fail")
        Issue.record("expected registry write failure")
    } catch {
        // Surfaced error shape depends on the write failure; the disk-state
        // assertions below are the contract.
    }
    // The OLD dir is back (sentinel present, staged tool.swift absent).
    #expect(FileManager.default.fileExists(atPath: activeDir.appendingPathComponent("SENTINEL").path))
    #expect(!FileManager.default.fileExists(atPath: activeDir.appendingPathComponent("tool.swift").path))
    #expect(litterNames(root).isEmpty)
}

@Test
func promote_entry_sweep_cleans_stale_litter_and_restores_orphaned_retired() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedProposal(root: root, id: "tool_sweeper")
    let activeRoot = activeRootURL(root)
    let fm = FileManager.default

    // (1) Stale staging dir → deleted.
    let staleStaging = activeRoot.appendingPathComponent(".staging-deadtool-abc123", isDirectory: true)
    try fm.createDirectory(at: staleStaging, withIntermediateDirectories: true)
    try Data("junk".utf8).write(to: staleStaging.appendingPathComponent("junk.txt"))
    try backdate(staleStaging)

    // (2) Retired dir whose tool HAS a live active dir → retired deleted,
    //     active kept.
    let retiredDone = activeRoot.appendingPathComponent(".retired-completed-abc123", isDirectory: true)
    try fm.createDirectory(at: retiredDone, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: retiredDone.appendingPathComponent("old.txt"))
    try backdate(retiredDone)
    let activeCompleted = activeRoot.appendingPathComponent("completed", isDirectory: true)
    try fm.createDirectory(at: activeCompleted, withIntermediateDirectories: true)
    try Data("KEEP".utf8).write(to: activeCompleted.appendingPathComponent("KEEP"))

    // (3) ORPHANED retired dir (active/<id> missing — crash hit between
    //     move-aside and move-in) → restored to active/<id>.
    let retiredOrphan = activeRoot.appendingPathComponent(".retired-ghost-abc123", isDirectory: true)
    try fm.createDirectory(at: retiredOrphan, withIntermediateDirectories: true)
    try Data("GHOST".utf8).write(to: retiredOrphan.appendingPathComponent("GHOST"))
    try backdate(retiredOrphan)

    // (4) FRESH staging dir (another engine instance could be mid-promote)
    //     → age gate skips it.
    let freshStaging = activeRoot.appendingPathComponent(".staging-livetool-xyz789", isDirectory: true)
    try fm.createDirectory(at: freshStaging, withIntermediateDirectories: true)

    let engine = makeEngine(root: root)
    _ = try await engine.promote(proposalId: "tool_sweeper")

    #expect(!fm.fileExists(atPath: staleStaging.path))
    #expect(!fm.fileExists(atPath: retiredDone.path))
    #expect(fm.fileExists(atPath: activeCompleted.appendingPathComponent("KEEP").path))
    #expect(!fm.fileExists(atPath: retiredOrphan.path))
    #expect(fm.fileExists(
        atPath: activeRoot.appendingPathComponent("ghost").appendingPathComponent("GHOST").path
    ))
    #expect(fm.fileExists(atPath: freshStaging.path))
}

// Serializing the WHOLE mutation body (not just the registry upsert) means
// the registry row always describes the dir that won the swap — even for
// same-id concurrent promotes, whose per-promote signedAt timestamps make
// each staged copy's fingerprint unique.
@Test
func promote_concurrent_same_id_registry_matches_on_disk_tool() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedProposal(root: root, id: "tool_race")
    let engine = makeEngine(root: root)

    async let a: [String: JSONValue] = engine.promote(proposalId: "tool_race")
    async let b: [String: JSONValue] = engine.promote(proposalId: "tool_race")
    _ = try await (a, b)

    let records = try readRegistry(root)
    #expect(records.count == 1)
    guard case .string(let registryFp) = records[0]["codeFingerprint"] ?? .null else {
        Issue.record("registry fingerprint missing"); return
    }
    let activeDir = activeRootURL(root).appendingPathComponent("tool_race", isDirectory: true)
    guard case .object(let manifest) = try JSONValue.parse(
        Data(contentsOf: activeDir.appendingPathComponent("manifest.json"))
    ) else {
        Issue.record("active manifest unreadable"); return
    }
    let recomputed = try ToolPromoteEngine.computeToolCodeFingerprintForPromote(
        toolDir: activeDir, manifest: manifest
    )
    #expect(registryFp == recomputed)
    #expect(litterNames(root).isEmpty)
}

// U5 W-B fix-round (gpt-5.5 NEEDS_FIX): production constructs a FRESH
// ToolPromoteEngine per promote call (SwiftNativeToolExecution.promote), so
// the actor's mutationTail serializes NOTHING across real concurrent
// promotes — the registry flock, which now spans the directory swap AND the
// registry upsert, is the only cross-instance serializer. The single-engine
// test above can't see that race; this one promotes the same id from two
// engine instances concurrently, several rounds, and requires the registry
// row to describe the dir that won the swap every time.
@Test
func promote_concurrent_two_engine_instances_same_id_registry_matches_disk() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedProposal(root: root, id: "tool_xinstance")
    let activeDir = activeRootURL(root).appendingPathComponent("tool_xinstance", isDirectory: true)

    for round in 0..<3 {
        let engineA = makeEngine(root: root)
        let engineB = makeEngine(root: root)
        async let a: [String: JSONValue] = engineA.promote(proposalId: "tool_xinstance")
        async let b: [String: JSONValue] = engineB.promote(proposalId: "tool_xinstance")
        _ = try await (a, b)

        let records = try readRegistry(root)
        #expect(records.count == 1, "round \(round): registry must hold ONE row")
        guard case .string(let registryFp) = records[0]["codeFingerprint"] ?? .null else {
            Issue.record("round \(round): registry fingerprint missing"); return
        }
        guard case .object(let manifest) = try JSONValue.parse(
            Data(contentsOf: activeDir.appendingPathComponent("manifest.json"))
        ) else {
            Issue.record("round \(round): active manifest unreadable"); return
        }
        let recomputed = try ToolPromoteEngine.computeToolCodeFingerprintForPromote(
            toolDir: activeDir, manifest: manifest
        )
        #expect(registryFp == recomputed, "round \(round): registry row must match the on-disk winner")
        #expect(litterNames(root).isEmpty, "round \(round): no swap litter may survive")
    }
}

@Test
func promote_reserved_prefix_id_rejected() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = makeEngine(root: root)
    for evil in [".staging-evil-1", ".retired-evil-1"] {
        do {
            _ = try await engine.promote(proposalId: evil)
            Issue.record("expected validationFailed for \(evil)")
        } catch ToolPromoteError.validationFailed {
            // ok
        }
    }
}

@Test
func swapDirName_toolId_parsing_handles_dashed_ids() {
    let token = ToolPromoteEngine.swapToken(Date())
    #expect(!token.contains("-"))
    let name = ".retired-my-dashed-tool-" + token
    #expect(ToolPromoteEngine.toolId(fromSwapDirName: name, prefix: ".retired-") == "my-dashed-tool")
    // No token segment → unparseable → nil (sweep deletes it).
    #expect(ToolPromoteEngine.toolId(fromSwapDirName: ".retired-xyz", prefix: ".retired-") == nil)
    // Empty id → nil.
    #expect(ToolPromoteEngine.toolId(fromSwapDirName: ".retired--abc", prefix: ".retired-") == nil)
    // Wrong prefix → nil.
    #expect(ToolPromoteEngine.toolId(fromSwapDirName: "plain", prefix: ".retired-") == nil)
}

// MARK: - Native signature/fingerprint pinning

private func stageSigningKey(_ root: URL) throws {
    let dir = root.appendingPathComponent("tools", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let key = Data(repeating: 0x42, count: 32)
    let path = dir.appendingPathComponent(".manifest_signing_key")
    try key.write(to: path, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
}

// MARK: - Finding #3 — registry-only field preservation
//
// Registry upsert starts from the existing record and lets promote-side fields
// override it, so fields that live only in the registry (useCount, autoCreated,
// sourceRunId, requestSource, proposalPath, ...) survive the promote. Pin that
// contract here.

@Test
func promote_preserves_registry_only_fields() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try seedProposal(root: root, id: "tool_preserve")

    // Pre-seed the registry with a record carrying counters / source flags
    // the promote payload would never re-populate on its own.
    let registryDir = root.appendingPathComponent("tools", isDirectory: true)
    try FileManager.default.createDirectory(at: registryDir, withIntermediateDirectories: true)
    let stale: [String: JSONValue] = [
        "id": .string("tool_preserve"),
        "name": .string("tool_preserve"),
        "status": .string("proposed"),
        "createdAt": .string("2026-05-01T00:00:00+00:00"),
        "useCount": .int(7),
        "autoCreated": .bool(true),
        "sourceRunId": .string("run-abc"),
        "requestSource": .string("inbox"),
        "proposalPath": .string("/some/old/path"),
    ]
    let initial = try JSONValue.array([.object(stale)]).serializedData(pretty: true)
    try initial.write(to: registryDir.appendingPathComponent("registry.json"))

    let engine = makeEngine(root: root)
    _ = try await engine.promote(proposalId: "tool_preserve")

    let records = try readRegistry(root)
    #expect(records.count == 1)
    let r = records[0]
    // Counters + provenance survive.
    if case .int(let n) = r["useCount"] ?? .null { #expect(n == 7) } else { Issue.record("useCount lost") }
    if case .bool(let b) = r["autoCreated"] ?? .null { #expect(b == true) } else { Issue.record("autoCreated lost") }
    if case .string(let s) = r["sourceRunId"] ?? .null { #expect(s == "run-abc") } else { Issue.record("sourceRunId lost") }
    if case .string(let s) = r["requestSource"] ?? .null { #expect(s == "inbox") } else { Issue.record("requestSource lost") }
    if case .string(let s) = r["proposalPath"] ?? .null { #expect(s == "/some/old/path") } else { Issue.record("proposalPath lost") }
    // Promote-side overrides win where they overlap.
    if case .string(let s) = r["status"] ?? .null { #expect(s == "active") } else { Issue.record("status not flipped") }
}

// Pins the TWO pure algorithms (canonical-HMAC manifest signature +
// tool_code_fingerprint) independently of the whole promote envelope.
// Excluded from this comparison (covered by other tests / known asymmetries):
//   - registry-record merging semantics (covered by
//     promote_preserves_registry_only_fields)
//   - timestamp fields (promotedAt/updatedAt — clock-dependent)
//   - sandbox-test execution results
//   - static scan errors
// The fixture stages a tests.json with a single passing case + safe imports
// so it would also clear the production SwiftToolValidator if it were wired
// to this engine (here we use makeEngine's permissive validator so the
// signature/fingerprint algorithms can be exercised in isolation).
@Test
func promote_signature_and_fingerprint_match_expected_algorithms() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try stageSigningKey(root)
    try seedProposal(
        root: root,
        id: "tool_parity",
        permissions: ["app_data_read"],
        extraManifest: [
            "tests": .array([
                .object(["name": .string("smoke"), "input": .object([:])]),
            ])
        ]
    )
    // Overwrite the empty tests.json the default seed wrote with a non-empty
    // case so the production validator would accept this fixture too.
    let proposalDir = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("proposals", isDirectory: true)
        .appendingPathComponent("tool_parity", isDirectory: true)
    let testCases: JSONValue = .array([
        .object(["name": .string("smoke"), "input": .object([:])]),
    ])
    let testData = try testCases.serializedData(pretty: true)
    try testData.write(to: proposalDir.appendingPathComponent("tests.json"))
    let engine = makeEngine(root: root)
    _ = try await engine.promote(proposalId: "tool_parity")

    let activeDir = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("active", isDirectory: true)
        .appendingPathComponent("tool_parity", isDirectory: true)
    let activeManifestURL = activeDir.appendingPathComponent("manifest.json")
    guard case .object(let signed) = try JSONValue.parse(Data(contentsOf: activeManifestURL)) else {
        Issue.record("manifest not object"); return
    }
    guard case .string(let swiftSig) = signed["manifestSignature"] ?? .null else {
        Issue.record("no signature"); return
    }

    var body = signed
    body.removeValue(forKey: "manifestSignature")
    body.removeValue(forKey: "signedAt")
    body["signatureVersion"] = .int(2)
    let canonical = try SwiftNativeManifestSigner.canonicalBytes(body)
    let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
    let mac = HMAC<SHA256>.authenticationCode(for: canonical, using: key)
    let expectedSig = hexDigest(mac)
    #expect(swiftSig == expectedSig)

    var hasher = SHA256()
    let nul = Data([0])
    for filename in ["manifest.json", "tool.swift", "tests.json"] {
        hasher.update(data: Data(filename.utf8))
        hasher.update(data: nul)
        let bytes = try Data(contentsOf: activeDir.appendingPathComponent(filename))
        hasher.update(data: bytes)
        hasher.update(data: nul)
    }
    let expectedFp = hexDigest(hasher.finalize())

    let regPath = root
        .appendingPathComponent("tools", isDirectory: true)
        .appendingPathComponent("registry.json")
    guard case .array(let regItems) = try JSONValue.parse(Data(contentsOf: regPath)) else {
        Issue.record("registry not array"); return
    }
    var storedFp = ""
    for it in regItems {
        if case .object(let o) = it,
           case .string(let rid) = o["id"] ?? .null, rid == "tool_parity",
           case .string(let fp) = o["codeFingerprint"] ?? .null {
            storedFp = fp; break
        }
    }
    #expect(!storedFp.isEmpty)
    #expect(storedFp == expectedFp)
}
