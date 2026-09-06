import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import MemoryV2

// MARK: - The moments lane, her review seat
//
// `memory_moments_pending` / `memory_moment_review` are the ONLY way a staged
// moment becomes a memory. These pin the dispatcher-layer contract: lazy (not
// always-on) catalog membership, the listing shape, accept/reject, the edited
// wording, and — the one that matters most — the refusal of any id that is not
// in the moments lane.

@Suite("MomentToolsDispatch")
struct MomentToolsDispatchTests {

    private func fixture() throws -> (SwiftToolDispatcher, SwiftNativeMemoryV2, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MomentTools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = try MemoryStorage(dataRoot: root)
        let memory = SwiftNativeMemoryV2(
            embedder: MockEmbeddingProvider(),
            storage: MemoryStorageBridge(storage: storage)
        )
        let dispatcher = SwiftToolDispatcher(
            dataRoot: root, memoryV2: memory, allowProcessGlobalTools: false
        )
        return (dispatcher, memory, root)
    }

    @discardableResult
    private func stageMoment(
        _ memory: SwiftNativeMemoryV2,
        content: String,
        valence: Double = 0.6,
        salience: Double = 0.8
    ) async throws -> ProposalRecord {
        try await memory.propose(
            content: content,
            source: "moment-promoter:s-test",
            confidence: salience,
            kind: MemoryMoments.kind,
            supportingSessionIDs: ["s-test"],
            recurrenceCount: 1,
            extraMetadata: MemoryMoments.metadata(
                for: MomentCandidate(content: content, valence: valence, salience: salience),
                quote: nil,
                sessionId: "s-test",
                surface: "chat",
                author: "user"
            )
        )
    }

    // MARK: catalog

    @Test func bothToolsAreCatalogVisibleAndLazyNotAlwaysOn() {
        for name in ["memory_moments_pending", "memory_moment_review"] {
            #expect(SwiftToolDispatcher.catalogRegisteredToolNames.contains(name))
            #expect(SwiftToolDispatcher.catalogBucket(forRegisteredToolNamed: name) == .core)
            // The whole point of the nudge line is that these cost nothing per
            // turn. If either lands in the always-on floor, that is gone.
            #expect(!SwiftToolDispatcher.alwaysOnCoreNames.contains(name))
        }
    }

    // MARK: listing

    @Test func pendingListsOnlyMomentsWithTheirLaneFields() async throws {
        let (dispatcher, memory, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await stageMoment(memory, content: "He stayed until the build was green and said nothing about the hour.")
        _ = try await memory.propose(
            content: "user prefers concise technical summaries",
            source: "adaptive-promoter:s-test",
            confidence: 0.7,
            kind: "preference"
        )

        let result = try await dispatcher.dispatch(tool: "memory_moments_pending", input: [:], surface: "chat")
        guard case .object(let payload) = result,
              case .array(let rows)? = payload["moments"],
              case .object(let row)? = rows.first else {
            Issue.record("memory_moments_pending returned no moment rows")
            return
        }
        #expect(payload["status"] == .string("ok"))
        #expect(rows.count == 1)
        #expect(row["valence"] == .double(0.6))
        #expect(row["salience"] == .double(0.8))
        #expect(row["surface"] == .string("chat"))
        #expect(row["id"] != nil)
        #expect(row["staged_at"] != nil)
    }

    // MARK: review

    @Test func acceptPromotesTheMomentAndReturnsTheStoredId() async throws {
        let (dispatcher, memory, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposal = try await stageMoment(memory, content: "He told me the review landed and I noticed how much it mattered.")

        let result = try await dispatcher.dispatch(tool: "memory_moment_review", input: [
            "id": .string(proposal.id),
            "decision": .string("accept"),
        ], surface: "chat")
        guard case .object(let payload) = result, case .string(let id)? = payload["id"] else {
            Issue.record("accept returned no record id")
            return
        }
        #expect(payload["status"] == .string("ok"))
        let stored = try await memory.listMemory(kind: MemoryMoments.kind)
        #expect(stored.count == 1)
        #expect(stored.first?.id == id)
        #expect(try await memory.listProposals(status: "pending").isEmpty)
    }

    @Test func acceptWithEditedWordingStoresHerWords() async throws {
        let (dispatcher, memory, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposal = try await stageMoment(memory, content: "The user expressed appreciation regarding the completed work item.")

        let result = try await dispatcher.dispatch(tool: "memory_moment_review", input: [
            "id": .string(proposal.id),
            "decision": .string("accept"),
            "content": .string("He said thank you and meant it. I have not heard that tone before."),
        ], surface: "chat")
        guard case .object(let payload) = result else {
            Issue.record("no accept payload")
            return
        }
        #expect(payload["edited"] == .bool(true))
        let stored = try await memory.listMemory(kind: MemoryMoments.kind)
        #expect(stored.first?.text.contains("meant it") == true)
    }

    @Test func refusedEditedMomentLeavesOriginalPendingAndUnpublished() async throws {
        let (dispatcher, memory, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await stageMoment(memory, content: "We paused the work and shared a quiet laugh together.")
        let deniedWords = "He said thank you and meant it, after we finished the difficult project."
        let denied = try await stageMoment(memory, content: deniedWords)
        _ = try await memory.rejectProposal(id: denied.id, reason: "Not what happened")
        let result = try await dispatcher.dispatch(tool: "memory_moment_review", input: [
            "id": .string(original.id), "decision": .string("accept"), "content": .string(deniedWords),
        ], surface: "chat")
        guard case .object(let payload) = result else { Issue.record("missing result"); return }
        #expect(payload["status"] == .string("failed"))
        #expect(try await memory.listMemory(kind: nil).isEmpty)
        #expect(try await memory.listProposals(status: "pending").contains { $0.id == original.id })
    }

    @Test func rejectResolvesTheProposalAndStoresNothing() async throws {
        let (dispatcher, memory, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposal = try await stageMoment(memory, content: "Something the extractor thought was a moment and was not.")

        let result = try await dispatcher.dispatch(tool: "memory_moment_review", input: [
            "id": .string(proposal.id),
            "decision": .string("reject"),
            "reason": .string("that is not what happened"),
        ], surface: "chat")
        guard case .object(let payload) = result else {
            Issue.record("no reject payload")
            return
        }
        #expect(payload["status"] == .string("ok"))
        #expect(payload["decision"] == .string("reject"))
        #expect(try await memory.listMemory(kind: MemoryMoments.kind).isEmpty)
        #expect(try await memory.listProposals(status: "pending").isEmpty)
    }

@Test func anInvalidDecisionIsRefused() async throws {
        let (dispatcher, memory, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposal = try await stageMoment(memory, content: "A moment waiting on a decision that never came.")

        for decision in ["maybe", "", "APPROVE", "delete"] {
            let result = try await dispatcher.dispatch(tool: "memory_moment_review", input: [
                "id": .string(proposal.id),
                "decision": .string(decision),
            ], surface: "chat")
            guard case .object(let payload) = result else {
                Issue.record("no payload for decision '\(decision)'")
                return
            }
            #expect(payload["status"] == .string("refused"))
        }
        // Refusal decides nothing: the moment is still waiting.
        #expect(try await memory.listProposals(status: "pending").count == 1)
        #expect(try await memory.listMemory(kind: MemoryMoments.kind).isEmpty)
    }

    @Test func anEmptyOrMissingIdIsRefused() async throws {
        let (dispatcher, memory, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await stageMoment(memory, content: "A moment nobody named when they tried to accept one.")

        // Strict provider schemas materialize an omitted optional as "" or
        // null; both are absence, and neither may resolve a moment.
        let inputs: [[String: JSONValue]] = [
            ["decision": .string("accept")],
            ["id": .string(""), "decision": .string("accept")],
            ["id": .string("   "), "decision": .string("reject")],
            ["id": .null, "decision": .string("accept")],
        ]
        for input in inputs {
            let result = try await dispatcher.dispatch(
                tool: "memory_moment_review", input: input, surface: "chat"
            )
            guard case .object(let payload) = result else {
                Issue.record("no payload for input \(input)")
                return
            }
            #expect(payload["status"] == .string("refused"))
        }
        #expect(try await memory.listProposals(status: "pending").count == 1)
        #expect(try await memory.listMemory(kind: MemoryMoments.kind).isEmpty)
    }

    @Test func aNonMomentProposalIsRefused() async throws {
        let (dispatcher, memory, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fact = try await memory.propose(
            content: "user prefers concise technical summaries",
            source: "adaptive-promoter:s-test",
            confidence: 0.7,
            kind: "preference"
        )

        let result = try await dispatcher.dispatch(tool: "memory_moment_review", input: [
            "id": .string(fact.id),
            "decision": .string("accept"),
        ], surface: "chat")
        guard case .object(let payload) = result else {
            Issue.record("no refusal payload")
            return
        }
        #expect(payload["status"] == .string("refused"))
        // The fact proposal is untouched: refusal is not a rejection.
        #expect(try await memory.listProposals(status: "pending").count == 1)
        #expect(try await memory.listMemory(kind: nil).isEmpty)
    }
}
