import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Studio
import TurnTrace
import MemoryV2
import AgentWorkspace
import ApprovalInbox
import Desk
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import ChatSessionWork
import AgentConversations
import ChatToolParsing
import TrustCenter
import ToolRegistry
import DreamREMCycle
import WorkshopExecution
import Dispatcher
import Browser
import NotificationInbox
import AuthoredCapabilities
import Experiences
import MacIntegration
import ProviderRouting
import MacControl
import Transcripts
// Blueprint: | `ChatToolApprovalExecution.swift` | Exact execution claims and retained settlement outcomes |
final class ChatToolApprovalExecutionOwners: @unchecked Sendable {
    struct Settlement: Sendable {
        let action: JSONValue
        let detail: String
        var result: JSONValue? = nil
    }
    private struct Key: Hashable {
        let root: String
        let approvalID: String
    }
    static let shared = ChatToolApprovalExecutionOwners()
    static let continuations = ChatToolApprovalExecutionOwners()
    private let lock = NSLock()
    private var active: Set<Key> = []
    private var retained: [Key: Settlement] = [:]
    func settlement(root: URL, approvalID: String) -> Settlement? {
        let key = Key(root: root.resolvingSymlinksInPath().standardizedFileURL.path, approvalID: approvalID)
        return lock.withLock { retained[key] }
    }
    func retain(_ settlement: Settlement?, root: URL, approvalID: String) {
        let key = Key(root: root.resolvingSymlinksInPath().standardizedFileURL.path, approvalID: approvalID)
        lock.withLock { retained[key] = settlement }
    }
    func acquire(root: URL, approvalID: String) -> Bool {
        let key = Key(root: root.resolvingSymlinksInPath().standardizedFileURL.path, approvalID: approvalID)
        return lock.withLock { active.insert(key).inserted }
    }
    func acquireRetained(root: URL, approvalID: String) throws -> Settlement? {
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
    func release(root: URL, approvalID: String) {
        let key = Key(root: root.resolvingSymlinksInPath().standardizedFileURL.path, approvalID: approvalID)
        _ = lock.withLock { active.remove(key) }
    }
}
