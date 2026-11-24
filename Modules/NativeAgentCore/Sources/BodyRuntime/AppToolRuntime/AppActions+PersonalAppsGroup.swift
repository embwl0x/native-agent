import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+PersonalAppsGroup.swift` | PersonalApps action declarations |

extension AppActions {
    static func personalAppsGroup() throws -> [AppAction] {
        try [
        // The rest of mail.* is answered by the native-mail part.
        .fold("mail_save_attachment", "mail"),
        .fold("mac_calendar_list_upcoming", "calendar", read: true),
        .fold("mac_calendar_calendars", "calendar", read: true),
        .fold("mac_calendar_free_busy", "calendar", read: true),
        .fold("mac_calendar_create_event", "calendar"),
        .fold("mac_calendar_modify_event", "calendar"),
        .fold("mac_calendar_delete_event", "calendar", irreversible: true),
        .fold("mac_reminders_list_due_today", "reminders", "Reminders due today and overdue as separate parts, each counted and capped independently",
            read: true),
        .fold("mac_reminders_query", "reminders", read: true),
        .fold("mac_reminders_lists", "reminders", "Every reminder list with its open count", read: true),
        .fold("mac_reminders_read", "reminders", read: true),
        .fold("mac_reminders_create", "reminders"),
        .fold("mac_reminders_list_rename", "reminders"),
        .fold("mac_reminders_list_create", "reminders"),
        .fold("mac_reminders_update", "reminders"),
        .fold("mac_reminders_complete", "reminders"),
        .fold("mac_reminders_delete", "reminders", irreversible: true),
        .fold("contacts_search", "contacts", read: true),
        .fold("contacts_create_or_update", "contacts"),
        .fold("contacts_delete", "contacts", irreversible: true),
        .fold("mac_notify", "notifications"),
        .fold("mobile_notify", "notifications"),
        .fold("phone_request", "pairing"),
        // Location is read-only; the wait covers an open phone's push, tap, fix and 8-second Mac drain, not a closed phone. A real answer took
        // about 65 s, so 90 s of wait (its call ends at 120 s with settlement) leaves room for the answer to arrive.
        .fold("phone_request", "pairing", id: "phone.location", "Ask the paired iPhone for its current location", [],
              input: ["kind": .string("location.current"), "wait_seconds": .int(90)], read: true),
        ]
    }
}
