import Testing
import Foundation
@testable import PersistenceCore
import NativeAgentCore

// MARK: - InstalledSkillInventory.list — the capability view's silent zero
//
// LEDGER: core.persistence.InstalledSkillInventory.list
//
// This is the projection `list_skills`, `read_skill`, the Mac capability gauges
// and `capabilities.summary` all read. It merges the runtime registry with the
// resolved persona skill shelf and returns a plain array — so a MISSING or
// MISRESOLVED shelf is indistinguishable from "this agent has no skills." The
// agent simply stops knowing what it can do, and nothing anywhere logs it.
//
// Both roots are pinned explicitly in every test here: a bare default would
// resolve to the live repo and read User's real persona shelf.
@Suite("InstalledSkillInventory.list")
struct InstalledSkillInventoryTests {

    /// THE MERGE ENVELOPE: registry rows + runtime bodies + persona shelf, each
    /// tagged with the source it came from, deduped by name with the registry
    /// winning, sorted by name. Counts are stated as a partition of the result
    /// (which source contributed what) rather than one opaque total, so a
    /// regression that drops an entire source is visible as a zero in its bucket
    /// instead of a slightly smaller number.
    @Test func mergesRegistryRuntimeAndPersonaShelfWithoutDoubleCounting() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeRegistry(names: ["alpha", "beta"])
        try fixture.writeRuntimeBody(name: "gamma")
        try fixture.writePersonaBody(name: "delta")
        // Same NAME as a registry row: must not appear twice.
        try fixture.writePersonaBody(name: "alpha")

        let rows = fixture.list()
        let names = rows.compactMap { fixture.string($0, "name") }
        let sources = rows.compactMap { fixture.string($0, "source") }

        #expect(names == ["alpha", "beta", "delta", "gamma"], "sorted by name, one row per name")
        #expect(names.count == Set(names).count, "a persona body sharing a registry name must not double-count")
        #expect(sources.filter { $0 == "runtime_registry" }.count == 2)
        #expect(sources.filter { $0 == "runtime_body" }.count == 1)
        #expect(sources.filter { $0 == "persona_body" }.count == 1)
        // The registry, not the shelf, owns a contested name.
        let alphaSource = rows
            .first { fixture.string($0, "name") == "alpha" }
            .flatMap { fixture.string($0, "source") }
        #expect(alphaSource == "runtime_registry")
    }

    /// THE SILENT ZERO, made visible. A misresolved persona root is not an
    /// error, a nil, or a diagnostic — it is a SHORTER LIST. The registry half
    /// still answers, so the caller sees a plausible inventory that is quietly
    /// missing the whole persona shelf.
    ///
    /// This is a characterization, not an endorsement: the fix needs a
    /// production seam (a reason channel on the return type) and this wave is
    /// tests-only. Pinning the exact delta means the day the seam lands, this
    /// test names what changed.
    @Test func misresolvedPersonaRootSilentlyShrinksTheListInsteadOfReporting() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writeRegistry(names: ["alpha"])
        try fixture.writePersonaBody(name: "delta")
        try fixture.writePersonaBody(name: "epsilon")

        let healthy = fixture.list()
        let misresolved = fixture.list(
            personaRoot: fixture.root.appendingPathComponent("persona-that-does-not-exist")
        )

        #expect(healthy.count == 3)
        // NOT zero, NOT an error — just two rows quieter.
        #expect(misresolved.count == 1)
        #expect(healthy.count - misresolved.count == 2)
        #expect(misresolved.compactMap { fixture.string($0, "source") } == ["runtime_registry"])
    }

    /// A registry with NO shelf and a shelf with NO registry both answer with
    /// their own half — the merge never requires both to be present, which is
    /// what makes a one-sided failure invisible. Stated so a future
    /// "fail-closed" change is a deliberate, visible break.
    @Test func eachSourceAnswersAloneWhenTheOtherIsAbsent() throws {
        let registryOnly = try Fixture()
        defer { registryOnly.cleanUp() }
        try registryOnly.writeRegistry(names: ["alpha", "beta"])
        #expect(registryOnly.list().count == 2)

        let shelfOnly = try Fixture()
        defer { shelfOnly.cleanUp() }
        try shelfOnly.writePersonaBody(name: "delta")
        #expect(shelfOnly.list().count == 1)

        let neither = try Fixture()
        defer { neither.cleanUp() }
        #expect(neither.list().isEmpty, "an empty inventory is a real state — it just cannot be told from a broken one")
    }

    /// A shelf body that violates skill-body hygiene is EXCLUDED, and its
    /// exclusion is silent too. Pinned because it is the one filter that can
    /// shrink the count for a reason other than a missing root — without this,
    /// the test above could be satisfied by a filter that dropped everything.
    @Test func hygieneViolatingShelfBodyIsExcluded() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.writePersonaBody(name: "clean")
        try fixture.writePersonaBody(name: "dirty", body: "# Dirty\n\nRun the python helper.\n")

        let names = fixture.list().compactMap { fixture.string($0, "name") }
        #expect(names == ["clean"])
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let dataRoot: URL
        let personaRoot: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("skill-inventory-\(UUID().uuidString)", isDirectory: true)
            dataRoot = root.appendingPathComponent("data", isDirectory: true)
            personaRoot = root.appendingPathComponent("persona", isDirectory: true)
            try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        func list(personaRoot override: URL? = nil) -> [JSONValue] {
            InstalledSkillInventory.list(
                dataRoot: dataRoot,
                sourceRoot: root,
                personaRoot: override ?? personaRoot
            )
        }

        func writeRegistry(names: [String]) throws {
            let skills = names.map { name in
                JSONValue.object([
                    "id": .string(name),
                    "name": .string(name),
                    "description": .string("\(name) description"),
                    "status": .string("installed"),
                ])
            }
            let path = dataRoot
                .appendingPathComponent("skills", isDirectory: true)
                .appendingPathComponent("registry.json")
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONValue.object(["skills": .array(skills)])
                .serializedData(pretty: true)
                .write(to: path, options: .atomic)
        }

        func writeRuntimeBody(name: String, body: String? = nil) throws {
            try writeBody(
                under: dataRoot.appendingPathComponent("skills/bodies", isDirectory: true),
                name: name,
                body: body
            )
        }

        func writePersonaBody(name: String, body: String? = nil) throws {
            try writeBody(
                under: personaRoot.appendingPathComponent("skills/bodies", isDirectory: true),
                name: name,
                body: body
            )
        }

        private func writeBody(under directory: URL, name: String, body: String?) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let text = body ?? "# \(name)\n\nUse this when \(name) applies.\n"
            try Data(text.utf8).write(
                to: directory.appendingPathComponent("\(name).md"),
                options: .atomic
            )
        }

        func string(_ row: JSONValue, _ key: String) -> String? {
            guard case .object(let object) = row,
                  case .string(let value)? = object[key] else { return nil }
            return value
        }
    }
}
