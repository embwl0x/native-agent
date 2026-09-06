import CognitiveSubstrate
import Foundation
import MemoryV2
import PersistenceCore
import Testing
@testable import NativeAgentApp

// THE APP HALF OF UNBIDDEN RECALL (review round, 2026-09-02).
//
// The substrate owns the gates; this file owns the two things only the app can
// get wrong, and the first cut got both wrong:
//
//   * WHICH STORE. `SwiftNativeMemoryV2.shared` is the user's real memory. A
//     runtime built on an alternate root reading it would mean a test — or any
//     alternate-root composition — pulling User's actual life into a capsule.
//   * WHOSE SURFACE. Disclosure is applied against a surface. Unbidden recall
//     is the *worst* place to skip it: nobody asked for the memory, so nobody
//     is checking where it came from.
//
// And the wiring the whole re-feel depends on: served moments must be given
// their stored feeling BEFORE the event is ingested, or `refelt` sees a bare id
// and moves nothing — "I get the fact of a feeling", unchanged.
@Suite("RemindedOfServedMomentWiring", .serialized)
struct RemindedOfServedMomentWiringTests {

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reminded-of-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func configuration() -> CognitiveConfiguration {
        CognitiveConfiguration(
            enabled: true,
            persistenceEnabled: true,
            workspaceEnabled: true,
            capsuleInjectionEnabled: true,
            affectEnabled: true,
            maximumCapsuleCharacters: 4_000
        )
    }

    /// One stored MOMENT, restricted to a single surface.
    private func seedMoment(
        at root: URL,
        id: String,
        valence: Double,
        permittedSurfaces: [String]
    ) async throws {
        let storage = try MemoryStorage(dataRoot: root)
        _ = try await storage.insertMemory(StoredMemory(
            id: id,
            content: "The night the crontab finally fired and we both stopped holding our breath.",
            source: "chat",
            metadata: .object([
                "kind": .string("moment"),
                "valence": .double(valence),
                "salience": .double(0.9),
                "permittedSurfaces": .array(permittedSurfaces.map { .string($0) }),
            ])))
    }

    private func servedTurn(
        id: String,
        surface: String?,
        memoryRecordIds: [String]
    ) -> CognitiveEvent {
        var metadata: [String: JSONValue] = [
            "sessionId": .string("served"),
            "memoryRecordIds": .array(memoryRecordIds.map { .string($0) }),
        ]
        if let surface { metadata["surface"] = .string(surface) }
        return CognitiveEvent(
            id: id,
            kind: .assistantTurnCompleted,
            subject: CognitiveSubjectReference(type: "chat.assistant_turn", id: "served:\(id)"),
            sourceClass: .selfReported,
            occurredAt: Date(),
            summary: "Worked the change through and reported what landed.",
            importance: 0.55,
            turnKind: .live,
            metadata: metadata)
    }

    /// A served moment is re-felt WITH ITS STORED WEIGHT. The runtime looks the
    /// id up and hands the substrate the feeling before `ingest` runs the
    /// re-feel — without that hop the id is bare and nothing moves.
    @Test func aServedMomentReachesTheSubstrateWithItsFeeling() async throws {
        let root = try temporaryRoot()
        try await seedMoment(at: root, id: "moment-warm", valence: 0.8, permittedSurfaces: ["chat"])

        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: configuration(),
            organismConfigurationOverride: .disabled)
        let substrate = await runtime.substrateForIntegration()
        let before = await substrate.affectSnapshot()

        await runtime.observe(servedTurn(
            id: "turn-1", surface: "chat", memoryRecordIds: ["moment-warm"]))

        let after = await substrate.affectSnapshot()
        #expect(after.socialWarmth > before.socialWarmth,
                "the served moment was re-read, not re-felt: \(before.socialWarmth) → \(after.socialWarmth)")
    }

    /// THE DISCLOSURE BOUNDARY HOLDS ON THE WAY IN. The same moment, restricted
    /// to Telegram, must not become a feeling on a chat turn.
    @Test func aSurfaceRestrictedMomentIsNotFeltOnAnotherSurface() async throws {
        let root = try temporaryRoot()
        try await seedMoment(
            at: root, id: "moment-telegram", valence: 0.8, permittedSurfaces: ["telegram"])

        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: configuration(),
            organismConfigurationOverride: .disabled)
        let substrate = await runtime.substrateForIntegration()
        let before = await substrate.affectSnapshot()

        await runtime.observe(servedTurn(
            id: "turn-1", surface: "chat", memoryRecordIds: ["moment-telegram"]))

        let after = await substrate.affectSnapshot()
        #expect(after.socialWarmth == before.socialWarmth,
                "a telegram-only memory became a feeling on a chat turn")
    }

    /// NO SURFACE, NO LOOKUP. An event that cannot say where it happened has no
    /// disclosure boundary to check against, and an unchecked read by id is a
    /// bypass. Fail closed.
    @Test func anEventWithNoSurfaceLooksNothingUp() async throws {
        let root = try temporaryRoot()
        try await seedMoment(at: root, id: "moment-warm", valence: 0.8, permittedSurfaces: ["chat"])

        let runtime = NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: configuration(),
            organismConfigurationOverride: .disabled)
        let substrate = await runtime.substrateForIntegration()
        let before = await substrate.affectSnapshot()

        await runtime.observe(servedTurn(
            id: "turn-1", surface: nil, memoryRecordIds: ["moment-warm"]))

        let after = await substrate.affectSnapshot()
        #expect(after.socialWarmth == before.socialWarmth)
    }

    /// AN ALTERNATE ROOT NEVER READS THE PRODUCTION STORE. This is the rule the
    /// chat recall factory already follows (`makeChatMemoryRecaller`), and the
    /// reason the two tests above can trust their own fixtures at all.
    @Test func momentRecallIsRootedAtTheRuntimesOwnDataRoot() async throws {
        let root = try temporaryRoot()
        #expect(!SwiftNativeMemoryV2.usesDefaultDataRoot(root))
        #expect(SwiftNativeMemoryV2.resolvedOwner(dataRoot: root) !== SwiftNativeMemoryV2.shared,
                "an alternate root was handed the user's real memory actor")
        #expect(SwiftNativeMemoryV2.resolvedOwner(dataRoot: PersistenceCore.defaultDataRoot())
                === SwiftNativeMemoryV2.shared,
                "the default root must still be the one production singleton")
    }

    /// A recall with no surface is refused before the store is touched — the
    /// same fail-closed rule as the served lane.
    @Test func momentRecallRefusesASurfacelessAsk() async throws {
        let root = try temporaryRoot()
        let moments = await NativeCognitionRuntime.recallMoments(
            feltLine: "proud — the register fix", limit: 5, surface: "  ", dataRoot: root)
        #expect(moments.isEmpty)
    }
}
