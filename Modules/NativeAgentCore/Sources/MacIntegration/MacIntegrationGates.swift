import Foundation
import PersistenceCore
// Blueprint: | `MacIntegrationGates.swift` | `MacIntegrationGates`: `byTool` (the switch each dispatcher tool is gated on), `refusal` (the off switch's refusal, asked before any card by the chat gate and the Workshop executor) |

/// Which Mac Integration switch each tool's dispatch is gated on, and the
/// refusal a switch User turned off gives it. One table for the dispatcher,
/// the parallel write veto, the chat approval gate and the Workshop executor,
/// so a card never asks for what the switch would refuse.
public enum MacIntegrationGates {
    public static let byTool: [String: (integration: String, mode: MacIntegrationPermissionMode)] = [
        // calendar group
        "mac_calendar_list_upcoming": (MacIntegrationID.calendar, .read),
        "mac_calendar_calendars": (MacIntegrationID.calendar, .read),
        "mac_calendar_free_busy": (MacIntegrationID.calendar, .read),
        "mac_calendar_create_event": (MacIntegrationID.calendar, .write),
        "mac_calendar_modify_event": (MacIntegrationID.calendar, .write),
        "mac_calendar_delete_event": (MacIntegrationID.calendar, .write),
        "mac_reminders_list_due_today": (MacIntegrationID.reminders, .read),
        "mac_reminders_query": (MacIntegrationID.reminders, .read),
        "mac_reminders_lists": (MacIntegrationID.reminders, .read),
        "mac_reminders_read": (MacIntegrationID.reminders, .read),
        "mac_reminders_update": (MacIntegrationID.reminders, .write),
        "mac_reminders_create": (MacIntegrationID.reminders, .write),
        "mac_reminders_list_rename": (MacIntegrationID.reminders, .write),
        "mac_reminders_list_create": (MacIntegrationID.reminders, .write),
        "mac_reminders_complete": (MacIntegrationID.reminders, .write),
        "mac_reminders_delete": (MacIntegrationID.reminders, .write),
        // mail group
        "mail_list_recent": (MacIntegrationID.mail, .read),
        "mail_read_batch": (MacIntegrationID.mail, .read),
        "mail_triage_batch": (MacIntegrationID.mail, .write),
        "mail_search": (MacIntegrationID.mail, .read),
        "mail_senders": (MacIntegrationID.mail, .read),
        "mail_send": (MacIntegrationID.mail, .write),
        "mail_mark_read": (MacIntegrationID.mail, .write),
        "mail_archive": (MacIntegrationID.mail, .write),
        "mail_delete": (MacIntegrationID.mail, .write),
        "mail_reply": (MacIntegrationID.mail, .write),
        "mail_draft": (MacIntegrationID.mail, .write),
        // messages group
        "messages_recent_threads": (MacIntegrationID.messages, .read),
        "messages_send": (MacIntegrationID.messages, .write),
        // notes group
        "notes_search": (MacIntegrationID.notes, .read),
        "notes_create": (MacIntegrationID.notes, .write),
        "notes_update": (MacIntegrationID.notes, .write),
        "notes_delete": (MacIntegrationID.notes, .write),
        // contacts group
        "contacts_search": (MacIntegrationID.contacts, .read),
        "contacts_create_or_update": (MacIntegrationID.contacts, .write),
        "contacts_delete": (MacIntegrationID.contacts, .write),
        // music group
        "music_now_playing": (MacIntegrationID.music, .read),
        "music_search_library": (MacIntegrationID.music, .read),
        "music_list_library": (MacIntegrationID.music, .read),
        "music_list_playlists": (MacIntegrationID.music, .read),
        "music_control": (MacIntegrationID.music, .write),
        // The parallel write veto covers every dispatchMacIntegrationTool case.
        "mac_notify": (MacIntegrationID.notifyMac, .write),
        "mobile_notify": (MacIntegrationID.notifyMobile, .write),
        "phone_request": (MacIntegrationID.notifyMobile, .write),
        "mail_save_attachment": (MacIntegrationID.mail, .read),
        "mac_spotlight_search": (MacIntegrationID.spotlight, .read),
        "scheduler_list_jobs": (MacIntegrationID.scheduler, .write),
        "scheduler_create_job": (MacIntegrationID.scheduler, .write),
        "scheduler_cancel_job": (MacIntegrationID.scheduler, .write),
        "scheduler_pause_job": (MacIntegrationID.scheduler, .write),
        "scheduler_resume_job": (MacIntegrationID.scheduler, .write),
        "scheduler_update_job": (MacIntegrationID.scheduler, .write),
    ]

    /// The refusal this tool's switch gives, or nil when it is on (or the
    /// tool has no switch).
    public static func refusal(tool: String, dataRoot: URL) async throws -> String? {
        guard let gate = byTool[tool] else { return nil }
        let store = dataRoot == defaultDataRoot() ? MacIntegrationPermissionStore.shared : MacIntegrationPermissionStore(dataRoot: dataRoot)
        return try await store.readinessChecked().refusal(integration: gate.integration, mode: gate.mode)
    }
}
