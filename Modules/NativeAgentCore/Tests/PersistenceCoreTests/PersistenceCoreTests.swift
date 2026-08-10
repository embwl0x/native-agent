import Testing
import Foundation
@testable import PersistenceCore
import NativeAgentCore

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersistenceCoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The canonical fixture exercising every JSON shape we care about.
private func fixtureValue() -> JSONValue {
    return .object([
        "alpha": .int(1),
        "beta": .double(2.5),
        "gamma": .bool(true),
        "delta": .bool(false),
        "epsilon": .null,
        "empty_obj": .object([:]),
        "empty_arr": .array([]),
        "strings": .object([
            "ascii": .string("hello"),
            "quotes": .string("a\"b\\c"),
            "control": .string("tab\there\nnewline"),
            // Use explicit scalars to dodge editor-level NFC/NFD ambiguity.
            "latin": .string("na\u{00EF}ve"),
            "cjk": .string("\u{65E5}\u{672C}\u{8A9E}"),
        ]),
        "nested": .array([
            .object(["k": .string("v")]),
            .array([.int(1), .int(2), .int(3)]),
            .double(0.1),
            .double(1.0),
        ]),
    ])
}

// MARK: - Factory

@Test func factoryAlwaysReturnsSwiftNative() async throws {
    #expect(makePersistenceCore() is SwiftNativePersistenceCore)
}

// MARK: - Canonical JSON / JSONL

@Test func swiftWriteJSON_writesCanonicalPrettyBytes() async throws {
    let dir = try makeTempDir()
    let swiftPath = dir.appendingPathComponent("swift.json")
    let core = SwiftNativePersistenceCore()
    try await core.writeJSON(fixtureValue(), to: swiftPath)
    let actual = try Data(contentsOf: swiftPath)
    let expected = try fixtureValue().serializedData(pretty: true)
    #expect(actual == expected)
    #expect(try JSONValue.parse(actual) == fixtureValue())
}

@Test func canonicalJSON_readableBySwift() async throws {
    let dir = try makeTempDir()
    let path = dir.appendingPathComponent("canonical.json")
    try fixtureValue().serializedData(pretty: true).write(to: path)
    let core = SwiftNativePersistenceCore()
    let read = await core.readJSON(path, defaultValue: .null)
    #expect(read == fixtureValue())
}

@Test func swiftWriteJSON_roundTripsThroughSwiftParser() async throws {
    let dir = try makeTempDir()
    let swiftPath = dir.appendingPathComponent("swift.json")
    let core = SwiftNativePersistenceCore()
    try await core.writeJSON(fixtureValue(), to: swiftPath)
    let swiftBytes = try Data(contentsOf: swiftPath)
    let expectedBytes = try fixtureValue().serializedData(pretty: true)
    #expect(try JSONValue.parse(swiftBytes) == fixtureValue())
    #expect(swiftBytes == expectedBytes)
}

@Test func swiftAppendJSONL_5records_tail3() async throws {
    let dir = try makeTempDir()
    let path = dir.appendingPathComponent("events.jsonl")
    let core = SwiftNativePersistenceCore()
    for i in 1...5 {
        try await core.appendJSONL(.object(["i": .int(Int64(i)), "kind": .string("event")]),
                                   to: path)
    }
    let parsed = try await core.tailJSONL(path, limit: 3, maxBytes: nil)
    let expected: JSONValue = .array([
        .object(["i": .int(3), "kind": .string("event")]),
        .object(["i": .int(4), "kind": .string("event")]),
        .object(["i": .int(5), "kind": .string("event")]),
    ])
    #expect(.array(parsed) == expected)
}

@Test func canonicalJSONL_5records_swiftRead() async throws {
    let dir = try makeTempDir()
    let path = dir.appendingPathComponent("events.jsonl")
    var data = Data()
    for i in 1...5 {
        var line = try JSONValue.object([
            "i": .int(Int64(i)),
            "kind": .string("event"),
        ]).serialize(pretty: false)
        line.append("\n")
        data.append(Data(line.utf8))
    }
    try data.write(to: path)
    let core = SwiftNativePersistenceCore()
    let all = try await core.readJSONL(path)
    #expect(all.count == 5)
    for i in 1...5 {
        #expect(all[i - 1] == .object(["i": .int(Int64(i)), "kind": .string("event")]))
    }
}

@Test func appendJSONL_writesCanonicalLine() async throws {
    let dir = try makeTempDir()
    let swiftPath = dir.appendingPathComponent("s.jsonl")
    let record: JSONValue = .object([
        "z": .int(1),
        "a": .string("na\u{00EF}ve"),
        "m": .array([.int(1), .int(2)]),
    ])
    let core = SwiftNativePersistenceCore()
    try await core.appendJSONL(record, to: swiftPath)
    let actual = try Data(contentsOf: swiftPath)
    let expected = Data((try record.serialize(pretty: false) + "\n").utf8)
    #expect(actual == expected)
}

// MARK: - Atomic write

@Test func concurrentWrites_neverGarbage() async throws {
    let dir = try makeTempDir()
    let path = dir.appendingPathComponent("hot.json")
    let core = SwiftNativePersistenceCore()
    let candidates: [JSONValue] = (0..<4).map { idx in
        .object(["who": .int(Int64(idx)), "payload": .string(String(repeating: "x", count: 1000))])
    }
    // Seed so the reader has something to find on its first poll.
    try await core.writeJSON(candidates[0], to: path)

    let writers: [Task<Void, Error>] = (0..<4).map { idx in
        Task {
            for _ in 0..<25 {
                try await core.writeJSON(candidates[idx], to: path)
            }
        }
    }
    let reader = Task<Int, Error> {
        var ok = 0
        for _ in 0..<200 {
            guard let data = try? Data(contentsOf: path) else { continue }
            guard let parsed = try? JSONValue.parse(data) else {
                Issue.record("reader saw a corrupt file mid-storm")
                return ok
            }
            if !candidates.contains(parsed) {
                Issue.record("reader saw an unknown JSONValue: \(parsed)")
                return ok
            }
            ok += 1
            try await Task.sleep(nanoseconds: 200_000)
        }
        return ok
    }
    for w in writers { try await w.value }
    _ = try await reader.value
}

@Test func noStaleTmpFiles() async throws {
    let dir = try makeTempDir()
    let path = dir.appendingPathComponent("ok.json")
    let core = SwiftNativePersistenceCore()
    for i in 0..<20 {
        try await core.writeJSON(.object(["i": .int(Int64(i))]), to: path)
    }
    let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let stale = contents.filter { $0.hasSuffix(".tmp") }
    #expect(stale.isEmpty, "leftover tmp files: \(stale)")
}

@Test func fileMode0600() async throws {
    let dir = try makeTempDir()
    let path = dir.appendingPathComponent("perm.json")
    let core = SwiftNativePersistenceCore()
    try await core.writeJSON(.object(["k": .string("v")]), to: path)
    let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
    let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
    #expect((perms & 0o777) == 0o600, "expected 0o600, got \(String(perms, radix: 8))")
}

// MARK: - Failure modes

@Test func readMissingFile_returnsDefault() async throws {
    let dir = try makeTempDir()
    let path = dir.appendingPathComponent("nope.json")
    let core = SwiftNativePersistenceCore()
    let v = await core.readJSON(path, defaultValue: .object(["sentinel": .bool(true)]))
    #expect(v == .object(["sentinel": .bool(true)]))
}

@Test func readMalformedFile_returnsDefault() async throws {
    let dir = try makeTempDir()
    let path = dir.appendingPathComponent("bad.json")
    try "{ not actually json".data(using: .utf8)!.write(to: path)
    let core = SwiftNativePersistenceCore()
    let v = await core.readJSON(path, defaultValue: .int(42))
    #expect(v == .int(42))
}

@Test func readJSONL_skipsMalformed() async throws {
    let dir = try makeTempDir()
    let path = dir.appendingPathComponent("mixed.jsonl")
    let text = "{\"i\": 1}\n{\"i\": 2}\nnot-json-at-all\n{\"i\": 3}\n"
    try text.data(using: .utf8)!.write(to: path)
    let core = SwiftNativePersistenceCore()
    let all = try await core.readJSONL(path)
    #expect(all.count == 3)
    #expect(all[0] == .object(["i": .int(1)]))
    #expect(all[1] == .object(["i": .int(2)]))
    #expect(all[2] == .object(["i": .int(3)]))
}

@Test func writeJSON_createsParentDir() async throws {
    let dir = try makeTempDir()
    let nested = dir.appendingPathComponent("a/b/c/file.json")
    let core = SwiftNativePersistenceCore()
    try await core.writeJSON(.string("ok"), to: nested)
    #expect(FileManager.default.fileExists(atPath: nested.path))
}

@Test func tailJSONL_emptyFile_returnsEmpty() async throws {
    let dir = try makeTempDir()
    let path = dir.appendingPathComponent("empty.jsonl")
    FileManager.default.createFile(atPath: path.path, contents: Data())
    let core = SwiftNativePersistenceCore()
    let v = try await core.tailJSONL(path)
    #expect(v.isEmpty)
}

@Test func tailJSONL_missingFile_returnsEmpty() async throws {
    let dir = try makeTempDir()
    let path = dir.appendingPathComponent("nope.jsonl")
    let core = SwiftNativePersistenceCore()
    let v = try await core.tailJSONL(path)
    #expect(v.isEmpty)
}

// MARK: - Concurrency / Sendable

@Test func sharedAcrossTasks() async throws {
    let dir = try makeTempDir()
    let core = SwiftNativePersistenceCore()
    let pathA = dir.appendingPathComponent("a.json")
    let pathB = dir.appendingPathComponent("b.json")
    async let a: Void = core.writeJSON(.string("A"), to: pathA)
    async let b: Void = core.writeJSON(.string("B"), to: pathB)
    _ = try await (a, b)
    let ra = await core.readJSON(pathA, defaultValue: .null)
    let rb = await core.readJSON(pathB, defaultValue: .null)
    #expect(ra == .string("A"))
    #expect(rb == .string("B"))
}

// MARK: - Edge cases

@Test func writeJSON_rejectsNaN() async throws {
    let dir = try makeTempDir()
    let path = dir.appendingPathComponent("nan.json")
    let core = SwiftNativePersistenceCore()
    do {
        try await core.writeJSON(.double(.nan), to: path)
        Issue.record("expected NaN to throw")
    } catch PersistenceCoreError.nonFiniteFloat {
        // expected
    }
}

@Test func writeJSON_rejectsInfinity() async throws {
    let dir = try makeTempDir()
    let path = dir.appendingPathComponent("inf.json")
    let core = SwiftNativePersistenceCore()
    do {
        try await core.writeJSON(.double(.infinity), to: path)
        Issue.record("expected Infinity to throw")
    } catch PersistenceCoreError.nonFiniteFloat {
        // expected
    }
}

// MARK: - Cross-language compatibility fixes

/// Fix 1 (read side): tolerate bare NaN/Infinity/-Infinity tokens from older
/// JSON writers; Swift converts them to null and leaves the same tokens INSIDE
/// string literals untouched.
@Test func bareNonFiniteTokens_readAsNull_butStringTokenPreserved() async throws {
    let dir = try makeTempDir()
    let path = dir.appendingPathComponent("nan.json")
    let raw = #"{"x": NaN, "y": Infinity, "z": -Infinity, "name": "NaN", "also": "has Infinity inside"}"#
    try Data(raw.utf8).write(to: path)
    let core = SwiftNativePersistenceCore()
    let v = await core.readJSON(path, defaultValue: .null)
    let expected: JSONValue = .object([
        "x": .null,
        "y": .null,
        "z": .null,
        "name": .string("NaN"),
        "also": .string("has Infinity inside"),
    ])
    #expect(v == expected)
}

/// Fix 1 (write side): non-finite Doubles throw with the path identified.
@Test func writeJSON_rejectsNaN_identifiesPath() async throws {
    let dir = try makeTempDir()
    let path = dir.appendingPathComponent("deep.json")
    let core = SwiftNativePersistenceCore()
    let value: JSONValue = .object([
        "a": .object([
            "b": .array([.int(1), .double(.nan), .int(3)])
        ])
    ])
    do {
        try await core.writeJSON(value, to: path)
        Issue.record("expected non-finite Double to throw")
    } catch PersistenceCoreError.nonFiniteFloat(_, let badPath) {
        #expect(badPath == "a.b[1]", "got path: \(badPath)")
    }
    // Also: written file must not exist (write was aborted).
    #expect(!FileManager.default.fileExists(atPath: path.path))
}

/// Fix 2: non-ASCII key sort order must use UTF-8 byte order, with
/// ensure-ASCII escaping in the emitted bytes.
@Test func nonAsciiKeySort_usesUTF8ByteOrder() async throws {
    let dir = try makeTempDir()
    let swiftPath = dir.appendingPathComponent("s.json")
    let value: JSONValue = .object([
        "\u{00E9}": .int(1),      // é
        "\u{00F1}": .int(2),      // ñ
        "\u{4E2D}": .int(3),      // 中
        "\u{1F600}": .int(4),     // 😀
        "a": .int(5),
        "z": .int(6),
    ])
    let core = SwiftNativePersistenceCore()
    try await core.writeJSON(value, to: swiftPath)
    let actual = try String(contentsOf: swiftPath, encoding: .utf8)
    let expected = #"""
{
  "a": 5,
  "z": 6,
  "\u00e9": 1,
  "\u00f1": 2,
  "\u4e2d": 3,
  "\ud83d\ude00": 4
}
"""#
    #expect(actual == expected,
            "non-ASCII key sort divergence.\nexpected: \(expected)\nactual:   \(actual)")
}

/// Fix 3: tailJSONL uses last-N-physical-lines semantics. Malformed lines
/// in the tail reduce the return count.
@Test func tailJSONL_malformedInTail_returnsFewer() async throws {
    let dir = try makeTempDir()
    let path = dir.appendingPathComponent("mixed.jsonl")
    var text = ""
    for i in 1...7 { text += "{\"i\": \(i)}\n" }
    text += "not-valid-json {{{\n"
    text += "also-broken ]]]\n"
    text += "{\"i\": 10}\n"
    try Data(text.utf8).write(to: path)
    let core = SwiftNativePersistenceCore()
    let result = try await core.tailJSONL(path, limit: 5, maxBytes: nil)
    // Last 5 physical lines are 6,7,8(bad),9(bad),10 → parsed = [6,7,10].
    #expect(result.count == 3, "got \(result.count) records: \(result)")
    #expect(result[0] == .object(["i": .int(6)]))
    #expect(result[1] == .object(["i": .int(7)]))
    #expect(result[2] == .object(["i": .int(10)]))
}

/// Fix 4: write into a read-only parent dir throws and leaves no .tmp behind.
@Test func atomicWrite_readOnlyDir_noTmpLeft() async throws {
    let dir = try makeTempDir()
    let core = SwiftNativePersistenceCore()
    let goodPath = dir.appendingPathComponent("good.json")
    try await core.writeJSON(.object(["k": .string("v")]), to: goodPath)
    let badPath = dir.appendingPathComponent("blocked.json")

    // Make parent read-only (read + exec, no write). Restore on exit.
    let restored = ManagedRestore {
        _ = chmod(dir.path, 0o700)
    }
    defer { restored.fire() }
    #expect(chmod(dir.path, 0o500) == 0)

    var threw = false
    do {
        try await core.writeJSON(.object(["k": .string("v2")]), to: badPath)
    } catch PersistenceCoreError.ioFailure {
        threw = true
    }
    #expect(threw, "expected ioFailure when writing into read-only dir")

    // Restore so we can list and assert.
    restored.fire()
    let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let stale = contents.filter { $0.hasSuffix(".tmp") }
    #expect(stale.isEmpty, "leftover tmp files: \(stale)")
    let blockedExists = contents.contains("blocked.json")
    #expect(!blockedExists, "blocked.json should not have been created")
}

/// Tiny one-shot cleanup helper for the read-only dir test.
private final class ManagedRestore {
    private var fired = false
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    func fire() {
        if fired { return }
        fired = true
        block()
    }
}

// MARK: - defaultDataRoot resolution (Subsystem #1 owns this — duplicate
// resolvers in ApprovalInbox/MCPDispatcher delegate here)

/// FileManager subclass that reports a caller-supplied path as CWD so the
/// repo-walkup branch can be exercised in isolation (no chdir side effects).
private final class FixedCWDFileManager: FileManager, @unchecked Sendable {
    private let cwd: String
    init(cwd: String) { self.cwd = cwd; super.init() }
    override var currentDirectoryPath: String { cwd }
}

@Test func defaultDataRoot_envVarWinsOverEverything() throws {
    let env = ["NATIVE_AGENT_DATA_ROOT": "/tmp/explicit-root"]
    let root = defaultDataRoot(fileManager: .default, environment: env)
    #expect(root.path == "/tmp/explicit-root")
}

@Test func defaultDataRoot_envVarUsedLiterally() throws {
    // Python: `Path(env)` — no expanduser. Mid-path `~` proves the explicit
    // expanduser call is gone (a prior worker had `(raw as NSString)
    // .expandingTildeInPath` which would have stripped it).
    let env = ["NATIVE_AGENT_DATA_ROOT": "/tmp/literal-~-segment/data"]
    let root = defaultDataRoot(fileManager: .default, environment: env)
    #expect(root.path.contains("~"))
    #expect(root.path == "/tmp/literal-~-segment/data")
}

@Test func defaultDataRoot_envVarPreservesLeadingTilde() throws {
    // Adversarial: catches the Darwin Foundation gotcha where
    // `URL(fileURLWithPath: "~/foo")` silently expands to "$HOME/foo".
    // Python's `Path(env)` keeps `~` literal; we must too. The production
    // resolver uses `URL(fileURLWithFileSystemRepresentation:)` specifically
    // to dodge URL's implicit expansion. This test would FAIL against the
    // prior `URL(fileURLWithPath:)` code path.
    let env = ["NATIVE_AGENT_DATA_ROOT": "~/explicit-tilde-prefix"]
    let root = defaultDataRoot(fileManager: .default, environment: env)
    let expanded = ("~/explicit-tilde-prefix" as NSString).expandingTildeInPath
    #expect(root.path != expanded,
            "leading ~ must NOT be expanded to \(expanded); got \(root.path)")
    // Must contain a literal tilde somewhere (percent-encoded `%7E` would
    // also count, but Foundation's fileSystemRepresentation keeps it raw).
    #expect(root.path.contains("~") || root.path.contains("%7E"),
            "expected literal ~ preserved in resolved path, got \(root.path)")
    #expect(root.lastPathComponent == "explicit-tilde-prefix",
            "last component should be literal segment, got \(root.lastPathComponent)")
}

@Test func defaultDataRoot_emptyEnvVarFallsAllTheWayToAppSupport() throws {
    // Isolated tempDir with NO marker files — walkup MUST fail and the
    // resolver MUST fall through to the AppSupport fallback (step 4).
    // Asserting AppSupport specifically proves:
    //   (a) the env-var branch was correctly skipped (empty string ignored),
    //   (b) the walkup didn't silently claim the tempDir, and
    //   (c) we didn't return "" or "/" (which would mean env-branch was
    //       taken with the empty value).
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let fm = FixedCWDFileManager(cwd: tempDir.path)
    let url = defaultDataRoot(
        fileManager: fm,
        environment: ["NATIVE_AGENT_DATA_ROOT": ""]
    )
    #expect(url.path != "")
    #expect(url.path != "/")
    #expect(!url.path.hasPrefix(tempDir.path),
            "walkup should not have claimed tempDir, got \(url.path)")
    #expect(url.path.hasSuffix("NativeAgent") || url.path.contains("Library/Application Support/NativeAgent"),
            "expected AppSupport fallback path, got \(url.path)")
}

@Test func defaultDataRoot_repoWalkupFindsMarkerPair() throws {
    // Stage a fake repo with the marker pair AND data/ subdir, then
    // chdir-by-injection into a nested subdir and confirm the walkup finds it.
    let tempRoot = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    try Data("// fake".utf8).write(
        to: tempRoot.appendingPathComponent("Package.swift"))
    // FAIL 5: walkup now requires data/ to exist.
    try FileManager.default.createDirectory(
        at: tempRoot.appendingPathComponent("data"),
        withIntermediateDirectories: true)
    let nested = tempRoot
        .appendingPathComponent("Modules", isDirectory: true)
        .appendingPathComponent("Sub", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    let fm = FixedCWDFileManager(cwd: nested.path)
    let root = defaultDataRoot(fileManager: fm, environment: [:])
    let expected = tempRoot.appendingPathComponent("data", isDirectory: true)
    #expect(root.standardizedFileURL.path == expected.standardizedFileURL.path)
}

@Test func defaultDataRoot_walkupRequiresDataDirExists() throws {
    // Same as the previous test but NO data/ — walkup must NOT match this dir
    // and must fall through to AppSupport.
    let tempRoot = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    try Data("// fake".utf8).write(
        to: tempRoot.appendingPathComponent("Package.swift"))
    // INTENTIONALLY no data/ dir.
    let fm = FixedCWDFileManager(cwd: tempRoot.path)
    let url = defaultDataRoot(fileManager: fm, environment: [:])
    #expect(!url.path.hasPrefix(tempRoot.path))
}

@Test func defaultDataRoot_stampedRepoPathHonored() throws {
    // Build a stamped layout: synthetic Resources/ dir with REPO_PATH pointing
    // at a fakeRepo that has ALL THREE markers + data/.
    let fakeRepo = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: fakeRepo) }
    let fm = FileManager.default
    try fm.createDirectory(at: fakeRepo.appendingPathComponent("persona"), withIntermediateDirectories: true)
    try fm.createDirectory(at: fakeRepo.appendingPathComponent("script"), withIntermediateDirectories: true)
    try fm.createDirectory(at: fakeRepo.appendingPathComponent("data"), withIntermediateDirectories: true)
    try "x".write(to: fakeRepo.appendingPathComponent("persona/SOUL.template.md"), atomically: true, encoding: .utf8)
    try "x".write(to: fakeRepo.appendingPathComponent("script/init_persona.sh"), atomically: true, encoding: .utf8)
    try "x".write(to: fakeRepo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    let bundleResources = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: bundleResources) }
    try fakeRepo.path.write(
        to: bundleResources.appendingPathComponent("REPO_PATH"),
        atomically: true, encoding: .utf8)
    let resolved = _stampedRepoFromBundleBases([bundleResources], fileManager: fm)
    #expect(resolved?.standardizedFileURL.path == fakeRepo.standardizedFileURL.path)
}

@Test func defaultDataRoot_stampedRepoPathRequiresAllThreeMarkers() throws {
    // Table-drive every marker — proves the validator rejects ANY missing
    // marker, not just the one a single hand-picked test happened to omit.
    let markers = [
        "persona/SOUL.template.md",
        "script/init_persona.sh",
        "Package.swift",
    ]
    let fm = FileManager.default
    for missingMarker in markers {
        let fakeRepo = try makeTempDir()
        defer { try? fm.removeItem(at: fakeRepo) }
        try fm.createDirectory(at: fakeRepo.appendingPathComponent("persona"), withIntermediateDirectories: true)
        try fm.createDirectory(at: fakeRepo.appendingPathComponent("script"), withIntermediateDirectories: true)
        try fm.createDirectory(at: fakeRepo.appendingPathComponent("data"), withIntermediateDirectories: true)
        for m in markers where m != missingMarker {
            try "x".write(to: fakeRepo.appendingPathComponent(m), atomically: true, encoding: .utf8)
        }
        let bundleResources = try makeTempDir()
        defer { try? fm.removeItem(at: bundleResources) }
        try fakeRepo.path.write(
            to: bundleResources.appendingPathComponent("REPO_PATH"),
            atomically: true, encoding: .utf8)
        let resolved = _stampedRepoFromBundleBases([bundleResources], fileManager: fm)
        #expect(resolved == nil,
                "stamp validation must reject when marker '\(missingMarker)' is missing")
    }
}

@Test func defaultDataRoot_rejectsRepoLayoutInsideAppBundle() throws {
    // Build <tempDir>/Fake.app/Contents/Resources/{Package.swift, data/}
    // and CWD-inject from inside that Resources dir. The walkup would match
    // the repo-marker pair, but pathInsideAppBundle MUST reject it — the
    // resolver should fall through to AppSupport instead of returning a
    // path inside a .app bundle.
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let fakeApp = tempDir.appendingPathComponent("Fake.app", isDirectory: true)
    let resources = fakeApp
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("Resources", isDirectory: true)
    let data = resources.appendingPathComponent("data", isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: data, withIntermediateDirectories: true)
    try "// stub".write(to: resources.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    let scoped = FixedCWDFileManager(cwd: resources.path)
    let url = defaultDataRoot(fileManager: scoped, environment: [:])
    #expect(!url.path.contains("Fake.app"),
            "resolver must NOT return a path inside .app bundle, got \(url.path)")
}

@Test func defaultDataRoot_fallbackToAppSupportWhenNothingResolves() throws {
    // Stage a dir tree with NO Package.swift marker anywhere up
    // to the filesystem root. Env empty. Stamp file won't exist (we're in
    // swift test, no Resources/REPO_PATH). Expect AppSupport branch.
    let tempRoot = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let isolated = tempRoot.appendingPathComponent("isolated", isDirectory: true)
    try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)

    let fm = FixedCWDFileManager(cwd: isolated.path)
    let root = defaultDataRoot(fileManager: fm, environment: [:])
    // The walkup will eventually reach `/` and find no markers. The stamp
    // lookup will not find REPO_PATH in the test runner's bundle. So we
    // must land on the AppSupport fallback.
    //
    // NOTE: in a fully-stamped scenario (NativeAgent.app with
    // Resources/REPO_PATH pointing at this repo) step 2 would fire first
    // and return <repo>/data. That branch is NOT exercised here because
    // Bundle.main inside `swift test` is the test runner, not a stamped
    // app bundle — the production code has the implementation, but
    // injecting Bundle.main would require a new param on defaultDataRoot
    // which the public-API constraint forbids. Step 2 will be exercised
    // by the running daemon when installed via script/install_app.sh; the
    // dev/swift-test paths exercise steps 1, 3, 4.
    #expect(root.lastPathComponent == "NativeAgent")
}

// MARK: - JSONValue Codable byte-equivalence regression
//
// PIN the warning: JSONValue's Codable conformance composes inside other
// Codable structs (for example persisted envelopes carrying metadata), but its output bytes are
// JSONEncoder's, which do NOT match `serializedData(pretty:)` — different
// key sort, no `\uXXXX` escapes for non-ASCII, different spacing. Any
// byte-sensitive write path MUST use serializedData(pretty:) directly.
// If this test ever passes (bytes match), someone has either reordered
// JSONEncoder output or replaced the canonical serializer — re-read the
// IMPORTANT doc on the Codable extension before "fixing" the test.
@Test func jsonValueCodable_is_NOT_byte_equivalent_to_serializedData() throws {
    let value: JSONValue = .object([
        "z_key": .int(1),
        "a_key": .string("café"),
        "m_key": .array([.int(2), .int(3)]),
    ])
    let codableBytes = try JSONEncoder().encode(value)
    let canonicalBytes = try value.serializedData(pretty: true)
    #expect(codableBytes != canonicalBytes,
            "JSONEncoder output MUST NOT match serializedData(pretty:) — if this fires, the byte-sensitive contract documented on the Codable extension may have silently changed.")
}

@Test func canonicalSerializer_largeStringProjectionStaysLinearEnoughForRuntimeSnapshots() throws {
    // This is intentionally a runtime-sized projection, not a microbenchmark.
    // Calling String.count inside encodeString once per value made this shape
    // quadratic and held multiple launch workers busy for tens of seconds.
    let rows = (0..<12_000).map { index in
        JSONValue.object([
            "id": .string("row-\(index)"),
            "text": .string("NativeAgent canonical projection payload \(index)"),
        ])
    }
    let clock = ContinuousClock()
    let started = clock.now
    let bytes = try JSONValue.array(rows).serializedData(pretty: false)
    let elapsed = started.duration(to: clock.now)

    #expect(bytes.count > 900_000)
    #expect(elapsed < .seconds(5), "large canonical JSON serialization regressed to \(elapsed)")
    #expect(try JSONValue.parse(bytes) == .array(rows))
}

// MARK: - Persona-root resolver
//
// Swift-native runtime code should prefer the real Agent persona docs wherever
// SOUL.md exists, and keep the old memory/ fallback only as a cold-start last
// resort.
@Test func personaRootResolver_matches_daemon_default_path() async throws {
    let dir = try makeTempDir()
    // Strip both env overrides so the resolver hits the fallback path.
    // The injected environment dict overrides ProcessInfo for this call.
    let env: [String: String] = [:]
    let resolved = defaultPersonaRoot(dataRoot: dir, environment: env)
    let expected = dir.appendingPathComponent("memory", isDirectory: true)
    #expect(resolved.standardizedFileURL.path == expected.standardizedFileURL.path,
            "fallback diverged from daemon: got \(resolved.path), expected \(expected.path)")
}

@Test func personaRootResolver_repoDataRoot_uses_repo_persona_when_soul_present() async throws {
    let (repo, dataRoot) = try makeFakeRepoWithDataRoot()
    defer { try? FileManager.default.removeItem(at: repo) }
    try "# Agent".write(
        to: repo.appendingPathComponent("persona/SOUL.md"),
        atomically: true,
        encoding: .utf8
    )

    let resolved = defaultPersonaRoot(dataRoot: dataRoot, environment: [:])
    let expected = repo.appendingPathComponent("persona", isDirectory: true)
    #expect(resolved.standardizedFileURL.path == expected.standardizedFileURL.path,
            "repo data root should resolve to real persona docs, got \(resolved.path)")
}

@Test func personaRootResolver_appSupportShape_uses_direct_canonical_persona() async throws {
    let dataRoot = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let personaRoot = dataRoot.appendingPathComponent("persona", isDirectory: true)
    try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
    try "# NativeAgent".write(
        to: personaRoot.appendingPathComponent("SOUL.md"),
        atomically: true,
        encoding: .utf8
    )

    let resolved = defaultPersonaRoot(dataRoot: dataRoot, environment: [:])
    #expect(resolved.standardizedFileURL == personaRoot.standardizedFileURL)
}

@Test func personaRootResolver_env_var_overrides_fallback() async throws {
    let dir = try makeTempDir()
    let override = try makeTempDir().appendingPathComponent("custom-persona", isDirectory: true)
    let env: [String: String] = ["NATIVE_AGENT_PERSONA_ROOT": override.path]
    let resolved = defaultPersonaRoot(dataRoot: dir, environment: env)
    #expect(resolved.standardizedFileURL.path == override.standardizedFileURL.path,
            "env override ignored: got \(resolved.path), expected \(override.path)")
}

// MARK: - resolveSandboxRepoRoot (§6.260 — closes §6.240 round-2 reopen #2)
//
// The in-process dispatch file-system sandbox previously used the data root's
// PARENT directly as its sole allowed root. For the bare AppSupport fallback
// that parent is `~/Library/Application Support` — the whole tree. These tests
// pin the tightened resolver: a repo root is returned ONLY when the parent is a
// proven NativeAgent checkout; otherwise nil (caller refuses sandbox → HTTP).

/// Build a fake repo dir with ALL THREE marker files + a `data/` subdir, and
/// return the `<repo>/data` URL (the shape `defaultDataRoot` returns for the
/// dev-walkup / stamped-install paths). Caller owns cleanup of `repoRoot`.
private func makeFakeRepoWithDataRoot() throws -> (repoRoot: URL, dataRoot: URL) {
    let repo = try makeTempDir()
    let fm = FileManager.default
    try fm.createDirectory(at: repo.appendingPathComponent("persona"), withIntermediateDirectories: true)
    try fm.createDirectory(at: repo.appendingPathComponent("script"), withIntermediateDirectories: true)
    let dataRoot = repo.appendingPathComponent("data", isDirectory: true)
    try fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    try "x".write(to: repo.appendingPathComponent("persona/SOUL.template.md"), atomically: true, encoding: .utf8)
    try "x".write(to: repo.appendingPathComponent("script/init_persona.sh"), atomically: true, encoding: .utf8)
    try "x".write(to: repo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    return (repo, dataRoot)
}

@Test func resolveSandboxRepoRoot_validRepoDataParent_returnsRepo() throws {
    // `<repo>/data` whose parent is a full marker-complete repo → return repo.
    let (repo, dataRoot) = try makeFakeRepoWithDataRoot()
    defer { try? FileManager.default.removeItem(at: repo) }
    let resolved = resolveSandboxRepoRoot(dataRoot: dataRoot)
    #expect(resolved != nil, "valid repo/data parent should resolve")
    #expect(resolved?.standardizedFileURL.path == repo.standardizedFileURL.path,
            "should return the repo root, got \(String(describing: resolved?.path))")
}

@Test func resolveSandboxRepoRoot_bareAppSupportFallback_returnsNil() throws {
    // The exact failure mode: `~/Library/Application Support/NativeAgent` BARE.
    // Parent is `…/Application Support` — must REFUSE (nil), never the tree.
    let appSupport = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    let dataRoot = appSupport.appendingPathComponent("NativeAgent", isDirectory: true)
    let resolved = resolveSandboxRepoRoot(dataRoot: dataRoot)
    #expect(resolved == nil,
            "bare AppSupport fallback must refuse the sandbox, got \(String(describing: resolved?.path))")
}

@Test func resolveSandboxRepoRoot_appSupportPatternWithPlantedMarkers_stillRefused() throws {
    // Belt-and-suspenders: even if marker files were somehow planted in an
    // Application Support dir, the AppSupport-pattern guard refuses outright.
    let fm = FileManager.default
    let base = try makeTempDir()
    defer { try? fm.removeItem(at: base) }
    let appSupport = base.appendingPathComponent("Library/Application Support", isDirectory: true)
    try fm.createDirectory(at: appSupport.appendingPathComponent("persona"), withIntermediateDirectories: true)
    try fm.createDirectory(at: appSupport.appendingPathComponent("script"), withIntermediateDirectories: true)
    try "x".write(to: appSupport.appendingPathComponent("persona/SOUL.template.md"), atomically: true, encoding: .utf8)
    try "x".write(to: appSupport.appendingPathComponent("script/init_persona.sh"), atomically: true, encoding: .utf8)
    try "x".write(to: appSupport.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    let dataRoot = appSupport.appendingPathComponent("NativeAgent", isDirectory: true)
    let resolved = resolveSandboxRepoRoot(dataRoot: dataRoot)
    #expect(resolved == nil,
            "AppSupport-pattern parent must be refused even with planted markers, got \(String(describing: resolved?.path))")
}

@Test func resolveSandboxRepoRoot_arbitraryEnvRootNonRepoParent_returnsNil() throws {
    // Mirrors the env-var data-root exposure: a data root whose parent is an
    // arbitrary directory lacking the markers → refuse (don't widen sandbox).
    let base = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let dataRoot = base.appendingPathComponent("some-data-dir", isDirectory: true)
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    let resolved = resolveSandboxRepoRoot(dataRoot: dataRoot)
    #expect(resolved == nil,
            "non-repo parent must refuse the sandbox, got \(String(describing: resolved?.path))")
}

@Test func resolveSandboxRepoRoot_rootLevelParent_returnsNil() throws {
    // A data root directly under "/" → parent is "/" → never a repo.
    let resolved = resolveSandboxRepoRoot(dataRoot: URL(fileURLWithPath: "/NativeAgent"))
    #expect(resolved == nil, "root-level parent must refuse, got \(String(describing: resolved?.path))")
}

@Test func resolveSandboxRepoRoot_partialMarkers_returnsNil() throws {
    // Parent has SOME but not all markers → not a proven repo → refuse.
    let fm = FileManager.default
    let repo = try makeTempDir()
    defer { try? fm.removeItem(at: repo) }
    try "x".write(to: repo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    // INTENTIONALLY omit persona/SOUL.template.md + script/init_persona.sh.
    let dataRoot = repo.appendingPathComponent("data", isDirectory: true)
    try fm.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    let resolved = resolveSandboxRepoRoot(dataRoot: dataRoot)
    #expect(resolved == nil,
            "partial-marker parent must refuse, got \(String(describing: resolved?.path))")
}

@Test func isValidRepoRootDir_tableDrivenMarkerRejection() throws {
    // Table-drive every marker: dropping ANY one must flip the verdict to false.
    let markers = ["persona/SOUL.template.md", "script/init_persona.sh", "Package.swift"]
    let fm = FileManager.default
    for missing in markers {
        let repo = try makeTempDir()
        defer { try? fm.removeItem(at: repo) }
        try fm.createDirectory(at: repo.appendingPathComponent("persona"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent("script"), withIntermediateDirectories: true)
        for m in markers where m != missing {
            try "x".write(to: repo.appendingPathComponent(m), atomically: true, encoding: .utf8)
        }
        #expect(isValidRepoRootDir(repo, fileManager: fm) == false,
                "missing \(missing) must invalidate the repo root")
    }
    // All three present → valid.
    let full = try makeTempDir()
    defer { try? fm.removeItem(at: full) }
    try fm.createDirectory(at: full.appendingPathComponent("persona"), withIntermediateDirectories: true)
    try fm.createDirectory(at: full.appendingPathComponent("script"), withIntermediateDirectories: true)
    for m in markers {
        try "x".write(to: full.appendingPathComponent(m), atomically: true, encoding: .utf8)
    }
    #expect(isValidRepoRootDir(full, fileManager: fm) == true,
            "all three markers present must validate")
}
