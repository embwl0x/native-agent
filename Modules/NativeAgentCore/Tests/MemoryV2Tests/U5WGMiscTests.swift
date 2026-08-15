import Testing
import Foundation
@testable import MemoryV2
import NativeAgentCore

// MARK: - U5 W-G (2026-06-11) misc small+safe tests

@Suite("U5 W-G — MemoryV2 misc")
struct U5WGMiscTests {
    /// Onboarded install — USER.md generation is gated on onboarding having
    /// completed (fix-blank-install-onboarding, 2026-08-02).
    private func tmpRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("u5wg-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? Data("completed_at=test\n".utf8).write(to: url.appendingPathComponent(".onboarded"))
        return url
    }

    // MARK: USER.md trailing-edge debounce

    /// A poke landing INSIDE the debounce window used to be dropped on the
    /// floor — USER.md stayed stale until some future poke happened outside
    /// the window. The fix schedules one trailing regeneration at window
    /// expiry. We regen, insert a new fact, poke (debounced → nil), then
    /// wait past the window and assert the fact landed WITHOUT another poke.
    @Test func requestRegeneration_trailingEdge_runsAfterWindow() async throws {
        let store = try MemoryStorage()
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persona = MemoryV2Defaults.personaID

        _ = try await store.insertMemory(StoredMemory(
            content: "first fact",
            source: "chat",
            metadata: .object(["kind": .string("user_fact")])
        ))
        // Pin analytic time so saturation elsewhere in the full Core suite
        // cannot spend the entire 400 ms debounce window between the explicit
        // regeneration and the in-window poke. The trailing task still waits
        // on a real 400 ms deadline, so this tests coalescing rather than host
        // scheduler speed.
        let frozenNow = Date(timeIntervalSince1970: 1_000_000)
        let gen = UserMDGenerator(
            storage: store,
            dataRoot: root,
            debounceInterval: 0.4,
            now: { frozenNow }
        )
        let url = try await gen.regenerate(persona: persona)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("first fact"))

        // New fact + an in-window poke: must be debounced (nil) ...
        _ = try await store.insertMemory(StoredMemory(
            content: "trailing fact",
            source: "chat",
            metadata: .object(["kind": .string("user_fact")])
        ))
        let immediate = try await gen.requestRegeneration(persona: persona)
        #expect(immediate == nil, "poke inside the window must be debounced")
        // ... but NOT dropped: the trailing edge regenerates at window close.
        var landed = false
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if (try? String(contentsOf: url, encoding: .utf8))?.contains("trailing fact") == true {
                landed = true
                break
            }
        }
        #expect(landed, "trailing-edge regeneration must run after the debounce window")
    }

    // MARK: getProposal by-id (O(N) scan removal)

    @Test func storage_getProposal_byId_returnsRowAndNilForMissing() async throws {
        let store = try MemoryStorage()
        let target = StoredProposal(id: "prop-target", content: "the one we want")
        _ = try await store.insertProposal(StoredProposal(id: "prop-a", content: "noise a"))
        _ = try await store.insertProposal(target)
        _ = try await store.insertProposal(StoredProposal(id: "prop-b", content: "noise b"))

        let hit = try await store.getProposal(id: "prop-target")
        #expect(hit?.id == "prop-target")
        #expect(hit?.content == "the one we want")
        #expect(hit?.status == "pending")

        let miss = try await store.getProposal(id: "prop-nope")
        #expect(miss == nil)
    }

    /// The protocol-level path the auto-accept sweep uses must agree with
    /// the direct lookup (MemoryStorageBridge.getProposal no longer scans
    /// the whole proposals table per call).
    @Test func storageBridge_getProposal_usesDirectLookup() async throws {
        let storage = try MemoryStorage()
        let bridge = MemoryStorageBridge(storage: storage)
        try await bridge.insertProposal(
            ProposalRecord(id: "p1", content: "direct lookup", source: "test",
                           status: "pending", createdAt: MemoryStorage.nowISO8601())
        )
        let found = try await bridge.getProposal(id: "p1")
        #expect(found?.id == "p1")
        #expect(found?.content == "direct lookup")
        let missing = try await bridge.getProposal(id: "absent")
        #expect(missing == nil)
    }
}
