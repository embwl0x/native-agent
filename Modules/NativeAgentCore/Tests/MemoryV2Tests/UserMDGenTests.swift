import Testing
import Foundation
@testable import MemoryV2
import NativeAgentCore

@Suite("UserMDGenerator")
struct UserMDGenTests {
    /// A data root for an install that has FINISHED onboarding — USER.md
    /// generation is gated on that (fix-blank-install-onboarding, 2026-08-02;
    /// see UserMDOnboardingGateTests for the blank-install side).
    private func tmpRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usermdgen-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? Data("completed_at=test\n".utf8).write(to: url.appendingPathComponent(".onboarded"))
        return url
    }

    @Test func regenerateWritesFlatUndatedMarkdown() async throws {
        let store = try MemoryStorage()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persona = MemoryV2Defaults.personaID

        _ = try await store.insertMemory(StoredMemory(content: "the user prefers Opus 4.8", source: "chat"))
        _ = try await store.insertMemory(StoredMemory(content: "Agent uses dry voice", source: "dream"))
        _ = try await store.insertMemory(StoredMemory(
            content: "2026-06-10: Worklog discipline",
            source: "chat",
            metadata: .object(["kind": .string("fact")])
        ))
        _ = try await store.insertMemory(StoredMemory(
            content: "2026-06-11: Claude restored commit_memory",
            source: "chat",
            metadata: .object(["kind": .string("milestone")])
        ))

        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        let gen = UserMDGenerator(storage: store, dataRoot: root, personaRoot: personaRoot)
        let url = try await gen.regenerate(persona: persona)

        #expect(url == personaRoot.appendingPathComponent("USER.md"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("# User Facts (auto-generated from memory SQLite)"))
        #expect(!text.contains("Last regenerated:"))
        #expect(!text.contains("Total memories:"))
        #expect(text.contains("the user prefers Opus 4.8"))
        #expect(text.contains("Agent uses dry voice"))
        #expect(text.contains("- Worklog discipline\n"))
        #expect(text.contains("- 2026-06-11: Claude restored commit_memory\n"))
        // Flat list: no provenance headers, no per-fact timestamps.
        #expect(!text.contains("## From"))
        #expect(!text.contains("- 2026-06-10: Worklog discipline"))
        // Each fact is a bare bullet — no trailing ISO date in parens.
        #expect(text.contains("- the user prefers Opus 4.8\n"))
    }

    @Test func preservesHumanPreamble() async throws {
        let store = try MemoryStorage()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persona = MemoryV2Defaults.personaID

        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        let target = personaRoot.appendingPathComponent("USER.md")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let seeded = """
        \(UserMDGenerator.preambleStartMarker)
        Hand-written notes the user wants to keep.
        \(UserMDGenerator.preambleEndMarker)

        old auto body
        """
        try seeded.write(to: target, atomically: true, encoding: .utf8)

        _ = try await store.insertMemory(StoredMemory(content: "fact", source: "chat"))

        let gen = UserMDGenerator(storage: store, dataRoot: root, personaRoot: personaRoot)
        _ = try await gen.regenerate(persona: persona)

        let text = try String(contentsOf: target, encoding: .utf8)
        #expect(text.contains("Hand-written notes the user wants to keep."))
        #expect(text.contains(UserMDGenerator.preambleStartMarker))
        #expect(text.contains(UserMDGenerator.preambleEndMarker))
        #expect(!text.contains("Last regenerated:"))
        #expect(!text.contains("Total memories:"))
        #expect(!text.contains("old auto body"))
    }

    @Test func personaRootProjectionUsesCanonicalPartitionForCustomDisplayName() async throws {
        let store = try MemoryStorage()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let customDisplayName = "Renamed Agent"
        let canonicalFact = "canonical memory survives a renamed agent"
        let legacyFact = "legacy display-name partition must not select USER.md"
        _ = try await store.insertMemory(StoredMemory(content: canonicalFact, source: "chat"))
        _ = try await store.insertMemory(StoredMemory(
            content: legacyFact,
            personaId: customDisplayName,
            source: "legacy"
        ))

        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        let gen = UserMDGenerator(storage: store, dataRoot: root, personaRoot: personaRoot)
        let url = try await gen.regenerate(persona: customDisplayName)
        let text = try String(contentsOf: url, encoding: .utf8)

        #expect(url == personaRoot.appendingPathComponent("USER.md"))
        #expect(text.contains(canonicalFact))
        #expect(!text.contains(legacyFact))
    }

    @Test func canonicalLaunchAndLegacyMutationProduceSameProjection() async throws {
        let store = try MemoryStorage()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyPersona = "Former Display Name"
        let canonicalFacts = [
            "canonical fact written before launch",
            "canonical fact retained after mutation",
        ]
        let legacyFact = "legacy-only fact must not replace canonical USER.md"
        for fact in canonicalFacts {
            _ = try await store.insertMemory(StoredMemory(content: fact, source: "chat"))
        }
        _ = try await store.insertMemory(StoredMemory(
            content: legacyFact,
            personaId: legacyPersona,
            source: "legacy"
        ))

        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        let gen = UserMDGenerator(
            storage: store,
            dataRoot: root,
            personaRoot: personaRoot,
            debounceInterval: 0
        )

        let launchURL = try await gen.regenerate(persona: MemoryV2Defaults.personaID)
        let launchText = try String(contentsOf: launchURL, encoding: .utf8)
        let mutationResult = try await gen.requestRegeneration(persona: legacyPersona)
        #expect(mutationResult == launchURL)
        guard let mutationURL = mutationResult else { return }
        let mutationText = try String(contentsOf: mutationURL, encoding: .utf8)

        #expect(mutationText == launchText)
        for fact in canonicalFacts {
            #expect(mutationText.contains(fact))
        }
        #expect(!mutationText.contains(legacyFact))
    }

    @Test func debounceSkipsRapidRegenerations() async throws {
        let store = try MemoryStorage()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let nowBox = ClockBox(date: Date(timeIntervalSince1970: 1_000_000))
        let gen = UserMDGenerator(
            storage: store,
            dataRoot: root,
            debounceInterval: 30,
            now: { nowBox.current }
        )

        _ = try await store.insertMemory(StoredMemory(content: "a", source: "chat"))
        let first = try await gen.requestRegeneration(persona: MemoryV2Defaults.personaID)
        #expect(first != nil)

        nowBox.advance(by: 5)
        let second = try await gen.requestRegeneration(persona: MemoryV2Defaults.personaID)
        #expect(second == nil)

        nowBox.advance(by: 30)
        let third = try await gen.requestRegeneration(persona: MemoryV2Defaults.personaID)
        #expect(third != nil)
    }

    @Test func attachedGeneratorRegeneratesOnInsert() async throws {
        let store = try MemoryStorage()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        let gen = UserMDGenerator(storage: store, dataRoot: root, personaRoot: personaRoot, debounceInterval: 0)
        await store.attachUserMDGenerator(gen)

        _ = try await store.insertMemory(StoredMemory(content: "via insert", source: "chat"))

        let target = gen.userMDPath(persona: MemoryV2Defaults.personaID)
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: target.path) && Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: target.path))
        let text = try String(contentsOf: target, encoding: .utf8)
        #expect(text.contains("via insert"))
    }

    /// USER.md rides every prompt and is joined against the memory CONTEXT
    /// projection for precoverage. A row the projection refuses must not be
    /// rendered here: it would both re-state a superseded fact to the model and
    /// break the all-or-nothing precoverage join for the whole document.
    @Test func skipsRowsTheContextProjectionRefuses() async throws {
        let store = try MemoryStorage()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await store.insertMemory(StoredMemory(
            content: "User's sleep schedule is 19:00-03:00 — an early-bird pattern.",
            source: "chat"
        ))
        // Superseded half of a corrected pair: still `active`, but
        // recall-INELIGIBLE everywhere else in the system.
        _ = try await store.insertMemory(StoredMemory(
            content: "User keeps nocturnal hours — 3 AM check-ins observed.",
            source: "chat",
            lifecycle: MemoryLifecycle.corrected
        ))
        // Non-durable by the same precision gate every write path applies.
        _ = try await store.insertMemory(StoredMemory(
            content: "user likes trying to push it and see",
            source: "adaptive-promoter",
            metadata: .object(["kind": .string("preference")])
        ))

        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        let gen = UserMDGenerator(storage: store, dataRoot: root, personaRoot: personaRoot)
        let text = try String(
            contentsOf: try await gen.regenerate(persona: MemoryV2Defaults.personaID),
            encoding: .utf8
        )

        #expect(text.contains("User's sleep schedule is 19:00-03:00"))
        #expect(!text.contains("User keeps nocturnal hours"))
        #expect(!text.contains("user likes trying to push it and see"))
    }
}

final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _date: Date
    init(date: Date) { self._date = date }
    var current: Date {
        lock.lock(); defer { lock.unlock() }
        return _date
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _date = _date.addingTimeInterval(seconds)
    }
}
