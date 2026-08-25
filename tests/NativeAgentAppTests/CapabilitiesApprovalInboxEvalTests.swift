import ApprovalInbox
import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

private actor CapabilitiesApprovalResolutionGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func holdResolver() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilResolverHasStarted() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func releaseResolver() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@Suite("app.settings · Capabilities approval inbox", .serialized)
struct CapabilitiesApprovalInboxEvalTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capabilities-approval-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func createPendingApproval(in inbox: SwiftNativeApprovalInbox, title: String) async throws -> ApprovalRecord {
        try await inbox.create(.object([
            "title": .string(title),
            "action": .string("capabilities.eval.no_effect"),
            "risk": .string("confirm"),
            "reason": .string("exercise the canonical approval decision boundary"),
            "payload": .object([:]),
        ]))
    }

    @Test @MainActor
    func concurrentCapabilitiesAndApprovalsSurfaceDecisionsCoalesceAtTheCanonicalInbox() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let pending = try await createPendingApproval(in: inbox, title: "Approve one time")
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let gate = CapabilitiesApprovalResolutionGate()
        var resolverCalls = 0
        app.approvalResolverOverride = { id, decision in
            resolverCalls += 1
            await gate.holdResolver()
            return try await client.resolveApproval(id: id, decision: decision)
        }

        async let first: CapabilitiesApprovalInboxResolution = app.resolveApprovalOnce(
            id: pending.id,
            decision: "approved"
        )
        await gate.waitUntilResolverHasStarted()
        let second = await app.resolveApprovalOnce(id: pending.id, decision: "approved")
        await gate.releaseResolver()
        let firstResult = await first

        guard case .applied(let applied) = firstResult else {
            Issue.record("first decision did not reach the durable resolver: \(firstResult)")
            return
        }
        #expect(applied.id == pending.id)
        #expect(resolverCalls == 1)
        #expect(second == .noOpInFlight(id: pending.id))
        #expect(!app.isResolvingApproval(id: pending.id))

        // This read is deliberately through a fresh canonical inbox actor,
        // proving the single app-facing resolver call produced one durable
        // terminal record rather than merely changing local view state.
        let reread = try await SwiftNativeApprovalInbox(root: root).get(pending.id)
        #expect(reread.status == "resolved")
        #expect(reread.decision == "approved")
    }

    @Test @MainActor
    func unavailableResolverLeavesTheCanonicalRequestPendingAndReenablesIt() async throws {
        enum ReaderFailure: Error { case unavailable }

        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let pending = try await createPendingApproval(in: inbox, title: "Do not mask unavailable storage")
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        app.approvalResolverOverride = { _, _ in throw ReaderFailure.unavailable }

        let outcome = await app.resolveApprovalOnce(id: pending.id, decision: "denied")
        guard case .unavailable(let detail) = outcome else {
            Issue.record("failed approval resolution was not visibly unavailable: \(outcome)")
            return
        }
        #expect(!detail.isEmpty)
        #expect(!app.isResolvingApproval(id: pending.id))

        let reread = try await SwiftNativeApprovalInbox(root: root).get(pending.id)
        #expect(reread.status == "pending")
        #expect(reread.decision == nil)
    }
}
