import Testing
import Foundation
@testable import PersonaEngine
import NativeAgentCore
import PersistenceCore

// MARK: - Helpers

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersonaEngineTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeFile(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
}

// MARK: - Factory / flag

@Test func placeholderFactoryReturnsSwiftNative() async throws {
    let impl = makePersonaEngine()
    #expect(impl is SwiftNativePersonaEngine)
}

@Test func isolatedPersonaEngineReadsOnlyInjectedDataRoot() async throws {
    let dataRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersonaIsolatedRoot-\(UUID().uuidString)", isDirectory: true)
    let identity = dataRoot
        .appendingPathComponent("persona", isDirectory: true)
        .appendingPathComponent("Fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: identity, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let marker = "isolated-soul-\(UUID().uuidString)"
    try Data(marker.utf8).write(to: identity.appendingPathComponent("SOUL.md"))

    let engine = SwiftNativePersonaEngine.isolated(dataRoot: dataRoot)
    let docs = try await engine.listPersonaDocs()
    let resolvedRoot = await engine.personaRoot

    #expect(resolvedRoot.standardizedFileURL == identity.standardizedFileURL)
    #expect(docs.map(\.content) == [marker])
}

// MARK: - Resolver: env var wins (literal)

@Test func resolvePersonaRoot_envVar_takes_precedence() async throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    let env = ["NATIVE_AGENT_PERSONA_ROOT": tmp.path]
    let resolved = PersonaRootResolver.resolve(environment: env, repoRoot: nil)
    #expect(resolved.path == tmp.path)
}

@Test func resolvePersonaRoot_envVar_preserves_literal_tilde() async throws {
    // KEY TRAP: Python `Path(env)` keeps `~` literal; Foundation
    // `URL(fileURLWithPath:)` silently expands it. The resolver must use
    // URLComponents to preserve the tilde so behavior matches Python.
    let env = ["NATIVE_AGENT_PERSONA_ROOT": "~/some/persona"]
    let resolved = PersonaRootResolver.resolve(environment: env, repoRoot: nil)
    // The literal `~` segment must survive — NOT expanded to $HOME.
    // URLComponents file-URL builders may percent-encode `~` as `%7E`;
    // both are valid literal-tilde forms. Mirror PersistenceCore's
    // `defaultDataRoot_envVarPreservesLeadingTilde` assertion shape.
    let expanded = ("~/some/persona" as NSString).expandingTildeInPath
    #expect(resolved.path != expanded,
            "leading ~ must NOT be expanded to \(expanded); got \(resolved.path)")
    #expect(resolved.path.contains("~") || resolved.path.contains("%7E"),
            "expected literal ~ preserved (raw or %7E), got \(resolved.path)")
}

// MARK: - Resolver: repo fallback

@Test func resolvePersonaRoot_repo_fallback_works() async throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    let personaDir = tmp.appendingPathComponent("persona", isDirectory: true)
    try FileManager.default.createDirectory(at: personaDir, withIntermediateDirectories: true)
    let env: [String: String] = [:] // unset
    let resolved = PersonaRootResolver.resolve(
        environment: env,
        repoRoot: tmp,
        dataRootProvider: { tmp.appendingPathComponent("data", isDirectory: true) }
    )
    #expect(resolved.path == personaDir.path)
}

@Test func resolvePersonaRoot_rejects_path_inside_app_bundle() async throws {
    // Simulate the bundle layout: <tmp>/SomeThing.app/Contents/Resources/persona
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    let bundleRepo = tmp
        .appendingPathComponent("Foo.app", isDirectory: true)
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("Resources", isDirectory: true)
    let personaDir = bundleRepo.appendingPathComponent("persona", isDirectory: true)
    try FileManager.default.createDirectory(at: personaDir, withIntermediateDirectories: true)
    // Fallback data root provides the canonical app-owned persona parent.
    let dataRoot = tmp.appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(
        at: dataRoot.appendingPathComponent("persona"),
        withIntermediateDirectories: true)
    let env: [String: String] = [:]
    let resolved = PersonaRootResolver.resolve(
        environment: env,
        repoRoot: bundleRepo,
        dataRootProvider: { dataRoot }
    )
    // Must NOT return the path inside the .app bundle — falls through to
    // the canonical data-root persona parent.
    #expect(resolved.path != personaDir.path)
    #expect(resolved.path == dataRoot.appendingPathComponent("persona").path)
}

@Test func resolvePersonaRoot_stampedRepo_missing_markers_falls_through() async throws {
    // Stage a tmp dir that looks vaguely like a repo (has `persona/`) but
    // is MISSING the required marker files. A stamped REPO_PATH pointing
    // at this dir must be REJECTED — Python's
    // `_validate_stamped_repo_path` requires all three of:
    //   persona/SOUL.template.md, script/init_persona.sh, Package.swift
    // Without marker validation, Swift would falsely accept and return
    // `<bad>/persona`. With the fix, it falls through to step 3 / step 4.
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }

    // The "bad" stamped target — has persona/ but no markers.
    let badRepo = tmp.appendingPathComponent("bad_repo", isDirectory: true)
    try FileManager.default.createDirectory(
        at: badRepo.appendingPathComponent("persona", isDirectory: true),
        withIntermediateDirectories: true)

    // Synthetic Resources/REPO_PATH layout pointing at badRepo.
    let fakeResources = tmp.appendingPathComponent("Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: fakeResources, withIntermediateDirectories: true)
    try Data(badRepo.path.utf8).write(to: fakeResources.appendingPathComponent("REPO_PATH"))

    // Data-root fallback — provide a clean canonical persona parent so we can
    // assert we landed there rather than at <bad>/persona.
    let dataRoot = tmp.appendingPathComponent("data", isDirectory: true)
    try FileManager.default.createDirectory(
        at: dataRoot.appendingPathComponent("persona"),
        withIntermediateDirectories: true)

    let resolved = PersonaRootResolver.resolve(
        environment: [:],
        repoRoot: tmp.appendingPathComponent("nonexistent-repo"),
        bundleBases: [fakeResources],
        dataRootProvider: { dataRoot }
    )

    let badPersona = badRepo.appendingPathComponent("persona").path
    #expect(resolved.path != badPersona,
            "stamped repo without markers must be rejected; got \(resolved.path)")
    #expect(resolved.path == dataRoot.appendingPathComponent("persona").path,
            "expected fallthrough to data_root/persona; got \(resolved.path)")
}

@Test func resolvePersonaRoot_stampedRepo_notesOnlyAgentDir_usesLegacyPersonaRoot() async throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }

    let repo = tmp.appendingPathComponent("repo", isDirectory: true)
    try writeFile("# Template", to: repo.appendingPathComponent("persona/SOUL.template.md"))
    try writeFile("# Agent", to: repo.appendingPathComponent("persona/SOUL.md"))
    try writeFile("# User", to: repo.appendingPathComponent("persona/USER.md"))
    try writeFile("#!/usr/bin/env bash\n", to: repo.appendingPathComponent("script/init_persona.sh"))
    try writeFile("// swift-tools-version: 6.0\n", to: repo.appendingPathComponent("Package.swift"))
    try writeFile("{}\n", to: repo.appendingPathComponent("persona/Agent/notes.jsonl"))

    let fakeResources = tmp.appendingPathComponent("Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: fakeResources, withIntermediateDirectories: true)
    try Data(repo.path.utf8).write(to: fakeResources.appendingPathComponent("REPO_PATH"))

    let dataRoot = tmp.appendingPathComponent("data", isDirectory: true)
    try writeFile("# Generated user", to: dataRoot.appendingPathComponent("persona/Agent/USER.md"))

    let resolved = PersonaRootResolver.resolve(
        environment: [:],
        repoRoot: tmp.appendingPathComponent("nonexistent-repo"),
        bundleBases: [fakeResources],
        dataRootProvider: { dataRoot }
    )

    #expect(resolved.path == repo.appendingPathComponent("persona", isDirectory: true).path,
            "notes-only persona/Agent must not hide legacy repo persona root; got \(resolved.path)")
}

@Test func resolvePersonaRoot_dataRoot_persona_fallback() async throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    let dataRoot = tmp.appendingPathComponent("data", isDirectory: true)
    let env: [String: String] = [:]
    let resolved = PersonaRootResolver.resolve(
        environment: env,
        repoRoot: tmp.appendingPathComponent("nonexistent-repo"),
        dataRootProvider: { dataRoot }
    )
    let expected = dataRoot.appendingPathComponent("persona")
    #expect(resolved.path == expected.path)
}

@Test func resolvePersonaRoot_directCanonicalSoul_beatsRepoFallback() async throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    let dataRoot = tmp.appendingPathComponent("app-support-root", isDirectory: true)
    let canonicalPersona = dataRoot.appendingPathComponent("persona", isDirectory: true)
    try writeFile("# Installed identity", to: canonicalPersona.appendingPathComponent("SOUL.md"))

    let unrelatedRepo = tmp.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(
        at: unrelatedRepo.appendingPathComponent("persona", isDirectory: true),
        withIntermediateDirectories: true
    )

    let resolved = PersonaRootResolver.resolve(
        environment: [:],
        repoRoot: unrelatedRepo,
        bundleBases: [],
        dataRootProvider: { dataRoot }
    )
    #expect(resolved.standardizedFileURL == canonicalPersona.standardizedFileURL)
}

// MARK: - listPersonaDocs

@Test func listPersonaDocs_empty_dir_returns_empty() async throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    let engine = hermeticPersona(root: tmp)
    let docs = try await engine.listPersonaDocs()
    #expect(docs.isEmpty)
}

@Test func listPersonaDocs_returns_md_files_sorted_by_id() async throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    try writeFile("Voice content", to: tmp.appendingPathComponent("VOICE.md"))
    try writeFile("Soul content", to: tmp.appendingPathComponent("SOUL.md"))
    try writeFile("User content", to: tmp.appendingPathComponent("USER.md"))
    let engine = hermeticPersona(root: tmp)
    let docs = try await engine.listPersonaDocs()
    let ids = docs.map(\.id)
    #expect(ids == ["SOUL", "USER", "VOICE"], "expected ASC sort, got \(ids)")
}

@Test func listPersonaDocs_skips_non_md_files() async throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    try writeFile("not markdown", to: tmp.appendingPathComponent("notes.txt"))
    try writeFile("Soul", to: tmp.appendingPathComponent("SOUL.md"))
    try writeFile("config", to: tmp.appendingPathComponent("config.json"))
    let engine = hermeticPersona(root: tmp)
    let docs = try await engine.listPersonaDocs()
    #expect(docs.map(\.id) == ["SOUL"])
}

@Test func listPersonaDocs_skips_dotfiles() async throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    try writeFile("system", to: tmp.appendingPathComponent(".DS_Store"))
    try writeFile("hidden md", to: tmp.appendingPathComponent(".hidden.md"))
    try writeFile("Soul", to: tmp.appendingPathComponent("SOUL.md"))
    let engine = hermeticPersona(root: tmp)
    let docs = try await engine.listPersonaDocs()
    #expect(docs.map(\.id) == ["SOUL"])
}

@Test func listPersonaDocs_skips_backup_files() async throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    try writeFile("Soul", to: tmp.appendingPathComponent("SOUL.md"))
    try writeFile("backup1", to: tmp.appendingPathComponent("SOUL.md.bak"))
    try writeFile("backup2", to: tmp.appendingPathComponent("USER.md.pre-2026-05-07.bak"))
    try writeFile("capevict", to: tmp.appendingPathComponent("USER.pre-capevict-2026-05-16T143455.bak"))
    let engine = hermeticPersona(root: tmp)
    let docs = try await engine.listPersonaDocs()
    #expect(docs.map(\.id) == ["SOUL"], "expected only SOUL, got \(docs.map(\.id))")
}

@Test func listPersonaDocs_includes_template_md_files() async throws {
    // The daemon treats `SOUL.template.md` as part of the persona surface
    // for first-run onboarding — it must be included in the listing.
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    try writeFile("Soul", to: tmp.appendingPathComponent("SOUL.md"))
    try writeFile("Soul template", to: tmp.appendingPathComponent("SOUL.template.md"))
    try writeFile("User template", to: tmp.appendingPathComponent("USER.template.md"))
    let engine = hermeticPersona(root: tmp)
    let docs = try await engine.listPersonaDocs()
    let ids = docs.map(\.id)
    #expect(ids == ["SOUL", "SOUL.template", "USER.template"], "got \(ids)")
}

@Test func listPersonaDocs_skips_subdirectories() async throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    try writeFile("Soul", to: tmp.appendingPathComponent("SOUL.md"))
    let subdir = tmp.appendingPathComponent("custom", isDirectory: true)
    try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
    try writeFile("Nested", to: subdir.appendingPathComponent("NESTED.md"))
    let engine = hermeticPersona(root: tmp)
    let docs = try await engine.listPersonaDocs()
    #expect(docs.map(\.id) == ["SOUL"], "must not descend into subdirs")
}

@Test func getPersonaDoc_found() async throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    try writeFile("hi", to: tmp.appendingPathComponent("SOUL.md"))
    let engine = hermeticPersona(root: tmp)
    let doc = try await engine.getPersonaDoc(id: "SOUL")
    #expect(doc != nil)
    #expect(doc?.content == "hi")
}

@Test func getPersonaDoc_notFound() async throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    try writeFile("hi", to: tmp.appendingPathComponent("SOUL.md"))
    let engine = hermeticPersona(root: tmp)
    let doc = try await engine.getPersonaDoc(id: "MISSING")
    #expect(doc == nil)
}

// MARK: - PersonaDoc invariants

@Test func PersonaDoc_sizeBytes_matches_utf8_byte_length() async throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    // Non-ASCII content — bytes != characters.
    let content = "Claude 🚀\nVoice\nLine 3\nüñïçødé"
    try writeFile(content, to: tmp.appendingPathComponent("SOUL.md"))
    let engine = hermeticPersona(root: tmp)
    let docs = try await engine.listPersonaDocs()
    #expect(docs.count == 1)
    let expected = content.utf8.count
    #expect(docs[0].sizeBytes == expected,
            "expected sizeBytes=\(expected), got \(docs[0].sizeBytes)")
}

@Test func PersonaDoc_mtime_matches_filesystem() async throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    let url = tmp.appendingPathComponent("SOUL.md")
    try writeFile("x", to: url)
    let fsMtime = try (FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    let engine = hermeticPersona(root: tmp)
    let docs = try await engine.listPersonaDocs()
    #expect(docs.count == 1)
    if let fs = fsMtime {
        // Within 1 second — depends on resource-value cache granularity.
        let diff = abs(docs[0].mtime.timeIntervalSince(fs))
        #expect(diff < 1.0, "mtime drift > 1s: \(diff)")
    }
}

// MARK: - Native file writes → Swift reads

@Test func markdownFileWrittenOnDisk_readsThroughSwift() async throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    let content = "Claude SOUL\n# Heading\nLine with unicode ✨ ü\n"
    try writeFile(content, to: tmp.appendingPathComponent("SOUL.md"))
    let engine = hermeticPersona(root: tmp)
    let docs = try await engine.listPersonaDocs()
    #expect(docs.count == 1)
    #expect(docs[0].id == "SOUL")
    #expect(docs[0].content == content)
    #expect(docs[0].sizeBytes == content.utf8.count)
}

// MARK: - Replay baseline

@Test func replayBaselinePersonaDocsMatchesCapture() async throws {
    // Locate the persona_engine capture dir. There is exactly one capture
    // landed in step 3 of the migration; if more accumulate, the test reads
    // the first one — they all describe the same persona-root snapshot.
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let capturesDir = repoRoot.appendingPathComponent("tests/replay/captures/persona_engine", isDirectory: true)
    guard FileManager.default.fileExists(atPath: capturesDir.path) else {
        // Capture not yet recorded — accept SKIP semantics (test passes,
        // logs a hint). Once the capture lands the assertion fires.
        return
    }
    let files = try FileManager.default.contentsOfDirectory(
        at: capturesDir, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard let first = files.first else { return }
    let captureData = try Data(contentsOf: first)
    let raw = try JSONSerialization.jsonObject(with: captureData, options: [])
    guard let dict = raw as? [String: Any],
          let output = dict["output"] as? [String: Any],
          let body = output["body"] as? [[String: Any]] else {
        Issue.record("capture shape unexpected at \(first.lastPathComponent)")
        return
    }

    // Seed a temp persona dir from the capture body.
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    for row in body {
        guard let id = row["id"] as? String,
              let content = row["content"] as? String else { continue }
        try writeFile(content, to: tmp.appendingPathComponent("\(id).md"))
    }

    let engine = hermeticPersona(root: tmp)
    let docs = try await engine.listPersonaDocs()

    // Same count.
    #expect(docs.count == body.count,
            "expected \(body.count), got \(docs.count)")

    // id sort is ASC and matches capture order.
    let expectedIds = body.compactMap { $0["id"] as? String }.sorted()
    #expect(docs.map(\.id) == expectedIds,
            "id order mismatch.\nexpected: \(expectedIds)\nactual:   \(docs.map(\.id))")

    // sizeBytes must match the capture (computed identically — UTF-8 bytes).
    for (i, doc) in docs.enumerated() {
        let row = body.first { ($0["id"] as? String) == doc.id }!
        if let expectedSize = row["sizeBytes"] as? Int {
            #expect(doc.sizeBytes == expectedSize,
                    "sizeBytes mismatch at idx \(i) (id \(doc.id))")
        }
    }
}

// MARK: - listPersonaDocSpecs (wire-shape adapter for /v1/personality/docs)

@Test func listPersonaDocSpecs_maps_fixture_docs_to_wire_shape() async throws {
    // The persona-doc listing always returns the fixed 5 specs
    // (SOUL/VOICE/GROWTH/USER/AGENTS), in that exact order.
    //   - SOUL missing → all 5 stay empty (uninitialized).
    //   - SOUL present → missing VOICE/GROWTH/AGENTS get default content and
    //     updatedAt stays nil (Swift doesn't write). USER.md is MemoryV2-owned,
    //     so it only surfaces content when the generated file exists.
    // This test fixture writes SOUL + USER, so VOICE/GROWTH/AGENTS get
    // their default content.
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }

    let soulURL = tmp.appendingPathComponent("SOUL.md")
    let userURL = tmp.appendingPathComponent("USER.md")
    try writeFile("Soul body", to: soulURL)
    try writeFile("User body", to: userURL)

    let soulMtime = Date(timeIntervalSince1970: 1_700_000_000)
    let userMtime = Date(timeIntervalSince1970: 1_700_100_000)
    try FileManager.default.setAttributes([.modificationDate: soulMtime], ofItemAtPath: soulURL.path)
    try FileManager.default.setAttributes([.modificationDate: userMtime], ofItemAtPath: userURL.path)

    let engine = hermeticPersona(root: tmp)
    let listing = try await engine.listPersonaDocSpecs()

    // Five fixed specs, in load-bearing order.
    #expect(listing.docs.count == 5, "expected 5 docs, got \(listing.docs.count)")
    #expect(listing.docs.map(\.id) == ["SOUL", "VOICE", "GROWTH", "USER", "AGENTS"])
    #expect(listing.docs.map(\.title) == ["Soul", "Voice", "Growth", "User", "Operating Manual"])
    #expect(listing.docs.map(\.filename) == ["SOUL.md", "VOICE.md", "GROWTH.md", "USER.md", "AGENTS.md"])

    // Paths are always the joined persona-root + filename, present-or-not.
    for spec in listing.docs {
        #expect(spec.path == tmp.appendingPathComponent(spec.filename).path,
                "spec path should always be <root>/<filename>: \(spec.id)")
    }

    // Present files surface their content + mtime.
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let soulDoc = listing.docs.first { $0.id == "SOUL" }!
    let userDoc = listing.docs.first { $0.id == "USER" }!
    #expect(soulDoc.content == "Soul body")
    #expect(soulDoc.updatedAt == iso.string(from: soulMtime))
    #expect(userDoc.content == "User body")
    #expect(userDoc.updatedAt == iso.string(from: userMtime))
    // SOUL is present so the persona is "initialized" — missing
    // VOICE/GROWTH/AGENTS must surface default content
    // (non-empty), with updatedAt still nil (Swift didn't write).
    for missingId in ["VOICE", "GROWTH", "AGENTS"] {
        let doc = listing.docs.first { $0.id == missingId }!
        #expect(!doc.content.isEmpty,
                "missing \(missingId).md must surface default content — got empty")
        #expect(doc.updatedAt == nil,
                "missing \(missingId).md must surface as nil updatedAt (no write happened)")
    }

    // Top-level updatedAt is `now_iso()` per daemon — non-nil, non-empty.
    #expect(listing.updatedAt != nil, "top-level updatedAt must be present (daemon emits now_iso)")
    #expect(!(listing.updatedAt ?? "").isEmpty)
}

// MARK: - Default persona doc content once SOUL exists

/// Regression net for fixed persona-doc listing. Once SOUL.md exists, mutable
/// missing docs surface default content. USER.md is MemoryV2-owned, so missing
/// USER stays empty until MemoryV2 regenerates it from SQLite.
/// This test pins:
///   1. SOUL missing → all 5 stay empty (uninitialized; matches daemon).
///   2. SOUL present, mutable docs missing → each mutable missing doc surfaces
///      default body text, while USER stays empty.
@Test func listPersonaDocSpecs_soulInitialized_fills_defaults_for_missing_docs() async throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    try writeFile("Soul present", to: tmp.appendingPathComponent("SOUL.md"))

    // Bug 5 fix (3rd-round Wave 4): listPersonaDocSpecs now loads profile.json
    // from dataRoot. Use an isolated empty dataRoot so the defaults fall back
    // to CompiledPersonalityProfile.defaults (name="NativeAgent") — otherwise
    // this test would inherit the host's real profile and become non-hermetic.
    let isolatedData = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: isolatedData) }
    let listing = try await SwiftNativePersonaEngine(root: tmp, dataRoot: isolatedData).listPersonaDocSpecs()
    let docs = Dictionary(uniqueKeysWithValues: listing.docs.map { ($0.id, $0) })

    // SOUL itself uses its on-disk body.
    #expect(docs["SOUL"]?.content == "Soul present")

    // Mutable missing docs get default content.
    for missingId in ["VOICE", "GROWTH", "AGENTS"] {
        let doc = docs[missingId]!
        #expect(!doc.content.isEmpty, "\(missingId): expected default content; got empty")
        #expect(doc.updatedAt == nil,
                "\(missingId): updatedAt must be nil — Swift doesn't write the default")
    }

    #expect(docs["USER"]?.content == "", "missing USER.md must not get a persona default")
    #expect(docs["USER"]?.updatedAt == nil)

    // Spot-check the others contain unmistakable header phrases.
    #expect(docs["VOICE"]?.content.contains("# NativeAgent Voice") == true)
    #expect(docs["GROWTH"]?.content.contains("# NativeAgent Growth") == true)
    #expect(docs["AGENTS"]?.content.contains("# NativeAgent Operating Manual") == true)
}

/// Bug 5 (3rd-round Wave 4 review): defaults rendered from `profile.json`
/// must reflect the user's customized name/voice/examples — matching the
/// daemon which calls `self.personality()` (NOT hardcoded defaults). Seed
/// profile.json with name="Claude" and check it appears in the defaults.
@Test func listPersonaDocSpecs_rendersDefaultsFromProfileJson() async throws {
    let personaRoot = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: personaRoot) }
    try writeFile("Soul present", to: personaRoot.appendingPathComponent("SOUL.md"))

    let dataRoot = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: dataRoot) }
    let memoryDir = dataRoot.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
    let profileJSON = """
    {
      "name": "Claude",
      "personaKind": "ai",
      "essence": "the user's tactical AI on his side.",
      "voice": "Dry, sharp, fast."
    }
    """
    try Data(profileJSON.utf8).write(to: memoryDir.appendingPathComponent("profile.json"))

    let engine = SwiftNativePersonaEngine(root: personaRoot, dataRoot: dataRoot)
    let listing = try await engine.listPersonaDocSpecs()
    let docs = Dictionary(uniqueKeysWithValues: listing.docs.map { ($0.id, $0) })

    // The customized name must appear in at least one rendered default doc.
    let renderedDefaults = [
        docs["VOICE"]?.content ?? "",
        docs["GROWTH"]?.content ?? "",
        docs["AGENTS"]?.content ?? "",
    ].joined(separator: "\n")
    #expect(renderedDefaults.contains("Claude"),
            "Bug 5 (3rd-round): default doc content must render from profile.json (name=Claude); got: \(renderedDefaults.prefix(200))")
}

/// Bug D (4th-round Wave 4 review): default doc content must byte-match
/// Python's `default_personality_doc_content` (daemon L34374-34466) more
/// closely. Two specific drift points fixed:
///   1. GROWTH must include the `now_iso()` baseline line (was: bare "- baseline · ...").
///   2. VOICE with empty profile.examples/forbiddenPatterns must fall
///      back to Python's exact strings ("- Lead with the useful answer."
///      and "- Generic assistant filler.") — was: Swift's multi-line
///      CompiledPersonalityProfile.defaults bodies.
@Test func defaultPersonalityDocContent_growthHasNowIsoLine_andVoiceFallbacks() async throws {
    // GROWTH: with a fixed `now` to make the assertion exact-bytes.
    let fixed = Date(timeIntervalSince1970: 1_780_000_000) // 2026-05-26T...
    let growth = SwiftNativePersonaEngine.defaultPersonalityDocContent(
        id: "GROWTH",
        profile: .defaults,
        now: fixed
    )
    // The baseline line must carry an ISO8601 timestamp prefix.
    let baselineRegex = #/^- \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* · baseline · Soul layer initialized for AI mode\.$/#
    let baselineLine = growth.split(separator: "\n").first { $0.contains("baseline") }
    #expect(baselineLine != nil, "GROWTH must contain a baseline line")
    if let line = baselineLine {
        #expect(String(line).wholeMatch(of: baselineRegex) != nil,
                "Bug D: GROWTH baseline line must include now_iso() timestamp; got: \(line)")
    }

    // VOICE: empty examples/forbidden must use Python's fallback strings.
    let voiceEmpty = SwiftNativePersonaEngine.defaultPersonalityDocContent(
        id: "VOICE",
        profile: CompiledPersonalityProfile(
            schemaVersion: 2,
            personaEngineVersion: "2.0",
            name: "NativeAgent",
            personaKind: "AI",
            essence: "",
            voice: "",
            customDirective: "",
            traits: CompiledPersonalityProfile.defaults.traits,
            examples: [],
            forbiddenPatterns: [],
            instincts: [],
            boundaries: [],
            surfaceOverrides: [:],
            updatedAt: ""
        )
    )
    #expect(voiceEmpty.contains("- Lead with the useful answer."),
            "Bug D: VOICE empty-examples fallback must be Python's exact string; got: \(voiceEmpty)")
    #expect(voiceEmpty.contains("- Generic assistant filler."),
            "Bug D: VOICE empty-forbidden fallback must be Python's exact string; got: \(voiceEmpty)")
    // And it must NOT carry Swift's multi-line defaults (drift).
    #expect(!voiceEmpty.contains("Lead with the useful answer, then show only"),
            "Bug D: VOICE empty-examples must not fall back to Swift CompiledPersonalityProfile.defaults")
    #expect(!voiceEmpty.contains("Corporate filler."),
            "Bug D: VOICE empty-forbidden must not fall back to Swift CompiledPersonalityProfile.defaults")
}

@Test func listPersonaDocSpecs_empty_dir_returns_five_empty_specs() async throws {
    // Daemon contract: even with no files on disk, /v1/personality/docs
    // returns the 5-spec placeholder list with content="" + updatedAt=nil
    // for each. This test exists specifically to lock in the bug-fix:
    // the prior dir-scan implementation returned ZERO rows here, which
    // diverged from the daemon's 5-placeholder response.
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }
    let listing = try await hermeticPersona(root: tmp).listPersonaDocSpecs()
    #expect(listing.docs.count == 5)
    #expect(listing.docs.map(\.id) == ["SOUL", "VOICE", "GROWTH", "USER", "AGENTS"])
    for spec in listing.docs {
        #expect(spec.content == "", "\(spec.id) content must be empty when file is missing")
        #expect(spec.updatedAt == nil, "\(spec.id) updatedAt must be nil when file is missing")
    }
    // Top-level updatedAt is now_iso() — present and non-empty.
    #expect((listing.updatedAt ?? "").isEmpty == false)
}

// MARK: - agentDisplayName tests

@Test func agentDisplayName_genericNames_fallToNativeAgent() {
    let genericNames = ["agent", "custom", "ai", "male", "female",
                        "AI", "Custom", "Agent", "Male", "Female"]
    for rawName in genericNames {
        let profile = CompiledPersonalityProfile(
            schemaVersion: CompiledPersonalityProfile.defaults.schemaVersion,
            personaEngineVersion: CompiledPersonalityProfile.defaults.personaEngineVersion,
            name: rawName,
            personaKind: CompiledPersonalityProfile.defaults.personaKind,
            essence: CompiledPersonalityProfile.defaults.essence,
            voice: CompiledPersonalityProfile.defaults.voice,
            customDirective: CompiledPersonalityProfile.defaults.customDirective,
            traits: CompiledPersonalityProfile.defaults.traits,
            examples: CompiledPersonalityProfile.defaults.examples,
            forbiddenPatterns: CompiledPersonalityProfile.defaults.forbiddenPatterns,
            instincts: CompiledPersonalityProfile.defaults.instincts,
            boundaries: CompiledPersonalityProfile.defaults.boundaries,
            surfaceOverrides: CompiledPersonalityProfile.defaults.surfaceOverrides,
            updatedAt: CompiledPersonalityProfile.defaults.updatedAt
        )
        let result = PersonaCompiler.agentDisplayName(profile: profile)
        #expect(result == "NativeAgent",
                "Generic name \"\(rawName)\" should fall back to \"NativeAgent\", got \"\(result)\"")
    }
}

@Test func agentDisplayName_realName_passesThrough() {
    let profile = CompiledPersonalityProfile(
        schemaVersion: CompiledPersonalityProfile.defaults.schemaVersion,
        personaEngineVersion: CompiledPersonalityProfile.defaults.personaEngineVersion,
        name: "Claude",
        personaKind: CompiledPersonalityProfile.defaults.personaKind,
        essence: CompiledPersonalityProfile.defaults.essence,
        voice: CompiledPersonalityProfile.defaults.voice,
        customDirective: CompiledPersonalityProfile.defaults.customDirective,
        traits: CompiledPersonalityProfile.defaults.traits,
        examples: CompiledPersonalityProfile.defaults.examples,
        forbiddenPatterns: CompiledPersonalityProfile.defaults.forbiddenPatterns,
        instincts: CompiledPersonalityProfile.defaults.instincts,
        boundaries: CompiledPersonalityProfile.defaults.boundaries,
        surfaceOverrides: CompiledPersonalityProfile.defaults.surfaceOverrides,
        updatedAt: CompiledPersonalityProfile.defaults.updatedAt
    )
    let result = PersonaCompiler.agentDisplayName(profile: profile)
    #expect(result == "Claude", "Real name \"Claude\" should pass through unchanged, got \"\(result)\"")
}

@Test func agentDisplayName_empty_fallsToNativeAgent() {
    for rawName in ["", "   "] {
        let profile = CompiledPersonalityProfile(
            schemaVersion: CompiledPersonalityProfile.defaults.schemaVersion,
            personaEngineVersion: CompiledPersonalityProfile.defaults.personaEngineVersion,
            name: rawName,
            personaKind: CompiledPersonalityProfile.defaults.personaKind,
            essence: CompiledPersonalityProfile.defaults.essence,
            voice: CompiledPersonalityProfile.defaults.voice,
            customDirective: CompiledPersonalityProfile.defaults.customDirective,
            traits: CompiledPersonalityProfile.defaults.traits,
            examples: CompiledPersonalityProfile.defaults.examples,
            forbiddenPatterns: CompiledPersonalityProfile.defaults.forbiddenPatterns,
            instincts: CompiledPersonalityProfile.defaults.instincts,
            boundaries: CompiledPersonalityProfile.defaults.boundaries,
            surfaceOverrides: CompiledPersonalityProfile.defaults.surfaceOverrides,
            updatedAt: CompiledPersonalityProfile.defaults.updatedAt
        )
        let result = PersonaCompiler.agentDisplayName(profile: profile)
        #expect(result == "NativeAgent",
                "Empty/whitespace name \"\(rawName)\" should fall back to \"NativeAgent\", got \"\(result)\"")
    }
}

@Test func agentDisplayName_truncatesAtEightyChars() {
    let longName = String(repeating: "a", count: 100)
    let profile = CompiledPersonalityProfile(
        schemaVersion: CompiledPersonalityProfile.defaults.schemaVersion,
        personaEngineVersion: CompiledPersonalityProfile.defaults.personaEngineVersion,
        name: longName,
        personaKind: CompiledPersonalityProfile.defaults.personaKind,
        essence: CompiledPersonalityProfile.defaults.essence,
        voice: CompiledPersonalityProfile.defaults.voice,
        customDirective: CompiledPersonalityProfile.defaults.customDirective,
        traits: CompiledPersonalityProfile.defaults.traits,
        examples: CompiledPersonalityProfile.defaults.examples,
        forbiddenPatterns: CompiledPersonalityProfile.defaults.forbiddenPatterns,
        instincts: CompiledPersonalityProfile.defaults.instincts,
        boundaries: CompiledPersonalityProfile.defaults.boundaries,
        surfaceOverrides: CompiledPersonalityProfile.defaults.surfaceOverrides,
        updatedAt: CompiledPersonalityProfile.defaults.updatedAt
    )
    let result = PersonaCompiler.agentDisplayName(profile: profile)
    #expect(result.count == 80, "100-char name should be truncated to 80 chars, got \(result.count)")
    #expect(result == String(repeating: "a", count: 80),
            "Truncated result should be first 80 'a' characters")
}

@Test func agentDisplayName_truncatesByCodePointsNotGraphemes() {
    // Python `name[:80]` slices Unicode CODE POINTS, not extended grapheme
    // clusters. The Swift mirror must do the same via unicodeScalars or it
    // diverges for grapheme-cluster-rich names (compound emoji, ZWJ
    // sequences). 100 thumbs-up-with-medium-skin-tone graphemes = 200 code
    // points; Python keeps 80 code points = 40 displayed graphemes.
    let oneGraphemeTwoScalars = "\u{1F44D}\u{1F3FD}"  // 👍🏽
    let payload = String(repeating: oneGraphemeTwoScalars, count: 100)
    // Sanity: 100 graphemes / 200 scalars.
    #expect(payload.count == 100)
    #expect(payload.unicodeScalars.count == 200)
    let profile = CompiledPersonalityProfile(
        schemaVersion: CompiledPersonalityProfile.defaults.schemaVersion,
        personaEngineVersion: CompiledPersonalityProfile.defaults.personaEngineVersion,
        name: payload,
        personaKind: CompiledPersonalityProfile.defaults.personaKind,
        essence: CompiledPersonalityProfile.defaults.essence,
        voice: CompiledPersonalityProfile.defaults.voice,
        customDirective: CompiledPersonalityProfile.defaults.customDirective,
        traits: CompiledPersonalityProfile.defaults.traits,
        examples: CompiledPersonalityProfile.defaults.examples,
        forbiddenPatterns: CompiledPersonalityProfile.defaults.forbiddenPatterns,
        instincts: CompiledPersonalityProfile.defaults.instincts,
        boundaries: CompiledPersonalityProfile.defaults.boundaries,
        surfaceOverrides: CompiledPersonalityProfile.defaults.surfaceOverrides,
        updatedAt: CompiledPersonalityProfile.defaults.updatedAt
    )
    let result = PersonaCompiler.agentDisplayName(profile: profile)
    // Mirror Python: 80 code points = 40 thumbs-up graphemes.
    #expect(result.unicodeScalars.count == 80,
            "Should slice to 80 code points like Python, got \(result.unicodeScalars.count)")
    #expect(result.count == 40,
            "80 code points = 40 graphemes (each is 2 scalars), got \(result.count)")
}

@Test func agentDisplayName_dataRootVariant_readsProfileJson() throws {
    let tmp = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: tmp) }

    let profileURL = tmp.appendingPathComponent("memory/profile.json")

    // Write a profile with a generic name — should fall back to "NativeAgent".
    let genericPayload = """
        {"name": "agent", "personaKind": "AI", "schemaVersion": 2,
         "personaEngineVersion": "2.0", "essence": "", "voice": "",
         "customDirective": "", "traits": [], "examples": [],
         "forbiddenPatterns": [], "instincts": [], "boundaries": [],
         "surfaceOverrides": {}, "updatedAt": ""}
        """
    try writeFile(genericPayload, to: profileURL)
    let genericResult = PersonaCompiler.agentDisplayName(dataRoot: tmp)
    #expect(genericResult == "NativeAgent",
            "dataRoot variant with name=\"agent\" should return \"NativeAgent\", got \"\(genericResult)\"")

    // Overwrite with a real name — should pass through.
    let realPayload = """
        {"name": "River", "personaKind": "AI", "schemaVersion": 2,
         "personaEngineVersion": "2.0", "essence": "", "voice": "",
         "customDirective": "", "traits": [], "examples": [],
         "forbiddenPatterns": [], "instincts": [], "boundaries": [],
         "surfaceOverrides": {}, "updatedAt": ""}
        """
    try writeFile(realPayload, to: profileURL)
    let realResult = PersonaCompiler.agentDisplayName(dataRoot: tmp)
    #expect(realResult == "River",
            "dataRoot variant with a configured name should preserve it, got \"\(realResult)\"")
}

// MARK: - A5.5(c): persona .bak backup retention

@Test func backupRetentionKeepsNewestNAndPrunesOlder() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersonaBackupRetention-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let target = dir.appendingPathComponent("SOUL.md")
    let writes = SwiftNativePersonaEngine.backupRetention + 5   // 15 with default 10
    for i in 0..<writes {
        try "Identity revision \(i)".write(to: target, atomically: true, encoding: .utf8)
        _ = try SwiftNativePersonaEngine.backupIfExists(target)
    }

    let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .map(\.lastPathComponent)
        .filter { $0.hasPrefix("SOUL.md.pre-") && $0.hasSuffix(".bak") }
    // Unbounded accumulation is the bug — retention caps it at backupRetention.
    #expect(backups.count == SwiftNativePersonaEngine.backupRetention,
            "expected \(SwiftNativePersonaEngine.backupRetention) backups, got \(backups.count)")
    // The sweep only ever touches THIS target's timestamped backups.
    #expect(FileManager.default.fileExists(atPath: target.path))
}

@Test func backupPruneIsScopedToTargetSiblingsOnly() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PersonaBackupScope-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // A different file's backups + a non-backup sibling must survive the sweep.
    let voiceBak = dir.appendingPathComponent("VOICE.md.pre-20260101T000000000000Z-deadbeef.bak")
    try "voice backup".write(to: voiceBak, atomically: true, encoding: .utf8)
    let unrelated = dir.appendingPathComponent("SOUL.md.notes")
    try "not a backup".write(to: unrelated, atomically: true, encoding: .utf8)

    let target = dir.appendingPathComponent("SOUL.md")
    for i in 0..<(SwiftNativePersonaEngine.backupRetention + 3) {
        try "rev \(i)".write(to: target, atomically: true, encoding: .utf8)
        _ = try SwiftNativePersonaEngine.backupIfExists(target)
    }

    #expect(FileManager.default.fileExists(atPath: voiceBak.path), "VOICE.md backup must not be swept")
    #expect(FileManager.default.fileExists(atPath: unrelated.path), "non-backup sibling must not be swept")
}
