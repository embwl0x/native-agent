import Foundation
import Testing
@testable import ApprovalInbox
@testable import ChatOrchestration
@testable import PersistenceCore
@testable import NativeAgentApp

// Eval coverage — fence `app.desk`, row `desk.approval.clickAutoApprover`
// (kind store-write, silent-failure class: state-lifecycle leak).
//
// `DeskClickApprovalFiler` answers the AutonomyGate's approval tier for the
// desk surface: User is present, the click IS the authority, so the filer files
// the same approval record the chat lane files and resolves it immediately.
// Two ways that goes wrong with nobody noticing:
//
//   1. the resolve is `_ = try? await inbox.resolve(...)` — a swallowed failure
//      leaves a PENDING card in the approvals inbox that no human decision will
//      ever match (an orphan that sits in User's queue forever), and
//   2. the record loses its attribution, so an auto-approval is indistinguishable
//      from a decision User actually made — or becomes remotely resolvable, which
//      would let a remote surface re-decide a local click.
//
// Nothing in the suite executed this path before: the three impl-routing tests
// in DeskInteractionTests go through DeskToolDispatchRouter, but desk_* never
// reaches approval tier there, so the filer was never constructed.
//
// Hermetic: every read and write is against a per-test temp dataRoot.

private func withTempApprovalRoot<T>(_ body: (URL) async throws -> T) async throws -> T {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("desk-approval-filer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}

/// The envelope: after the click's approval is filed, the queue holds exactly
/// one more record and NOTHING is left pending. A create without a landed
/// resolve is the leak this pins.
///
/// Mutation proof: commenting out the `inbox.resolve(...)` line in
/// `DeskClickApprovalFiler.fileApprovalRequest` fails this test on the
/// pending-count assertion.
@Test("a desk click leaves no pending approval row behind")
func deskClickApprovalLeavesNoPendingRow() async throws {
    try await withTempApprovalRoot { root in
        let inbox = SwiftNativeApprovalInbox(root: root)
        #expect(try await inbox.list(filter: .all).isEmpty)

        let filer = DeskClickApprovalFiler(dataRoot: root)
        let id = try await filer.fileApprovalRequest(
            toolName: "desk_close",
            surface: DeskToolDispatchRouter.surface,
            payload: .object(["handle": .string("desk_1")]),
            reason: "Trust policy puts desk_close at approval tier")

        #expect(!id.isEmpty)

        let all = try await inbox.list(filter: .all)
        #expect(all.count == 1, "expected exactly one record for one click, got \(all.count)")
        let pending = try await inbox.list(filter: .pending)
        #expect(pending.isEmpty,
                "the click left \(pending.count) pending approval(s) nobody will ever decide")

        let record = try await inbox.get(id)
        #expect(record.status != "pending")
        #expect(record.decision == ApprovalDecision.approved.rawValue)
        #expect(record.resolvedAt != nil, "a resolved record with no resolvedAt is a half-written row")

        // The gate's own question ("does a human approve?") answers the same way
        // the record does — the filer must not report approved while filing a
        // denial, or vice versa.
        let decision = try await filer.awaitResolution(id: id)
        #expect(decision == .approved)
    }
}

/// The audit half: the record has to say WHO decided and HOW, and a
/// locally-auto-approved click must never be remotely resolvable.
///
/// Mutation proof: changing `decidedBy:` to any other string, or setting
/// `remoteResolvable` to `true` in the filed body, fails this test.
@Test("the auto-approved desk click is attributed, disclosed, and local-only")
func deskClickApprovalIsAttributedAndLocalOnly() async throws {
    try await withTempApprovalRoot { root in
        let filer = DeskClickApprovalFiler(dataRoot: root)
        let id = try await filer.fileApprovalRequest(
            toolName: "desk_defer",
            surface: DeskToolDispatchRouter.surface,
            payload: .object(["handle": .string("desk_2"), "until": .string("2026-12-24")]),
            reason: "policy tier")

        let record = try await SwiftNativeApprovalInbox(root: root).get(id)

        // Attribution: the decision names the desk click, not a person.
        #expect(record.decidedBy == "local_desk_click",
                "decidedBy is `\(record.decidedBy ?? "nil")` — an auto-approval that reads as a human decision")

        // Disclosure: the reason says out loud that this was auto-approved, and
        // it keeps the policy reason that got it here.
        #expect(record.reason.lowercased().contains("auto-approved"),
                "the record no longer discloses that the click auto-approved itself: \(record.reason)")
        #expect(record.reason.contains("policy tier"),
                "the caller's policy reason was dropped from the audit row")

        // Authority: a decision made by a local click may not be re-decidable
        // from a remote surface.
        #expect(record.remoteResolvable == false)
        #expect(record.localOnly == true)

        // The action recorded is the tool that was gated, so a reader can tell
        // which desk mutation this approved.
        #expect(record.action == "desk_defer")

        // And the payload survived into the record rather than being flattened
        // away — an approval card with no payload cannot be reviewed later.
        if case .object(let payload) = record.payload {
            #expect(payload["handle"] == .string("desk_2"))
            #expect(payload["until"] == .string("2026-12-24"))
        } else {
            Issue.record("the filed approval lost its payload: \(record.payload)")
        }
    }
}

/// Two clicks in a row are two independent records — not one record resolved
/// twice (which would throw `alreadyResolved` and, because the resolve is
/// `try?`, silently leave the second click's row pending).
@Test("repeated desk clicks each file and resolve their own approval row")
func repeatedDeskClicksDoNotOrphanTheSecondRow() async throws {
    try await withTempApprovalRoot { root in
        let filer = DeskClickApprovalFiler(dataRoot: root)
        var ids: [String] = []
        for index in 0..<3 {
            ids.append(try await filer.fileApprovalRequest(
                toolName: "desk_note",
                surface: DeskToolDispatchRouter.surface,
                payload: .object(["handle": .string("desk_\(index)")]),
                reason: "policy tier"))
        }

        #expect(Set(ids).count == 3, "two clicks reused one approval id")

        let inbox = SwiftNativeApprovalInbox(root: root)
        #expect(try await inbox.list(filter: .all).count == 3)
        let pending = try await inbox.list(filter: .pending)
        #expect(pending.isEmpty, "\(pending.count) of 3 clicks left an orphaned pending row")
        for id in ids {
            #expect(try await inbox.get(id).decision == ApprovalDecision.approved.rawValue)
        }
    }
}
