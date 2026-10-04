import Foundation
import Observation
import ApprovalInbox
import NativeAgentShared
import PersistenceCore

/// `NativeAgentEngine.approvals` (S10): the ApprovalInbox for one data root, in
/// core types. Every surface that shows approvals renders `records`; the read
/// is nonisolated so the phone lanes use the same owner. Decisions still run
/// through the approval executors (`NativeClient.resolveApproval`).
@MainActor
@Observable
public final class ApprovalsFacade {
    public nonisolated let dataRoot: URL

    /// Every approval, pending and decided, newest first, as of the last read.
    public var records: [ApprovalRecord] = [] {
        didSet { recordsDidChange?() }
    }
    @ObservationIgnored public var recordsDidChange: (@MainActor () -> Void)?

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    nonisolated private var inbox: SwiftNativeApprovalInbox {
        SwiftNativeApprovalInbox(root: dataRoot)
    }

    /// Every approval record, newest first.
    public nonisolated func list() async throws -> [ApprovalRecord] {
        try await inbox.list(filter: .all)
    }

    /// The one file the reader and the resolver share; mounted pages watch it.
    public nonisolated func requestsPath() async -> URL {
        await inbox.approvalsPath
    }
}

extension ApprovalRequest {
    /// The phone's approvals.json row, in the shape the Mac has always sent.
    public init(record: ApprovalRecord) {
        self.init(
            id: record.id,
            title: record.title,
            action: record.action,
            risk: record.risk,
            reason: record.reason,
            status: record.status,
            createdAt: record.createdAt,
            resolvedAt: record.resolvedAt,
            decision: record.decision,
            payloadPreview: record.payloadPreview,
            localOnly: record.localOnly,
            remoteResolvable: record.remoteResolvable,
            // Where the phone draws its inline card: the conversation the
            // approval's chat card went to, else the one that asked.
            chatOriginSessionId: record.chatCardSessionId ?? record.chatOriginSessionId,
            lastRequestedAt: record.lastRequestedAt
        )
    }
}
