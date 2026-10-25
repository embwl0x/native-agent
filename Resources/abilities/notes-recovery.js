/* NativeAgent ability
{"id": "notes-recovery", "kind": "tool", "version": 1, "reach": {"capabilities": []}, "face": {"page": "notes"}, "record": {"description": "Recovery wording for structured notes failure reasons. No app access or effects.", "actions": [], "inputSchema": {"type": "object", "readOnly": true, "properties": {}, "additionalProperties": false}}}
*/
function run(input) {
    return {
        "missing_body": "Nothing to send or save: put the text in body.",
        "missing_title": "Give the note's title.",
        "no_matching_note": "No note has that exact id or title; find it with notes_search and copy its full id or title.",
        "invalid_note_body_offset": "Use body_offset with the same note id and next_body_offset from its last read; the offset must be within the current text.",
        "missing_body_append_or_new_title": "Say what to change: body (replace), append, or new_title.",
        "body_and_append_mutually_exclusive": "Use body to replace or append to add, not both."
    };
}
