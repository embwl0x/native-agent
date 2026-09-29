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

extension ApprovalRecord {
    /// The conversation that asked, for a chat tool approval: the filer
    /// (`NativeAgentChatApprovalFiler`) records it as `payload.origin.sessionId`.
    /// Only chat approvals carry a chat origin — every other kind is nil rather
    /// than borrowing a lookalike field.
    public var chatOriginSessionId: String? {
        guard case .object(let fields) = payload,
              case .string(let kind)? = fields["kind"],
              // ACP questions belong to a live protocol request, not a tool
              // replay. They share chat presentation only, never execution.
              kind == "chat_tool_approval" || kind == "agent_acp_live_approval",
              case .object(let origin)? = fields["origin"],
              case .string(let sessionId)? = origin["sessionId"] else { return nil }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
            chatOriginSessionId: record.chatOriginSessionId,
            lastRequestedAt: record.lastRequestedAt
        )
    }
}
