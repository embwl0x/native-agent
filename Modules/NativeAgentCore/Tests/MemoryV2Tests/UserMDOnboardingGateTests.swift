import Testing
import Foundation
@testable import MemoryV2
import NativeAgentCore

// fix-blank-install-onboarding (2026-08-02): launch ran
// `UserMDGenerator.regenerate()` unconditionally, and with zero memories it
// still created the persona directory and wrote a USER.md holding nothing but
// the autogen header. USER.md is one of onboarding's OWN transaction targets,
// so that empty file satisfied onboarding's `hasExisting` / `hasIdentityAnchor`
// checks and a blank machine looked already-onboarded — the wizard never
// appeared, leaving an unnamed agent with no SOUL/VOICE documents.
@Suite("UserMDGenerator onboarding gate")
struct UserMDOnboardingGateTests {
    private func tmpRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usermd-gate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a blank install writes no USER.md and no persona directory")
    func blankInstallWritesNothing() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        let store = try MemoryStorage(dataRoot: root)
        let gen = UserMDGenerator(storage: store, dataRoot: root, personaRoot: personaRoot)

        #expect(gen.onboardingHasCompleted == false)
        await #expect(throws: UserMDGeneratorError.self) {
            _ = try await gen.regenerate(persona: MemoryV2Defaults.personaID)
        }

        // Old behavior: both of these existed after the launch pass.
        #expect(!FileManager.default.fileExists(atPath: personaRoot.appendingPathComponent("USER.md").path))
        #expect(!FileManager.default.fileExists(atPath: personaRoot.path))
    }

    @Test("a debounce poke before onboarding is refused, not queued")
    func requestRegenerationIsGatedToo() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        let store = try MemoryStorage(dataRoot: root)
        let gen = UserMDGenerator(
            storage: store,
            dataRoot: root,
            personaRoot: personaRoot,
            debounceInterval: 0
        )

        await #expect(throws: UserMDGeneratorError.self) {
            _ = try await gen.requestRegeneration(persona: MemoryV2Defaults.personaID)
        }
        #expect(!FileManager.default.fileExists(atPath: personaRoot.appendingPathComponent("USER.md").path))
    }

    @Test("the completion sentinel opens the gate")
    func sentinelOpensGate() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        let store = try MemoryStorage(dataRoot: root)
        _ = try await store.insertMemory(StoredMemory(
            content: "the user prefers Opus 4.8",
            source: "chat",
            metadata: .object(["kind": .string("preference")])
        ))
        let gen = UserMDGenerator(storage: store, dataRoot: root, personaRoot: personaRoot)

        try Data("completed_at=x\n".utf8).write(to: root.appendingPathComponent(".onboarded"))
        #expect(gen.onboardingHasCompleted == true)

        let url = try await gen.regenerate(persona: MemoryV2Defaults.personaID)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("the user prefers Opus 4.8"))
    }

    @Test("an install predating the sentinel keeps regenerating from SOUL.md")
    func legacyIdentityDocsOpenGate() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
        try Data("# Soul\n".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))

        let store = try MemoryStorage(dataRoot: root)
        let gen = UserMDGenerator(storage: store, dataRoot: root, personaRoot: personaRoot)
        #expect(gen.onboardingHasCompleted == true)
        _ = try await gen.regenerate(persona: MemoryV2Defaults.personaID)
        #expect(FileManager.default.fileExists(atPath: personaRoot.appendingPathComponent("USER.md").path))
    }

    @Test("USER.md alone is not proof of onboarding — that would be circular")
    func ownOutputIsNotProof() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
        try Data("# User Facts (auto-generated from memory SQLite)\n\n".utf8)
            .write(to: personaRoot.appendingPathComponent("USER.md"))

        let store = try MemoryStorage(dataRoot: root)
        let gen = UserMDGenerator(storage: store, dataRoot: root, personaRoot: personaRoot)
        #expect(gen.onboardingHasCompleted == false)
    }

    /// gpt-5.5 review NEEDS_FIX 3 (2026-08-02): this gate and
    /// `Onboarding.startOnboarding` disagreed about a prose-bearing USER.md —
    /// the start gate called it onboarded (hiding the wizard) while this gate
    /// called it incomplete (refusing regeneration forever). The install was
    /// stuck with no way out. Resolved by making the START gate stop accepting
    /// USER.md; this gate's answer was already the right one, and the wizard is
    /// now reachable for such an install. The rule both gates share: only
    /// `.onboarded` and `SOUL.md` are proof.
    @Test("prose in USER.md is not proof either — regeneration would erase it")
    func proseUserDocIsNotProof() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let personaRoot = root.appendingPathComponent("persona", isDirectory: true)
        try FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
        try Data("""
        # User

        User builds macOS agents and lives in America/New_York.
        """.utf8).write(to: personaRoot.appendingPathComponent("USER.md"))

        let store = try MemoryStorage(dataRoot: root)
        let gen = UserMDGenerator(storage: store, dataRoot: root, personaRoot: personaRoot)
        #expect(gen.onboardingHasCompleted == false)
        await #expect(throws: UserMDGeneratorError.self) {
            _ = try await gen.regenerate(persona: MemoryV2Defaults.personaID)
        }
        // The prose is intact: a refused regeneration destroys nothing.
        let after = try String(contentsOf: personaRoot.appendingPathComponent("USER.md"), encoding: .utf8)
        #expect(after.contains("America/New_York"))
    }
}
