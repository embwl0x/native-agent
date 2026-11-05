// Share one retained revision; each source keeps its own failure without blanking siblings.

import AgentConversations
import Foundation
import PersistenceCore
import Desk
import NativeAgentShared
import ApprovalInbox
import NotificationInbox
// Blueprint: | `DeskBoardRead.swift` | `DeskBoardRead` struct |

/// Read all Desk stores off the main actor.
public struct DeskBoardRead: Sendable {
    public var revision: UInt64 = 0
    public var deskState: DeskState?
    /// A nil `deskState` must carry its read failure rather than claim an empty board.
    public var deskError: String?
    /// The agent's jobs, its own lines among them; a job that carries a Desk item is that item's movement.
    public var agentJobs: DeskLaneState<AgentJob> = .rows([])
    public var overview: WorkOverview?

    public var approvals: Result<[ApprovalRecord], Error> = .success([])
    public var inbox: Result<[InboxItemRecord], Error> = .success([])

    public var items: [DeskItem] { deskState?.items ?? [] }
    public var debugProjection: String = ""
    public init(
        deskState: DeskState? = nil,
        deskError: String? = nil,
        agentJobs: DeskLaneState<AgentJob> = .rows([])
    ) {
        self.deskState = deskState
        self.deskError = deskError
        self.agentJobs = agentJobs
    }

}
