import PersistenceCore
import MacNerves
import NativeAgentCore
import NativeAgentShared
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+DeskGroup.swift` | Desk action declarations |

extension AppActions {
    static func deskGroup() throws -> [AppAction] {
        try [
        .fold("desk_read", "desk", """
            Your Desk: paged items with status, summary, notes and refs; handle reads one item, query searches, limit/offset page, sort changes order only
            """, subject: ["handle"], read: true),
        .fold("desk_add_item", "desk"),
        .fold("desk_note", "desk", subject: ["handle"]),
        .fold("desk_set_status", "desk", subject: ["handle"]),
        .fold("desk_wait", "desk", subject: ["handle"]),
        .fold("desk_update_item", "desk", subject: ["handle"]),
        .fold("desk_add_ref", "desk", subject: ["handle"]),
        .fold("desk_blocked_on", "desk", subject: ["handle"]),
        .fold("desk_defer", "desk", subject: ["handle"]),
        .fold("desk_close", "desk", subject: ["handle"], argumentNames: ["reason": ["evidence", "summary"], "canceled": ["status"]],
              argumentValues: ["canceled": ["canceled": .bool(true), "cancelled": .bool(true), "done": .bool(false)]]),
        .fold("desk_work_log", "desk", subject: ["handle"]),
        .fold("desk_set_cadence", "desk", subject: ["handle"]),
        .fold("desk_set_notify", "desk", subject: ["handle"]),
        .fold("desk_nag_control", "desk"),
        .fold("scheduler_list_jobs", "desk", read: true),
        .fold("scheduler_create_job", "desk", """
            Schedule a read on the clock: connector_action (a watch) or proactive_scan; for intentions, check-ins and reminders use queue.add
            """),
        .fold("scheduler_cancel_job", "desk", "Cancel a scheduled read: it leaves the clock; a read already running finishes"),
        .fold("scheduler_cancel_job", "desk", id: "schedule.delete"),
        ]
    }
}
