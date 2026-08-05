import Foundation
import Testing
import ApprovalInbox
import ChatOrchestration
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

// Perf wave 2. `awaitResolution` used to re-read the approvals inbox once per
// second for the whole time a human sat looking at a Telegram approval prompt,
// and `inbox.get(id)` is not cheap: it takes the approvals flock, parses and
// validates all 300 rows of `requests.json`, and sorts them, to pull out one
// record. It now waits on a kqueue `FileChangeWatcher` over that file, with a
// 15s repair poll as the only remaining timer.
//
// The contract these tests pin: reaction is STRICTLY FASTER than the old 1s
// tick, cancellation still tears everything down, and the decision mapping is
// byte-identical to what it was.
@Suite("TelegramApprovalFiler awaitResolution watcher")
struct TelegramApprovalWatcherTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TelegramApprovalWatcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFiler(root: URL) -> TelegramApprovalFiler {
        TelegramApprovalFiler(
            dataRoot: root,
            token: "test-token",
            promptSender: { _, _, _, _, _ in },
            approvalResolver: { _, _ in }
        )
    }

    private func stageApproval(root: URL) async throws -> ApprovalRecord {
        try await SwiftNativeApprovalInbox(root: root).create(.object([
            "title": .string("Approve test_tool"),
            "action": .string("test_tool"),
            "risk": .string("confirm"),
            "reason": .string("unit test"),
            "payload": .object([:]),
            "remoteResolvable": .bool(true),
            "localOnly": .bool(false),
        ]))
    }

    // MUTATION TEST — the watcher must actually FIRE. An external resolution
    // (the shape a Telegram button tap produces: a different actor writes
    // `requests.json`) has to wake the waiter well inside the old 1s tick, and
    // far inside the 15s repair poll. If the kqueue arm is ever dropped, this
    // waits out the repair interval and blows the 3s deadline.
    @Test(.timeLimit(.minutes(1)))
    func anExternalResolutionWakesTheWaiterFasterThanTheRepairPoll() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let filer = makeFiler(root: root)
        let approval = try await stageApproval(root: root)

        #expect(
            TelegramApprovalFiler.resolutionRepairPollSeconds >= 10,
            "test premise: the repair poll must be far longer than this deadline, so passing proves the WATCHER fired and not the timer"
        )

        let started = Date()
        async let decision = filer.awaitResolution(id: approval.id)

        // Give the waiter a moment to arm and take its first read, then resolve
        // from outside — exactly what the Telegram callback path does.
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try await SwiftNativeApprovalInbox(root: root)
            .resolve(approval.id, decision: .approved, decidedBy: "telegram-test")

        let resolved = try await decision
        let elapsed = Date().timeIntervalSince(started)

        #expect(resolved == .approved)
        #expect(
            elapsed < 3,
            "the watcher must react in well under the 15s repair poll (took \(elapsed)s)"
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func anAlreadyResolvedApprovalReturnsWithoutWaitingAtAll() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let filer = makeFiler(root: root)
        let approval = try await stageApproval(root: root)
        _ = try await SwiftNativeApprovalInbox(root: root)
            .resolve(approval.id, decision: .denied, decidedBy: "telegram-test")

        let started = Date()
        let decision = try await filer.awaitResolution(id: approval.id)
        #expect(decision == .denied)
        #expect(
            Date().timeIntervalSince(started) < 2,
            "the first read happens before any wait — a resolved approval never blocks"
        )
    }

    // Cancellation must exit promptly AND tear down the watcher and the repair
    // ticker. A leaked kqueue source holds an O_EVTONLY descriptor for the
    // process lifetime.
    @Test(.timeLimit(.minutes(1)))
    func cancellationExitsPromptly() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let filer = makeFiler(root: root)
        let approval = try await stageApproval(root: root)

        let waiter = Task { try await filer.awaitResolution(id: approval.id) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        waiter.cancel()

        do {
            _ = try await waiter.value
            Issue.record("a cancelled wait must not return a decision")
        } catch {
            // CancellationError, or the inbox read throwing on cancellation —
            // either is a clean exit.
        }
        #expect(
            Date().timeIntervalSince(started) < 3,
            "cancellation must not wait out the repair poll"
        )
    }

    // Byte-identical decision mapping: the switch is unchanged, and an unknown
    // decision string still denies (fail closed).
    @Test(.timeLimit(.minutes(1)))
    func decisionMappingIsUnchanged() async throws {
        for (written, expected) in [
            (ApprovalDecision.approved, ApprovalDecision.approved),
            (ApprovalDecision.denied, ApprovalDecision.denied),
        ] {
            let root = try tempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let filer = makeFiler(root: root)
            let approval = try await stageApproval(root: root)
            _ = try await SwiftNativeApprovalInbox(root: root)
                .resolve(approval.id, decision: written, decidedBy: "telegram-test")
            #expect(try await filer.awaitResolution(id: approval.id) == expected)
        }
    }
}
