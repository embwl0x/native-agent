import MacIntegration

/// Shared tool policy tables; turn intent is not inferred from message text.
public enum ToolPreloadHeuristics {
    /// The built-in SearXNG server's tool (MCPDispatcher default server).
    public static let webSearchTools: Set<String> = ["mcp__searxng-local__search"]

    /// Dispatch-time Mac Integration permissions, also used by the parallel write veto.
    package static let macIntegrationGates: [String: (integration: String, mode: MacIntegrationPermissionMode)] = [
        // calendar group
        "mac_calendar_list_upcoming": (MacIntegrationID.calendar, .read),
        "mac_calendar_calendars": (MacIntegrationID.calendar, .read),
        "mac_calendar_free_busy": (MacIntegrationID.calendar, .read),
        "mac_calendar_create_event": (MacIntegrationID.calendar, .write),
        "mac_calendar_modify_event": (MacIntegrationID.calendar, .write),
        "mac_calendar_delete_event": (MacIntegrationID.calendar, .write),
        "mac_reminders_list_due_today": (MacIntegrationID.reminders, .read),
        "mac_reminders_query": (MacIntegrationID.reminders, .read),
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
        // Not in any preload pattern group, but the table doubles as the
        // parallel-dispatch write veto (U1 step 6) — it must cover EVERY
        // dispatchMacIntegrationTool case, not just preloadable ones
        // (gpt-5.5 review, 2026-06-10: scheduler_list_jobs gates on .write
        // — scheduler has no read axis — yet its "list" name walked the
        // positive read-signal branch into the parallel set).
        "mac_notify": (MacIntegrationID.notifyMac, .write),
        "mac_spotlight_search": (MacIntegrationID.spotlight, .read),
        "scheduler_list_jobs": (MacIntegrationID.scheduler, .write),
        "scheduler_create_job": (MacIntegrationID.scheduler, .write),
        "scheduler_cancel_job": (MacIntegrationID.scheduler, .write),
        "scheduler_delete_job": (MacIntegrationID.scheduler, .write),
        "scheduler_pause_job": (MacIntegrationID.scheduler, .write),
        "scheduler_resume_job": (MacIntegrationID.scheduler, .write),
        "scheduler_update_job": (MacIntegrationID.scheduler, .write),
    ]

}
