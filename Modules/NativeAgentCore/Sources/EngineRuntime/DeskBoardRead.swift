// One retained Desk revision, shared by Mac pages, status publication and DeviceSync.
// Each checked lane keeps its own failure; one unavailable source never blanks another.

import Foundation
import PersistenceCore
import Desk
import WorkshopExecution
import NativeAgentShared
import ApprovalInbox
import NotificationInbox
// Blueprint: | `DeskBoardRead.swift` | `DeskBoardRead` struct |

/// One read of every Desk store, taken off the main actor.
public struct DeskBoardRead: Sendable {
    /// The desk feed, or nil when it could not be read.
    public var deskState: DeskState?
    /// Why the desk feed could not be read. Non-nil exactly when `deskState` is
    /// nil — a lane that failed says so instead of presenting as empty.
    public var deskError: String?
    public var executions: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord> = .rows([])
    public var overview: WorkOverview?

    public var approvals: Result<[ApprovalRecord], Error> = .success([])
    public var inbox: Result<[InboxItemRecord], Error> = .success([])

    public var items: [DeskItem] { deskState?.items ?? [] }
    public var debugProjection: String = ""
    public init(
        deskState: DeskState? = nil,
        deskError: String? = nil,
        executions: DeskLaneState<WorkshopExecution.WorkshopExecutionRecord> = .rows([])
    ) {
        self.deskState = deskState
        self.deskError = deskError
        self.executions = executions
    }

}
