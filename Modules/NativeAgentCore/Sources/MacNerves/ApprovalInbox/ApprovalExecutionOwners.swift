import Foundation
import Synchronization
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import SenseCore
// Blueprint: | `ApprovalExecutionOwners.swift` | Shared approval execution claims and retained outcome settlement for coordinator and resident drain |
public final class ApprovalExecutionOwners: Sendable {
    public struct Settlement: Sendable {
        public let action: JSONValue
        public let detail: String
        public var result: JSONValue? = nil
        public init(action: JSONValue, detail: String, result: JSONValue? = nil) {
            self.action = action; self.detail = detail; self.result = result
        }
    }
    private struct Key: Hashable {
        let root: String
        let approvalID: String
    }
    public static let shared = ApprovalExecutionOwners()
    public static let continuations = ApprovalExecutionOwners()
    private struct State {
        var active: Set<Key> = []
        var retained: [Key: Settlement] = [:]
    }
    private let state = Mutex(State())
    public func settlement(root: URL, approvalID: String) -> Settlement? {
        let key = Key(root: root.resolvingSymlinksInPath().standardizedFileURL.path, approvalID: approvalID)
        return state.withLock { $0.retained[key] }
    }
    public func retain(_ settlement: Settlement?, root: URL, approvalID: String) {
        let key = Key(root: root.resolvingSymlinksInPath().standardizedFileURL.path, approvalID: approvalID)
        state.withLock { $0.retained[key] = settlement }
    }
    public func acquire(root: URL, approvalID: String) -> Bool {
        let key = Key(root: root.resolvingSymlinksInPath().standardizedFileURL.path, approvalID: approvalID)
        return state.withLock { $0.active.insert(key).inserted }
    }
    public func acquireRetained(root: URL, approvalID: String) throws -> Settlement? {
        let key = Key(root: root.resolvingSymlinksInPath().standardizedFileURL.path, approvalID: approvalID)
        return try state.withLock { state in
            guard let settlement = state.retained[key] else { return nil }
            guard state.active.insert(key).inserted else {
                throw NSError(domain: "NativeAgentApprovals", code: 409, userInfo: [
                    NSLocalizedDescriptionKey: "The execution receipt is still being saved. Retry the same decision after that save finishes."
                ])
            }
            return settlement
        }
    }
    public func release(root: URL, approvalID: String) {
        let key = Key(root: root.resolvingSymlinksInPath().standardizedFileURL.path, approvalID: approvalID)
        _ = state.withLock { $0.active.remove(key) }
    }

    @concurrent public static func settleExecution(_ id: String, inbox: SwiftNativeApprovalInbox, settlement: Settlement) async -> Result<ApprovalRecord, Error> {
        let dataRoot = inbox.root
        return await settle {
            shared.retain(settlement, root: dataRoot, approvalID: id)
            defer { shared.release(root: dataRoot, approvalID: id) }
            do {
                let record = try await inbox.annotateExecution(
                    id, executedAction: settlement.action, detail: settlement.detail, result: settlement.result)
                shared.retain(nil, root: dataRoot, approvalID: id)
                await RepairOwed.settle(dataRoot, operation: "approval.receipt:" + id,
                    evidence: .init(source: "workflows/approvals/requests.json", id: id)).value
                return .success(record)
            } catch { return .failure(error) }
        }
    }

    @discardableResult
    public static func perform(_ record: ApprovalRecord, inbox: SwiftNativeApprovalInbox,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> Settlement?
    ) async -> Bool {
        let dataRoot = inbox.root
        guard shared.acquire(root: dataRoot, approvalID: record.id) else { return false }
        var settlementOwnsRelease = false
        defer { if !settlementOwnsRelease { shared.release(root: dataRoot, approvalID: record.id) } }
        let settlement: Settlement
        if let retained = shared.settlement(root: dataRoot, approvalID: record.id) { settlement = retained }
        else {
            let id = record.id
            do {
                // Between the yes and the saved outcome the record reads running, not empty.
                try? await inbox.markRunning(id)
                guard let returned = try await operation() else {
                    await settle { _ = try? await inbox.markRunning(id, running: false) }
                    return false
                }
                settlement = returned
            } catch {
                await settle { _ = try? await inbox.markRunning(id, running: false) }
                if error is CancellationError { return false }
                await RepairOwed.owe(dataRoot, id: "approval.application:" + record.id, kind: .run,
                    operation: "approval.application:" + record.id, owner: "Approval " + record.id,
                    words: error.localizedDescription,
                    lever: "Inspect the domain owner's application evidence, repair its failure, then reconcile this same approval.").value
                return false
            }
        }
        settlementOwnsRelease = true
        switch await settleExecution(record.id, inbox: inbox, settlement: settlement) {
        case .success:
            await RepairOwed.settle(dataRoot, operation: "approval.application:" + record.id,
                evidence: .init(source: "workflows/approvals/requests.json", id: record.id)).value
            return true
        case .failure(let error):
            await RepairOwed.owe(dataRoot, id: "approval.receipt:" + record.id, kind: .run,
                operation: "approval.receipt:" + record.id, owner: "Approval " + record.id,
                words: error.localizedDescription, lever: "Retry this same decision to save its retained outcome without repeating the effect.").value
            return false
        }
    }
}
