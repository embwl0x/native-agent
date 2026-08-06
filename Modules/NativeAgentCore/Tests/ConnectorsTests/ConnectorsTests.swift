import Testing
import Foundation
@testable import Connectors
import NativeAgentCore
import PersistenceCore

// MARK: - Helpers

private func tempRoot() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("connectors-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Write the connectors/workspaces.json registry under `root`.
private func writeWorkspaces(_ root: URL, _ items: [JSONValue]) throws {
    let dir = root.appendingPathComponent("connectors")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = try JSONValue.array(items).serializedData(pretty: true)
    try data.write(to: dir.appendingPathComponent("workspaces.json"))
}

/// Build a workspace dir with files and return a workspace JSON row pointing at it.
@discardableResult
private func makeWorkspaceDir(name: String, files: [String: String]) throws -> (URL, JSONValue) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ws-\(name)-\(UUID().uuidString)")
    for (rel, contents) in files {
        let f = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: f)
    }
    let row: JSONValue = .object([
        "id": .string("ws-\(name)"),
        "name": .string(name),
        "path": .string(dir.path),
        "permissions": .array([.string("read")]),
        "createdAt": .string("2026-06-01T00:00:00+00:00"),
    ])
    return (dir, row)
}

private func stringField(_ v: JSONValue, _ key: String) -> String? {
    if case .object(let o) = v, case .string(let s)? = o[key] { return s }
    return nil
}

private func resultsOf(_ envelope: JSONValue?) -> [JSONValue] {
    guard case .object(let o)? = envelope, case .array(let r)? = o["results"] else { return [] }
    return r
}

// MARK: - listWorkspaces

@Test func listWorkspacesReturnsEmptyWhenMissing() async throws {
    let root = tempRoot()
    let client = SwiftNativeConnectorsClient(root: root)
    let rows = try await client.listWorkspaces()
    #expect(rows.isEmpty)
}

@Test func listWorkspacesPassthrough() async throws {
    let root = tempRoot()
    let row: JSONValue = .object([
        "id": .string("w1"),
        "name": .string("Docs"),
        "path": .string("/tmp/docs"),
        "permissions": .array([.string("read"), .string("write")]),
        "createdAt": .string("2026-06-01T00:00:00+00:00"),
        "lastUsedAt": .null,
    ])
    try writeWorkspaces(root, [row])
    let client = SwiftNativeConnectorsClient(root: root)
    let rows = try await client.listWorkspaces()
    #expect(rows.count == 1)
    #expect(stringField(rows[0], "id") == "w1")
    #expect(stringField(rows[0], "name") == "Docs")
}

@Test func listWorkspacesNonArrayBecomesEmpty() async throws {
    let root = tempRoot()
    // Write a non-array (object) to workspaces.json — Python coerces to [].
    let dir = root.appendingPathComponent("connectors")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{\"bogus\":true}".utf8).write(to: dir.appendingPathComponent("workspaces.json"))
    let client = SwiftNativeConnectorsClient(root: root)
    let rows = try await client.listWorkspaces()
    #expect(rows.isEmpty)
}

// MARK: - searchWorkspaces

@Test func searchEmptyQueryReturnsNil() async throws {
    let root = tempRoot()
    let client = SwiftNativeConnectorsClient(root: root)
    let r1 = try await client.searchWorkspaces(query: "")
    let r2 = try await client.searchWorkspaces(query: "   ")
    #expect(r1 == nil)
    #expect(r2 == nil)
}

@Test func searchFilenameMatch() async throws {
    let root = tempRoot()
    let (_, row) = try makeWorkspaceDir(name: "proj", files: [
        "AlphaNotes.txt": "unrelated body",
        "beta.md": "nothing here",
    ])
    try writeWorkspaces(root, [row])
    let client = SwiftNativeConnectorsClient(root: root)
    let env = try await client.searchWorkspaces(query: "alpha")
    let results = resultsOf(env)
    #expect(results.count == 1)
    #expect(stringField(results[0], "reason") == "filename")
    #expect(stringField(results[0], "relativePath") == "AlphaNotes.txt")
    #expect(stringField(env!, "query") == "alpha")
}

@Test func searchContentMatch() async throws {
    let root = tempRoot()
    let (_, row) = try makeWorkspaceDir(name: "proj", files: [
        "readme.txt": "this file mentions the SECRETWORD inside it",
    ])
    try writeWorkspaces(root, [row])
    let client = SwiftNativeConnectorsClient(root: root)
    let env = try await client.searchWorkspaces(query: "secretword")
    let results = resultsOf(env)
    #expect(results.count == 1)
    #expect(stringField(results[0], "reason") == "content")
}

@Test func searchSkipsExcludedDirs() async throws {
    let root = tempRoot()
    let (_, row) = try makeWorkspaceDir(name: "proj", files: [
        ".git/config": "needle inside git",
        "node_modules/pkg/index.js": "needle in node_modules",
        "__pycache__/x.pyc": "needle cached",
        ".build/out.o": "needle built",
        "real.txt": "the needle is here",
    ])
    try writeWorkspaces(root, [row])
    let client = SwiftNativeConnectorsClient(root: root)
    let env = try await client.searchWorkspaces(query: "needle")
    let results = resultsOf(env)
    // Only real.txt should match; the four files in excluded dirs are pruned.
    #expect(results.count == 1)
    #expect(stringField(results[0], "relativePath") == "real.txt")
}

@Test func searchResultCapAtFifty() async throws {
    let root = tempRoot()
    var files: [String: String] = [:]
    for i in 0..<120 { files["match_\(i).txt"] = "x" }  // all filename-match "match"
    let (_, row) = try makeWorkspaceDir(name: "big", files: files)
    try writeWorkspaces(root, [row])
    let client = SwiftNativeConnectorsClient(root: root)
    let env = try await client.searchWorkspaces(query: "match")
    let results = resultsOf(env)
    #expect(results.count == 50)
}

@Test func searchSkipsMissingWorkspaceDir() async throws {
    let root = tempRoot()
    let row: JSONValue = .object([
        "id": .string("gone"),
        "name": .string("Gone"),
        "path": .string("/tmp/does-not-exist-\(UUID().uuidString)"),
        "permissions": .array([.string("read")]),
        "createdAt": .string("2026-06-01T00:00:00+00:00"),
    ])
    try writeWorkspaces(root, [row])
    let client = SwiftNativeConnectorsClient(root: root)
    let env = try await client.searchWorkspaces(query: "anything")
    #expect(resultsOf(env).isEmpty)
    // Envelope is still well-formed (non-nil) for a non-empty query.
    #expect(env != nil)
}

@Test func searchSpansMultipleWorkspaces() async throws {
    // Regression for gpt-5.5 review #1: a non-results-cap stop in the first
    // workspace must NOT prevent later workspaces from being searched.
    let root = tempRoot()
    let (_, w1) = try makeWorkspaceDir(name: "first", files: [
        "doc.txt": "the needle is here",
    ])
    let (_, w2) = try makeWorkspaceDir(name: "second", files: [
        "other.txt": "another needle over here",
    ])
    try writeWorkspaces(root, [w1, w2])
    let client = SwiftNativeConnectorsClient(root: root)
    let env = try await client.searchWorkspaces(query: "needle")
    let results = resultsOf(env)
    #expect(results.count == 2)
    let wsIds = Set(results.compactMap { stringField($0, "path") })
    #expect(wsIds.count == 2)
}

@Test func searchMatchesFileNamedLikeSkipDir() async throws {
    // Regression for gpt-5.5 review #3: a REGULAR FILE literally named `.git`
    // (a directory name in the skip set) must still be searchable — os.walk
    // only prunes DIRECTORIES by name, not files.
    let root = tempRoot()
    let (_, row) = try makeWorkspaceDir(name: "proj", files: [
        ".git": "this is a file named like a skip dir, with the keyword token",
    ])
    try writeWorkspaces(root, [row])
    let client = SwiftNativeConnectorsClient(root: root)
    let env = try await client.searchWorkspaces(query: "keyword")
    let results = resultsOf(env)
    #expect(results.count == 1)
    #expect(stringField(results[0], "relativePath") == ".git")
}

// MARK: - Factory gating

@Test func factoryReturnsNative() async throws {
    let client = makeConnectorsClient(root: tempRoot())
    #expect(client is SwiftNativeConnectorsClient)
}

// MARK: - Activity-event parity (FLIP PREREQ — wave 32 W20)

/// Read every JSONL row from <root>/activity/events.jsonl.
private func readActivity(_ root: URL) -> [JSONValue] {
    let path = root.appendingPathComponent("activity/events.jsonl")
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
        try? JSONValue.parse(Data($0.utf8))
    }
}

private func intField(_ v: JSONValue, _ path: [String]) -> Int64? {
    var cur = v
    for key in path {
        guard case .object(let o) = cur, let next = o[key] else { return nil }
        cur = next
    }
    if case .int(let i) = cur { return i }
    return nil
}

@Test func searchAppendsActivityEventWithExactEnvelope() async throws {
    let root = tempRoot()
    let (_, row) = try makeWorkspaceDir(name: "proj", files: [
        "AlphaNotes.txt": "body",
        "beta.md": "alpha appears in content too",
    ])
    try writeWorkspaces(root, [row])
    let client = SwiftNativeConnectorsClient(
        root: root,
        now: { Date(timeIntervalSince1970: 0) },
        activityIDFactory: { "fixed-id-001" }
    )
    let env = try await client.searchWorkspaces(query: "alpha")
    // Two matches: filename (AlphaNotes.txt) + content (beta.md).
    #expect(resultsOf(env).count == 2)

    let rows = readActivity(root)
    #expect(rows.count == 1)
    let ev = rows[0]
    #expect(stringField(ev, "id") == "fixed-id-001")
    #expect(stringField(ev, "kind") == "connector")
    #expect(stringField(ev, "title") == "Workspace search")
    #expect(stringField(ev, "detail") == "alpha")  // query, lowercased upstream
    #expect(stringField(ev, "status") == "ok")
    // missionId is JSON null.
    if case .object(let o) = ev { #expect(o["executionId"] == .null) }
    #expect(intField(ev, ["payload", "resultCount"]) == 2)
    // createdAt is ISO-8601 UTC with +00:00 offset.
    #expect(stringField(ev, "createdAt")?.hasSuffix("+00:00") == true)
}

@Test func searchActivityDetailRedactsCredential() async throws {
    // Security wiring proof: a query that contains a credential-shaped token
    // must be redacted in the durable activity detail (mirrors the daemon's
    // redact_secret_text on record_activity title/detail). The query is
    // lowercased upstream; the GitHub pattern matches lowercase `ghp_...`.
    let root = tempRoot()
    try writeWorkspaces(root, [])  // no workspaces → empty results, append still fires
    let client = SwiftNativeConnectorsClient(
        root: root,
        activityIDFactory: { "redact-id" }
    )
    // 40-char ghp_ token (well over the {20,} minimum), already lowercase.
    let token = "ghp_" + String(repeating: "a", count: 36)
    let env = try await client.searchWorkspaces(query: token)
    #expect(env != nil)

    let rows = readActivity(root)
    #expect(rows.count == 1)
    let detail = stringField(rows[0], "detail") ?? ""
    #expect(!detail.contains(token))               // raw secret must be gone
    #expect(detail.hasPrefix("[REDACTED_GITHUB_TOKEN:"))
    #expect(detail.hasSuffix("]"))
}

@Test func searchAppendsActivityEvenWhenNoResults() async throws {
    // The daemon calls record_activity unconditionally at the tail of
    // search_workspaces, so an empty-result search still appends resultCount=0.
    let root = tempRoot()
    let row: JSONValue = .object([
        "id": .string("gone"),
        "name": .string("Gone"),
        "path": .string("/tmp/does-not-exist-\(UUID().uuidString)"),
        "permissions": .array([.string("read")]),
        "createdAt": .string("2026-06-01T00:00:00+00:00"),
    ])
    try writeWorkspaces(root, [row])
    let client = SwiftNativeConnectorsClient(root: root, activityIDFactory: { "empty-id" })
    _ = try await client.searchWorkspaces(query: "nomatch")
    let rows = readActivity(root)
    #expect(rows.count == 1)
    #expect(intField(rows[0], ["payload", "resultCount"]) == 0)
    #expect(stringField(rows[0], "detail") == "nomatch")
}

@Test func emptyQueryDoesNotAppendActivity() async throws {
    // Empty/whitespace query returns nil (falls through to HTTP) WITHOUT
    // appending — the daemon raises before record_activity, so the native
    // path must not emit a row.
    let root = tempRoot()
    let client = SwiftNativeConnectorsClient(root: root)
    let r1 = try await client.searchWorkspaces(query: "")
    let r2 = try await client.searchWorkspaces(query: "   ")
    #expect(r1 == nil)
    #expect(r2 == nil)
    #expect(readActivity(root).isEmpty)
}

@Test func secretRedactorRedactsKnownPatterns() async throws {
    // Direct unit coverage of the ported regex table (parity with
    // _SECRET_TEXT_PATTERNS). Each token is well over its {N,} minimum.
    //
    // NOTE on label precedence (verified empirically against the daemon):
    // patterns apply IN ORDER, and OPENAI_KEY (`sk-(?:proj-)?[A-Za-z0-9_-]{20,}`)
    // is listed BEFORE ANTHROPIC_KEY (`sk-ant-...`). So an `sk-ant-...` token is
    // labeled OPENAI_KEY by BOTH the daemon and this port — they shadow-collide,
    // which is faithful behavior, not a port bug. The Anthropic pattern is only
    // reachable for tokens the OpenAI pattern can't match (e.g. shorter bodies),
    // none of which are valid anthropic keys, so ANTHROPIC_KEY is effectively
    // dead in the daemon too. We assert the parity-correct labels below.
    let samples: [(String, String)] = [
        ("sk-ant-" + String(repeating: "x", count: 30), "OPENAI_KEY"),  // shadowed by OPENAI (parity)
        ("ghp_" + String(repeating: "a", count: 30), "GITHUB_TOKEN"),
        ("xoxb-" + String(repeating: "1", count: 24), "SLACK_TOKEN"),
        ("AIza" + String(repeating: "Z", count: 30), "GOOGLE_API_KEY"),
        ("sk_live_" + String(repeating: "9", count: 20), "STRIPE_KEY"),
    ]
    for (token, kind) in samples {
        let out = SecretRedactor.redactText("prefix \(token) suffix")
        #expect(!out.contains(token), "token \(kind) leaked: \(out)")
        #expect(out.contains("[REDACTED_\(kind):"), "missing label \(kind): \(out)")
        #expect(out.hasPrefix("prefix [REDACTED_\(kind):"))
        #expect(out.hasSuffix("] suffix"))
    }
    // Byte-for-byte digest parity with the daemon: sk-ant-x*30 → the daemon
    // produces exactly this digest (verified via the daemon's redact_secret_text).
    let antTok = "sk-ant-" + String(repeating: "x", count: 30)
    #expect(SecretRedactor.redactText(antTok) == "[REDACTED_OPENAI_KEY:8d46870a2cd9]")
    // Non-secret text passes through untouched.
    #expect(SecretRedactor.redactText("just a normal sentence") == "just a normal sentence")
    // Numbers/bools/null in a value are untouched; nested strings are redacted.
    let v: JSONValue = .object([
        "n": .int(5),
        "b": .bool(true),
        "s": .string("tok sk-ant-" + String(repeating: "q", count: 30)),
    ])
    let red = SecretRedactor.redactValue(v)
    if case .object(let o) = red {
        #expect(o["n"] == .int(5))
        #expect(o["b"] == .bool(true))
        if case .string(let s)? = o["s"] { #expect(s.contains("[REDACTED_OPENAI_KEY:")) }
    }
}

// MARK: - Connector OAuth "clear" (REVOKE) WRITE port (wave 35 W06 §6.117)

/// Write `<root>/oauth_tokens/<provider>.json` with a 0600 token, matching
/// OAuthManager.save_token's on-disk shape.
private func writeToken(_ root: URL, _ provider: String) throws -> URL {
    let dir = root.appendingPathComponent("oauth_tokens")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("\(provider).json")
    let payload: JSONValue = .object([
        "provider": .string(provider),
        "access_token": .string("tok-xyz"),
        "scope": .string("read"),
        "token_type": .string("bearer"),
        "saved_at": .string("2026-06-02T00:00:00+00:00"),
    ])
    try payload.serializedData(pretty: true).write(to: path)
    return path
}

/// Write `<root>/connectors/registry.json`.
private func writeRegistry(_ root: URL, _ items: [JSONValue]) throws -> URL {
    let dir = root.appendingPathComponent("connectors")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("registry.json")
    try JSONValue.array(items).serializedData(pretty: true).write(to: path)
    return path
}

private func readRegistry(_ root: URL) throws -> [JSONValue] {
    let path = root.appendingPathComponent("connectors/registry.json")
    let data = try Data(contentsOf: path)
    if case .array(let arr) = try JSONValue.parse(data) { return arr }
    return []
}

private func recordById(_ rows: [JSONValue], _ id: String) -> [String: JSONValue]? {
    for r in rows {
        if case .object(let o) = r, case .string(let rid)? = o["id"], rid == id { return o }
    }
    return nil
}

@Test func revokeUnlinksTokenAndWritesRegistryRecord() async throws {
    let root = tempRoot()
    let tok = try writeToken(root, "github")
    _ = try writeRegistry(root, [
        .object([
            "id": .string("github"),
            "name": .string("GitHub"),
            "enabled": .bool(true),
            "authState": .string("connected"),
            "healthStatus": .string("ok"),
        ]),
        .object([
            "id": .string("slack"),
            "name": .string("Slack"),
            "enabled": .bool(true),
            "authState": .string("connected"),
            "healthStatus": .string("ok"),
        ]),
    ])
    #expect(FileManager.default.fileExists(atPath: tok.path))

    let client = SwiftNativeConnectorAuthClient(root: root)
    let body = try await client.revokeConnector(provider: "github")

    // Return body parity with connector_revoke.
    #expect(body == .object([
        "ok": .bool(true),
        "provider": .string("github"),
        "revoked": .bool(true),
    ]))

    // Token file unlinked.
    #expect(!FileManager.default.fileExists(atPath: tok.path))

    // The github record flipped to the daemon's revoke state.
    let rows = try readRegistry(root)
    let gh = recordById(rows, "github")
    #expect(gh?["enabled"] == .bool(false))
    #expect(gh?["authState"] == .string("not_connected"))
    #expect(gh?["healthStatus"] == .string("planned"))

    // The non-target record (slack) is untouched.
    let sl = recordById(rows, "slack")
    #expect(sl?["enabled"] == .bool(true))
    #expect(sl?["authState"] == .string("connected"))
    #expect(sl?["healthStatus"] == .string("ok"))
}

@Test func revokeIsNoOpUnlinkWhenTokenMissing() async throws {
    // Daemon: `if path.exists(): path.unlink()` — a missing token is a no-op.
    let root = tempRoot()
    _ = try writeRegistry(root, [
        .object([
            "id": .string("notion"),
            "enabled": .bool(true),
            "authState": .string("connected"),
            "healthStatus": .string("ok"),
        ]),
    ])
    let client = SwiftNativeConnectorAuthClient(root: root)
    let body = try await client.revokeConnector(provider: "notion")
    #expect(body == .object([
        "ok": .bool(true),
        "provider": .string("notion"),
        "revoked": .bool(true),
    ]))
    let notion = recordById(try readRegistry(root), "notion")
    #expect(notion?["enabled"] == .bool(false))
    #expect(notion?["authState"] == .string("not_connected"))
}

@Test func revokeUnknownProviderUnlinksTokenLeavesRegistryShape() async throws {
    // Daemon: the registry loop matches `str(c.get("id")) == provider`; an
    // unknown provider mutates no record but still unlinks any token file +
    // returns the revoked envelope. (default_connectors re-derivation on the
    // next list_connectors is the daemon's job — not this record-only write.)
    let root = tempRoot()
    let tok = try writeToken(root, "x")
    _ = try writeRegistry(root, [
        .object(["id": .string("github"), "enabled": .bool(true)]),
    ])
    let client = SwiftNativeConnectorAuthClient(root: root)
    let body = try await client.revokeConnector(provider: "x")
    #expect(body == .object([
        "ok": .bool(true),
        "provider": .string("x"),
        "revoked": .bool(true),
    ]))
    #expect(!FileManager.default.fileExists(atPath: tok.path))
    // github record untouched (no id match for "x").
    #expect(recordById(try readRegistry(root), "github")?["enabled"] == .bool(true))
}

@Test func revokeWritesRegistryWhenMissingFileTreatedAsEmpty() async throws {
    // read_json(connectors_path, []) → []; no record to mutate; an empty array
    // is written back. The unlink still runs. No crash on a missing registry.
    let root = tempRoot()
    let tok = try writeToken(root, "email")
    let client = SwiftNativeConnectorAuthClient(root: root)
    _ = try await client.revokeConnector(provider: "email")
    #expect(!FileManager.default.fileExists(atPath: tok.path))
    let rows = try readRegistry(root)
    #expect(rows.isEmpty)
}

@Test func revokeSwallowsRegistryWriteFailureAfterTokenUnlink() async throws {
    // FAILURE PARITY (gpt-5.5 review #1): the daemon wraps the registry update
    // in `try/except: pass` and STILL returns {ok, provider, revoked} even if
    // the registry write fails — the token is already gone (revoke succeeded)
    // and the next list_connectors() re-derives not_connected from the absent
    // token. We simulate a registry-write failure by making registry.json a
    // DIRECTORY (so the atomic-replace can't write a file there) and assert the
    // revoke still unlinks the token AND returns the success envelope.
    let root = tempRoot()
    let tok = try writeToken(root, "github")
    // registry.json is a directory -> writeJSON's atomic replace fails.
    let regDir = root.appendingPathComponent("connectors/registry.json")
    try FileManager.default.createDirectory(at: regDir, withIntermediateDirectories: true)

    let client = SwiftNativeConnectorAuthClient(root: root)
    let body = try await client.revokeConnector(provider: "github")

    // Token unlinked (the load-bearing mutation succeeded).
    #expect(!FileManager.default.fileExists(atPath: tok.path))
    // Success envelope returned despite the registry-write failure (daemon parity).
    #expect(body == .object([
        "ok": .bool(true),
        "provider": .string("github"),
        "revoked": .bool(true),
    ]))
}

// MARK: - Connector OAuth connect-success (SAVE) WRITE port (wave 36 W03 §6.137 #3)

@Test func connectFlipsRegistryRecordToConnected() async throws {
    let root = tempRoot()
    // wave 37 W02 §6.159: the connect-success registry write is the structural
    // tail of a successful save_token, so the token must already be persisted
    // (the daemon's poll thread / handle_authcode_callback save it before the
    // registry write). Stage the token so the SAVE-TOKEN gate is satisfied.
    _ = try writeToken(root, "github")
    _ = try writeRegistry(root, [
        .object([
            "id": .string("github"),
            "name": .string("GitHub"),
            "enabled": .bool(false),
            "authState": .string("not_connected"),
            "healthStatus": .string("planned"),
        ]),
        .object([
            "id": .string("slack"),
            "name": .string("Slack"),
            "enabled": .bool(false),
            "authState": .string("not_connected"),
            "healthStatus": .string("planned"),
        ]),
    ])

    let client = SwiftNativeConnectorAuthClient(root: root)
    let body = try await client.connectConnector(provider: "github")

    // Return body parity with handle_authcode_callback.
    #expect(body == .object([
        "provider": .string("github"),
        "authorized": .bool(true),
        "message": .string("github connected successfully."),
    ]))

    // The github record flipped to the daemon's connect-success state.
    let rows = try readRegistry(root)
    let gh = recordById(rows, "github")
    #expect(gh?["enabled"] == .bool(true))
    #expect(gh?["authState"] == .string("connected"))
    #expect(gh?["healthStatus"] == .string("ok"))

    // The non-target record (slack) is untouched.
    let sl = recordById(rows, "slack")
    #expect(sl?["enabled"] == .bool(false))
    #expect(sl?["authState"] == .string("not_connected"))
    #expect(sl?["healthStatus"] == .string("planned"))
}

@Test func connectDoesNotWriteAnyOtherTokenFile() async throws {
    // The connect SAVE port is REGISTRY-ONLY: the save_token access-token write is
    // the daemon-internal tail of the OAuth network exchange and is NOT reproduced
    // here. wave 37 W02 §6.159: the SAVE-TOKEN gate requires the provider's own
    // token to already exist (staged here), so assert connectConnector leaves that
    // token UNCHANGED and creates no token for a DIFFERENT provider.
    let root = tempRoot()
    _ = try writeToken(root, "notion")
    _ = try writeRegistry(root, [
        .object(["id": .string("notion"), "enabled": .bool(false)]),
    ])
    let client = SwiftNativeConnectorAuthClient(root: root)
    _ = try await client.connectConnector(provider: "notion")
    // No token fabricated for a non-target provider.
    let otherTok = root.appendingPathComponent("oauth_tokens/slack.json")
    #expect(!FileManager.default.fileExists(atPath: otherTok.path))
    // The notion token (the gate's precondition) is left in place by connect.
    let notionTok = root.appendingPathComponent("oauth_tokens/notion.json")
    #expect(FileManager.default.fileExists(atPath: notionTok.path))
}

@Test func connectRejectsUnknownProvider() async throws {
    // wave 37 W02 §6.159 — UNKNOWN-PROVIDER REJECT. The daemon `raise ValueError`
    // for any provider outside {github,email,calendar,notion,slack,x} BEFORE any
    // registry write (start_connector_connect / handle_authcode_callback). The
    // port mirrors that: an unknown provider THROWS unknownProvider, mutates NO
    // record, and returns NO fake-success envelope — even if a token file happens
    // to exist for it.
    let root = tempRoot()
    _ = try writeToken(root, "dropbox") // a token alone must not authorize an unknown provider
    _ = try writeRegistry(root, [
        .object(["id": .string("github"), "enabled": .bool(false)]),
        .object(["id": .string("dropbox"), "enabled": .bool(false)]),
    ])
    let client = SwiftNativeConnectorAuthClient(root: root)
    await #expect(throws: ConnectorAuthError.unknownProvider("dropbox")) {
        _ = try await client.connectConnector(provider: "dropbox")
    }
    // No record mutated — neither the unknown one nor any other.
    #expect(recordById(try readRegistry(root), "dropbox")?["enabled"] == .bool(false))
    #expect(recordById(try readRegistry(root), "github")?["enabled"] == .bool(false))
}

@Test func connectRejectsKnownProviderWithNoSavedToken() async throws {
    // wave 37 W02 §6.159 — SAVE-TOKEN GATE. The daemon's connect-success registry
    // write is the structural tail of a successful save_token; it is never reached
    // without a saved token. A KNOWN provider with NO token at
    // oauth_tokens/<provider>.json must THROW tokenNotSaved, mutate NO record, and
    // return NO fake-success — this is the FAKE-SUCCESS / HALF-STATE bug this wave
    // fixes (previously it wrote enabled=true with no token behind it).
    let root = tempRoot()
    _ = try writeRegistry(root, [
        .object([
            "id": .string("github"),
            "enabled": .bool(false),
            "authState": .string("not_connected"),
            "healthStatus": .string("planned"),
        ]),
    ])
    let client = SwiftNativeConnectorAuthClient(root: root)
    await #expect(throws: ConnectorAuthError.tokenNotSaved("github")) {
        _ = try await client.connectConnector(provider: "github")
    }
    // The record was NOT flipped to connected — no half-state left behind.
    let gh = recordById(try readRegistry(root), "github")
    #expect(gh?["enabled"] == .bool(false))
    #expect(gh?["authState"] == .string("not_connected"))
    #expect(gh?["healthStatus"] == .string("planned"))
}

@Test func connectRejectsMalformedOrEmptyCanonicalTokenFile() async throws {
    let root = tempRoot()
    let authPath = root.appendingPathComponent("connectors/notion/auth.json")
    try FileManager.default.createDirectory(
        at: authPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: authPath)
    _ = try writeRegistry(root, [
        .object([
            "id": .string("notion"),
            "enabled": .bool(false),
            "authState": .string("not_connected"),
            "healthStatus": .string("needs_auth"),
        ]),
    ])

    let client = SwiftNativeConnectorAuthClient(root: root)
    await #expect(throws: ConnectorAuthError.tokenNotSaved("notion")) {
        _ = try await client.connectConnector(provider: "notion")
    }
    let notion = recordById(try readRegistry(root), "notion")
    #expect(notion?["enabled"] == .bool(false))
    #expect(notion?["authState"] == .string("not_connected"))
}

@Test func connectWritesRegistryWhenMissingFileTreatedAsEmpty() async throws {
    // read_json(connectors_path, []) -> []; no record to mutate; an empty array is
    // written back. No crash on a missing registry. wave 37 W02 §6.159: stage the
    // token so the SAVE-TOKEN gate is satisfied; the missing-registry path is the
    // thing under test.
    let root = tempRoot()
    _ = try writeToken(root, "email")
    let client = SwiftNativeConnectorAuthClient(root: root)
    _ = try await client.connectConnector(provider: "email")
    #expect(try readRegistry(root).isEmpty)
}

@Test func connectSwallowsRegistryWriteFailure() async throws {
    // FAILURE PARITY: the daemon wraps the connect-success registry write in
    // `try/except: pass` and STILL reports a
    // successful connect even if the write fails. We simulate a write failure by
    // making registry.json a DIRECTORY and assert connectConnector still returns
    // the success envelope (daemon parity — the token is already saved by the
    // network tail; the next list_connectors() re-derives connected).
    // wave 37 W02 §6.159: the token gate runs BEFORE the swallowed RMW, so stage
    // the token; the swallow path is the thing under test.
    let root = tempRoot()
    _ = try writeToken(root, "github")
    let regDir = root.appendingPathComponent("connectors/registry.json")
    try FileManager.default.createDirectory(at: regDir, withIntermediateDirectories: true)
    let client = SwiftNativeConnectorAuthClient(root: root)
    let body = try await client.connectConnector(provider: "github")
    #expect(body == .object([
        "provider": .string("github"),
        "authorized": .bool(true),
        "message": .string("github connected successfully."),
    ]))
}

/// Connect/revoke are EXACT mirror-images on the same record: revoke writes the
/// not_connected/planned/false triple, connect writes the connected/ok/true
/// triple. Round-trip a single record through both to pin the symmetry.
@Test func connectThenRevokeRoundTripsRegistryState() async throws {
    let root = tempRoot()
    let tok = try writeToken(root, "github")
    _ = try writeRegistry(root, [
        .object(["id": .string("github"), "enabled": .bool(false),
                 "authState": .string("not_connected"), "healthStatus": .string("planned")]),
    ])
    let client = SwiftNativeConnectorAuthClient(root: root)

    _ = try await client.connectConnector(provider: "github")
    var gh = recordById(try readRegistry(root), "github")
    #expect(gh?["enabled"] == .bool(true))
    #expect(gh?["authState"] == .string("connected"))
    #expect(gh?["healthStatus"] == .string("ok"))

    _ = try await client.revokeConnector(provider: "github")
    gh = recordById(try readRegistry(root), "github")
    #expect(gh?["enabled"] == .bool(false))
    #expect(gh?["authState"] == .string("not_connected"))
    #expect(gh?["healthStatus"] == .string("planned"))
    // Revoke also unlinked the token; connect never wrote one back.
    #expect(!FileManager.default.fileExists(atPath: tok.path))
}

@Test func connectorAuthFactoryReturnsNative() async throws {
    let client = makeConnectorAuthClient(root: tempRoot())
    #expect(client is SwiftNativeConnectorAuthClient)
}
