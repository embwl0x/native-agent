import Testing
import Foundation
@testable import Skills
import NativeAgentCore
import PersistenceCore

// ============================================================================
// Coverage-ledger evals — fence core.toolexec (docs/evals/ledger.json).
//
// Rows closed here:
//   • skills.listSkills.personaBodyMerge
//   • skills.useCount
// ============================================================================

private func evalSkillsRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SkillsCoverageEvals-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeBody(_ url: URL, title: String, line: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("# \(title)\n\n\(line)\n".utf8).write(to: url)
}

private func rows(_ values: [JSONValue]) -> [[String: JSONValue]] {
    values.compactMap { if case .object(let o) = $0 { return o } else { return nil } }
}

// MARK: - skills.listSkills.personaBodyMerge
//
// UNTESTED ARM WITH A HOST-LEAK HAZARD: listSkills merges a SECOND body
// directory resolved through `defaultPersonaRoot(dataRoot:)`, which honours
// NATIVE_AGENT_PERSONA_ROOT and falls through to stamped-bundle / repo-relative
// lookups. Nothing proved (a) that persona bodies actually appear in the Skills
// tab, nor (b) that a fixture-rooted call cannot resolve to the HOST's real
// persona dir and read live skills into a test.

@Test func evalSkillsPersonaBodyMerge_personaBodiesAppearTaggedAndRegistryNamesWin() async throws {
    // The resolution this eval depends on is only honest when the host has not
    // pinned a persona root out from under it.
    if ProcessInfo.processInfo.environment["NATIVE_AGENT_PERSONA_ROOT"] != nil {
        Issue.record("NATIVE_AGENT_PERSONA_ROOT is set in this process — the persona-body arm cannot be proven hermetically here")
        return
    }

    let root = try evalSkillsRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // <dataRoot>/persona/<name>/SOUL.md makes the fixture the FIRST persona
    // subdir with a soul, which is what defaultPersonaRoot resolves to.
    let personaDir = root
        .appendingPathComponent("persona", isDirectory: true)
        .appendingPathComponent("evalpersona", isDirectory: true)
    try FileManager.default.createDirectory(at: personaDir, withIntermediateDirectories: true)
    try Data("# Soul\n\nfixture persona.\n".utf8)
        .write(to: personaDir.appendingPathComponent("SOUL.md"))

    // (1) HOST-LEAK GUARD — pure, no process state: the resolved persona root
    //     for this fixture is INSIDE the fixture. If this ever resolved to the
    //     host's real persona dir, every persona-body test would silently be
    //     reading User's live skills.
    let resolved = defaultPersonaRoot(dataRoot: root, environment: [:])
    // /var is a symlink to /private/var on macOS — compare resolved paths.
    let fixturePrefix = root.resolvingSymlinksInPath().path
    #expect(
        resolved.resolvingSymlinksInPath().path.hasPrefix(fixturePrefix),
        "defaultPersonaRoot escaped the fixture: \(resolved.path) is not under \(root.path)"
    )
    #expect(resolved.lastPathComponent == "evalpersona")

    // A persona body and a runtime body, plus a registry row whose NAME
    // collides with the persona body.
    try writeBody(
        personaDir.appendingPathComponent("skills/bodies/persona-only.md"),
        title: "Persona Only", line: "Guidance that lives only in the persona tree."
    )
    try writeBody(
        personaDir.appendingPathComponent("skills/bodies/collides.md"),
        title: "Collides", line: "The persona copy of a skill the registry also knows."
    )
    try writeBody(
        root.appendingPathComponent("skills/bodies/runtime-only.md"),
        title: "Runtime Only", line: "Guidance that lives in the runtime bodies dir."
    )
    let registry: JSONValue = .array([
        .object([
            "id": .string("collides"),
            "name": .string("collides"),
            "description": .string("registry version"),
            "triggers": .array([]),
            "status": .string("active"),
            "createdAt": .string("2026-08-18T00:00:00Z"),
            "useCount": .int(0),
            "lastUsedAt": .null,
        ]),
    ])
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("skills", isDirectory: true),
        withIntermediateDirectories: true
    )
    try registry.serializedData(pretty: true)
        .write(to: root.appendingPathComponent("skills/registry.json"))

    let client = SwiftNativeSkillsClient(
        root: root,
        legacyManifestPath: root.appendingPathComponent("skills/absent_legacy.json")
    )
    let listed = rows(try await client.listSkills())
    let byName = Dictionary(uniqueKeysWithValues: listed.compactMap { row -> (String, [String: JSONValue])? in
        guard case .string(let name)? = row["name"] else { return nil }
        return (name, row)
    })

    // (2) THE MERGE IS REAL — a fresh install with only persona bodies must
    //     NOT look like "no skills" to the user. That regression is exactly
    //     what the production comment says the merge exists to prevent.
    #expect(
        byName["persona-only"] != nil,
        "the persona-body arm produced nothing — the Skills tab would show a different surface than the agent sees. Listed: \(byName.keys.sorted())"
    )
    #expect(byName["persona-only"]?["source"] == .string("persona_body"),
            "persona bodies must be TAGGED so the UI can suppress destructive actions on them")
    #expect(byName["runtime-only"]?["source"] == .string("runtime_body"))

    // Body rows decode into the Mac UI's SkillRecord model: id+name+description
    // +triggers are all required there.
    let personaRow = try #require(byName["persona-only"])
    #expect(personaRow["id"] == .string("persona-only"))
    #expect(personaRow["description"] == .string("Guidance that lives only in the persona tree."))
    if case .array? = personaRow["triggers"] {} else { Issue.record("body row must carry a triggers array") }
    if case .string(let bodyPath)? = personaRow["bodyPath"] {
        #expect(
            URL(fileURLWithPath: bodyPath).resolvingSymlinksInPath().path.hasPrefix(fixturePrefix),
            "bodyPath must point inside the fixture, not at the host; got \(bodyPath)"
        )
    } else {
        Issue.record("persona body row carries no bodyPath")
    }

    // (3) REGISTRY NAMES WIN — a body must never shadow a promoted skill.
    #expect(byName["collides"]?["description"] == .string("registry version"),
            "a registry row must win over a same-named body")
    #expect(listed.filter { $0["name"] == .string("collides") }.count == 1,
            "the collision must dedupe to ONE row, not two")
    #expect(listed.count == 3, "registry(1) + persona body(1, deduped) + runtime body(1) — got \(listed.count)")
}

// MARK: - skills.useCount
//
// DEAD COUNTER PRESENTED AS A LIVE SIGNAL. The only write in the codebase is
// `"useCount": .int(0)` at creation. Nothing increments it and nothing stamps
// lastUsedAt for a skill — yet it is rendered as a real number in four places
// and it GATES a list. The user is shown "never used" about every skill
// forever.
//
// This eval NAMES the counter as not-wired rather than printing a zero: it
// fails the day something starts advancing it (at which point the ledger row
// flips to a real telemetry assertion).

@Test func evalSkillsUseCount_isInertAcrossTheWholeMutationSurface() async throws {
    let root = try evalSkillsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("skills", isDirectory: true),
        withIntermediateDirectories: true
    )
    try JSONValue.array([.object([
        "id": .string("eval-skill"),
        "name": .string("eval-skill"),
        "description": .string("a skill nobody counts"),
        "triggers": .array([]),
        "status": .string("active"),
        "createdAt": .string("2026-08-18T00:00:00Z"),
        "useCount": .int(0),
        "lastUsedAt": .null,
    ])]).serializedData(pretty: true)
        .write(to: root.appendingPathComponent("skills/registry.json"))

    let client = SwiftNativeSkillsClient(
        root: root,
        legacyManifestPath: root.appendingPathComponent("skills/absent_legacy.json")
    )

    func currentUseCount() async throws -> JSONValue? {
        rows(try await client.listSkills()).first { $0["id"] == .string("eval-skill") }?["useCount"]
    }

    #expect(try await currentUseCount() == .int(0))

    // Exercise the whole public mutation surface. None of it is a "use", and
    // none of it advances the counter — that is the finding.
    _ = try? await client.enableSkill(name: "eval-skill")
    _ = try? await client.disableSkill(name: "eval-skill")
    _ = try? await client.enableSkill(name: "eval-skill")
    _ = try? await client.updateSkill(body: .object([
        "id": .string("eval-skill"),
        "description": .string("edited"),
    ]))
    for _ in 0..<5 { _ = try await client.listSkills() }

    #expect(
        try await currentUseCount() == .int(0),
        "KNOWN DEAD COUNTER changed: something now advances skills useCount. Good — flip the ledger row from REPORTS-ONLY and assert the real increment."
    )

    // A newly created skill starts at 0 and stays there, and lastUsedAt is
    // never stamped — so the promotion signal it feeds is permanently flat.
    _ = try? await client.createSkill(body: .object([
        "name": .string("fresh-skill"),
        "description": .string("brand new"),
        "body": .string("# Fresh\n\nDo the thing.\n"),
    ]))
    let fresh = rows(try await client.listSkills()).first { $0["name"] == .string("fresh-skill") }
    if let fresh {
        let count = fresh["useCount"] ?? .null
        #expect(count == .int(0) || count == .null,
                "a fresh skill must not arrive pre-counted; got \(count)")
        let lastUsed = fresh["lastUsedAt"] ?? .null
        #expect(lastUsed == .null || lastUsed == .string(""),
                "KNOWN GAP: nothing stamps lastUsedAt for a skill; got \(lastUsed)")
    }

    // STRUCTURAL half: no increment site exists anywhere in the Swift tree.
    // A UI that renders "\(useCount) uses" and a list that filters on
    // `useCount > 0` are reading a number nothing writes.
    guard let repoRoot = skillsEvalRepositoryRoot() else {
        Issue.record("could not locate the repository root from #filePath")
        return
    }
    let (incrementSites, filesScanned) = scanForUseCountIncrements(repoRoot: repoRoot)
    #expect(filesScanned > 100, "the source scan walked only \(filesScanned) files — it is not reaching the tree")
    #expect(
        incrementSites.isEmpty,
        "an increment site appeared: \(incrementSites). The counter is being wired — update this eval and flip skills.useCount in the ledger."
    )
}

/// Synchronous source walk — `FileManager.enumerator`'s iterator is unavailable
/// from async contexts, so the scan lives outside the async test body.
func scanForUseCountIncrements(repoRoot: URL) -> (sites: [String], filesScanned: Int) {
    var incrementSites: [String] = []
    var filesScanned = 0
    for name in ["Sources", "Modules", "iOS"] {
        let base = repoRoot.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path),
              let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        else { continue }
        for case let url as URL in walker where url.pathExtension == "swift" {
            // MemoryV2 has its own unrelated useCount; Tests are not production.
            if url.path.contains("/MemoryV2/") || url.path.contains("/Tests/") { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            filesScanned += 1
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let increments = trimmed.contains("useCount +=")
                    || trimmed.contains("useCount + 1")
                    || trimmed.contains("useCount) + 1")
                if increments { incrementSites.append("\(url.lastPathComponent):\(index + 1)") }
            }
        }
    }
    return (incrementSites, filesScanned)
}

/// Walks up from this source file to the repository root.
func skillsEvalRepositoryRoot() -> URL? {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<12 {
        let manifest = directory.appendingPathComponent("Package.swift")
        let modules = directory.appendingPathComponent("Modules", isDirectory: true)
        if FileManager.default.fileExists(atPath: manifest.path),
           FileManager.default.fileExists(atPath: modules.path) {
            return directory
        }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { return nil }
        directory = parent
    }
    return nil
}
