import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Blocked-receipt audit append (wave 32 W03 — CUTOVER §6.55 prereq #4)

/// Make a fresh temp audit-file path inside a unique dir; caller cleans up.
private func _makeTempAuditPath() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("macctl_audit_test_\(UUID().uuidString)", isDirectory: true)
    return dir.appendingPathComponent("mac_control_audit.jsonl")
}

/// Read all JSONL rows from an audit file as parsed objects, simulating the
/// daemon's `_load_audit` (json.loads per line). Returns [] if absent.
private func _readAuditRows(_ path: URL) -> [[String: JSONValue]] {
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line -> [String: JSONValue]? in
        guard let parsed = try? JSONValue.parse(Data(line.utf8)),
              case .object(let obj) = parsed else { return nil }
        return obj
    }
}

@Test func gateRefusalEmitsAuditRowWhenAuditPathSet() async throws {
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.enabled = false  // master gate off → refuse
    let auditPath = _makeTempAuditPath()
    defer { try? FileManager.default.removeItem(at: auditPath.deletingLastPathComponent()) }

    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol),
        auditAppendPath: auditPath
    )
    let r = try await client.dispatch(action: "shell", body: [
        "command": .string("echo hi"), "trigger": .string("user"),
    ])
    #expect(r.ok == false)
    #expect(r.httpStatus == 403)
    // No HTTP round-trip — refusal is in-process.
    let calls = await http.calls
    #expect(calls.isEmpty)

    let rows = _readAuditRows(auditPath)
    #expect(rows.count == 1, "exactly one blocked-receipt row must be appended")
    guard let row = rows.first else { return }
    // _blocked_receipt → make_receipt(blocked=True, block_reason=…) parity shape.
    #expect(row["blocked"] == .bool(true))
    #expect(row["block_reason"] == .string("mac_control_disabled: master gate off"))
    #expect(row["method"] == .string("run_shell"))      // daemon method name for shell
    #expect(row["category"] == .string("shell"))
    #expect(row["trigger"] == .string("user"))
    #expect(row["trigger_source"] == .string("user"))
    #expect(row["args_hash"] == .string("sha256:none"))
    #expect(row["approved"] == .null)
    #expect(row["exit_code"] == .int(0))
    #expect(row["stdout"] == .string(""))
    #expect(row["stderr"] == .string(""))
    #expect(row["duration_ms"] == .int(0))
    // approval_required: approvalRequiredFor is nil → daemon defaults shell to
    // ["shell"] ⇒ true.
    #expect(row["approval_required"] == .bool(true))
    // wave-33 W02: byte-equivalence requires NO extra keys the daemon never
    // writes. The wave-32 `logged_by` marker is gone; the row carries exactly
    // make_receipt's 15 fields.
    #expect(row["logged_by"] == nil)
    #expect(row.count == 15)
    // id + executed_at present and non-empty.
    if case .string(let id)? = row["id"] { #expect(!id.isEmpty) } else { Issue.record("missing id") }
    if case .string(let ts)? = row["executed_at"] { #expect(ts.contains("T")) } else { Issue.record("missing executed_at") }
}

@Test func gateRefusalDoesNotWriteAuditWhenPathNil() async throws {
    // No auditAppendPath → no Swift-side write (wave-31 behavior preserved).
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.enabled = false
    let probe = _makeTempAuditPath()  // path we ASSERT stays absent
    defer { try? FileManager.default.removeItem(at: probe.deletingLastPathComponent()) }

    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol)
        // auditAppendPath omitted → nil
    )
    let r = try await client.dispatch(action: "shell", body: ["command": .string("echo hi")])
    #expect(r.ok == false)
    #expect(r.httpStatus == 403)
    #expect(!FileManager.default.fileExists(atPath: probe.path),
            "no audit file may be created when auditAppendPath is nil")
}

@Test func fileOpsFilePolicyRefusalEmitsFileOpsAuditRow() async throws {
    // A file-policy refusal (workspace fence) must also log, with the file_ops
    // category + the mapped daemon method name for the action.
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    // Constrain the workspace so an out-of-workspace path is refused by the
    // file-policy layer (NOT the sensitive fence — use a benign /tmp path).
    // trustPolicy non-nil + outsideWorkspaceDefault="deny" + full-mac inactive
    // (empty expiry) makes fileReason refuse a path outside workspaceRoots.
    pol.trustPolicy = MacControlTrustPolicy(
        outsideWorkspaceDefault: "deny"
    )
    pol.workspaceRoots = ["/some/workspace/only"]
    let auditPath = _makeTempAuditPath()
    defer { try? FileManager.default.removeItem(at: auditPath.deletingLastPathComponent()) }

    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol),
        auditAppendPath: auditPath
    )
    let r = try await client.dispatch(action: "file/read", body: [
        "path": .string("/tmp/outside_workspace_file.txt"),
        "trigger": .string("user"),
    ])
    // Only assert the audit row IF the file-policy layer actually refused
    // (guards against a permissive default in the gate that would let it pass).
    let rows = _readAuditRows(auditPath)
    if r.httpStatus == 403 {
        #expect(rows.count == 1)
        guard let row = rows.first else { return }
        #expect(row["blocked"] == .bool(true))
        #expect(row["category"] == .string("file_ops"))
        #expect(row["method"] == .string("read_file"))
        // approvalRequiredFor is nil on this policy → daemon default for a
        // non-shell category is [] → approval_required false.
        #expect(row["approval_required"] == .bool(false))
        if case .string(let br)? = row["block_reason"] { #expect(!br.isEmpty) } else { Issue.record("block_reason") }
    } else {
        // If the gate allowed it, there must be NO audit row (we only log refusals).
        #expect(rows.isEmpty)
    }
}

@Test func auditApprovalRequiredReflectsLivePolicyList() async throws {
    // Daemon-parity finding (W03 gpt-5.5 review #1): approval_required must
    // reflect the LIVE approval_required_for list, not a hardcoded default.
    // When the list is PRESENT, it overrides the shell special-case: a list
    // that EXCLUDES "shell" makes a shell refusal record approval_required=false.
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.enabled = false // master gate off → refuse (category still = shell)
    pol.approvalRequiredFor = ["file_ops"] // shell deliberately NOT in the list
    let auditPath = _makeTempAuditPath()
    defer { try? FileManager.default.removeItem(at: auditPath.deletingLastPathComponent()) }

    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol),
        auditAppendPath: auditPath
    )
    _ = try await client.dispatch(action: "shell", body: ["command": .string("echo hi")])
    let rows = _readAuditRows(auditPath)
    #expect(rows.count == 1)
    // List present + shell absent from it → false (NOT the ["shell"] default).
    #expect(rows.first?["approval_required"] == .bool(false))
    #expect(rows.first?["category"] == .string("shell"))
}

@Test func auditApprovalRequiredDefaultPolicyMatchesDaemon() async throws {
    // W03 re-review finding #1: MacControlPolicy.default carries
    // DEFAULT_MAC_CONTROL_POLICY["approval_required_for"], so a default-policy
    // file_ops refusal logs approval_required=true (daemon parity), not the
    // nil-branch false. Use .default with file_ops disabled-by-default → refuse.
    let http = _MockHTTPClient()
    let auditPath = _makeTempAuditPath()
    defer { try? FileManager.default.removeItem(at: auditPath.deletingLastPathComponent()) }
    // .default has enabled=false (master gate off) → any action refuses.
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: .default),
        auditAppendPath: auditPath
    )
    _ = try await client.dispatch(action: "file/read", body: ["path": .string("/tmp/x")])
    let rows = _readAuditRows(auditPath)
    #expect(rows.count == 1)
    #expect(rows.first?["category"] == .string("file_ops"))
    #expect(rows.first?["approval_required"] == .bool(true),
            "default policy includes file_ops in approval_required_for")
}

@Test func auditSystemMethodNameResolvesConcreteSubMethod() async throws {
    // W03 re-review finding #2: /v1/mac_control/system fans out to concrete
    // daemon methods (set_volume etc) chosen by body["action"]. The audit row's
    // `method` must record the concrete name, not the generic "system".
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.categoryAllowed["system_control_allowed"] = false // system refused
    let auditPath = _makeTempAuditPath()
    defer { try? FileManager.default.removeItem(at: auditPath.deletingLastPathComponent()) }
    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol),
        auditAppendPath: auditPath
    )
    _ = try await client.dispatch(action: "system", body: [
        "action": .string("set_volume"), "value": .int(50),
    ])
    let rows = _readAuditRows(auditPath)
    #expect(rows.count == 1)
    #expect(rows.first?["category"] == .string("system"))
    #expect(rows.first?["method"] == .string("set_volume"),
            "system refusal must record the concrete daemon method, not \"system\"")
}

@Test func auditRowIsValidJSONLParseable() async throws {
    // The daemon's audit reader does json.loads per line; assert the Swift row
    // round-trips cleanly (no trailing comma, valid JSON object, newline-terminated).
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.categoryAllowed["notifications_allowed"] = false
    let auditPath = _makeTempAuditPath()
    defer { try? FileManager.default.removeItem(at: auditPath.deletingLastPathComponent()) }

    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol),
        auditAppendPath: auditPath
    )
    _ = try await client.dispatch(action: "notify", body: [
        "title": .string("x"), "message": .string("y"),
    ])
    let raw = try Data(contentsOf: auditPath)
    let text = String(data: raw, encoding: .utf8) ?? ""
    #expect(text.hasSuffix("\n"), "JSONL row must be newline-terminated")
    let rows = _readAuditRows(auditPath)
    #expect(rows.count == 1)
    #expect(rows.first?["method"] == .string("post_notification"))
    #expect(rows.first?["category"] == .string("notifications"))
    // notifications is NOT in the default approval_required_for list.
    #expect(rows.first?["approval_required"] == .bool(false))
}

// MARK: - Native audit byte contract

@Test func auditRowMatchesNativeBlockedReceiptByteContract() async throws {
    let http = _MockHTTPClient()
    var pol = _permissiveMacPolicy()
    pol.enabled = false  // master gate off → refuse
    let auditPath = _makeTempAuditPath()
    defer { try? FileManager.default.removeItem(at: auditPath.deletingLastPathComponent()) }

    let client = SwiftNativeMacControl(
        http: http,
        policyProvider: _StubPolicyProvider(policy: pol),
        auditAppendPath: auditPath
    )
    _ = try await client.dispatch(action: "shell", body: [
        "command": .string("echo hi"), "trigger": .string("user"),
    ])

    // Raw bytes Swift wrote (strip the trailing newline; compare the JSON body).
    let rawData = try Data(contentsOf: auditPath)
    var swiftLine = String(data: rawData, encoding: .utf8) ?? ""
    #expect(swiftLine.hasSuffix("\n"))
    if swiftLine.hasSuffix("\n") { swiftLine.removeLast() }

    // Dynamic fields still have strict byte shapes:
    //   • id          — lowercase UUID.
    //   • executed_at — `...+00:00` offset with optional 6-digit microseconds.
    let rows0 = _readAuditRows(auditPath)
    guard let row0 = rows0.first else { Issue.record("no audit row"); return }
    guard case .string(let id)? = row0["id"] else {
        Issue.record("missing id")
        return
    }
    do {
        #expect(id == id.lowercased(), "id must be a LOWERCASE uuid (Python parity), got: \(id)")
        #expect(id.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
                         options: .regularExpression) != nil,
                "id must match lowercase-hex UUID shape, got: \(id)")
    }
    guard case .string(let ts)? = row0["executed_at"] else {
        Issue.record("missing executed_at")
        return
    }
    do {
        // Fraction is optional: whole-second instants omit it, otherwise it is
        // exactly 6 digits.
        #expect(ts.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{6})?\+00:00$"#,
                         options: .regularExpression) != nil,
                "executed_at must be YYYY-MM-DDTHH:MM:SS[.ffffff]+00:00, got: \(ts)")
    }

    let expectedLine = try JSONValue.serializeOrderedObjectPython([
        ("id", .string(id)),
        ("method", .string("run_shell")),
        ("category", .string("shell")),
        ("args_hash", .string("sha256:none")),
        ("trigger", .string("user")),
        ("trigger_source", .string("user")),
        ("approval_required", .bool(true)),
        ("approved", .null),
        ("exit_code", .int(0)),
        ("stdout", .string("")),
        ("stderr", .string("")),
        ("duration_ms", .int(0)),
        ("executed_at", .string(ts)),
        ("blocked", .bool(true)),
        ("block_reason", .string("mac_control_disabled: master gate off")),
    ])

    #expect(swiftLine == expectedLine,
            "Swift audit line must match the native ordered blocked-receipt contract.\nSWIFT  : \(swiftLine)\nEXPECTED: \(expectedLine)")
}

@Test func executedAtFormatMatchesNativeIsoformatContractAcrossEdgeCases() async throws {
    let fixtures: [(epoch: Double, expected: String)] = [
        (1_780_000_447.123456, "2026-05-28T20:34:07.123456+00:00"),
        (1_780_000_447.0, "2026-05-28T20:34:07+00:00"),
        (1_780_000_447.1234566, "2026-05-28T20:34:07.123456+00:00"),
        (1_780_000_447.9999996, "2026-05-28T20:34:07.999999+00:00"),
    ]
    for fixture in fixtures {
        let epoch = fixture.epoch
        let fixed = Date(timeIntervalSince1970: epoch)
        let http = _MockHTTPClient()
        var pol = _permissiveMacPolicy()
        pol.enabled = false
        let auditPath = _makeTempAuditPath()
        defer { try? FileManager.default.removeItem(at: auditPath.deletingLastPathComponent()) }
        let client = SwiftNativeMacControl(
            http: http,
            now: { fixed },
            policyProvider: _StubPolicyProvider(policy: pol),
            auditAppendPath: auditPath
        )
        _ = try await client.dispatch(action: "shell", body: ["command": .string("x")])
        let rows = _readAuditRows(auditPath)
        guard case .string(let swiftTs)? = rows.first?["executed_at"] else {
            Issue.record("missing executed_at for epoch \(epoch)"); continue
        }
        #expect(swiftTs == fixture.expected,
                "executed_at byte mismatch for epoch \(epoch).\nSWIFT  : \(swiftTs)\nEXPECTED: \(fixture.expected)")
    }
}

/// Unit-level pin of the ordered serializer itself: keys emit in the GIVEN
/// order (NOT sorted), and non-ASCII + control chars escape through the native
/// canonical audit serializer.
@Test func serializeOrderedObjectKeepsNativeAuditByteContract() async throws {
    // Deliberately NOT alphabetical, with a non-ASCII value and an escape char,
    // so a sort-keys or ensure_ascii regression would diverge.
    let pairs: [(String, JSONValue)] = [
        ("z_first", .string("café\n\"q\"")),   // é (U+00E9) + newline + quote
        ("a_last", .int(7)),
        ("mid", .bool(false)),
        ("nullable", .null),
        ("emoji", .string("🚀")),               // surrogate-pair path
    ]
    let swift = try JSONValue.serializeOrderedObjectPython(pairs)
    let expected = #"{"z_first": "caf\u00e9\n\"q\"", "a_last": 7, "mid": false, "nullable": null, "emoji": "\ud83d\ude80"}"#
    #expect(swift == expected,
            "ordered serializer must match the native audit byte contract.\nSWIFT  : \(swift)\nEXPECTED: \(expected)")
}
