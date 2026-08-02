import Testing
import Foundation
import NativeAgentCore
@testable import Onboarding

// fix-blank-install-onboarding (2026-08-02): `startOnboarding` counted the mere
// EXISTENCE of USER.md as both "already onboarded" (`hasExisting`) and as an
// identity anchor. The memory subsystem writes that same path as a derived
// projection, so on a blank machine a USER.md containing nothing but the
// autogen header made onboarding declare itself finished — and because it
// satisfied `hasIdentityAnchor`, it did not even route into the resetRequired
// recovery lane. ContentView then took the `guard !start.hasExisting` early
// return and the wizard never appeared.
//
// gpt-5.5 review round 2 (2026-08-02) found the circularity only half-broken:
// the start gate had learned to read USER.md's CONTENT while the completion
// gate still did a raw `fileExists` sweep over the same file, and the MemoryV2
// generator gate accepted neither. Resolution: USER.md is not proof of
// onboarding in ANY gate. All three now recognize exactly `.onboarded` and
// `SOUL.md`. USER.md survives only in `completeOnboarding`, as bytes that must
// not be destroyed silently.
@Suite("Onboarding blank-install identity anchor")
struct OnboardingBlankInstallAnchorTests {
    private func tmpDirs() -> (dataRoot: URL, personaRoot: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("onboarding-anchor-\(UUID().uuidString)", isDirectory: true)
        let personaRoot = base.appendingPathComponent("persona", isDirectory: true)
        let dataRoot = base.appendingPathComponent("data", isDirectory: true)
        try? FileManager.default.createDirectory(at: personaRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        return (dataRoot, personaRoot)
    }

    /// The exact bytes `UserMDGenerator` produced on a blank install (captured
    /// from a real run against an empty temp NATIVE_AGENT_DATA_ROOT).
    private static let emptyProjection = """
    <!-- USER_MD_AUTOGEN_START -->
    # User Facts (auto-generated from memory SQLite)


    <!-- USER_MD_AUTOGEN_END -->

    """

    /// The same generator, after memories exist. Bullets are a projection of
    /// SQLite — they are NOT identity, and the old content predicate said they
    /// were.
    private static let populatedProjection = """
    <!-- USER_MD_AUTOGEN_START -->
    # User Facts (auto-generated from memory SQLite)

    - the user prefers Opus 4.8
    - the user's timezone is America/New_York

    <!-- USER_MD_AUTOGEN_END -->

    """

    // MARK: classification

    @Test("classifyUserDoc: absent, projection, and authored are distinguished")
    func classificationShape() throws {
        let (dataRoot, personaRoot) = tmpDirs()
        defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }
        let path = personaRoot.appendingPathComponent("probe.md")

        #expect(SwiftNativeOnboardingClient.classifyUserDoc(at: path) == .absent)

        try Data(Self.emptyProjection.utf8).write(to: path)
        #expect(SwiftNativeOnboardingClient.classifyUserDoc(at: path) == .generatorProjection)

        // Memory bullets live INSIDE the autogen body, so they are projection —
        // this is the case the previous `userDocCarriesIdentity` got wrong.
        try Data(Self.populatedProjection.utf8).write(to: path)
        #expect(SwiftNativeOnboardingClient.classifyUserDoc(at: path) == .generatorProjection)

        // An empty preserved preamble is still projection.
        try Data("""
        <!-- USER_PREAMBLE_START -->
        <!-- USER_PREAMBLE_END -->

        \(Self.emptyProjection)
        """.utf8).write(to: path)
        #expect(SwiftNativeOnboardingClient.classifyUserDoc(at: path) == .generatorProjection)

        // Human-edited preamble content is authored — the generator preserves
        // it but can never produce it.
        try Data("""
        <!-- USER_PREAMBLE_START -->
        User ships macOS agents and hates being greeted by name he never gave.
        <!-- USER_PREAMBLE_END -->

        \(Self.emptyProjection)
        """.utf8).write(to: path)
        #expect(SwiftNativeOnboardingClient.classifyUserDoc(at: path) == .authored)

        // Onboarding's own persona template is prose with no autogen markers.
        let docs = try PersonaTemplates.generate(name: "Claude", personaType: "ai", userName: "User")
        try Data(docs.user.utf8).write(to: path)
        #expect(SwiftNativeOnboardingClient.classifyUserDoc(at: path) == .authored)
    }

    // MARK: start gate

    @Test("an empty auto-generated USER.md does not count as onboarded")
    func emptyProjectionIsNotOnboarded() async throws {
        let (dataRoot, personaRoot) = tmpDirs()
        defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }
        try Data(Self.emptyProjection.utf8).write(to: personaRoot.appendingPathComponent("USER.md"))

        let client = SwiftNativeOnboardingClient(personaRoot: personaRoot, dataRoot: dataRoot)
        let start = try await client.startOnboarding()

        // Old behavior: hasExisting == true, so the wizard never opened.
        #expect(start.hasExisting == false)
        #expect(start.resetRequired == false)
        #expect(start.pendingRecovery == false)
    }

    /// gpt-5.5 review NEEDS_FIX 3: an install carrying only a prose USER.md —
    /// no sentinel, no SOUL — used to be told "already onboarded" by the start
    /// gate while the MemoryV2 generator refused to regenerate forever. USER.md
    /// is no longer proof anywhere, so the wizard is reachable and the stuck
    /// state cannot form.
    @Test("a USER.md-only install is NOT onboarded — the wizard is reachable")
    func proseUserDocAloneIsNotOnboarded() async throws {
        let (dataRoot, personaRoot) = tmpDirs()
        defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }
        let docs = try PersonaTemplates.generate(name: "Claude", personaType: "ai", userName: "User")
        try Data(docs.user.utf8).write(to: personaRoot.appendingPathComponent("USER.md"))

        let client = SwiftNativeOnboardingClient(personaRoot: personaRoot, dataRoot: dataRoot)
        let start = try await client.startOnboarding()

        #expect(start.hasExisting == false)
        #expect(start.pendingRecovery == false)
        // Only VOICE/GROWTH route to the auxiliary-only reset lane; a lone
        // USER.md does not, because it is not persona identity at all.
        #expect(start.resetRequired == false)
    }

    @Test("SOUL.md and the sentinel remain the proofs of a completed install")
    func realProofsStillCount() async throws {
        for proof in ["soul", "sentinel"] {
            let (dataRoot, personaRoot) = tmpDirs()
            defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }
            if proof == "soul" {
                try Data("# Soul\n".utf8).write(to: personaRoot.appendingPathComponent("SOUL.md"))
            } else {
                try Data("completed_at=x\n".utf8).write(to: dataRoot.appendingPathComponent(".onboarded"))
            }
            let client = SwiftNativeOnboardingClient(personaRoot: personaRoot, dataRoot: dataRoot)
            #expect(try await client.startOnboarding().hasExisting == true, "\(proof) must count as onboarded")
        }
    }

    // MARK: completion gate agrees with the start gate

    @Test("an empty USER.md does not block the wizard from onboarding cleanly")
    func blankInstallStillReachesTheWizard() async throws {
        let (dataRoot, personaRoot) = tmpDirs()
        defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }

        let client = SwiftNativeOnboardingClient(personaRoot: personaRoot, dataRoot: dataRoot)
        #expect(try await client.startOnboarding().hasExisting == false)

        let result = try await client.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: "Claude", personaType: "ai", userName: "User")
        )
        #expect(result.ok == true, "blank install must complete: \(result.error ?? "-")")
        #expect(FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(".onboarded").path))
        #expect(try await client.startOnboarding().hasExisting == true)
    }

    /// gpt-5.5 review BLOCKING 1, the contaminated-machine case. A machine that
    /// ran the old launch bug carries a header-only USER.md. The start gate opens
    /// the wizard; the completion gate used to answer `persona_already_exists`,
    /// a dead end. Both gates now classify the file the same way, so Build works.
    @Test("a contaminated header-only USER.md does not dead-end Build")
    func contaminatedProjectionCompletes() async throws {
        let (dataRoot, personaRoot) = tmpDirs()
        defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }
        let userPath = personaRoot.appendingPathComponent("USER.md")
        try Data(Self.emptyProjection.utf8).write(to: userPath)

        let client = SwiftNativeOnboardingClient(personaRoot: personaRoot, dataRoot: dataRoot)
        #expect(try await client.startOnboarding().hasExisting == false)

        let result = try await client.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: "Claude", personaType: "ai", userName: "User")
        )
        #expect(result.ok == true, "contaminated install must complete: \(result.error ?? "-")")
        #expect(FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(".onboarded").path))

        // The header-only projection was replaced by real persona prose.
        let written = try String(contentsOf: userPath, encoding: .utf8)
        #expect(SwiftNativeOnboardingClient.classifyUserDoc(at: userPath) == .authored)
        #expect(!written.contains(UserMDAutogenMarkers.bodyStart))
    }

    @Test("a populated projection is also overwritable — bullets are not identity")
    func populatedProjectionCompletes() async throws {
        let (dataRoot, personaRoot) = tmpDirs()
        defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }
        try Data(Self.populatedProjection.utf8).write(to: personaRoot.appendingPathComponent("USER.md"))

        let client = SwiftNativeOnboardingClient(personaRoot: personaRoot, dataRoot: dataRoot)
        #expect(try await client.startOnboarding().hasExisting == false)
        let result = try await client.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: "Claude", personaType: "ai", userName: "User")
        )
        #expect(result.ok == true, "populated projection must not block Build: \(result.error ?? "-")")
    }

    /// The other half of BLOCKING 1: authored bytes must still block, because
    /// reset (which backs them up) is the only safe way past them. This is a
    /// blocked Build with a reset affordance, not a silent overwrite.
    @Test("authored USER.md bytes still block Build, and reset clears the way")
    func authoredUserDocBlocksThenResetRecovers() async throws {
        let (dataRoot, personaRoot) = tmpDirs()
        defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }
        let userPath = personaRoot.appendingPathComponent("USER.md")
        try Data("User builds macOS agents and lives in America/New_York.\n".utf8).write(to: userPath)

        let client = SwiftNativeOnboardingClient(personaRoot: personaRoot, dataRoot: dataRoot)
        let blocked = try await client.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: "Claude", personaType: "ai", userName: "User")
        )
        #expect(blocked.ok == false)
        #expect(blocked.error == "persona_already_exists")

        let reset = try await client.resetOnboarding(confirm: true)
        #expect(reset.ok == true)

        // Reset preserved the authored bytes as a backup before clearing them.
        // `.bak` only — file locking leaves sibling `.lock` artifacts next to it.
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: personaRoot.path))?
            .filter { $0.hasPrefix("USER.md.pre-reset-") && $0.hasSuffix(".bak") } ?? []
        #expect(backups.count == 1, "reset must back up authored USER.md bytes")
        if let name = backups.first {
            let restored = try String(contentsOf: personaRoot.appendingPathComponent(name), encoding: .utf8)
            #expect(restored.contains("America/New_York"), "the backup must hold the original bytes")
        }

        let after = try await client.completeOnboarding(
            payload: OnboardingCompletePayload(agentName: "Claude", personaType: "ai", userName: "User")
        )
        #expect(after.ok == true, "onboarding must succeed after reset: \(after.error ?? "-")")
    }

    /// The transaction pins the exact projection bytes it intends to replace, so
    /// a concurrent writer between manifest publication and commit fails closed
    /// rather than being silently clobbered.
    @Test("an overwritable projection is pinned by base hash in the manifest")
    func projectionOverwriteIsHashPinned() async throws {
        let (dataRoot, personaRoot) = tmpDirs()
        defer { try? FileManager.default.removeItem(at: dataRoot.deletingLastPathComponent()) }
        let userPath = personaRoot.appendingPathComponent("USER.md")
        try Data(Self.emptyProjection.utf8).write(to: userPath)

        // Publish the manifest, then have someone else rewrite USER.md before
        // the commit reaches it.
        let client = SwiftNativeOnboardingClient(personaRoot: personaRoot, dataRoot: dataRoot) { step in
            if step == .manifestPrepared {
                try? Data(Self.populatedProjection.utf8).write(to: userPath)
            }
        }
        await #expect(throws: (any Error).self) {
            _ = try await client.completeOnboarding(
                payload: OnboardingCompletePayload(agentName: "Claude", personaType: "ai", userName: "User")
            )
        }
        #expect(!FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(".onboarded").path),
                "a fail-closed commit must not publish the completion sentinel")
    }
}
