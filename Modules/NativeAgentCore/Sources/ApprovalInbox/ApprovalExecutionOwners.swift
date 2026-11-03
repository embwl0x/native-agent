import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Experiences
// Blueprint: | `ApprovalExecutionOwners.swift` | Shared approval execution claims and retained outcome settlement for coordinator and resident drain |
public final class ApprovalExecutionOwners: @unchecked Sendable {
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
    private let lock = NSLock()
    private var active: Set<Key> = []
    private var retained: [Key: Settlement] = [:]
    public func settlement(root: URL, approvalID: String) -> Settlement? {
        let key = Key(root: root.resolvingSymlinksInPath().standardizedFileURL.path, approvalID: approvalID)
        return lock.withLock { retained[key] }
    }
    public func retain(_ settlement: Settlement?, root: URL, approvalID: String) {
        let key = Key(root: root.resolvingSymlinksInPath().standardizedFileURL.path, approvalID: approvalID)
        lock.withLock { retained[key] = settlement }
    }
    public func acquire(root: URL, approvalID: String) -> Bool {
        let key = Key(root: root.resolvingSymlinksInPath().standardizedFileURL.path, approvalID: approvalID)
        return lock.withLock { active.insert(key).inserted }
    }
    public func acquireRetained(root: URL, approvalID: String) throws -> Settlement? {
        let key = Key(root: root.resolvingSymlinksInPath().standardizedFileURL.path, approvalID: approvalID)
        return try lock.withLock {
            guard let settlement = retained[key] else { return nil }
            guard active.insert(key).inserted else {
                throw NSError(domain: "NativeAgentApprovals", code: 409, userInfo: [
                    NSLocalizedDescriptionKey: "The execution receipt is still being saved. Retry the same decision after that save finishes."
                ])
            }
            return settlement
        }
    }
    public func release(root: URL, approvalID: String) {
        let key = Key(root: root.resolvingSymlinksInPath().standardizedFileURL.path, approvalID: approvalID)
        _ = lock.withLock { active.remove(key) }
    }

    public static func settleExecution(_ id: String, dataRoot: URL, settlement: Settlement) async -> Result<ApprovalRecord, Error> {
        await settle {
            shared.retain(settlement, root: dataRoot, approvalID: id)
            defer { shared.release(root: dataRoot, approvalID: id) }
            do {
                let record = try await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                    id, executedAction: settlement.action, detail: settlement.detail, result: settlement.result)
                shared.retain(nil, root: dataRoot, approvalID: id)
                await RepairOwed.settle(dataRoot, operation: "approval.receipt:" + id,
                    evidence: .init(source: "workflows/approvals/requests.json", id: id)).value
                return .success(record)
            } catch { return .failure(error) }
        }
    }

    @discardableResult
    public static func perform(_ record: ApprovalRecord, dataRoot: URL,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> Settlement?
    ) async -> Bool {
        guard shared.acquire(root: dataRoot, approvalID: record.id) else { return false }
        var settlementOwnsRelease = false
        defer { if !settlementOwnsRelease { shared.release(root: dataRoot, approvalID: record.id) } }
        let settlement: Settlement
        if let retained = shared.settlement(root: dataRoot, approvalID: record.id) { settlement = retained }
        else {
            do {
                guard let returned = try await operation() else { return false }
                settlement = returned
            } catch {
                await RepairOwed.owe(dataRoot, id: "approval.application:" + record.id, kind: .run,
                    operation: "approval.application:" + record.id, owner: "Approval " + record.id,
                    words: error.localizedDescription,
                    lever: "Inspect the domain owner's application evidence, repair its failure, then reconcile this same approval.").value
                return false
            }
        }
        settlementOwnsRelease = true
        switch await settleExecution(record.id, dataRoot: dataRoot, settlement: settlement) {
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
