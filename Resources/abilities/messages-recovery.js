/* NativeAgent ability
{"id": "messages-recovery", "kind": "tool", "version": 1, "reach": {"capabilities": []}, "face": {"page": "messages"}, "record": {"description": "Recovery wording for structured messages failure reasons. No app access or effects.", "actions": [], "inputSchema": {"type": "object", "readOnly": true, "properties": {}, "additionalProperties": false}}}
*/
function run(input) {
    return {
        "missing_body": "Nothing to send or save: put the text in body.",
        "thread_not_found": "That conversation is not in Messages now; list threads again with messages_recent_threads.",
        "invalid_history_cursor": "before_message_id works only with the same thread_id, using older_before_message_id from the last read.",
        "choose_recipient_or_thread": "Give one of to (a phone number or email) or thread_id, not both.",
        "read_thread_before_reply": "Open the thread first (messages_recent_threads with its thread_id) and pass its participant handles as expected_participants.",
        "invalid_expected_participants": "expected_participants must be the handles from the latest thread read, each once.",
        "participants_changed_read_thread_again": "The people in that thread changed; open it again and reply with the new participants. Nothing was sent."
    };
}
