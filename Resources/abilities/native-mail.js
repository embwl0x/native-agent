/* NativeAgent ability
{"id": "native-mail", "kind": "ability", "version": 1, "face": {"page": "mail"}, "reach": {"capabilities": ["app_write:com.apple.mail", "computer_files"], "readPaths": ["~/Library/Mail"]}, "record": {"description": "Apple Mail through the door: list, search and read mail from Mail's local index and message files, rank senders, triage, mark read, archive, move to Trash, send, reply and save drafts through Mail's own Apple Events.", "actions": []}, "answers": {"mail.recent": {"summary": "Read Apple Mail drafts to a person/address with mailbox:\"drafts\"; also inbox or sent. Read one body with scope + message_id + expected_message_id + expected_account_id", "description": "List Apple Mail's inbox, sent or drafts metadata and exact mailbox totals; inbox_unread_by_category counts Primary, Transactions, Updates, Promotions and unclassified across the whole inbox. Primary is not proof of a human sender. Filtered or explicitly sorted lists cover all categories. Pass scope + message_id + expected_message_id + expected_account_id from one row to read a body and attachments (filename, content_type, size in bytes, 1-based index). Read-only; requires Mail → Read permission.", "class": "read", "irreversible": false, "screen": false, "args": {"type": "object", "properties": {"limit": {"type": "integer", "description": "Maximum messages to return (1-50, default 10)."}, "scope": {"type": "string", "description": "Mailbox scope: inbox (default), sent or drafts. Keep the same scope for continuation and message-body reads."}, "mailbox": {"type": "string", "enum": ["inbox", "sent", "drafts"], "description": "Alias for scope; both must agree when supplied together."}, "all_categories": {"type": "boolean", "description": "Inbox lists show Mail's Primary and Transactions categories; true lists Updates and Promotions too."}, "unread": {"type": "boolean", "description": "true selects unread messages, false selects read messages; omit for both."}, "sort": {"type": "string", "enum": ["newest", "oldest"], "description": "Date order; default newest. Keep unchanged for continuation."}, "offset": {"description": "Live mailbox continuation returned as next_offset; copy it unchanged; omit initially.", "anyOf": [{"type": "integer", "minimum": 0, "maximum": 10000}, {"type": "object", "additionalProperties": {"type": "integer", "minimum": 0, "description": ""}}]}, "body_offset": {"type": "integer", "description": "Exact detail continuation offset from body_end, up to 2000000; omit initially."}, "message_id": {"type": "integer", "minimum": 1, "description": "Exact positive message ID from a prior read in the same scope; returns up to 16000 characters of body."}, "expected_message_id": {"type": "string", "description": "Exact RFC message identifier paired with message_id in the prior read."}, "expected_account": {"type": "string", "description": "expected_account from the same row, when it has one."}, "position": {"type": "integer", "minimum": 1, "description": "position from the same row: finds the message fast."}, "expected_account_id": {"type": "string", "description": "expected_account_id from the same row; Mail's index checks the account with it."}}, "required": [], "additionalProperties": false}}, "mail.search": {"description": "Search or list Apple Mail's whole inbox, sent or drafts mailbox, all categories, with optional query, from, since, unread, category, attachment; default newest. Returns matching_total, has_more, next_offset and metadata, plus up to five attachment_names per message when filtering attachments. Inbox search results can be passed to mail.mark_read in one call. Bodies are not searched. Requires Mail → Read permission.", "class": "read", "irreversible": false, "screen": false, "args": {"type": "object", "properties": {"query": {"anyOf": [{"type": "string"}, {"type": "array", "items": {"type": "string"}}], "description": "One search term or an array of terms matched with OR against mailbox subject and sender metadata. Example: [\"receipt\", \"order confirmation\"]. Keep the same terms for continuation."}, "from": {"type": "string", "description": "Sender name or address fragment, matched case and accents aside; combined with other filters using AND."}, "attachment": {"description": "true selects messages with any attachment; a nonempty string matches an attachment filename fragment, case and accents aside. Combined with other filters using AND.", "anyOf": [{"type": "boolean", "enum": [true]}, {"type": "string", "minLength": 1}]}, "since": {"type": "string", "description": "Inclusive received date: this week (start of the local calendar week), local YYYY-MM-DD, or ISO-8601 with a time zone."}, "category": {"type": "string", "description": "Mail categories: primary, transactions, updates, promotions; comma-separated categories combine. A category is not a guarantee of a human sender."}, "unread": {"type": "boolean", "description": "true selects unread messages, false selects read messages; omit for both."}, "sort": {"type": "string", "enum": ["newest", "oldest"], "description": "Date order; default newest. Keep unchanged for continuation."}, "scope": {"type": "string", "description": "Mailbox scope: inbox (default), sent or drafts. Keep the same scope for continuation and message-body reads."}, "mailbox": {"type": "string", "enum": ["inbox", "sent", "drafts"], "description": "Alias for scope; both must agree when supplied together."}, "limit": {"type": "integer", "description": "Maximum messages to return (1-50, default 10)."}, "offset": {"description": "Live mailbox continuation returned as next_offset; copy it unchanged; omit initially.", "anyOf": [{"type": "integer", "minimum": 0, "maximum": 10000}, {"type": "object", "additionalProperties": {"type": "integer", "minimum": 0, "description": ""}}]}}, "required": [], "additionalProperties": false}}, "mail.senders": {"summary": "Read top and most frequent email senders and unread counts to identify unsubscribe candidates", "description": "Rank Apple Mail senders by exact message count in one bounded read-only grouped query, with unread count, newest date, address and display name. Covers inbox by default or all indexed mail; supports date, category and unread filters. Useful for sender frequency and unsubscribe candidates. Requires Mail Read permission and macOS Full Disk Access.", "class": "read", "irreversible": false, "screen": false, "args": {"type": "object", "properties": {"limit": {"type": "integer", "description": "Maximum senders to return (1-50, default 15)."}, "since": {"type": "string", "description": "Inclusive received date: this week, local YYYY-MM-DD, or ISO-8601 with a time zone."}, "scope": {"type": "string", "enum": ["inbox", "all"], "description": "Mailbox scope; default inbox."}, "category": {"type": "string", "description": "Mail categories: primary, transactions, updates, promotions; comma-separated categories combine."}, "unread_only": {"type": "boolean", "description": "Count and rank only unread messages; default false."}}, "required": [], "additionalProperties": false}}, "mail.read": {"description": "Read bodies for 1–10 selected Apple Mail messages in one bounded call. Each item uses an observed workspace name or exact message_id + expected_message_id + expected_account + expected_account_id and scope. Returns ordered per-item receipts, up to 4000 body characters each, and body_end for continuation when truncated. No rediscovery or retry; unfinished items are explicit. Requires Mail Read permission.", "class": "read", "irreversible": false, "screen": false, "args": {"type": "object", "properties": {"items": {"type": "array", "minItems": 1, "maxItems": 10, "items": {"type": "object", "properties": {"name": {"type": "string", "description": "Observed workspace name, such as mail.3. Omit locator fields when using a name."}, "message_id": {"type": "integer", "description": "Exact positive message_id from the selected row."}, "expected_message_id": {"type": "string", "description": "RFC identifier from that row; may be empty only for reads."}, "expected_account": {"type": "string", "description": "Exact expected_account from that row; required with a locator."}, "position": {"type": "integer", "description": "Position hint from the same row."}, "expected_account_id": {"type": "string", "description": "expected_account_id from that row; Mail's index checks the account with it."}, "scope": {"type": "string", "description": "Same mailbox scope: inbox or sent for reads; inbox for actions."}, "body_offset": {"type": "integer", "description": "Body continuation from this item's body_end, up to 2000000; omit initially."}}, "additionalProperties": false}}}, "required": ["items"], "additionalProperties": false}}, "mail.triage": {"description": "Triage 1–10 selected inbox messages in one bounded call: mark read, flag/unflag, then archive in the source account. Each item uses an observed workspace name or exact message_id + expected_message_id + expected_account; actions require a nonempty RFC identifier. Returns ordered per-item and per-action receipts, including partial effects. Cancellation, deadline or uncertain effects stop remaining work; never replay an uncertain item. No deletion: mail.delete retains its move-to-Trash approval gate. Requires Mail Write permission.", "class": "write", "irreversible": false, "screen": false, "args": {"type": "object", "properties": {"items": {"type": "array", "minItems": 1, "maxItems": 10, "items": {"type": "object", "properties": {"name": {"type": "string", "description": "Observed workspace name, such as mail.3. Omit locator fields when using a name."}, "message_id": {"type": "integer", "description": "Exact positive message_id from the selected row."}, "expected_message_id": {"type": "string", "description": "RFC identifier from that row; may be empty only for reads."}, "expected_account": {"type": "string", "description": "Exact expected_account from that row; required with a locator."}, "position": {"type": "integer", "description": "Position hint from the same row."}, "expected_account_id": {"type": "string", "description": "expected_account_id from that row, passed along as its identity."}, "scope": {"type": "string", "description": "Same mailbox scope: inbox or sent for reads; inbox for actions."}, "mark_read": {"type": "boolean", "description": "true to mark this message read; omit to leave it unchanged."}, "flagged": {"type": "boolean", "description": "true to flag, false to unflag; omit to leave it unchanged."}, "archive": {"type": "boolean", "description": "true to move this message to its own account's Archive, after other requested actions."}}, "additionalProperties": false}}}, "required": ["items"], "additionalProperties": false}}, "mail.mark_read": {"description": "Mark read a selected inbox result set: pass messages from mail.search (1–50) as the only argument. Returns per-message receipts; partial or uncertain work is explicit. If unread search has_more, repeat the same search without offset after marking, since the result set shrinks. Also accepts one exact locator or every message with a subject. Requires Mail → Write permission.", "class": "write", "irreversible": false, "screen": false, "args": {"type": "object", "properties": {"messages": {"type": "array", "minItems": 1, "maxItems": 50, "items": {"type": "object", "properties": {"message_id": {"type": "integer", "description": "Exact positive message_id from the selected row."}, "expected_message_id": {"type": "string", "description": "RFC identifier from that row; may be empty only for reads."}, "expected_account": {"type": "string", "description": "Exact expected_account from that row; required with a locator."}, "position": {"type": "integer", "description": "Position hint from the same row."}, "expected_account_id": {"type": "string", "description": "expected_account_id from that row, passed along as its identity."}, "scope": {"type": "string", "description": "Same mailbox scope: inbox or sent for reads; inbox for actions."}}, "additionalProperties": true}}, "subject": {"type": "string", "description": "Or the message's subject, when there's no message_id."}, "sender": {"type": "string", "description": "Optional sender filter with subject."}, "message_id": {"type": "integer", "minimum": 1, "description": "Inbox message_id from mail.recent."}, "expected_message_id": {"type": "string", "description": "expected_message_id from the same row."}, "expected_account": {"type": "string", "description": "expected_account from the same row, when it has one."}, "position": {"type": "integer", "minimum": 1, "description": "position from the same row: finds the message fast."}}, "required": [], "additionalProperties": false}}, "mail.archive": {"description": "Archive one inbox message by message_id + expected_message_id from mail.recent, or a subject only one message has. Requires Mail → Write permission.", "class": "write", "irreversible": false, "screen": false, "args": {"type": "object", "properties": {"subject": {"type": "string", "description": "Or the message's subject, when there's no message_id."}, "sender": {"type": "string", "description": "Optional sender filter with subject."}, "message_id": {"type": "integer", "minimum": 1, "description": "Inbox message_id from mail.recent."}, "expected_message_id": {"type": "string", "description": "expected_message_id from the same row."}, "expected_account": {"type": "string", "description": "expected_account from the same row, when it has one."}, "position": {"type": "integer", "minimum": 1, "description": "position from the same row: finds the message fast."}}, "required": [], "additionalProperties": false}}, "mail.delete": {"description": "Move one message to its account's Trash, including archived mail, by message_id + expected_message_id from a prior read, or a subject only one indexed message has. Rechecks identity in its current mailbox. Never permanently deletes. Requires Mail → Write permission and the existing approval policy.", "class": "write", "irreversible": true, "screen": false, "args": {"type": "object", "properties": {"subject": {"type": "string", "description": "Or the message's subject, when there's no message_id."}, "sender": {"type": "string", "description": "Optional sender filter with subject."}, "message_id": {"type": "integer", "minimum": 1, "description": "Message_id from a prior Mail read; the message may have been archived since that read."}, "expected_message_id": {"type": "string", "description": "expected_message_id from the same row."}, "expected_account": {"type": "string", "description": "expected_account from the same row, when it has one."}, "position": {"type": "integer", "minimum": 1, "description": "Optional prior position hint; deletion locates the current mailbox by indexed identity."}}, "required": [], "additionalProperties": false}}, "mail.send": {"description": "Sends an email now through Apple Mail. Requires Mail Write permission, requested inline when needed, or admitted Full Mac access. An explicit Mail Write revocation still applies.", "class": "send", "irreversible": true, "screen": false, "args": {"type": "object", "properties": {"to": {"anyOf": [{"type": "string"}, {"type": "array", "items": {"type": "string"}}], "description": "Recipient address(es). May be a single string or list of strings."}, "subject": {"type": "string", "description": "Email subject (required)."}, "body": {"type": "string", "description": "Email body text (required)."}, "cc": {"anyOf": [{"type": "string"}, {"type": "array", "items": {"type": "string"}}], "description": "Optional CC recipient(s). String or array."}, "bcc": {"anyOf": [{"type": "string"}, {"type": "array", "items": {"type": "string"}}], "description": "Optional BCC recipient(s). String or array."}}, "required": ["to", "subject", "body"], "additionalProperties": false}}, "mail.reply": {"description": "Sends a reply now to an exact inbox message_id plus expected_message_id, or a uniquely matching subject (and optional sender). Ambiguous or changed targets are refused. Requires Mail → Write permission (off by default).", "class": "send", "irreversible": true, "screen": false, "args": {"type": "object", "properties": {"subject": {"type": "string", "description": "Subject selection when no exact message locator is supplied; optional sender disambiguates matches."}, "message_id": {"type": "integer", "minimum": 1, "description": "Exact positive inbox message ID from the latest read."}, "expected_message_id": {"type": "string", "description": "Exact RFC message identifier paired with message_id."}, "expected_account": {"type": "string", "description": "expected_account from the same row, when it has one."}, "position": {"type": "integer", "minimum": 1, "description": "position from the same row: finds the message fast."}, "expected_account_id": {"type": "string", "description": "expected_account_id from the same row."}, "body": {"type": "string", "description": "Reply body (required)."}, "sender": {"type": "string", "description": "Optional sender filter — disambiguates when multiple messages share the subject."}, "reply_all": {"type": "boolean", "description": "Reply to all recipients. Defaults to false."}}, "required": ["body"], "additionalProperties": false}}, "mail.draft": {"summary": "Compose an email draft or draft a reply without sending it", "description": "Saves an unsent email in Apple Mail → Drafts, without sending or opening a window. Use for draft, don't send, just draft, save as draft or not yet requests. For a reply, use an exact inbox message_id plus expected_message_id, or a uniquely matching subject (and optional sender); ambiguous or changed targets are refused. For a new email, supply to, subject and body instead. Requires Mail Write permission. Confirms a new Drafts message by subject, recipients and content after saving; returns created, saved_in and the saved message's draft_id. Inspect drafts with mail.recent or mail.search using mailbox:\"drafts\"; never repeat an unconfirmed save before checking.", "class": "write", "irreversible": false, "screen": false, "args": {"type": "object", "properties": {"subject": {"type": "string", "description": "Subject selection when no exact message locator is supplied; optional sender disambiguates matches."}, "message_id": {"type": "integer", "minimum": 1, "description": "Exact positive inbox message ID from the latest read."}, "expected_message_id": {"type": "string", "description": "Exact RFC message identifier paired with message_id."}, "expected_account": {"type": "string", "description": "expected_account from the same row, when it has one."}, "position": {"type": "integer", "minimum": 1, "description": "position from the same row: finds the message fast."}, "expected_account_id": {"type": "string", "description": "expected_account_id from the same row."}, "body": {"type": "string", "description": "Reply body (required)."}, "sender": {"type": "string", "description": "Optional sender filter — disambiguates when multiple messages share the subject."}, "reply_all": {"type": "boolean", "description": "Reply to all recipients. Defaults to false."}, "to": {"anyOf": [{"type": "string"}, {"type": "array", "items": {"type": "string"}}], "description": "Recipient address(es) for a new draft. Omit for a reply draft."}, "cc": {"anyOf": [{"type": "string"}, {"type": "array", "items": {"type": "string"}}], "description": "Optional CC recipient(s) for a new draft."}, "bcc": {"anyOf": [{"type": "string"}, {"type": "array", "items": {"type": "string"}}], "description": "Optional BCC recipient(s) for a new draft."}}, "required": ["body"], "additionalProperties": false}}}}
*/
const BUNDLE = "com.apple.mail";
const CATEGORIES = ["primary", "transactions", "updates", "promotions"];
const NOT_CONFIGURED = "__NATIVEAGENT_MAIL_NOT_CONFIGURED__";
// One row identity travels from a listing into later reads and actions.
const IDENTITY = ["message_id", "expected_message_id", "expected_account", "expected_account_id", "position", "scope"];
// Recovery words for structured failure reasons; status, reason and effects stay the owner's.
const WORDS = {
    missing_query: "Nothing to search for: give a word or phrase in query.",
    missing_to: "Say who it goes to in to (an email address).",
    missing_compose_subject: "Give the new message's subject in subject.",
    missing_message_selector: "Say which message: its message_id and expected_message_id from mail.recent, or its subject.",
    missing_body: "Nothing to send or save: put the text in body.",
    invalid_message_locator: "message_id needs the expected_message_id from the same mail.recent row.",
    message_not_in_inbox: "That message is no longer in the inbox; list it again with mail.recent and use the new message_id.",
    message_changed_or_moved_refresh_inbox: "That message moved or changed; list the inbox again with mail.recent and use the new message_id.",
    message_changed_or_ambiguous_refresh_inbox:
        "That message moved, changed, or its subject matches several; list the inbox again and reply by message_id.",
    no_matching_message: "No inbox message matches; list the inbox with mail.recent and pass its message_id. An archived message is no longer "
        + "in the inbox, so delete or mark it before archiving.",
    mail_refused_send: "Mail refused to send it (no account can send, or it is offline); nothing went out.",
    no_archive_mailbox: "Mail has no Archive mailbox, so nothing moved; leave it or use mail.delete.",
    mail_delete_no_match: "No indexed message matches in Mail, including archived mail; nothing moved to Trash.",
    mail_delete_target_changed: "The indexed message moved or changed before deletion; nothing moved to Trash. Locate it again before trying again.",
    no_trash_mailbox: "Mail has no Trash mailbox for this message's account; nothing was deleted.",
    message_already_in_trash: "That message is already in Trash; it was left there and was not permanently deleted.",
    mail_lookup_timed_out: "Mail did not answer in time; nothing changed. Read it again, and if it repeats, look at Mail itself.",
    mail_index_unavailable: "Mail's message index could not be read (NativeAgent may need macOS Full Disk Access); nothing was listed or changed."
};

// MARK: envelopes

function failed(reason, message) {
    const envelope = {status: "failed", integration: "mail", reason};
    if (message !== undefined) envelope.message = message;
    // A refusal or a miss before the change; a send Mail declined may still sit in its Outbox.
    if (reason !== "mail_refused_send") envelope.effects = "none";
    return envelope;
}

function errorEnvelope(code, text, reason) {
    const envelope = {status: "failed", integration: "mail", error_code: code, error: text};
    if (reason !== undefined) envelope.reason = reason;
    return envelope;
}

function denied(remedy) {
    return {status: "denied", reason: "os_automation_denied", integration: "mail", app: "Mail", remedy: remedy === undefined ? null : remedy};
}

/// Mail's own failed answer inside an apps.call refusal, or null when the stem refused before Mail was asked.
function answered(error) {
    if (error.name !== "AppError" || error.reason === "cancelled") throw error;
    const receipt = error.receipt || {};
    const answer = receipt.result && typeof receipt.result === "object" && !Array.isArray(receipt.result) ? receipt.result : null;
    return answer && answer.bundle_id !== undefined ? answer : null;
}

/// A failed owner call becomes the verb's envelope; cancellation and non-owner faults end the run.
function appFailure(error) {
    const answer = answered(error), receipt = error.receipt || {};
    // A stem refusal (the Write switch, consent, Trust) keeps its own envelope.
    if (!answer) return receipt;
    if (["denied", "needs_consent"].includes(receipt.reason)) return denied(receipt.remedy !== undefined ? receipt.remedy : answer.remedy);
    if (receipt.effects !== undefined && receipt.effects !== "none") {
        return {status: "unknown", receipt_owner: "applescript", result_class: "unknown", effects: receipt.effects, reason: receipt.reason,
            integration: "mail", error_code: answer.code, error: answer.message};
    }
    return errorEnvelope(answer.code, answer.message, receipt.reason === "failed" ? undefined : receipt.reason);
}

/// An index or message file the stem could not read.
function fileFailure(error) {
    if (error.name !== "AppError" || error.reason === "cancelled") throw error;
    const envelope = failed("mail_index_unavailable");
    if (error.receipt && error.receipt.remedy !== undefined) envelope.remedy = error.receipt.remedy;
    return envelope;
}

class ReadFault extends Error {
    constructor(code, text, reason) { super(text); this.name = "ReadFault"; this.code = code; this.reason = reason; }
}

function faultEnvelope(error) {
    if (error.name === "ReadFault") return errorEnvelope(error.code, error.message, error.reason);
    if (error.name === "AppError" && error.reason !== "cancelled") {
        const envelope = {status: "failed", integration: "mail", reason: error.reason, error: error.message};
        if (error.receipt && error.receipt.remedy !== undefined) envelope.remedy = error.receipt.remedy;
        return envelope;
    }
    throw error;
}

/// Failed results carry the recovery words for their reason, in items and per-action receipts too.
function recovered(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return value;
    const fields = Object.assign({}, value);
    if (fields.status === "failed" && fields.integration === "mail" && typeof fields.reason === "string" && WORDS[fields.reason] !== undefined) {
        fields.message = WORDS[fields.reason];
    }
    if (Array.isArray(fields.items)) fields.items = fields.items.map(recovered);
    if (fields.actions && typeof fields.actions === "object" && !Array.isArray(fields.actions)) {
        fields.actions = Object.fromEntries(Object.entries(fields.actions).map(([key, action]) => [key, recovered(action)]));
    }
    return fields;
}

// MARK: input

const quoted = value => String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\r\n/g, "\\n").replace(/\n/g, "\\n").replace(/\r/g, "\\r");

function scalar(value) {
    if (typeof value === "string") return value;
    if (typeof value === "number") return String(value);
    if (typeof value === "boolean") return value ? "true" : "false";
    return null;
}

function strings(value) {
    if (typeof value === "string") return value ? [value] : [];
    if (Array.isArray(value)) return value.map(scalar).filter(text => text !== null && text !== "");
    return [];
}

const wholeNumber = text => /^[+-]?\d+$/.test(text) ? Number(text) : NaN;

/// A supplied numeric bound is an integer or refused; the default applies only when omitted.
function clamped(raw, fallback, min, max) {
    if (raw === undefined) return Math.max(min, Math.min(max, fallback));
    const value = typeof raw === "number" ? (Number.isInteger(raw) ? raw : NaN) : typeof raw === "string" ? wholeNumber(raw.trim()) : NaN;
    if (!Number.isSafeInteger(value)) {
        throw new ReadFault(-400, "A supplied numeric limit, offset or duration is not an integer. Correct the argument; defaults apply only when omitted.");
    }
    return Math.max(min, Math.min(max, value));
}

/// Exact inbox locator for reads; an RFC id is required for mutations.
function locator(input, allowMissingMessageID) {
    const idText = scalar(input.message_id);
    const id = idText === null ? NaN : wholeNumber(idText.trim());
    const messageID = scalar(input.expected_message_id);
    if (!Number.isSafeInteger(id) || id <= 0 || messageID === null || messageID.length >= 4096) return null;
    const bounded = value => { const text = scalar(value); return text === null || text === "" || text.length > 512 ? null : text; };
    const account = bounded(input.expected_account), accountID = bounded(input.expected_account_id);
    const positionText = scalar(input.position);
    const place = positionText === null ? NaN : wholeNumber(positionText.trim());
    const position = Number.isSafeInteger(place) && place > 0 && place < 10000000 ? place : null;
    if (messageID === "" && !(allowMissingMessageID && (account !== null || position !== null))) return null;
    return {id, messageID, account, accountID, position};
}

function readScope(input) {
    const value = input.scope !== undefined ? input.scope : input.mailbox !== undefined ? input.mailbox : "inbox";
    if (typeof value !== "string" || !["inbox", "sent", "drafts"].includes(value)) return null;
    if (input.scope !== undefined && input.mailbox !== undefined && input.scope !== input.mailbox) return null;
    return value;
}

// MARK: Mail's own answers

function mailScript(source, readOnly) {
    return host.apps.call({bundle_id: BUNDLE, script: source, launch: true, read_only: readOnly}).value;
}

/// Current account and mailbox records, one {name, id, mailbox} triple per account mailbox in scope.
function accountScript(scope) {
    const box = scope === "inbox" ? "inbox" : scope + " mailbox";
    return `
with timeout of 4 seconds
    set enabledAccounts to (accounts whose enabled is true)
    if (count of enabledAccounts) is 0 then return "${NOT_CONFIGURED}"
    set output to {}
    repeat with mb in ((mailboxes of ${box}) as list)
        set end of output to {(name of account of mb) as text, (id of account of mb) as text, (name of mb) as text}
    end repeat
    return output
end timeout
`;
}

function notConfigured() {
    return {status: "failed", integration: "mail", reason: "not_configured", fix: "Add and enable a Mail account in System Settings → Internet Accounts."};
}

function accountRecords(value) {
    if (!Array.isArray(value)) {
        throw new ReadFault(-1, "Mail returned an invalid account/mailbox record. Repair the mailbox transport before reading it again; no coverage was "
            + "inferred.", "malformed_mail_account_header");
    }
    return value.map((record, index) => {
        if (!Array.isArray(record) || record.length !== 3 || !record.every(field => typeof field === "string")) {
            throw new ReadFault(-1, "Mail returned an invalid account/mailbox record at line " + (index + 1) + ". Repair the mailbox transport before "
                + "reading it again; no coverage was inferred.", "malformed_mail_account_header");
        }
        return {name: record[0], id: record[1], inbox: record[2]};
    });
}

// MARK: Mail's index

// Mail keeps one store per version directory; supported macOS releases write V10 or later and the newest present is current.
function store() {
    let found = null;
    for (let version = 10; version < 30; version++) {
        const path = "~/Library/Mail/V" + version + "/MailData/Envelope Index";
        try {
            const reply = host.files.query({path, sql: "SELECT value FROM properties WHERE key = 'UUID'", limit: 1});
            found = {root: "~/Library/Mail/V" + version, path, uuid: reply.rows.length ? String(reply.rows[0][0]) : null};
        } catch (error) {
            if (error.name !== "AppError" || error.reason !== "not_found") throw error;
            if (found) break;
        }
    }
    if (!found) {
        const error = new Error("Mail's Envelope Index was not found under ~/Library/Mail.");
        error.name = "AppError"; error.reason = "not_found"; error.receipt = {};
        throw error;
    }
    return found;
}

function query(index, sql, params, limit, seconds) {
    const request = {path: index.path, sql, params, limit};
    if (seconds !== undefined) request.seconds = seconds;
    const reply = host.files.query(request);
    if (reply.truncated) {
        const error = new Error("Mail's index returned more rows than one bounded read holds.");
        error.name = "AppError"; error.reason = "sqlite_error"; error.receipt = {};
        throw error;
    }
    return reply.rows;
}

const text = value => value === null || value === undefined ? "" : String(value);

/// Every account type's mailbox URL is `scheme://<account id>/<mailbox path>` (imap, ews, pop, local).
function mailboxURL(value) {
    const match = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]*)([^?#]*)/.exec(value);
    if (!match) return null;
    try {
        return {scheme: match[1].toLowerCase(), host: decodeURIComponent(match[2]), path: decodeURIComponent(match[3])};
    } catch (error) { return null; }
}

const same = (a, b) => a.toLowerCase() === b.toLowerCase();

/// The account's mailboxes as Mail's index numbers them.
function indexMailboxes(index, accounts) {
    const ids = [...new Set(accounts.filter(account => account.id !== "").map(account => account.id.toLowerCase()))];
    if (!ids.length) return [];
    const rows = query(index, "SELECT ROWID, url FROM mailboxes WHERE " + ids.map((_, n) => "instr(lower(url), ?" + (n + 1) + ") > 0").join(" OR "),
        ids, 1000);
    return rows.map(row => ({id: row[0], url: mailboxURL(text(row[1]))})).filter(row => row.url)
        .map(row => ({id: row.id, account: row.url.host, path: row.url.path.replace(/^\//, "")}));
}

/// Mail's `Name <address>` format quotes special characters and leaves bare-address names bare.
function senderText(comment, address) {
    if (!comment) return address;
    const bareAddress = comment.includes("@") && !/\s/.test(comment);
    const name = bareAddress || !/[()<>[\]:;@\\,."]/.test(comment) ? comment : '"' + comment.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
    return address ? name + " <" + address + ">" : name;
}

const pad = (value, width) => String(value).padStart(width || 2, "0");

/// Mail displays local time: ISO-8601 with the local offset.
function localISO(seconds) {
    const date = new Date(seconds * 1000), offset = -date.getTimezoneOffset();
    const zone = offset === 0 ? "Z" : (offset > 0 ? "+" : "-") + pad(Math.floor(Math.abs(offset) / 60)) + ":" + pad(Math.abs(offset) % 60);
    return pad(date.getFullYear(), 4) + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate()) + "T" + pad(date.getHours()) + ":"
        + pad(date.getMinutes()) + ":" + pad(date.getSeconds()) + zone;
}

const zulu = seconds => new Date(seconds * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");

/// Case, accents and width aside, as the index's folded_contains matches.
const folded = value => value.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();

/// since and category filters; bind appends a parameter and returns its placeholder.
function indexFilters(input, bind) {
    let filter = "";
    if (input.since !== undefined) {
        if (typeof input.since !== "string") return {error: failed("invalid_mail_since")};
        const value = input.since;
        let date = null;
        if (value === "this week") {
            const now = new Date(), first = new Intl.Locale(Intl.DateTimeFormat().resolvedOptions().locale).getWeekInfo().firstDay % 7;
            date = new Date(now.getFullYear(), now.getMonth(), now.getDate() - ((now.getDay() - first + 7) % 7));
        } else if (value.length === 10) {
            const parts = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
            if (parts) {
                const local = new Date(Number(parts[1]), Number(parts[2]) - 1, Number(parts[3]));
                const shown = pad(local.getFullYear(), 4) + "-" + pad(local.getMonth() + 1) + "-" + pad(local.getDate());
                if (shown === value) date = local;
            }
        } else if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:?\d{2})$/.test(value) && !Number.isNaN(Date.parse(value))) {
            date = new Date(Date.parse(value));
        }
        if (date === null) {
            return {error: {status: "failed", integration: "mail",
                message: "since must be this week (start of the local calendar week), local YYYY-MM-DD, or ISO-8601 with a time zone."}};
        }
        filter += " AND m.date_received >= " + bind(Math.trunc(date.getTime() / 1000));
    }
    if (input.category !== undefined) {
        if (typeof input.category !== "string") return {error: failed("invalid_mail_category")};
        const names = input.category.split(",").map(name => name.trim());
        const indices = names.map(name => CATEGORIES.indexOf(name)).filter(index => index >= 0);
        if (!indices.length || indices.length !== names.length) return {error: failed("invalid_mail_category")};
        filter += " AND coalesce(g.model_category, 0) IN (" + indices.map(bind).join(",") + ")";
    }
    return {sql: filter};
}

// MARK: mailbox pages

/// Index queries cover whole-mailbox subjects and senders; missing account coverage stays explicit.
function indexPage(accounts, input, terms) {
    const scope = readScope(input);
    if (!scope) return failed("unsupported_mailbox");
    const limit = clamped(input.limit, 10, 1, 50);
    if (![undefined, true, false].includes(input.unread) || ![undefined, "oldest", "newest"].includes(input.sort)) return failed("invalid_mail_filter");
    const oldest = input.sort === "oldest";
    const cursor = input.offset !== null && typeof input.offset === "object" && !Array.isArray(input.offset) ? input.offset : null;
    const listOffset = cursor ? 0 : clamped(input.offset, 0, 0, 10000);
    if (cursor && !Object.values(cursor).every(value => Number.isSafeInteger(value) && value >= 0)) return failed("invalid_mail_offset");
    const offsets = Object.assign({}, cursor || {});
    if (!accounts.length) {
        return failed("mailbox_coverage_unavailable",
            "Mail returned no account mailboxes in this scope. Mailbox coverage could not be established; no empty message list was inferred.");
    }
    let index;
    try { index = store(); } catch (error) { return fileFailure(error); }
    // A Gmail inbox is a label over All Mail; other inboxes hold their messages.
    const inbox = alias => alias + ".deleted = 0 AND (" + alias + ".mailbox = ?1 OR " + alias
        + ".ROWID IN (SELECT message_id FROM labels WHERE mailbox_id = ?1))";
    const joins = "LEFT JOIN subjects s ON s.ROWID = m.subject LEFT JOIN addresses a ON a.ROWID = m.sender "
        + "LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id";
    // Each row's place in the mailbox as Mail numbers it (newest first), so a filtered row still carries its true position.
    const positions = "(SELECT m.ROWID AS id, row_number() OVER (ORDER BY m.date_received DESC, m.ROWID DESC) AS position FROM messages m WHERE "
        + inbox("m") + ") p";
    // Inbox lists default to Primary and Transactions unless all_categories; searches cover every category.
    const primaryOnly = scope === "inbox" && terms === null && ["unread", "sort", "from", "since", "category", "attachment"]
        .every(key => input[key] === undefined) && input.all_categories !== true;
    let filter = "1";
    const bindings = [];
    const bind = value => { bindings.push(value); return "?" + (bindings.length + 3); };
    if (primaryOnly) filter += " AND coalesce(g.model_category, 0) IN (0, 1)";
    if (typeof input.unread === "boolean") filter += " AND m.read = " + (input.unread ? 0 : 1);
    // The displayed subject prefix counts in matching; case and accents do not distinguish a match.
    const patterns = (terms || []).map(term => bind(folded(term)));
    if (patterns.length) {
        filter += " AND (" + patterns.map(parameter => "(folded_contains(coalesce(m.subject_prefix, '') || coalesce(s.subject, ''), " + parameter
            + ") OR folded_contains(a.address, " + parameter + ") OR folded_contains(a.comment, " + parameter + "))").join(" OR ") + ")";
    }
    if (input.from !== undefined) {
        if (typeof input.from !== "string" || !input.from.trim()) return failed("invalid_mail_sender");
        const parameter = bind(folded(input.from));
        filter += " AND (folded_contains(a.address, " + parameter + ") OR folded_contains(a.comment, " + parameter + "))";
    }
    const dated = indexFilters(input, bind);
    if (dated.error) return dated.error;
    filter += dated.sql;
    if (input.attachment !== undefined) {
        let nameFilter = "";
        if (typeof input.attachment === "string" && input.attachment.trim()) {
            nameFilter = " AND folded_contains(x.name, " + bind(folded(input.attachment)) + ")";
        }
        else if (input.attachment !== true) return failed("invalid_mail_attachment");
        filter += " AND EXISTS (SELECT 1 FROM attachments x WHERE x.message = m.ROWID" + nameFilter + ")";
    }
    let mailboxes;
    try { mailboxes = indexMailboxes(index, accounts); } catch (error) { return fileFailure(error); }
    const boxes = [], notListed = [];
    const unreadByCategory = Object.fromEntries(CATEGORIES.concat(["unclassified"]).map(name => [name, 0]));
    const ordered = accounts.slice().sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
    for (const account of ordered) {
        const offset = Number.isSafeInteger(offsets[account.id]) ? offsets[account.id] : listOffset;
        const unnamed = account.id === "" || account.inbox === "";
        const mailbox = unnamed ? undefined : mailboxes.find(box => same(box.account, account.id) && same(box.path, account.inbox));
        if (mailbox === undefined) {
            notListed.push(unnamed
                ? {account: account.name, reason: "account_details_unreadable",
                    message: "Mail did not give this mailbox's account id or name, so its mail is not in this list."}
                : {account: account.name, reason: "mailbox_not_in_mail_index",
                    message: "This account's requested mailbox was not found in Mail's index, so its mail is not in this list."});
            continue;
        }
        let total = 0, unread = 0, count = 0;
        const rows = [];
        try {
            for (const row of query(index, "SELECT coalesce(g.model_category, 0), count(*), coalesce(sum(m.read = 0), 0) FROM messages m "
                + "LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id WHERE " + inbox("m") + " GROUP BY coalesce(g.model_category, 0)",
                [mailbox.id], 1000)) {
                const category = Number(row[0]), categoryUnread = Number(row[2]);
                total += Number(row[1]); unread += categoryUnread;
                unreadByCategory[category >= 0 && category < CATEGORIES.length ? CATEGORIES[category] : "unclassified"] += categoryUnread;
            }
            if (filter !== "1") {
                count = Number(query(index, "SELECT count(*) FROM messages m " + joins + " WHERE " + inbox("m") + " AND " + filter,
                    [mailbox.id, 0, 0].concat(bindings), 1)[0][0]);
            }
            for (const row of query(index, "SELECT m.ROWID, g.message_id_header, m.subject_prefix, s.subject, a.comment, a.address, m.date_received, "
                + "m.read, g.model_category, p.position FROM " + positions + " JOIN messages m ON m.ROWID = p.id " + joins + " WHERE " + filter
                + " ORDER BY p.position " + (oldest ? "DESC" : "ASC") + " LIMIT ?2 OFFSET ?3", [mailbox.id, limit, offset].concat(bindings), limit)) {
                let messageID = text(row[1]);
                if (messageID.startsWith("<") && messageID.endsWith(">")) messageID = messageID.slice(1, -1);
                const out = {message_id: row[0], expected_message_id: messageID, subject: text(row[2]) + text(row[3]),
                    sender: senderText(text(row[4]), text(row[5])), date: row[6] === null ? "" : localISO(Math.trunc(row[6])),
                    unread: !row[7], position: row[9], body_status: "not_loaded", scope};
                if (account.name) out.expected_account = account.name;
                out.expected_account_id = account.id;
                const category = row[8] === null ? 0 : Number(row[8]);
                if (category >= 0 && category < CATEGORIES.length) out.category = CATEGORIES[category];
                rows.push(out);
            }
        } catch (error) { return fileFailure(error); }
        if (filter === "1") count = total;
        boxes.push({account: account.id, total, unread, count, offset, consumed: 0, rows});
    }
    // Merge account heads; fetched rows outside this page remain unconsumed.
    const messages = [];
    while (messages.length < limit) {
        let next = -1;
        boxes.forEach((box, at) => {
            if (box.consumed >= box.rows.length) return;
            if (next < 0) { next = at; return; }
            const candidate = box.rows[box.consumed].date, selected = boxes[next].rows[boxes[next].consumed].date;
            if (oldest ? candidate < selected : candidate > selected) next = at;
        });
        if (next < 0) break;
        messages.push(boxes[next].rows[boxes[next].consumed]);
        boxes[next].consumed += 1;
    }
    if (input.attachment !== undefined && messages.length) {
        const ids = messages.map(row => row.message_id);
        const names = {};
        try {
            for (const row of query(index, "SELECT message, name FROM (SELECT message, name, row_number() OVER (PARTITION BY message ORDER BY "
                + "attachment_id, name) AS position FROM attachments WHERE message IN (" + ids.map((_, n) => "?" + (n + 1)).join(",")
                + ")) WHERE position <= 5 ORDER BY message, position", ids, 1000)) {
                (names[row[0]] = names[row[0]] || []).push(text(row[1]));
            }
        } catch (error) { return fileFailure(error); }
        messages.forEach(row => { row.attachment_names = names[row.message_id] || []; });
    }
    // A checked empty mailbox is coverage; no matched mailbox is not.
    const result = {status: !boxes.length ? "failed" : !notListed.length ? "completed" : "partial",
        account_coverage: notListed.length ? "partial" : "complete", count: messages.length, messages, scope, detail: false,
        sort: oldest ? "oldest" : "newest",
        content_note: "Mailbox metadata only; open a message to load its body. Pages read the current mailbox, which may change between reads.",
        mailbox_total: boxes.reduce((sum, box) => sum + box.total, 0)};
    const hasMore = boxes.some(box => box.count > box.offset + box.consumed);
    result.has_more = hasMore;
    if (filter !== "1") result.matching_total = boxes.reduce((sum, box) => sum + box.count, 0);
    if (terms !== null) {
        result.note = "Matched the supplied filters across the whole " + scope + " mailbox; query searches sender and subject, from searches sender "
            + "only. Bodies were not searched.";
    } else if (primaryOnly) {
        result.note = "Primary and Transactions only (Mail's categories); all_categories: true lists Updates and Promotions too.";
    }
    if (hasMore) {
        boxes.forEach(box => { offsets[box.account] = box.offset + box.consumed; });
        result.next_offset = offsets;
    }
    if (scope === "inbox") {
        result.inbox_total = result.mailbox_total;
        result.inbox_unread = boxes.reduce((sum, box) => sum + box.unread, 0);
        result.inbox_unread_by_category = unreadByCategory;
        result.category_note = "Exact unread counts across all inbox categories, independent of this page's filters. Mail's Primary category is not a "
            + "guarantee that the sender is a person; unclassified covers unknown category codes.";
    }
    if (notListed.length) {
        if (!boxes.length) result.reason = "mailbox_coverage_unavailable";
        // The totals would count different accounts, so a partial page carries none.
        for (const key of ["mailbox_total", "inbox_total", "inbox_unread", "matching_total", "inbox_unread_by_category", "category_note"]) {
            delete result[key];
        }
        result.accounts_not_listed = notListed;
        result.message = "Not listed: " + notListed.map(row => row.account || "an account").join(", ") + "; see accounts_not_listed."
            + (boxes.length ? " The other accounts are listed." : "");
    }
    return result;
}

/// Bounded mailbox reads with opaque owner ids; one exact locator reads that message's body.
function workspaceRead(given, terms) {
    const input = Object.assign({}, given);
    if (input.message_id !== undefined && input.expected_message_id === undefined) input.expected_message_id = "";
    const scope = readScope(input);
    if (!scope) {
        return {status: "failed", integration: "mail", reason: "unsupported_mailbox",
            message: "Accepted scopes: inbox, sent, drafts. scope and mailbox must agree when both are supplied."};
    }
    if (input.message_id !== undefined && !locator(input, true)) {
        return {status: "failed", integration: "mail", reason: "invalid_message_locator",
            message: "Call mail.recent without message_id, then copy scope, message_id, expected_message_id, expected_account, expected_account_id "
                + "and position from the same row to read it."};
    }
    try {
        if (input.message_id !== undefined) {
            return {status: "completed", count: 1, messages: [fileRead(input, false)], scope, detail: true};
        }
        let records;
        try { records = mailScript(accountScript(scope), true); } catch (error) { return readFailure(error); }
        if (records === NOT_CONFIGURED) return notConfigured();
        return indexPage(accountRecords(records), input, terms);
    } catch (error) { return faultEnvelope(error); }
}

/// A read changes nothing, so the outcome-unknown caution for sends does not apply. One attempt per request: an immediate rerun would wait on the same
/// dialog or busy Mail.
function readFailure(error) {
    const envelope = appFailure(error);
    if (["app_timeout", "blocked_by_dialog"].includes(error.reason) && envelope.integration === "mail") {
        return {status: "failed", integration: "mail", error_code: envelope.error_code, reason: error.reason,
            error: "Mail did not answer this read in time (it may be showing a dialog or busy syncing). Nothing was changed. When Mail is ready, call "
                + "mail.recent again; for a message body, use the scope, identifiers and position from a fresh row.", detail: envelope.error};
    }
    return envelope;
}

function recent(input) { return workspaceRead(input, null); }

function search(input) {
    const terms = strings(input.query).map(term => term.trim());
    if ((input.query !== undefined && !terms.length) || !terms.every(term => term !== "")) return failed("missing_query");
    return workspaceRead(input, terms);
}

// MARK: senders

function senders(input) {
    const scope = input.scope !== undefined ? input.scope : "inbox";
    if ((scope !== "inbox" && scope !== "all") || ![undefined, true, false].includes(input.unread_only)) return failed("invalid_mail_filter");
    let accounts = [];
    try {
        if (scope === "inbox") {
            let records;
            try { records = mailScript(accountScript("inbox"), true); } catch (error) { return appFailure(error); }
            if (records === NOT_CONFIGURED) return notConfigured();
            accounts = accountRecords(records);
            if (!accounts.length) {
                return failed("inbox_coverage_unavailable",
                    "Mail returned no inbox account mailboxes. Sender coverage could not be established; no empty sender list was inferred.");
            }
        }
        let index;
        try { index = store(); } catch (error) { return fileFailure(error); }
        const bindings = [];
        const bind = value => { bindings.push(value); return "?" + bindings.length; };
        const dated = indexFilters(input, bind);
        if (dated.error) return dated.error;
        let filter = "m.deleted = 0" + dated.sql;
        if (input.unread_only === true) filter += " AND m.read = 0";
        if (scope === "inbox") {
            let mailboxes;
            try { mailboxes = indexMailboxes(index, accounts); } catch (error) { return fileFailure(error); }
            const matched = new Set(), ids = [];
            for (const box of mailboxes) {
                const at = accounts.findIndex(account => account.id !== "" && account.inbox !== "" && same(box.account, account.id)
                    && same(box.path, account.inbox));
                if (at >= 0) { matched.add(at); ids.push(box.id); }
            }
            if (matched.size !== accounts.length) return failed("inbox_coverage_unavailable");
            const selected = ids.map(bind).join(",");
            filter += " AND (m.mailbox IN (" + selected + ") OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (" + selected + ")))";
        }
        const limit = clamped(input.limit, 15, 1, 50);
        // Expensive aggregation stops at its deadline rather than returning guessed or partial totals.
        let rows;
        try {
            rows = query(index, "SELECT lower(trim(coalesce(a.address, ''))), a.comment, count(*), sum(m.read = 0), max(m.date_received) "
                + "FROM messages m LEFT JOIN addresses a ON a.ROWID = m.sender LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id "
                + "WHERE " + filter + " GROUP BY lower(trim(coalesce(a.address, ''))) "
                + "ORDER BY count(*) DESC, max(m.date_received) DESC, lower(trim(coalesce(a.address, ''))) LIMIT " + limit, bindings, limit, 2);
        } catch (error) {
            if (error.name === "AppError" && error.reason === "deadline") return failed("sender_counts_unavailable");
            return fileFailure(error);
        }
        const list = rows.map(row => ({address: text(row[0]), display_name: text(row[1]), message_count: Number(row[2]), unread_count: Number(row[3] || 0),
            newest_date: row[4] === null ? null : zulu(Math.trunc(row[4]))}));
        return {status: "completed", scope, count: list.length, unread_only: input.unread_only === true, senders: list};
    } catch (error) { return faultEnvelope(error); }
}

// MARK: message bodies

const graphemes = value => Array.from(new Intl.Segmenter(undefined, {granularity: "grapheme"}).segment(value), piece => piece.segment);
const identity = value => value.replace(/^[\s<>]+|[\s<>]+$/g, "");

/// The index locates the file; the index and the RFC header must both match the paired identity.
function fileRead(input, batch) {
    const exact = locator(input, true);
    if (!exact || exact.messageID === "" || exact.accountID === null) {
        // A supplied id the locator could not take is refused, never read as absent.
        if (input.expected_account_id !== undefined && input.expected_account_id !== null) {
            throw new ReadFault(10, "expected_account_id is not a Mail account id; copy it from a fresh mail.recent row.");
        }
        throw new ReadFault(6, "The local read needs expected_message_id and expected_account_id from a mail.recent row.");
    }
    const mismatch = () => new ReadFault(7, "Mismatch: message_id " + exact.id + " is a different email than expected_message_id names. Use the "
        + "identifiers from one fresh mail.recent row.");
    const unavailable = () => new ReadFault(1, "Mail's index is unavailable. Check Mail's index and Full Disk Access.");
    let index, rows;
    try {
        index = store();
        rows = query(index, "SELECT b.url, g.message_id_header, m.subject_prefix, s.subject, a.comment, a.address, m.date_received, m.read "
            + "FROM messages m JOIN mailboxes b ON b.ROWID = m.mailbox LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id "
            + "LEFT JOIN subjects s ON s.ROWID = m.subject LEFT JOIN addresses a ON a.ROWID = m.sender WHERE m.ROWID = ?1 AND m.deleted = 0",
            [exact.id], 1);
    } catch (error) {
        if (error.name !== "AppError" || error.reason === "cancelled") throw error;
        throw unavailable();
    }
    if (!rows.length) {
        throw new ReadFault(8, "Mail's index has no message " + exact.id + "; it was deleted or moved. Call mail.recent again and use one fresh row.");
    }
    const row = rows[0], mailbox = mailboxURL(text(row[0]));
    if (!mailbox || !index.uuid) throw unavailable();
    // The index names an account by its id, the host of the mailbox URL, never by name.
    if (!same(mailbox.host, exact.accountID)) {
        throw new ReadFault(10, "Mismatch: Mail's index files message_id " + exact.id + " under account id " + (mailbox.host || "(none)")
            + ", not expected_account_id " + exact.accountID + ". Use the identifiers from one fresh mail.recent row.");
    }
    if (identity(text(row[1])) !== identity(exact.messageID)) throw mismatch();
    const box = mailbox.scheme === "file" ? mailbox.path
        : index.root + "/" + mailbox.host + "/" + mailbox.path.split("/").filter(Boolean).map(part => part + ".mbox").join("/");
    const shard = String(Math.floor(exact.id / 1000)).split("").reverse().join("/");
    // Each mailbox keeps its messages in the store named by the index's own UUID.
    const directory = box + "/" + index.uuid + "/Data/" + shard + "/Messages/";
    let otherEmail = false;
    for (const suffix of ["emlx", "partial.emlx"]) {
        let message;
        try { message = host.files.mime({path: directory + exact.id + "." + suffix, max_text_bytes: 16 * 1024 * 1024}); }
        catch (error) {
            if (error.name === "AppError" && error.reason === "not_found") continue;
            throw error;
        }
        if (identity(message.headers["message-id"] || "") !== identity(exact.messageID)) { otherEmail = true; continue; }
        const found = {message_id: exact.id, expected_message_id: exact.messageID, subject: text(row[2]) + text(row[3]),
            sender: senderText(text(row[4]), text(row[5])), date: row[6] === null ? "" : localISO(Math.trunc(row[6])), unread: !row[7],
            scope: readScope(input) || "inbox"};
        if (exact.account !== null) found.expected_account = exact.account;
        found.expected_account_id = exact.accountID;
        if (exact.position !== null) found.position = exact.position;
        found.verification = "Account verified by the local read against Mail's index; scope is the one passed in.";
        return Object.assign(found, bodyFields(message, input, batch));
    }
    if (otherEmail) throw mismatch();
    throw new ReadFault(9, "No local copy of this message is on disk at its indexed mailbox. Download the message in Mail, then refresh its locator "
        + "before reading its body or attachments.");
}

function bodyFields(message, input, batch) {
    const textParts = type => message.parts.filter(part => part.text !== undefined && part.filename === undefined && part.type === type)
        .map(part => part.text);
    const plains = textParts("text/plain"), htmls = textParts("text/html");
    const attachments = message.parts.filter(part => part.filename !== undefined);
    const plain = plains.length ? plains.join("\n") : null, html = htmls.length ? htmls.join("\n") : null;
    const body = plain !== null && plain.trim() !== "" ? plain : html !== null ? htmlText(html) : attachments.length ? "" : null;
    if (body === null) throw new ReadFault(2, "The saved message could not be parsed: its local copy has incomplete or unsupported MIME content.");
    const offset = clamped(input.body_offset, 0, 0, 2000000);
    const pieces = graphemes(body), end = Math.min(pieces.length, offset + (batch ? 4000 : 16000));
    const fields = {body: offset < end ? pieces.slice(offset, end).join("") : "", body_offset: offset, body_end: end, body_total: pieces.length,
        truncated: end < pieces.length, attachments: attachments.map((part, at) => ({filename: part.filename, content_type: part.type,
            size: part.bytes === undefined ? null : part.bytes, index: at + 1}))};
    if (message.partial) fields.body_complete = false;
    const tables = htmlTables(html);
    if (tables.length) fields.body_tables = tables;
    return fields;
}

function htmlText(html) {
    let out = html.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, "")
        .replace(/<br\b[^>]*>|<\/(?:p|div|tr|li|h[1-6])\s*>/gi, "\n")
        .replace(/<[^>]*>/g, " ");
    for (const [entity, value] of [["&nbsp;", " "], ["&lt;", "<"], ["&gt;", ">"], ["&quot;", "\""], ["&#39;", "'"], ["&apos;", "'"], ["&amp;", "&"]]) {
        out = out.replace(new RegExp(entity, "gi"), () => value);
    }
    for (let match = /&#(x?)([0-9a-fA-F]{1,6});/.exec(out); match; match = /&#(x?)([0-9a-fA-F]{1,6});/.exec(out)) {
        const code = match[0].slice(2, -1);
        const value = /^[xX]/.test(code) ? (/^[0-9a-fA-F]+$/.test(code.slice(1)) ? parseInt(code.slice(1), 16) : NaN)
            : /^\d+$/.test(code) ? Number(code) : NaN;
        const scalarOK = value >= 0 && value <= 0x10FFFF && !(value >= 0xD800 && value <= 0xDFFF);
        out = out.slice(0, match.index) + (scalarOK ? String.fromCodePoint(value) : " ") + out.slice(match.index + match[0].length);
    }
    // Marketing preheaders pad with invisible characters; they are not text.
    out = out.replace(/[­͏​-‏⁠﻿]/g, "");
    return out.split("\n").map(line => line.split(/\s+/).filter(Boolean).join(" ")).join("\n").trim();
}

function matches(pattern, value) {
    return Array.from(value.matchAll(new RegExp(pattern, "gi")), match => match.map(group => group === undefined ? "" : group));
}

/// One block (a <p> or <div> around the text) is still one line; a break or a second block is not.
function cellText(inner) {
    if (/<(br|li|tr|h[1-6])\b/i.test(inner) || inner.split("<").filter(piece => /^(p|div)\b/i.test(piece)).length > 1) return null;
    const line = htmlText(inner).split(/\s+/).filter(Boolean).join(" ");
    return line.length > 120 ? null : line;
}

/// Only bounded, uniform, single-line tables accompany the body; irregular tables remain in the body text.
function htmlTables(html) {
    if (html === null) return [];
    const tables = [];
    let cells = 0;
    for (const table of matches("<table\\b[^>]*>((?:(?!<table\\b)[\\s\\S])*?)</table>", html)) {
        const rows = [], heads = [];
        let simple = true;
        for (const tr of matches("<tr\\b[^>]*>([\\s\\S]*?)</tr>", table[1])) {
            const found = matches("<t(h|d)\\b[^>]*>([\\s\\S]*?)</t[hd]\\s*>", tr[1]);
            const texts = found.map(cell => cellText(cell[2]));
            if (texts.includes(null)) { simple = false; break; }
            if (texts.every(cell => cell === "")) continue;
            rows.push(texts); heads.push(found.every(cell => cell[1].toLowerCase() === "h"));
        }
        const width = rows.length ? rows[0].length : 0;
        if (!simple || rows.length < 2 || rows.length > 30 || width < 2 || width > 10 || !rows.every(row => row.length === width)
            || cells + rows.length * width > 200) continue;
        cells += rows.length * width;
        tables.push({header: heads[0], rows});
    }
    return tables;
}

// MARK: Apple Event recipes

/// One exact id lookup in the checked mailbox; a supplied position is observation metadata.
const exactLookup = (exact, list) => "set " + list + " to (messages of targetBox whose id is " + exact.id + ")";

function identityCheck(exact, list, fail) {
    const lines = ["if (count of " + list + ") is not 1 then return \"" + fail + "\"",
        "if (id of item 1 of " + list + ") is not " + exact.id + " then return \"" + fail + "\""];
    if (exact.messageID !== "") {
        lines.push("if ((message id of item 1 of " + list + ") as text) is not \"" + quoted(exact.messageID) + "\" then return \"" + fail + "\"");
    }
    if (exact.account !== null) {
        lines.push("if ((name of account of mailbox of item 1 of " + list + ") as text) is not \"" + quoted(exact.account) + "\" then return \"" + fail
            + "\"");
    }
    return lines.join("\n");
}

/// A requested account must resolve exactly; it never expands to the combined mailbox.
function accountScope(account) {
    if (account === null) return "set targetBox to inbox";
    return `set targetBox to missing value
set accountMailboxes to mailboxes of inbox
repeat with mb in accountMailboxes
    set mailboxAccountName to (name of account of mb) as text
    if mailboxAccountName is "${quoted(account)}" then
        if targetBox is not missing value then error "Several Mail mailboxes match the requested account; refresh the message locator."
        set targetBox to contents of mb
    end if
end repeat
if targetBox is missing value then error "The requested Mail account mailbox is unavailable; refresh the message locator."`;
}

/// Inputs enter the lookup predicate escaped for AppleScript.
function matchWhere(subject, sender) {
    if (sender) return "(subject is \"" + quoted(subject) + "\") and (sender contains \"" + quoted(sender) + "\")";
    return "subject is \"" + quoted(subject) + "\"";
}

function mutationResult(raw, action) {
    const value = String(raw).trim();
    if (value === "0") return failed("no_matching_message");
    if (value === "__LOOKUP_TIMED_OUT__") return failed("mail_lookup_timed_out");
    if (value === "-2") return failed(action === "deleted" ? "mail_delete_target_changed" : "message_changed_or_moved_refresh_inbox");
    if (value === "__NO_ARCHIVE__") return failed("no_archive_mailbox");
    if (value === "__NO_TRASH__") return failed("no_trash_mailbox");
    if (value === "__ALREADY_TRASH__") return failed("message_already_in_trash");
    const bar = value.indexOf("|");
    const head = bar < 0 ? value : value.slice(0, bar), tail = bar < 0 ? null : value.slice(bar + 1);
    if (head === "-3" && tail !== null) {
        return {status: "failed", integration: "mail", reason: "several_messages_match",
            message: tail + " inbox messages have that subject, so nothing changed. Pass the message_id and expected_message_id from mail.recent, "
                + "or add sender."};
    }
    const count = /^\d+$/.test(head) ? Number(head) : 0;
    if (count <= 0) return {status: "outcome_unknown", action, message: "I couldn't confirm what changed. Check Mail before trying again."};
    return {status: "completed", action, matched_count: count, subject: tail === null ? "" : tail};
}

/// Archive and delete require an unambiguous match to avoid changing another message. The lookup is bounded before any mutation.
function manage(input, action, single, body) {
    const exact = locator(input, false);
    if ((input.message_id !== undefined || input.expected_message_id !== undefined) && !exact) return failed("invalid_message_locator");
    const subject = scalar(input.subject) || "";
    if (!exact && !subject) return failed("missing_message_selector");
    const lookup = exact ? exactLookup(exact, "hits") : "set hits to (messages of targetBox whose " + matchWhere(subject, scalar(input.sender)) + ")";
    const check = exact ? identityCheck(exact, "hits", "-2") : single ? "if n > 1 then return \"-3|\" & (n as text)" : "";
    const source = `
try
    with timeout of 8 seconds
        ${accountScope(exact ? exact.account : null)}
        ${lookup}
        set n to count of hits
        if n is 0 then return "0"
        ${check}
        set firstSubject to (subject of item 1 of hits) as text
    end timeout
on error errText number errNum
    if errNum is -1712 then return "__LOOKUP_TIMED_OUT__"
    error errText number errNum
end try
${body}
return (n as text) & "|" & firstSubject
`;
    try { return mutationResult(mailScript(source, false), action); } catch (error) { return appFailure(error); }
}

function markRead(input) {
    if (input.messages !== undefined) return batch(input, true);
    return manage(input, "marked_read", false, `repeat with msg in hits
    set read status of msg to true
end repeat`);
}

function archive(input) {
    return manage(input, "archived", true, `set archiveBox to missing value
set msg to item 1 of hits
try
    set archiveBox to mailbox "Archive" of account of mailbox of msg
end try
if archiveBox is missing value then return "__NO_ARCHIVE__"
move msg to archiveBox`);
}

/// Move to Trash explicitly; delete can be permanent under account settings. Lookup failure stops the mutation.
function remove(input) {
    return manage(input, "deleted", true, `set msg to item 1 of hits
set trashBox to missing value
try
    with timeout of 6 seconds
        set messageAccountID to id of account of mailbox of msg
        set trashMailboxes to mailboxes of trash mailbox
        repeat with mb in trashMailboxes
            set trashAccountID to id of account of mb
            if trashAccountID is messageAccountID then
                set trashBox to contents of mb
                exit repeat
            end if
        end repeat
        if trashBox is missing value then return "__NO_TRASH__"
        if (mailbox of msg) is trashBox then return "__ALREADY_TRASH__"
    end timeout
on error errText number errNum
    if errNum is -1712 then return "__LOOKUP_TIMED_OUT__"
    error errText number errNum
end try
try
    with timeout of 8 seconds
        move msg to trashBox
    end timeout
on error errText number errNum
    if errNum is -1712 then return "__OUTCOME_UNKNOWN__"
    error errText number errNum
end try`);
}

// MARK: batches

/// One bounded job over selected identities. Completed receipts are kept when cancellation or an uncertain script stops the remaining work; nothing
/// is replayed.
function batch(input, effects) {
    const markReadOnly = effects && input.messages !== undefined;
    const key = markReadOnly ? "messages" : "items";
    const keys = Object.keys(input).filter(name => name !== "__session_id");
    const items = input[key];
    if (keys.length !== 1 || keys[0] !== key || !Array.isArray(items) || items.length < 1 || items.length > (markReadOnly ? 50 : 10)) {
        return failed("invalid_mail_batch");
    }
    const deadline = Date.now() + 45000;
    const receipts = [], seen = new Set(), identityKeys = IDENTITY.concat(["name"]);
    const actionKeys = ["mark_read", "flagged", "archive"];
    const allowed = identityKeys.concat(effects ? actionKeys : ["body_offset"]);
    let stopped = false;
    items.forEach((item, at) => {
        const receipt = {index: at};
        if (!item || typeof item !== "object" || Array.isArray(item)) {
            receipts.push(Object.assign(receipt, {status: "failed", reason: "invalid_message_locator"}));
            return;
        }
        let row = Object.assign({}, item);
        if (markReadOnly) {
            row = Object.fromEntries(Object.entries(row).filter(([name]) => identityKeys.includes(name) && name !== "name"));
            row.mark_read = true;
        }
        if (row.binding_error !== undefined) {
            receipts.push(Object.assign(receipt, {status: "failed", reason: "invalid_mail_batch_item", detail: row.binding_error}));
            return;
        }
        if (!effects && row.expected_message_id === undefined) row.expected_message_id = "";
        for (const name of identityKeys) if (row[name] !== undefined) receipt[name] = row[name];
        receipt.requested = Object.fromEntries(Object.entries(row).filter(([name]) => actionKeys.concat(["body_offset"]).includes(name)));
        const scope = row.scope !== undefined ? row.scope : "inbox";
        const validOffset = row.body_offset === undefined || (Number.isInteger(row.body_offset) && row.body_offset >= 0 && row.body_offset <= 2000000);
        const validActions = ["mark_read", "archive"].every(name => row[name] === undefined || row[name] === true)
            && [undefined, true, false].includes(row.flagged) && actionKeys.some(name => row[name] !== undefined);
        const named = scalar(row.name);
        const exact = locator(row, !effects);
        if (!Object.keys(row).every(name => allowed.includes(name)) || !Number.isInteger(row.message_id) || row.message_id <= 0
            || typeof row.expected_message_id !== "string" || typeof row.expected_account !== "string" || !row.expected_account
            || !(row.name === undefined || (named !== null && named.startsWith("mail.") && named.length <= 32))
            || !exact || exact.account !== row.expected_account || !(scope === "inbox" || (!effects && scope === "sent"))
            || !validOffset || (effects && !validActions)) {
            receipts.push(Object.assign(receipt, {status: "failed", reason: "invalid_mail_batch_item"}));
            return;
        }
        const key = JSON.stringify([String(row.message_id), row.expected_account, scope === "sent" ? "sent" : "inbox"]);
        if (seen.has(key)) {
            receipts.push(Object.assign(receipt, {status: "failed", reason: "duplicate_mail_batch_item"}));
            return;
        }
        seen.add(key);
        receipt.scope = scope;
        if (stopped || Date.now() >= deadline) {
            stopped = true;
            receipts.push(Object.assign(receipt, {status: "not_attempted", reason: "batch_stopped"}));
            return;
        }
        if (effects) {
            const actions = {};
            for (const action of actionKeys) {
                if (row[action] === undefined) continue;
                if (stopped || Date.now() >= deadline) {
                    stopped = true;
                    actions[action] = {status: "not_attempted"};
                    continue;
                }
                const result = batchMutation(exact, action, row[action]);
                actions[action] = result;
                if (["outcome_unknown", "denied"].includes(result.status) || result.reason === "cancelled") stopped = true;
                // A refused action does not authorize later effects on this item.
                if (result.status !== "completed") {
                    for (const remaining of actionKeys) {
                        if (row[remaining] !== undefined && actions[remaining] === undefined) actions[remaining] = {status: "not_attempted"};
                    }
                    break;
                }
            }
            const states = Object.values(actions).map(action => action.status);
            receipt.actions = actions;
            receipt.status = states.every(state => state === "completed") ? "completed" : states.includes("outcome_unknown") ? "outcome_unknown"
                : states.includes("completed") ? "partial" : "failed";
        } else {
            try {
                Object.assign(receipt, fileRead(row, true));
                receipt.status = "completed";
            } catch (error) {
                const envelope = faultEnvelope(error);
                receipt.status = "failed";
                receipt.error = envelope.error;
                stopped = true;
            }
        }
        receipts.push(receipt);
    });
    const completed = receipts.filter(row => row.status === "completed").length;
    const uncertain = receipts.some(row => row.status === "outcome_unknown");
    return {status: uncertain ? "outcome_unknown" : completed === items.length ? "completed" : "partial", integration: "mail", count: items.length,
        completed_count: completed, items: receipts};
}

function batchAccountScope(account) {
    return `set targetBox to missing value
set matchingBoxes to 0
repeat with mb in (mailboxes of inbox)
    if ((name of account of mb) as text) is "${quoted(account)}" then
        set targetBox to contents of mb
        set matchingBoxes to matchingBoxes + 1
    end if
end repeat
if matchingBoxes is not 1 then return "__MESSAGE_CHANGED__"`;
}

function batchMutation(exact, action, value) {
    if (exact.account === null) return failed("invalid_message_locator");
    const flag = value === true ? "true" : "false";
    const body = action === "mark_read" ? `set read status of msg to true
if (read status of msg) is not true then return "__OUTCOME_UNKNOWN__"`
        : action === "flagged" ? `set flagged status of msg to ${flag}
if (flagged status of msg) is not ${flag} then return "__OUTCOME_UNKNOWN__"`
        : `set archiveBox to missing value
try
    set archiveBox to mailbox "Archive" of account of mailbox of msg
end try
if archiveBox is missing value then return "__NO_ARCHIVE__"
move msg to archiveBox
if (mailbox of msg) is not archiveBox then return "__OUTCOME_UNKNOWN__"`;
    const source = `
try
    with timeout of 4 seconds
        ${batchAccountScope(exact.account)}
        ${exactLookup(exact, "hits")}
        ${identityCheck(exact, "hits", "__MESSAGE_CHANGED__")}
    end timeout
on error errText number errNum
    if errNum is -1712 then return "__LOOKUP_TIMED_OUT__"
    error errText number errNum
end try
set msg to item 1 of hits
try
    with timeout of 4 seconds
        ${body}
    end timeout
on error
    return "__OUTCOME_UNKNOWN__"
end try
return "1|"
`;
    let raw;
    try { raw = mailScript(source, false); }
    catch (error) {
        if (error.name === "AppError" && error.reason === "cancelled") return {status: "not_attempted", reason: "cancelled"};
        const answer = answered(error), receipt = error.receipt || {};
        if (!answer || ["denied", "needs_consent"].includes(receipt.reason)) return appFailure(error);
        return {status: "outcome_unknown", error: answer.message};
    }
    if (raw === "__MESSAGE_CHANGED__") return failed("message_changed_or_moved_refresh_inbox");
    return mutationResult(raw, action);
}

// MARK: compose, reply, draft

function saveDraft(message) {
    return `set draftSubject to subject of ${message}
set draftRecipients to address of every to recipient of ${message}
set draftContent to content of ${message}
save ${message}
set savedDraftIDs to {}
repeat with savedMsg in (messages of drafts mailbox whose subject is draftSubject)
    if (id of savedMsg) is not in priorDraftIDs and (address of every to recipient of savedMsg) is draftRecipients then
        if (content of savedMsg) contains draftContent then set end of savedDraftIDs to id of savedMsg
    end if
end repeat
if (count of savedDraftIDs) is 1 then return "draft|" & ((item 1 of savedDraftIDs) as text)
return "__DRAFT_UNCONFIRMED__"`;
}

function draftResult(raw, input) {
    const id = /^draft\|\d+$/.test(raw) && Number(raw.slice(6)) > 0 ? Number(raw.slice(6)) : null;
    const result = {status: id !== null ? "completed" : "outcome_unknown", action: id !== null ? "draft_saved" : "draft_save_unconfirmed",
        saved_in: "Apple Mail → Drafts", account: input.expected_account !== undefined ? input.expected_account : null};
    if (id !== null) {
        Object.assign(result, {created: true, draft_id: String(id), message_id: id,
            verification: "Read back a new message in Drafts with the draft's subject, recipients and content."});
    } else result.message = "Draft creation could not be confirmed. Read Drafts before trying again.";
    if (input.subject !== undefined) result.subject = input.subject;
    if (input.to !== undefined) result.to = input.to;
    return result;
}

function compose(input, send) {
    const to = strings(input.to);
    if (!to.length) return failed("missing_to");
    const subject = scalar(input.subject);
    if (subject === null) return failed("missing_compose_subject");
    const body = scalar(input.body);
    if (body === null) return failed("missing_body");
    const recipients = to.map(address => "make new to recipient at end of to recipients with properties {address:\"" + quoted(address) + "\"}")
        .concat(strings(input.cc).map(address => "make new cc recipient at end of cc recipients with properties {address:\"" + quoted(address) + "\"}"))
        .concat(strings(input.bcc).map(address => "make new bcc recipient at end of bcc recipients with properties {address:\"" + quoted(address)
            + "\"}"));
    const finish = send ? `set sendOK to send newMsg
if sendOK is true then return "sent"
return "refused"` : saveDraft("newMsg");
    const source = `
${send ? "" : "set priorDraftIDs to id of every message of drafts mailbox"}
set newMsg to make new outgoing message with properties {subject:"${quoted(subject)}", content:"${quoted(body)}", visible:false}
tell newMsg
    ${recipients.join("\n    ")}
end tell
${finish}
`;
    let raw;
    try { raw = String(mailScript(source, false)).trim(); } catch (error) { return appFailure(error); }
    if (!send) return draftResult(raw, input);
    if (raw !== "sent") return failed("mail_refused_send");
    return {status: "completed", action: "sent", to, subject};
}

/// Reply only to an exact identity or a unique subject/sender so another conversation cannot receive the reply.
function respond(input, send) {
    const exact = locator(input, false);
    if ((input.message_id !== undefined || input.expected_message_id !== undefined) && !exact) return failed("invalid_message_locator");
    const subject = scalar(input.subject) || "";
    if (!exact && !subject) return failed("missing_message_selector");
    const body = scalar(input.body);
    if (!body) return failed("missing_body");
    const all = input.reply_all;
    const replyAll = typeof all === "boolean" ? all : typeof all === "string" ? ["true", "1", "yes"].includes(all.toLowerCase())
        : typeof all === "number" ? all !== 0 : false;
    const finish = send ? `set sendOK to send replyMsg
if sendOK is true then return "1"
return "-1"` : saveDraft("replyMsg");
    const source = `
${accountScope(exact ? exact.account : null)}
with timeout of 8 seconds
    ${exact ? exactLookup(exact, "hits") : "set hits to (messages of targetBox whose " + matchWhere(subject, scalar(input.sender)) + ")"}
end timeout
if (count of hits) is 0 then return "0"
if (count of hits) is not 1 then return "-2"
set originalMsg to first item of hits
${exact ? identityCheck(exact, "hits", "-2") : ""}
${send ? "" : "set priorDraftIDs to id of every message of drafts mailbox"}
set replyMsg to reply originalMsg opening window false ${replyAll ? "with reply to all" : "without reply to all"}
tell replyMsg
    set content to "${quoted(body)}"
end tell
${finish}
`;
    let raw;
    try { raw = String(mailScript(source, false)).trim(); } catch (error) { return appFailure(error); }
    if (raw === "-2") return failed("message_changed_or_ambiguous_refresh_inbox");
    if (raw === "0") return failed("no_matching_message");
    if (raw === "-1" && send) return failed("mail_refused_send");
    if (raw === "1" && send) return {status: "completed", action: "sent_reply", subject};
    if (!send && (raw === "__DRAFT_UNCONFIRMED__" || /^draft\|[1-9]\d*$/.test(raw))) return draftResult(raw, input);
    return {status: "outcome_unknown", integration: "mail", effects: "unknown", reason: "unexpected_mail_reply_result",
        requested_message: Object.fromEntries(Object.entries(input).filter(([name]) => IDENTITY.concat(["subject", "sender"]).includes(name))),
        action: send ? "sent_reply" : "draft_save_unconfirmed",
        message: "Mail returned an unrecognized reply result. Check the original conversation and " + (send ? "Sent and Outbox" : "Drafts")
            + " before trying again."};
}

function draft(input) {
    const result = input.to !== undefined ? compose(input, false) : respond(input, false);
    if (!result || typeof result !== "object") return result;
    if (result.effects === "none") return Object.assign({}, result, {created: false});
    if (!["completed", "outcome_unknown", "unknown"].includes(result.status)) return result;
    return Object.assign({}, result, {next_call: {tool: "app", input: {action: "mail.recent", args: {mailbox: "drafts"}}}});
}

// MARK: door

const VERBS = {
    "mail.recent": recent,
    "mail.search": search,
    "mail.senders": senders,
    "mail.read": input => batch(input, false),
    "mail.triage": input => batch(input, true),
    "mail.mark_read": markRead,
    "mail.archive": archive,
    "mail.delete": remove,
    "mail.send": input => compose(input, true),
    "mail.reply": input => respond(input, true),
    "mail.draft": draft
};

function run(input) {
    const args = Object.assign({}, input);
    delete args.verb;
    const verb = VERBS[input.verb];
    if (!verb) return failed("unknown_verb", "native-mail answers " + Object.keys(VERBS).join(", ") + ".");
    try { return recovered(verb(args)); }
    catch (error) { return recovered(faultEnvelope(error)); }
}
