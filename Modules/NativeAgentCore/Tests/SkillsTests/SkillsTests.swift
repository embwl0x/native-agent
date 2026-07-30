import Testing
import Foundation
@testable import Skills
import NativeAgentCore
import PersistenceCore

// MARK: - Helpers

private func obj(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }

private func stringField(_ v: JSONValue, _ key: String) -> String? {
    if case .object(let o) = v, case .string(let s)? = o[key] { return s }
    return nil
}

private func idsOf(_ vals: [JSONValue]) -> [String] {
    vals.compactMap { stringField($0, "id") }
}

private func namesOf(_ vals: [JSONValue]) -> [String] {
    vals.compactMap { stringField($0, "name") }
}

/// A temp data root with `skills/` subdir, auto-cleaned by the caller.
private func makeTempRoot() throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("skills-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: base.appendingPathComponent("skills", isDirectory: true),
        withIntermediateDirectories: true)
    return base
}

private func writeJSON(_ value: JSONValue, to url: URL) throws {
    let data = try value.serializedData(pretty: false)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

// MARK: - list_skills sort semantics

@Test func listSkills_sortsByUpdatedThenCreatedDescending() throws {
    // Mirrors Runtime.list_skills: sorted by str(updatedAt or createdAt or "")
    // reverse=True. Build records that exercise each branch.
    let a = obj(["id": .string("a"), "updatedAt": .string("2026-01-01T00:00:00")])
    let b = obj(["id": .string("b"), "updatedAt": .string("2026-03-01T00:00:00")])
    // c has no updatedAt → falls to createdAt.
    let c = obj(["id": .string("c"), "createdAt": .string("2026-02-01T00:00:00")])
    // d has neither → sort key "" → sorts LAST in DESC.
    let d = obj(["id": .string("d")])
    let sorted = SkillsRegistry.sortedDescending([d, a, c, b])
    #expect(idsOf(sorted) == ["b", "c", "a", "d"])
}

@Test func listSkills_emptyUpdatedAtFallsToCreatedAt() throws {
    // Python `"" or createdAt` → createdAt, because "" is falsey.
    let withEmptyUpdated = obj([
        "id": .string("x"),
        "updatedAt": .string(""),
        "createdAt": .string("2026-05-09T00:00:00"),
    ])
    #expect(SkillsRegistry.sortKey(withEmptyUpdated) == "2026-05-09T00:00:00")
}

@Test func listSkills_stableTieBreakPreservesInputOrder() throws {
    // Equal sort keys → Python's stable sorted() keeps input order; we emulate.
    let p = obj(["id": .string("p"), "updatedAt": .string("2026-05-01")])
    let q = obj(["id": .string("q"), "updatedAt": .string("2026-05-01")])
    let r = obj(["id": .string("r"), "updatedAt": .string("2026-05-01")])
    let sorted = SkillsRegistry.sortedDescending([p, q, r])
    #expect(idsOf(sorted) == ["p", "q", "r"])
}

@Test func swiftNativeListSkills_readsRegistryAndSorts() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([
        obj(["id": .string("old"), "updatedAt": .string("2026-01-01")]),
        obj(["id": .string("new"), "updatedAt": .string("2026-06-01")]),
    ]), to: root.appendingPathComponent("skills/registry.json"))

    let client = SwiftNativeSkillsClient(root: root)
    let rows = try await client.listSkills()
    #expect(idsOf(rows) == ["new", "old"])
}

@Test func swiftNativeListSkills_missingFileReturnsEmpty() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // No registry.json written.
    let client = SwiftNativeSkillsClient(root: root)
    let rows = try await client.listSkills()
    #expect(rows.isEmpty)
}

@Test func swiftNativeListSkills_skipsDirtyBodyOnlySkills() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bodies = root.appendingPathComponent("skills/bodies", isDirectory: true)
    try FileManager.default.createDirectory(at: bodies, withIntermediateDirectories: true)
    try """
    # Clean Body

    Use this when skill discovery needs a clean body-only skill.
    """.write(to: bodies.appendingPathComponent("clean-body.md"), atomically: true, encoding: .utf8)
    try """
    # Dirty Body

    Use this when the python daemon is involved.
    """.write(to: bodies.appendingPathComponent("dirty-body.md"), atomically: true, encoding: .utf8)
    let dirtyRegistryBody = bodies.appendingPathComponent("dirty-registry.md")
    try """
    # Dirty Registry

    Use this when the python daemon is involved.
    """.write(to: dirtyRegistryBody, atomically: true, encoding: .utf8)
    try writeJSON(.array([
        obj([
            "id": .string("dirty-registry"),
            "name": .string("dirty-registry"),
            "bodyPath": .string(dirtyRegistryBody.path),
            "updatedAt": .string("2026-06-19T18:00:00Z"),
        ]),
    ]), to: root.appendingPathComponent("skills/registry.json"))

    let client = SwiftNativeSkillsClient(root: root)
    let rows = try await client.listSkills()
    #expect(namesOf(rows).contains("clean-body"))
    #expect(!namesOf(rows).contains("dirty-body"))
    #expect(!namesOf(rows).contains("dirty-registry"))
}

@Test func swiftNativeListSkills_doesNotWriteBack() async throws {
    // Unlike list_workflows, list_skills is a PURE read. Confirm the file is
    // untouched (no merge/write-back) — a regression here would corrupt the
    // registry on a flipped read.
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let regPath = root.appendingPathComponent("skills/registry.json")
    let original = Data("[{\"id\":\"only\"}]".utf8)
    try original.write(to: regPath)
    let before = try FileManager.default.attributesOfItem(atPath: regPath.path)
    let beforeBytes = try Data(contentsOf: regPath)

    let client = SwiftNativeSkillsClient(root: root)
    _ = try await client.listSkills()

    let afterBytes = try Data(contentsOf: regPath)
    let after = try FileManager.default.attributesOfItem(atPath: regPath.path)
    #expect(beforeBytes == afterBytes)
    // mtime unchanged (no write occurred).
    let bm = before[.modificationDate] as? Date
    let am = after[.modificationDate] as? Date
    #expect(bm == am)
}

// MARK: - manifest merge semantics

@Test func manifestMerge_dataRootWinsOnNameCollision() throws {
    // The daemon iterates [legacy, dataRoot] and overwrites — so the data-root
    // entry wins for a colliding name.
    let legacy = obj(["schemaVersion": .int(1), "skills": obj([
        "shared": obj(["state": .string("legacy"), "version": .string("1")]),
        "legacyOnly": obj(["state": .string("drafted")]),
    ])])
    let dataRoot = obj(["schemaVersion": .int(1), "skills": obj([
        "shared": obj(["state": .string("installed"), "version": .string("2")]),
        "dataRootOnly": obj(["state": .string("active")]),
    ])])
    let merged = SkillManifestRegistry.merge(entries: [
        (raw: legacy, parentPath: "/legacy/dir", filePath: "/legacy/dir/manifest_registry.json"),
        (raw: dataRoot, parentPath: "/data/dir", filePath: "/data/dir/manifest_registry.json"),
    ])
    #expect(merged.count == 3)
    let byName = Dictionary(uniqueKeysWithValues: merged.map { ($0.name, $0.entry) })
    if case .object(let shared)? = byName["shared"] {
        #expect(shared["state"] == .string("installed"))
        #expect(shared["version"] == .string("2"))
        // sourceRoot defaulted to the WINNING file's parent.
        #expect(shared["sourceRoot"] == .string("/data/dir"))
        #expect(shared["registryPath"] == .string("/data/dir/manifest_registry.json"))
    } else {
        Issue.record("shared entry missing")
    }
    // Collision keeps the original insertion position. Within the legacy file
    // names are visited sorted (legacyOnly, shared); the data-root file then
    // adds dataRootOnly. "shared" collides but KEEPS its legacy position (it
    // does NOT jump to the end where its value came from). So the order is
    // [legacyOnly, shared, dataRootOnly].
    #expect(merged.map { $0.name } == ["legacyOnly", "shared", "dataRootOnly"])
}

@Test func manifestMerge_setdefaultPreservesExistingSourceRoot() throws {
    // setdefault: an entry that ALREADY carries sourceRoot/registryPath keeps
    // them; we do NOT clobber.
    let legacy = obj(["schemaVersion": .int(1), "skills": obj([
        "pinned": obj([
            "state": .string("active"),
            "sourceRoot": .string("/custom/root"),
            "registryPath": .string("/custom/root/reg.json"),
        ]),
    ])])
    let merged = SkillManifestRegistry.merge(entries: [
        (raw: legacy, parentPath: "/legacy/dir", filePath: "/legacy/dir/manifest_registry.json"),
    ])
    let byName = Dictionary(uniqueKeysWithValues: merged.map { ($0.name, $0.entry) })
    if case .object(let pinned)? = byName["pinned"] {
        #expect(pinned["sourceRoot"] == .string("/custom/root"))
        #expect(pinned["registryPath"] == .string("/custom/root/reg.json"))
    } else {
        Issue.record("pinned entry missing")
    }
}

@Test func manifestMerge_skipsNonObjectRootAndNonDictSkills() throws {
    // root not an object → skipped; skills not an object → skipped; an entry
    // value that is not a dict → skipped.
    let badRoot: JSONValue = .array([.string("not a registry")])
    let badSkills = obj(["schemaVersion": .int(1), "skills": .string("nope")])
    let mixed = obj(["schemaVersion": .int(1), "skills": obj([
        "good": obj(["state": .string("active")]),
        "bad": .string("not a dict"),
    ])])
    let merged = SkillManifestRegistry.merge(entries: [
        (raw: badRoot, parentPath: "/a", filePath: "/a/x.json"),
        (raw: badSkills, parentPath: "/b", filePath: "/b/x.json"),
        (raw: mixed, parentPath: "/c", filePath: "/c/x.json"),
    ])
    #expect(merged.count == 1)
    let names = Set(merged.map { $0.name })
    #expect(names.contains("good"))
    #expect(!names.contains("bad"))
}

@Test func manifestReshape_emitsNameKeyAndKeepsEmbeddedName() throws {
    // {"name": k, **v}: missing name → injected; embedded name in v → kept
    // (the spread wins over the leading literal in Python). Order is preserved
    // exactly as supplied (the merge output order).
    let merged: [(name: String, entry: JSONValue)] = [
        (name: "hasName", entry: obj(["state": .string("active"), "name": .string("Pretty Name")])),
        (name: "noName", entry: obj(["state": .string("active")])),
    ]
    let list = SkillManifestRegistry.reshapeToList(merged)
    #expect(list.count == 2)
    #expect(stringField(list[0], "name") == "Pretty Name")  // embedded name kept
    #expect(stringField(list[1], "name") == "noName")        // injected from key
}

@Test func swiftNativeManifest_mergesBothFilesEndToEnd() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacyPath = root.appendingPathComponent("legacy/manifest_registry.json")
    let dataRootPath = root.appendingPathComponent("skills/manifest_registry.json")
    try writeJSON(obj(["schemaVersion": .int(1), "skills": obj([
        "alpha": obj(["state": .string("drafted"), "version": .string("1"), "type": .string("connector"), "path": .string("/p/alpha")]),
    ])]), to: legacyPath)
    try writeJSON(obj(["schemaVersion": .int(1), "skills": obj([
        "beta": obj(["state": .string("installed"), "version": .string("2"), "type": .string("skill"), "path": .string("/p/beta")]),
    ])]), to: dataRootPath)

    let client = SwiftNativeSkillsClient(root: root, legacyManifestPath: legacyPath)
    let list = try await client.listManifestSkills()
    #expect(Set(namesOf(list)) == ["alpha", "beta"])
    // Each entry decodes into the Mac's SkillRegistryEntry shape (name/state/version/type/path).
    for v in list {
        #expect(stringField(v, "state") != nil)
        #expect(stringField(v, "version") != nil)
        #expect(stringField(v, "type") != nil)
        #expect(stringField(v, "path") != nil)
    }
}

@Test func swiftNativeManifest_missingFilesReturnsEmpty() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Point legacy at a non-existent path; data-root manifest also absent.
    let client = SwiftNativeSkillsClient(
        root: root,
        legacyManifestPath: root.appendingPathComponent("nope/manifest_registry.json"))
    let list = try await client.listManifestSkills()
    #expect(list.isEmpty)
}

// MARK: - Factory gating

@Test func factory_returnsSwiftNative() throws {
    let client = makeSkillsClient(root: URL(fileURLWithPath: "/tmp/na"))
    #expect(client is SwiftNativeSkillsClient)
}

// MARK: - Mutation port (wave 32 W15)

private func readRegistry(_ root: URL) throws -> [JSONValue] {
    let url = root.appendingPathComponent("skills/registry.json")
    guard let data = try? Data(contentsOf: url) else { return [] }
    if case .array(let a) = try JSONValue.parse(data) { return a }
    return []
}

private func readActivity(_ root: URL) -> [JSONValue] {
    let url = root.appendingPathComponent("activity/events.jsonl")
    guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { try? JSONValue.parse(Data($0.utf8)) }
}

/// Fixed clock so updatedAt/createdAt are deterministic.
private let fixedNow: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }

private func clientFor(_ root: URL) -> SwiftNativeSkillsClient {
    SwiftNativeSkillsClient(
        root: root,
        legacyManifestPath: root.appendingPathComponent("nope/manifest_registry.json"),
        now: fixedNow)
}

@Test func updateSkill_patchesAllowedKeysRestampsAndEmitsActivity() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([
        obj(["id": .string("s1"), "name": .string("Alpha"), "status": .string("draft"),
             "description": .string("old"), "createdAt": .string("2026-01-01T00:00:00")]),
    ]), to: root.appendingPathComponent("skills/registry.json"))

    let client = clientFor(root)
    let result = try await client.updateSkill(body: obj([
        "id": .string("s1"), "status": .string("active"), "description": .string("new"),
        // unrelated key NOT in the allowed set — must be ignored.
        "useCount": .int(99),
    ]))
    #expect(stringField(result, "status") == "active")
    #expect(stringField(result, "description") == "new")
    #expect(stringField(result, "updatedAt") != nil)  // restamped
    // useCount must NOT have been written (not an allowed update key).
    if case .object(let o) = result { #expect(o["useCount"] == nil) }

    // Persisted.
    let reg = try readRegistry(root)
    #expect(stringField(reg[0], "status") == "active")

    // record_activity fired: kind=skill, title="Skill updated".
    let events = readActivity(root)
    #expect(events.count == 1)
    #expect(stringField(events[0], "kind") == "skill")
    #expect(stringField(events[0], "title") == "Skill updated")
    #expect(stringField(events[0], "detail") == "Alpha")  // str(name or id)
}

@Test func updateSkill_matchesByNameNotJustId() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([
        obj(["id": .string("s1"), "name": .string("Beta"), "status": .string("draft")]),
    ]), to: root.appendingPathComponent("skills/registry.json"))
    let client = clientFor(root)
    let result = try await client.updateSkill(body: obj(["id": .string("Beta"), "status": .string("active")]))
    #expect(stringField(result, "id") == "s1")
    #expect(stringField(result, "status") == "active")
}

@Test func updateSkill_unknownThrows() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([]), to: root.appendingPathComponent("skills/registry.json"))
    let client = clientFor(root)
    await #expect(throws: SkillsError.self) {
        _ = try await client.updateSkill(body: obj(["id": .string("missing"), "status": .string("active")]))
    }
}

@Test func deleteSkill_removesRecordCleansBodyFileEmitsActivity() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bodiesDir = root.appendingPathComponent("skills/bodies", isDirectory: true)
    try FileManager.default.createDirectory(at: bodiesDir, withIntermediateDirectories: true)
    let bodyURL = bodiesDir.appendingPathComponent("s1.md")
    try "# Alpha\n".data(using: .utf8)!.write(to: bodyURL)
    try writeJSON(.array([
        obj(["id": .string("s1"), "name": .string("Alpha"), "bodyPath": .string(bodyURL.path)]),
        obj(["id": .string("s2"), "name": .string("Beta")]),
    ]), to: root.appendingPathComponent("skills/registry.json"))

    let client = clientFor(root)
    let result = try await client.deleteSkill(id: "s1")
    #expect(stringField(result, "id") == "s1")
    if case .object(let o) = result { #expect(o["deleted"] == .bool(true)) }

    // s1 removed, s2 kept.
    let reg = try readRegistry(root)
    #expect(idsOf(reg) == ["s2"])
    // body file unlinked.
    #expect(!FileManager.default.fileExists(atPath: bodyURL.path))
    // activity event.
    let events = readActivity(root)
    #expect(stringField(events.last ?? .null, "title") == "Skill deleted")
}

@Test func deleteSkill_pathConfinedBodyNotUnlinkedOutsideBodiesDir() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // A body path OUTSIDE skills/bodies must NOT be unlinked.
    let outside = root.appendingPathComponent("outside.md")
    try "x".data(using: .utf8)!.write(to: outside)
    try writeJSON(.array([
        obj(["id": .string("s1"), "name": .string("Alpha"), "bodyPath": .string(outside.path)]),
    ]), to: root.appendingPathComponent("skills/registry.json"))
    let client = clientFor(root)
    _ = try await client.deleteSkill(id: "s1")
    #expect(FileManager.default.fileExists(atPath: outside.path))  // preserved
}

@Test func deleteSkill_manifestFallbackWhenNotInLegacyRegistry() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([]), to: root.appendingPathComponent("skills/registry.json"))
    // Put the skill in the DATA-ROOT manifest registry only.
    try writeJSON(obj([
        "schemaVersion": .int(1),
        "skills": obj([
            "my-cli-skill": obj(["name": .string("My CLI Skill"), "state": .string("installed")]),
        ]),
    ]), to: root.appendingPathComponent("skills/manifest_registry.json"))

    let client = clientFor(root)
    let result = try await client.deleteSkill(id: "my-cli-skill")
    #expect(stringField(result, "source") == "manifest")
    if case .object(let o) = result { #expect(o["deleted"] == .bool(true)) }
    // Removed from the data-root manifest.
    let list = try await client.listManifestSkills()
    #expect(!namesOf(list).contains("My CLI Skill"))
}

@Test func deleteSkill_unknownInBothThrows() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([]), to: root.appendingPathComponent("skills/registry.json"))
    let client = clientFor(root)
    await #expect(throws: SkillsError.self) {
        _ = try await client.deleteSkill(id: "ghost")
    }
}

@Test func enableSkill_legacyStatusFlipToActive() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([
        obj(["id": .string("s1"), "name": .string("Alpha"), "status": .string("disabled")]),
    ]), to: root.appendingPathComponent("skills/registry.json"))
    let client = clientFor(root)
    let result = try await client.enableSkill(name: "s1")
    #expect(stringField(result, "status") == "active")
}

@Test func disableSkill_legacyStatusFlipToDisabled() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([
        obj(["id": .string("s1"), "name": .string("Alpha"), "status": .string("active")]),
    ]), to: root.appendingPathComponent("skills/registry.json"))
    let client = clientFor(root)
    let result = try await client.disableSkill(name: "s1")
    #expect(stringField(result, "status") == "disabled")
}

@Test func enableSkill_manifestStateMachineDraftedToInstalled() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([]), to: root.appendingPathComponent("skills/registry.json"))
    try writeJSON(obj([
        "schemaVersion": .int(1),
        "skills": obj(["cli-x": obj(["state": .string("drafted")])]),
    ]), to: root.appendingPathComponent("skills/manifest_registry.json"))
    let client = clientFor(root)
    let result = try await client.enableSkill(name: "cli-x")
    #expect(stringField(result, "state") == "installed")
    #expect(stringField(result, "name") == "cli-x")
    // Persisted to the data-root manifest.
    let list = try await client.listManifestSkills()
    let entry = list.first { stringField($0, "name") == "cli-x" }
    #expect(stringField(entry ?? .null, "state") == "installed")
}

@Test func disableSkill_manifestStateMachineInstalledToDormant() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([]), to: root.appendingPathComponent("skills/registry.json"))
    try writeJSON(obj([
        "schemaVersion": .int(1),
        "skills": obj(["cli-y": obj(["state": .string("installed")])]),
    ]), to: root.appendingPathComponent("skills/manifest_registry.json"))
    let client = clientFor(root)
    let result = try await client.disableSkill(name: "cli-y")
    #expect(stringField(result, "state") == "dormant")
}

@Test func enableSkill_manifestDisallowedStateThrows() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([]), to: root.appendingPathComponent("skills/registry.json"))
    try writeJSON(obj([
        "schemaVersion": .int(1),
        "skills": obj(["cli-z": obj(["state": .string("quarantined")])]),
    ]), to: root.appendingPathComponent("skills/manifest_registry.json"))
    let client = clientFor(root)
    await #expect(throws: SkillsError.self) {
        _ = try await client.enableSkill(name: "cli-z")
    }
}

@Test func createSkill_newRecordDefaultsAndBodyWrite() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([]), to: root.appendingPathComponent("skills/registry.json"))
    let client = clientFor(root)
    let result = try await client.createSkill(body: obj([
        "name": .string("My New Skill"),
        "content": .string("# My New Skill\n\nUse this when creating a new reusable skill body.\n"),
    ]))
    #expect(stringField(result, "id") == "my-new-skill")  // slugify
    #expect(stringField(result, "status") == "active")     // not autoCreated → active
    #expect(stringField(result, "description") == "Reusable procedure for My New Skill.")
    // triggers default to [name].
    if case .object(let o) = result, case .array(let t)? = o["triggers"] {
        #expect(t == [.string("My New Skill")])
    } else { Issue.record("triggers missing") }
    // body file written.
    let bodyPath = root.appendingPathComponent("skills/bodies/my-new-skill.md")
    #expect(FileManager.default.fileExists(atPath: bodyPath.path))
    // createSkill does NOT fire record_activity (parity with Python).
    #expect(readActivity(root).isEmpty)
}

@Test func createSkill_autoCreatedDefaultsToDraftStatus() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([]), to: root.appendingPathComponent("skills/registry.json"))
    let client = clientFor(root)
    let result = try await client.createSkill(body: obj([
        "name": .string("Auto Skill"), "autoCreated": .bool(true),
    ]))
    #expect(stringField(result, "status") == "draft")
}

@Test func createSkill_rejectsDirtySkillBody() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([]), to: root.appendingPathComponent("skills/registry.json"))
    let client = clientFor(root)
    await #expect(throws: SkillsError.self) {
        _ = try await client.createSkill(body: obj([
            "name": .string("Dirty Skill"),
            "content": .string("# Dirty Skill\n\nUse this when the python daemon should run.\n"),
        ]))
    }
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("skills/bodies/dirty-skill.md").path
    ))
}

@Test func createSkill_caseInsensitiveNameDedupUpdatesExisting() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([
        obj(["id": .string("existing-id"), "name": .string("Shared Name"),
             "status": .string("draft"), "createdAt": .string("2026-01-01T00:00:00")]),
    ]), to: root.appendingPathComponent("skills/registry.json"))
    let client = clientFor(root)
    let result = try await client.createSkill(body: obj([
        "name": .string("SHARED NAME"),  // different case → same skill
        "description": .string("updated desc"),
        "content": .string("# Shared Name\n\nUse this when updating an existing skill body.\n"),
    ]))
    // Reuses the EXISTING id, doesn't create a new record.
    #expect(stringField(result, "id") == "existing-id")
    #expect(stringField(result, "description") == "updated desc")
    let reg = try readRegistry(root)
    #expect(reg.count == 1)  // no duplicate appended
}

@Test func createSkill_repairsLegacyRowMissingIdIntoCanonicalBodyPath() async throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([
        obj(["name": .string("Keep It Light"), "description": .string("legacy row")]),
    ]), to: root.appendingPathComponent("skills/registry.json"))
    let result = try await clientFor(root).createSkill(body: obj([
        "name": .string("keep it light"),
        "description": .string("canonical row"),
        "content": .string("# Keep It Light\n\nUse this when casual conversation should stay playful.\n"),
    ]))
    #expect(stringField(result, "id") == "keep-it-light")
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent("skills/bodies/keep-it-light.md").path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("skills/bodies/None.md").path
    ))
}

@Test func slugify_matchesDaemon() throws {
    #expect(SkillMutation.slugify("My New Skill") == "my-new-skill")
    #expect(SkillMutation.slugify("Hello, World!!") == "hello-world")
    #expect(SkillMutation.slugify("  --leading--trailing--  ") == "leading-trailing")
    #expect(SkillMutation.slugify("UPPER_case 123") == "upper-case-123")
}

@Test func registryWrite_isPrettySortedKeysParity() async throws {
    // The persisted registry.json must match json.dumps(indent=2, sort_keys=True).
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([
        obj(["id": .string("s1"), "name": .string("Alpha"), "status": .string("draft")]),
    ]), to: root.appendingPathComponent("skills/registry.json"))
    let client = clientFor(root)
    _ = try await client.updateSkill(body: obj(["id": .string("s1"), "status": .string("active")]))
    let raw = try String(contentsOf: root.appendingPathComponent("skills/registry.json"), encoding: .utf8)
    // pretty (2-space indent) + keys sorted: "id" before "name" before "status" before "updatedAt".
    #expect(raw.contains("  {\n"))                 // indent=2
    let idIdx = raw.range(of: "\"id\"")!.lowerBound
    let nameIdx = raw.range(of: "\"name\"")!.lowerBound
    let statusIdx = raw.range(of: "\"status\"")!.lowerBound
    #expect(idIdx < nameIdx)
    #expect(nameIdx < statusIdx)  // sorted keys
}

// MARK: - gpt-5.5 review fixes (wave 32 W15)

@Test func enableSkill_manifestEntryNameKeyWinsOverRouteName() async throws {
    // Python {"name": _name, "state": target, **_entry}: if the manifest entry
    // already carries a "name", the spread WINS over the route's name literal.
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([]), to: root.appendingPathComponent("skills/registry.json"))
    try writeJSON(obj([
        "schemaVersion": .int(1),
        "skills": obj(["cli-key": obj([
            "state": .string("drafted"),
            "name": .string("Pretty Display Name"),  // entry has its own name
        ])]),
    ]), to: root.appendingPathComponent("skills/manifest_registry.json"))
    let client = clientFor(root)
    let result = try await client.enableSkill(name: "cli-key")
    // entry's name wins, NOT the route key "cli-key".
    #expect(stringField(result, "name") == "Pretty Display Name")
    #expect(stringField(result, "state") == "installed")
}

@Test func createSkill_emptyStatusFallsThroughToDefault() async throws {
    // Python `body.get("status") or (...)`: an empty-string status is falsey and
    // must fall through to the autoCreated/active default (NOT persist as "").
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([]), to: root.appendingPathComponent("skills/registry.json"))
    let client = clientFor(root)
    let result = try await client.createSkill(body: obj([
        "name": .string("Blank Status Skill"),
        "status": .string(""),     // falsey → must NOT persist
        "kind": .string(""),       // falsey → must fall to "skill"
    ]))
    #expect(stringField(result, "status") == "active")
    #expect(stringField(result, "kind") == "skill")
}

@Test func createSkill_stripsNewlinesFromNameLikePythonStrip() async throws {
    // Python .strip() removes leading/trailing newlines; Swift must too.
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([]), to: root.appendingPathComponent("skills/registry.json"))
    let client = clientFor(root)
    let result = try await client.createSkill(body: obj([
        "name": .string("\n  Spaced Skill  \n"),
        "content": .string("\n# Spaced Skill\n\nUse this when skill names need whitespace normalization.\n"),
    ]))
    #expect(stringField(result, "name") == "Spaced Skill")
    #expect(stringField(result, "id") == "spaced-skill")
}

@Test func updateSkill_nullIdNormalizesToEmptyNotNoneString() async throws {
    // str(body.get("id") or "") collapses null → "", so the lookup uses ""
    // (no skill matches) rather than the literal "None".
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([
        obj(["id": .string("None"), "name": .string("Trap")]),  // a literal "None" id
    ]), to: root.appendingPathComponent("skills/registry.json"))
    let client = clientFor(root)
    // body with id=null → "" → should NOT match the "None"-id trap row.
    await #expect(throws: SkillsError.self) {
        _ = try await client.updateSkill(body: obj(["id": .null, "status": .string("active")]))
    }
}

// MARK: - Trust-gate 403 parity (wave 34 W19)
//
// PARITY DISPOSITION: the daemon's two 403 conditions on the skill mutation
// routes (_check_origin CSRF + _mobile_admin_route_denied) are HTTP-TRANSPORT
// guards keyed off the client socket + Authorization header. The SwiftNative
// impl is invoked ONLY in-process by the local Mac owner — it has NO concept of
// a remote socket or pairing token — so neither guard is reachable here, and
// none is ported (it would be dead code). These tests PIN that invariant so a
// future refactor can't silently add a remote caller to this seam without a
// test screaming, and document why the absence of a 403 check is deliberate.

@Test func trustGateParity_mutationApiHasNoRemoteCallerSurface() async throws {
    // The mutation methods accept ZERO transport-identity parameters (no origin,
    // no bearer/pairing token, no client address). A mutation by the local owner
    // succeeds unconditionally — exactly as the daemon's Runtime.update_skill
    // does once a request has already cleared the HTTP-layer 403 gates. The 403
    // enforcement lives on the HTTP boundary the daemon serves to REMOTE callers;
    // this in-process seam is the local-owner path by construction.
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeJSON(.array([
        obj(["id": .string("s1"), "name": .string("Gamma"), "status": .string("draft")]),
    ]), to: root.appendingPathComponent("skills/registry.json"))
    let client = clientFor(root)
    // No gate to satisfy / no token to present — the call just runs.
    let result = try await client.updateSkill(body: obj(["id": .string("s1"), "status": .string("active")]))
    #expect(stringField(result, "status") == "active")
}

@Test func trustGateParity_factoryUsesLocalOwnerSwiftClient() throws {
    // The in-process factory always returns the local-owner Swift client; remote
    // boundary policy belongs outside this seam.
    let client = makeSkillsClient(root: URL(fileURLWithPath: "/tmp/na"))
    #expect(client is SwiftNativeSkillsClient)
}

@Test func trustGateParity_allFiveMutationsRunForLocalOwner() async throws {
    // wave 37 W11 (§6.159): extend the W34 W19 invariant from the single
    // representative `updateSkill` to the FULL mutation surface the cluster
    // names — create + update + delete + enable + disable. EACH runs to
    // completion for the in-process local owner with no transport-identity
    // argument anywhere. This is the Swift symmetry of the Python gate pin
    // (test_nextgen_consolidation.py: all five routes deny a paired-mobile
    // remote caller, all five allow the loopback owner). The W36 W12 audit
    // established there is no admin-bearer credential to port; the absence of
    // ANY 403 check on these methods is the deliberate local-owner invariant,
    // and this pins it across the whole surface so a refactor can't add a
    // remote caller to one method without a test screaming.
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Seed one known legacy-registry record so update/enable/disable/delete have
    // a deterministic target (matched by id OR name).
    try writeJSON(.array([
        obj(["id": .string("s1"), "name": .string("Gamma"), "status": .string("active")]),
    ]), to: root.appendingPathComponent("skills/registry.json"))
    let client = clientFor(root)

    // create — no gate, no token; auto-generates a record. Runs to completion.
    let created = try await client.createSkill(body: obj([
        "name": .string("NewlyMade"), "status": .string("draft"),
    ]))
    #expect(stringField(created, "name") == "NewlyMade")
    // update — runs (matches the seeded record by id). Set a non-terminal
    // status distinct from what disable/enable target so the later flip
    // assertions actually witness a CHANGE (not a no-op coincidence).
    let updated = try await client.updateSkill(body: obj([
        "id": .string("s1"), "status": .string("draft"),
    ]))
    #expect(stringField(updated, "status") == "draft")
    // disable / enable — legacy-registry status flip on the seeded record.
    // disableSkill writes "disabled" (was "draft" → real flip); enableSkill
    // writes "active" (was "disabled" → real flip).
    let disabled = try await client.disableSkill(name: "s1")
    #expect(stringField(disabled, "status") == "disabled")
    let enabled = try await client.enableSkill(name: "s1")
    #expect(stringField(enabled, "status") == "active")
    // delete — runs, returns deleted:true.
    let deleted = try await client.deleteSkill(id: "s1")
    if case .object(let d) = deleted { #expect(d["deleted"] == .bool(true)) }
}
