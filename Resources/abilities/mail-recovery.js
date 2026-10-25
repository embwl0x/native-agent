/* NativeAgent ability
{"id": "mail-recovery", "kind": "tool", "version": 1, "reach": {"capabilities": []}, "face": {"page": "mail"}, "record": {"description": "Recovery wording for structured mail failure reasons. No app access or effects.", "actions": [], "inputSchema": {"type": "object", "readOnly": true, "properties": {}, "additionalProperties": false}}}
*/
function run(input) {
    return {
        "missing_query": "Nothing to search for: give a word or phrase in query.",
        "missing_to": "Say who it goes to in to (an email address).",
        "missing_subject": "Say which message: its message_id and expected_message_id from mail_list_recent, or its subject.",
        "missing_body": "Nothing to send or save: put the text in body.",
        "invalid_message_locator": "message_id needs the expected_message_id from the same mail_list_recent row.",
        "message_not_in_inbox": "That message is no longer in the inbox; list it again with mail_list_recent and use the new message_id.",
        "message_changed_or_moved_refresh_inbox": "That message moved or changed; list the inbox again with mail_list_recent and use the new message_id.",
        "message_changed_or_ambiguous_refresh_inbox": "That message moved, changed, or its subject matches several; list the inbox again and reply by message_id.",
        "no_matching_message": "No inbox message matches; list the inbox with mail_list_recent and pass its message_id. An archived message is no longer in the inbox, so delete or mark it before archiving.",
        "mail_refused_send": "Mail refused to send it (no account can send, or it is offline); nothing went out.",
        "no_archive_mailbox": "Mail has no Archive mailbox, so nothing moved; leave it or use mail_delete.",
        "mail_delete_no_match": "No indexed message matches in Mail, including archived mail; nothing moved to Trash.",
        "mail_delete_target_changed": "The indexed message moved or changed before deletion; nothing moved to Trash. Locate it again before trying again.",
        "no_trash_mailbox": "Mail has no Trash mailbox for this message's account; nothing was deleted.",
        "message_already_in_trash": "That message is already in Trash; it was left there and was not permanently deleted.",
        "mail_lookup_timed_out": "Mail did not answer in time; nothing changed. Read it again, and if it repeats, look at Mail itself.",
        "mail_index_unavailable": "Mail's message index could not be read (NativeAgent may need macOS Full Disk Access); nothing was listed or changed."
    };
}
