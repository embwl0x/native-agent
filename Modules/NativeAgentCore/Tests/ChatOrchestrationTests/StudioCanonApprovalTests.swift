import ApprovalInbox
import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
@testable import PersistenceCore

// MARK: - The inverted card (desk 903 phase 4)
//
// Agent is the SOLE approver of her own canon — "my taste, not User's to sign
// off." Every other approval card in this app asks the owner; this one refuses
// him. These tests pin that inversion at both ends, and — the part the first
// cut got wrong — they pin that the seat cannot be MINTED by whoever happens to
// call the tool. `studio_canon_resolve` is an ordinary lazy chat tool, so the
// bridge tool runner, an approval executor and a replay can all reach it. The
// seat therefore comes from runtime provenance: a live, local chat turn.

@Suite("Studio canon approval")
struct StudioCanonApprovalTests {

    private func hermeticRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioCanonApproval-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func draft(
        action: StudioCanonAction = .promote,
        title: String = "The Green Ray",
        entryIDs: [String] = ["entry_b", "entry_c", "entry_d"]
    ) -> StudioCanonProposalDraft {
        StudioCanonProposalDraft(
            action: action,
            workTitle: title,
            workCreator: "Éric Rohmer",
            evidenceKind: action == .promote ? .recurrence : .silence,
            evidenceEntryIDs: entryIDs,
            recurrenceCount: entryIDs.count,
            recallHits: 0,
            lastActivityAt: "2026-08-01T00:00:00.000000Z"
        )
    }

    /// HER live turn: exactly what the chat tool loop binds around a dispatch,
    /// and nothing a caller could supply through tool input.
    private func inHerLiveTurn<T>(
        surface: String = "chat",
        turnID: String = "run_live_1",
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await ChatTurnRuntimeContext.$current.withValue(
            .init(model: "test-model", surface: surface, personaID: "agent", providerID: "test")
        ) {
            try await ChatToolSessionContext.$verifiedSessionId.withValue(turnID) {
                try await body()
            }
        }
    }

    private func provenance() -> StudioCanonTurnProvenance {
        StudioCanonTurnProvenance(surface: "chat", turnID: "run_live_1")
    }

    private func object(_ value: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let obj) = value else {
            Issue.record("not an object: \(value)")
            throw CancellationError()
        }
        return obj
    }

    // MARK: The card

    @Test("a staged card is local-only, not remotely resolvable, and shows the evidence")
    func cardShapeIsLocalAndEvidenceFirst() async throws {
        let root = hermeticRoot()
        let inbox = SwiftNativeApprovalInbox(root: root)
        let record = try await StudioCanonProposal.stage(draft(), inbox: inbox)
        #expect(record.action == StudioCanonProposal.approvalAction)
        #expect(record.localOnly)
        #expect(!record.remoteResolvable)
        #expect(record.status == "pending")
        // The preview is the EVIDENCE, not a verdict: the entries that argued
        // for it, so she can pull them before deciding.
        #expect(record.payloadPreview.contains("entry_b"))
        #expect(record.payloadPreview.contains("recurrence"))
        #expect(record.reason.contains("studio_canon_resolve"))
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: The seat cannot be minted by whoever calls the tool

    /// The Claude bridge's `/claude/tool` runner dispatches with its own
    /// surface and binds no turn context. It must not be able to decide her
    /// canon, and it must be TOLD why rather than silently failing.
    @Test("the bridge tool runner cannot mint her seat")
    func bridgeToolRunIsRefused() async throws {
        let root = hermeticRoot()
        let inbox = SwiftNativeApprovalInbox(root: root)
        let staged = try await StudioCanonProposal.stage(draft(), inbox: inbox)
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        // No ChatTurnRuntimeContext at all — exactly what a direct dispatch has.
        let result = try await dispatcher.impl_studio_canon_resolve(
            input: [
                "proposal_id": .string(staged.id),
                "decision": .string("approve"),
            ],
            surface: "claude-bridge"
        )
        let obj = try object(result)
        #expect(obj["status"] == .string("refused"))
        #expect(obj["refusal"] == .string(StudioCanonSeatGate.Refusal.notALiveTurn.rawValue))
        #expect(try await SwiftNativeStudioStore(dataRoot: root).readCanon().isEmpty)
        // And the card is untouched, so she can still decide it herself.
        #expect(try await inbox.get(staged.id).status == "pending")
        try? FileManager.default.removeItem(at: root)
    }

    /// The bridge's MESSAGE lane runs a real tool loop on `surface: "chat"`, so
    /// the surface string alone would let it through. It is caught by the two
    /// things it binds and a local turn never does.
    @Test("a bridge-steered chat turn cannot mint her seat either")
    func bridgeMessageLaneIsRefused() async throws {
        let root = hermeticRoot()
        let inbox = SwiftNativeApprovalInbox(root: root)
        let staged = try await StudioCanonProposal.stage(draft(), inbox: inbox)
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let result = try await inHerLiveTurn {
            try await ChatPersistenceContext.$originProvenance.withValue(
                ChatMessageOrigin(surface: "claude-bridge", agent: "claude")
            ) {
                try await dispatcher.impl_studio_canon_resolve(
                    input: [
                        "proposal_id": .string(staged.id),
                        "decision": .string("approve"),
                    ],
                    surface: "chat"
                )
            }
        }
        let obj = try object(result)
        #expect(obj["status"] == .string("refused"))
        #expect(obj["refusal"] == .string(StudioCanonSeatGate.Refusal.bridgeLane.rawValue))
        #expect(try await SwiftNativeStudioStore(dataRoot: root).readCanon().isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("a remote surface cannot decide the canon")
    func remoteTurnIsRefused() async throws {
        let root = hermeticRoot()
        let inbox = SwiftNativeApprovalInbox(root: root)
        let staged = try await StudioCanonProposal.stage(draft(), inbox: inbox)
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let result = try await inHerLiveTurn(surface: "telegram") {
            try await dispatcher.impl_studio_canon_resolve(
                input: [
                    "proposal_id": .string(staged.id),
                    "decision": .string("approve"),
                ],
                surface: "telegram"
            )
        }
        let obj = try object(result)
        #expect(obj["status"] == .string("refused"))
        #expect(obj["refusal"] == .string(StudioCanonSeatGate.Refusal.remoteSurface.rawValue))
        #expect(try await SwiftNativeStudioStore(dataRoot: root).readCanon().isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("a turn with no identity to record is refused rather than stamped blank")
    func turnWithoutIdentityIsRefused() async throws {
        let root = hermeticRoot()
        let inbox = SwiftNativeApprovalInbox(root: root)
        let staged = try await StudioCanonProposal.stage(draft(), inbox: inbox)
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let result = try await ChatTurnRuntimeContext.$current.withValue(
            .init(model: "test-model", surface: "chat", personaID: "agent", providerID: "test")
        ) {
            try await ChatToolSessionContext.$verifiedSessionId.withValue(nil) {
                try await ChatPersistenceContext.$pinnedTurnRunID.withValue(nil) {
                    try await dispatcher.impl_studio_canon_resolve(
                        input: [
                            "proposal_id": .string(staged.id),
                            "decision": .string("approve"),
                            // A model-supplied session id must not rescue it.
                            "__session_id": .string("forged"),
                        ],
                        surface: "chat"
                    )
                }
            }
        }
        let obj = try object(result)
        #expect(obj["status"] == .string("refused"))
        #expect(obj["refusal"] == .string(StudioCanonSeatGate.Refusal.noTurnIdentity.rawValue))
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: User

    @Test("User approving a canon card is REFUSED and nothing reaches the ledger")
    func ownerApprovalIsRefused() async throws {
        let root = hermeticRoot()
        let inbox = SwiftNativeApprovalInbox(root: root)
        let staged = try await StudioCanonProposal.stage(draft(), inbox: inbox)
        // The Activity approval UI's own seat.
        let resolved = try await inbox.resolve(
            staged.id, decision: .approved, decidedBy: "mac_ui"
        )
        await #expect(throws: StudioCanonError.approvalNotFromAgentSeat("mac_ui")) {
            try await StudioCanonProposal.applyResolved(
                record: resolved, dataRoot: root, provenance: provenance()
            )
        }
        let store = SwiftNativeStudioStore(dataRoot: root)
        #expect(try await store.readCanon().isEmpty)
        #expect(try await store.canonMembership().isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    /// Even her own seat cannot land a row without a live turn — which is what
    /// makes the approval EXECUTOR unable to write one on replay.
    @Test("her seat without a live turn writes nothing")
    func agentSeatWithoutTurnWritesNothing() async throws {
        let root = hermeticRoot()
        let inbox = SwiftNativeApprovalInbox(root: root)
        let staged = try await StudioCanonProposal.stage(draft(), inbox: inbox)
        let resolved = try await inbox.resolve(
            staged.id, decision: .approved, decidedBy: StudioCanonSeat.agent
        )
        await #expect(throws: StudioCanonError.decisionHasNoLiveTurn) {
            try await StudioCanonProposal.applyResolved(
                record: resolved,
                dataRoot: root,
                provenance: StudioCanonTurnProvenance(surface: "", turnID: "")
            )
        }
        #expect(try await SwiftNativeStudioStore(dataRoot: root).readCanon().isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Her

    @Test("her live local turn approves and the canon row lands, with its provenance")
    func agentApprovalWritesCanon() async throws {
        let root = hermeticRoot()
        let inbox = SwiftNativeApprovalInbox(root: root)
        let staged = try await StudioCanonProposal.stage(draft(), inbox: inbox)
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let result = try await inHerLiveTurn {
            try await dispatcher.impl_studio_canon_resolve(
                input: [
                    "proposal_id": .string(staged.id),
                    "decision": .string("approve"),
                ],
                surface: "chat"
            )
        }
        let obj = try object(result)
        #expect(obj["status"] == .string("ok"))
        #expect(obj["row_written"] == .bool(true))
        #expect(obj["decided_on_surface"] == .string("chat"))

        let store = SwiftNativeStudioStore(dataRoot: root)
        let rows = try await store.readCanon()
        #expect(rows.count == 1)
        #expect(rows.first?.decidedBy == StudioCanonSeat.agent)
        #expect(rows.first?.decidedOnSurface == "chat")
        #expect(rows.first?.decidedInTurn == "run_live_1")
        #expect(rows.first?.standing == .canon)
        #expect(rows.first?.evidenceEntryIDs.contains("entry_b") == true)
        #expect(try await store.canonMembership().count == 1)

        let listed = try await dispatcher.impl_studio_canon(input: [:])
        guard case .array(let canon)? = try object(listed)["canon"] else {
            Issue.record("unexpected canon listing: \(listed)")
            return
        }
        #expect(canon.count == 1)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("she can put a work on the anti-canon shelf; nothing infers that shelf for her")
    func antiCanonIsHerChoice() async throws {
        let root = hermeticRoot()
        let inbox = SwiftNativeApprovalInbox(root: root)
        let staged = try await StudioCanonProposal.stage(
            draft(title: "A Loud Building"), inbox: inbox
        )
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        _ = try await inHerLiveTurn {
            try await dispatcher.impl_studio_canon_resolve(
                input: [
                    "proposal_id": .string(staged.id),
                    "decision": .string("approve"),
                    "standing": .string("anti_canon"),
                ],
                surface: "chat"
            )
        }
        let rows = try await SwiftNativeStudioStore(dataRoot: root).readCanon()
        #expect(rows.first?.standing == .antiCanon)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("denying writes nothing at all")
    func denialWritesNothing() async throws {
        let root = hermeticRoot()
        let inbox = SwiftNativeApprovalInbox(root: root)
        let staged = try await StudioCanonProposal.stage(draft(), inbox: inbox)
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let result = try await inHerLiveTurn {
            try await dispatcher.impl_studio_canon_resolve(
                input: [
                    "proposal_id": .string(staged.id),
                    "decision": .string("deny"),
                ],
                surface: "chat"
            )
        }
        #expect(try object(result)["row_written"] == .bool(false))
        #expect(try await SwiftNativeStudioStore(dataRoot: root).readCanon().isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Dedupe

    /// A denial settles the ARGUMENT she saw, not the subject. Re-proposing the
    /// same evidence is noise; proposing new evidence is a new question.
    @Test("a denied card blocks its own evidence, not the work forever")
    func denialDoesNotSilenceTheWorkForever() async throws {
        let root = hermeticRoot()
        let inbox = SwiftNativeApprovalInbox(root: root)
        let first = draft(entryIDs: ["entry_b", "entry_c", "entry_d"])
        let staged = try await StudioCanonProposal.stage(first, inbox: inbox)
        // Pending: the lane is occupied, whatever the evidence says.
        #expect(await StudioCanonProposal.isAlreadyFiled(
            draft: draft(entryIDs: ["entry_x", "entry_y", "entry_z"]), inbox: inbox
        ))
        _ = try await inbox.resolve(staged.id, decision: .denied, decidedBy: "studio_agent")
        // Resolved: the same argument stays settled …
        #expect(await StudioCanonProposal.isAlreadyFiled(draft: first, inbox: inbox))
        // … and a year of new entries is a new one.
        #expect(!(await StudioCanonProposal.isAlreadyFiled(
            draft: draft(entryIDs: ["entry_b", "entry_c", "entry_d", "entry_e"]), inbox: inbox
        )))
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Tending

    /// NO PROMPT MASS, and no auto-canonization: the tending pass may stage
    /// cards and nothing else. With an empty journal it does not even do that.
    @Test("a tending pass on an empty studio proposes nothing and writes nothing")
    func tendingIsInertWithoutEvidence() async throws {
        let root = hermeticRoot()
        let report = await StudioCanonTending.run(dataRoot: root)
        #expect(report.stagedApprovalIDs.isEmpty)
        #expect(report.proposalsConsidered == 0)
        #expect(try await SwiftNativeStudioStore(dataRoot: root).readCanon().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: SwiftNativeStudioStore(dataRoot: root).canonPath.path
        ))
        try? FileManager.default.removeItem(at: root)
    }

    @Test("the canon tool refuses an id that is not a canon proposal")
    func resolveRefusesForeignCards() async throws {
        let root = hermeticRoot()
        let inbox = SwiftNativeApprovalInbox(root: root)
        let other = try await inbox.create(.object([
            "title": .string("something else"),
            "action": .string("rem.proposal"),
            "risk": .string("low"),
            "reason": .string("not canon"),
            "payload": .object([:]),
        ]))
        let dispatcher = SwiftToolDispatcher(dataRoot: root)
        let result = try await inHerLiveTurn {
            try await dispatcher.impl_studio_canon_resolve(
                input: [
                    "proposal_id": .string(other.id),
                    "decision": .string("approve"),
                ],
                surface: "chat"
            )
        }
        #expect(try object(result)["status"] == .string("refused"))
        #expect(try await SwiftNativeStudioStore(dataRoot: root).readCanon().isEmpty)
        try? FileManager.default.removeItem(at: root)
    }
}
