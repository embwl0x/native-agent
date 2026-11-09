/* NativeAgent ability
{"id": "native-messages", "kind": "ability", "version": 1, "reach": {"capabilities": ["app_write:com.apple.MobileSMS", "computer_files"], "readPaths": ["~/Library/Messages/chat.db"]}, "face": {"page": "messages"}, "record": {"description": "Read Messages conversations and history from chat.db and send texts through Messages, with the recovery words for each failure reason.", "actions": []}, "answers": {"messages.recent": {"summary": "List Messages threads with selected fields, latest-unread filtering and a since window; or read sent, received and exact conversation history", "description": "Read Messages: from_me selects newest sent or received messages across all conversations, with named participants and exact sent_count or received_count when since is given; otherwise list conversations with optional fields, since and latest-unread filtering, order by oldest unread incoming message (past 30 days by default), find them by person or words, or open an exact thread. Threads include unread_count across all dates and latest_message_is_read; history includes each message's is_read when chat.db exposes it, otherwise unread_state says unavailable. These are local read flags, not recipient read receipts. Requires Messages Read permission and macOS Full Disk Access. Plain and supported archived text are shown; unsupported formats and attachment content are explicitly unavailable, never presented as empty messages.", "class": "read", "irreversible": false, "screen": false, "args": {"type": "object", "properties": {"limit": {"type": "integer", "description": "Maximum threads or messages to return (1-30, default 10); exact window counts are independent of this limit."}, "from_me": {"type": "boolean", "description": "true: latest messages sent by you across all threads, newest first, with thread_id, named participants, date and text or attachment label. false: latest received messages. Omit to keep the conversation view. Cannot combine with thread_id, query, unread_only, sort, offset or before_message_id."}, "since": {"type": "string", "description": "Inclusive window: local YYYY-MM-DD, ISO-8601 with time zone, a positive duration such as 7d (m/h/d/w), or this week (start of the local calendar week). Thread lists use latest-message dates; oldest_unread also selects its unread message within this window and defaults to the past 30 days. Other sorts have no default date cutoff. With from_me, returns exact sent_count or received_count over local message records, including attachments, reactions and special records. Omit for an exact thread read."}, "fields": {"type": "array", "items": {"type": "string"}, "description": "Thread-list row keys to return; omitted returns every existing field. [] returns empty rows with envelope counts. Choose thread_id, name, participants, date, preview, snippet, latest_message_is_read, unread_count, oldest_unread_message_id, oldest_unread_date, oldest_unread_preview, oldest_unread_preview_status. Aliases returned under the requested key: handle is an array of participant handles, last_at is date, unread is the all-date unread_count. For no message text use [handle,name,last_at,unread]. Cannot combine with thread_id or from_me."}, "offset": {"type": "integer", "description": "Conversations to skip: next_offset from the previous page; omit initially."}, "unread_only": {"type": "boolean", "description": "List only threads whose latest message is incoming and unread; default false. Older unread records alone do not qualify. Omit for an exact thread read."}, "sort": {"type": "string", "enum": ["newest", "oldest_unread"], "description": "Thread order; default newest. oldest_unread selects unread incoming messages within since (default past 30 days), earliest first, and includes oldest_unread_message_id, oldest_unread_date, oldest_unread_preview and its availability status unless fields excludes them. Omit for an exact thread read."}, "query": {"type": "string", "description": "A person (name, number or email) or words they wrote; lists only matching conversations."}, "thread_id": {"type": "string", "description": "Exact thread_id returned by this tool, to inspect that conversation."}, "before_message_id": {"type": "integer", "minimum": 1, "description": "Older-page cursor returned as older_before_message_id. Requires the same exact thread_id; omit for recent messages."}}, "required": []}}, "messages.send": {"description": "Sends a text message now (iMessage/SMS) to an explicit recipient, or sends a reply now to an exact observed Messages thread with its expected participants. Choose exactly one of to or thread_id. Requires Messages write authority.", "class": "send", "irreversible": true, "screen": false, "args": {"type": "object", "properties": {"to": {"type": "string", "description": "Phone number or email for a new message (a name: find it with contacts.search). Omit when replying by thread_id."}, "thread_id": {"type": "string", "description": "Exact observed Messages thread. Requires expected_participants; do not use a thread ID as to."}, "expected_participants": {"type": "array", "items": {"type": "string"}, "description": "Exact participant handles from the latest thread read, checked again before sending."}, "body": {"type": "string", "description": "Message body (required)."}}, "required": ["body"]}}}}
*/
// Messages: conversations and history read from chat.db through host.files.query; texts sent through Messages' own scripting.
const DB = "~/Library/Messages/chat.db", BUNDLE = "com.apple.MobileSMS";
const ARCHIVE_BYTES = 64 * 1024, PAGE_ROWS = 1000, BUDGET_SECONDS = 2, REFERENCE_EPOCH = 978307200;
const WORDS = {
    "missing_body": "Nothing to send or save: put the text in body.",
    "thread_not_found": "That conversation is not in Messages now; list threads again with messages.recent.",
    "invalid_history_cursor": "before_message_id works only with the same thread_id, using older_before_message_id from the last read.",
    "choose_recipient_or_thread": "Give one of to (a phone number or email) or thread_id, not both.",
    "read_thread_before_reply": "Open the thread first (messages.recent with its thread_id) and pass its participant handles as expected_participants.",
    "invalid_expected_participants": "expected_participants must be the handles from the latest thread read, each once.",
    "participants_changed_read_thread_again": "The people in that thread changed; open it again and reply with the new participants. Nothing was sent."
};
const OPEN_NOTE = "Messages' local database could not be opened. NativeAgent may need macOS Full Disk Access. No permission was changed.";
const LIST_LATE = "The conversation list did not finish within its bounded read; refresh to retry.";
const READ_LATE = "The bounded conversation read was cancelled or exceeded its time budget; refresh to retry.";
const READ_FAILED = "The bounded history read did not finish. No partial page is presented as a complete conversation; refresh to retry.";
const graphemes = new Intl.Segmenter(undefined, {granularity: "grapheme"});

function run(input) {
    if (input.verb === "messages.recent") return worded(recent(input));
    if (input.verb === "messages.send") return worded(send(input));
    throw new Error("native-messages answers messages.recent and messages.send, not " + input.verb + ".");
}

// A failed Messages result names its reason; the recovery words for that reason replace its message.
function worded(result) {
    if (result.status === "failed" && result.integration === "messages" && typeof result.reason === "string" && WORDS[result.reason] !== undefined) {
        return Object.assign({}, result, {message: WORDS[result.reason]});
    }
    return result;
}

function failed(reason, message) {
    const result = {status: "failed", integration: "messages", reason};
    if (message !== undefined) result.message = message;
    result.effects = "none";
    return result;
}

function scalar(value) {
    if (typeof value === "string") return value;
    if (typeof value === "number" || typeof value === "boolean") return String(value);
    return null;
}

// An omitted number takes its default; a supplied one must be an integer and is clamped into range.
function clamped(raw, fallback, min, max) {
    let value = raw === undefined ? fallback : null;
    if (typeof raw === "number" && Number.isInteger(raw)) value = raw;
    if (typeof raw === "string" && /^[+-]?\d+$/.test(raw.trim())) value = parseInt(raw.trim(), 10);
    if (value === null) {
        throw new Error("A supplied numeric limit, offset or duration is not an integer. Correct the argument; defaults apply only when omitted.");
    }
    return Math.max(min, Math.min(max, value));
}

// MARK: messages.recent

function recent(input) {
    const limit = clamped(input.limit, 10, 1, 30);
    const threadID = input.thread_id === undefined ? null : scalar(input.thread_id);
    const isBool = value => value === undefined || value === true || value === false;
    if (!isBool(input.unread_only) || !isBool(input.from_me) || !(input.sort === undefined || input.sort === "newest" || input.sort === "oldest_unread")) {
        return failed("invalid_thread_filter", "unread_only and from_me take true or false; sort takes newest or oldest_unread. Nothing was read.");
    }
    const unreadOnly = input.unread_only === true, oldestUnread = input.sort === "oldest_unread";
    let fields = null;
    if (input.fields !== undefined) {
        const allowed = ["thread_id", "name", "participants", "date", "preview", "snippet", "latest_message_is_read", "unread_count",
            "oldest_unread_message_id", "oldest_unread_date", "oldest_unread_preview", "oldest_unread_preview_status", "handle", "last_at", "unread"];
        if (threadID !== null || input.from_me !== undefined || !Array.isArray(input.fields)
            || !input.fields.every(key => typeof key === "string" && allowed.includes(key))) {
            return failed("invalid_thread_fields", "fields is a list from: " + allowed.slice().sort().join(", ")
                + "; it lists threads, so it does not combine with thread_id or from_me. Nothing was read.");
        }
        fields = input.fields;
    }
    let since = null;
    if (input.since !== undefined) {
        const date = threadID === null && typeof input.since === "string" ? sinceDate(input.since) : null;
        if (date === null || !(Math.abs(referenceSeconds(date) * 1e9) < 9223372036854775807)) {
            return {status: "failed", integration: "messages", effects: "none", message: "since takes local YYYY-MM-DD, ISO-8601 with a time zone, "
                + "a positive duration such as 7d (m/h/d/w), or this week. Use it with a thread list or from_me, within the Messages date range."};
        }
        since = date;
    } else if (oldestUnread) since = new Date(Date.now() - 30 * 86400 * 1000);
    if (threadID !== null && (unreadOnly || oldestUnread)) return failed("thread_filters_require_listing");
    const offset = threadID === null ? clamped(input.offset, 0, 0, 100000) : 0;
    const asked = input.query === undefined ? null : scalar(input.query);
    const query = asked === null || asked.trim() === "" ? null : asked.trim();
    let before = null;
    if (input.before_message_id !== undefined) {
        if (threadID === null || !Number.isInteger(input.before_message_id) || input.before_message_id <= 0) return failed("invalid_history_cursor");
        before = input.before_message_id;
    }
    if (typeof input.from_me === "boolean") {
        if (threadID !== null || query !== null || ["unread_only", "sort", "offset"].some(key => input[key] !== undefined)) {
            return {status: "failed", integration: "messages", effects: "none",
                message: "from_me selects messages across all conversations. Omit thread_id, query, unread_only, sort and offset for this view."};
        }
        const result = history(null, limit, null, input.from_me, since);
        result.status = result.history_status === "available" ? "completed" : "failed";
        result.integration = "messages";
        result.effects = "none";
        return named(result);
    }
    const listing = threads(threadID === null ? query : null, threadID, unreadOnly, oldestUnread, since);
    if (!Array.isArray(listing.threads)) {
        return {status: "failed", integration: "messages", reason: listing.history_reason || "history_read_failed", effects: "none",
            message: listing.history_note || "Messages' conversations could not be read; refresh to retry."};
    }
    // People by their formatted numbers where known (so a number finds them); handles stay the identity.
    let rows = named({threads: listing.threads}).threads;
    if (threadID !== null) {
        if (!rows.length) return failed("thread_not_found");
    } else if (query !== null) {
        const digits = numerals(query), wanted = query.toLocaleLowerCase();
        rows = rows.filter(row => {
            const texts = [];
            if (typeof row.name === "string") texts.push(row.name);
            (Array.isArray(row.participants) ? row.participants : []).forEach(person => ["handle", "name"].forEach(key => {
                if (person && typeof person[key] === "string") texts.push(person[key]);
            }));
            return row.snippet !== undefined || texts.some(text => text.toLocaleLowerCase().includes(wanted)
                || (digits.length >= 7 && numerals(text).includes(digits)));
        });
    }
    const page = rows.slice(offset, offset + limit);
    let result = {status: "completed", count: page.length, total: rows.length, has_more: offset + page.length < rows.length, threads: page,
        ordering: oldestUnread ? "Oldest unread incoming message within since first (default: past 30 days)."
            : "Newest conversation first, by its last message.",
        history_status: "select_conversation",
        history_note: "Open a conversation to read a bounded page of its local history. fields selects only the requested thread metadata or previews."};
    if (since !== null) result.since = zulu(since);
    if (offset + page.length < rows.length) result.next_offset = offset + page.length;
    // A word search cut short by its budget says so (the room shows `note`).
    ["partial", "note", "unread_state", "unread_note"].forEach(key => { if (listing[key] !== undefined) result[key] = listing[key]; });
    if (threadID !== null) {
        result.thread_id = threadID;
        const read = history(threadID, limit, before, null, null);
        result = Object.assign(result, read);
        const available = read.history_status === "available";
        result.status = available ? "completed" : "failed";
        result.integration = "messages";
        result.effects = "none";
        if (!available) {
            result.partial = true;
            result.note = "Only the selected thread's metadata was read; its requested history is unavailable.";
            result.reason = read.history_reason;
            result.message = read.history_note;
        }
    }
    result = named(result);
    if (fields !== null && Array.isArray(result.threads)) {
        result.threads = result.threads.map(row => {
            const selected = {};
            fields.forEach(field => {
                let value = row[field];
                if (field === "last_at") value = row.date;
                if (field === "unread") value = row.unread_count;
                if (field === "handle") {
                    value = Array.isArray(row.participants)
                        ? row.participants.filter(person => person && person.handle !== undefined).map(person => person.handle) : undefined;
                }
                if (value !== undefined) selected[field] = value;
            });
            return selected;
        });
    }
    return result;
}

function sinceDate(raw) {
    const value = raw.trim();
    if (value === "this week") {
        const now = new Date(), first = new Intl.Locale(Intl.DateTimeFormat().resolvedOptions().locale).getWeekInfo().firstDay % 7;
        return new Date(now.getFullYear(), now.getMonth(), now.getDate() - (now.getDay() - first + 7) % 7);
    }
    const units = {m: 60, h: 3600, d: 86400, w: 604800};
    const amount = value.slice(0, -1);
    if (units[value.slice(-1)] !== undefined && /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(amount)) {
        const count = Number(amount);
        if (Number.isFinite(count) && count > 0) return new Date(Date.now() - count * units[value.slice(-1)] * 1000);
    }
    let parts = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
    if (value.length === 10) {
        if (!parts) return null;
        const day = new Date(+parts[1], +parts[2] - 1, +parts[3]);
        return day.getFullYear() === +parts[1] && day.getMonth() === +parts[2] - 1 && day.getDate() === +parts[3] ? day : null;
    }
    parts = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(Z|[+-]\d{2}:?\d{2})$/.exec(value);
    if (!parts) return null;
    const zone = parts[2] === "Z" ? "Z" : parts[2].slice(0, 3) + ":" + parts[2].slice(-2);
    const time = Date.parse(parts[1] + zone);
    return Number.isNaN(time) ? null : new Date(time);
}

function referenceSeconds(date) { return date.getTime() / 1000 - REFERENCE_EPOCH; }
function zulu(date) { return date.toISOString().replace(/\.\d{3}Z$/, "Z"); }
// chat.db dates count nanoseconds since 2001 on current macOS and seconds on older stores.
function when(raw) {
    if (typeof raw !== "number" || !(raw > 0)) return null;
    return zulu(new Date((raw / (raw > 100000000000 ? 1000000000 : 1) + REFERENCE_EPOCH) * 1000));
}
function numerals(text) { return text.replace(/[^\p{N}]/gu, ""); }
function prefix(text, count) {
    let out = "", taken = 0;
    for (const part of graphemes.segment(text)) {
        if (taken++ === count) break;
        out += part.segment;
    }
    return out;
}
function fold(text) { return text.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase(); }

// Use formatted numbers as participant and sender names so a reply retains the handle identity instead of selecting a namesake.
function named(result) {
    function name(handle) {
        if (typeof handle !== "string" || handle.includes("@")) return null;
        const trimmed = handle.trim(), digits = trimmed.slice(1).replace(/[^0-9]/g, "");
        if (!trimmed.startsWith("+") || !/^[0-9 ()\-.]*$/.test(trimmed.slice(1)) || digits.length < 7 || digits.length > 15 || digits[0] === "0") return null;
        if (!digits.startsWith("1") || numerals(handle).length !== 11) return null;
        const d = numerals(handle).slice(-10);
        return "(" + d.slice(0, 3) + ") " + d.slice(3, 6) + "-" + d.slice(6);
    }
    const out = Object.assign({}, result);
    ["threads", "messages"].forEach(key => {
        if (!Array.isArray(result[key])) return;
        out[key] = result[key].map(value => {
            if (!value || typeof value !== "object" || Array.isArray(value)) return value;
            const row = Object.assign({}, value);
            if (Array.isArray(row.participants)) {
                row.participants = row.participants.map(person => {
                    const found = person && typeof person === "object" ? name(person.handle) : null;
                    return found === null ? person : Object.assign({}, person, {name: found});
                });
            }
            const sender = name(row.sender);
            if (sender !== null) row.sender_name = sender;
            return row;
        });
    });
    return out;
}

// MARK: chat.db reads

function unavailable(reason, note) { return {history_status: "unavailable", history_reason: reason, history_note: note}; }

// A read that cannot open the store, runs out of time or meets another schema becomes that read's named unavailability.
function readFailure(error, notes) {
    if (error.name !== "AppError" || error.reason === "cancelled") throw error;
    // The store's own remedy (Full Disk Access) rides the unavailability, as the native reader's did.
    if (error.reason === "not_permitted" || error.reason === "not_found") {
        const remedy = error.receipt && error.receipt.remedy;
        return Object.assign(unavailable("database_unavailable", notes.open), remedy ? {remedy} : {});
    }
    if (error.reason === "deadline") return unavailable(notes.late[0], notes.late[1]);
    if (error.reason === "sqlite_error") {
        return /no such (table|column)/.test(error.message) ? unavailable("unsupported_history_schema", notes.schema)
            : unavailable(notes.failed[0], notes.failed[1]);
    }
    throw error;
}

function once(sql, params) {
    return host.files.query({path: DB, sql, params, limit: PAGE_ROWS, seconds: BUDGET_SECONDS}).rows;
}
function deadline() {
    const error = new Error("The read ran past its time budget.");
    error.name = "AppError"; error.reason = "deadline";
    return error;
}
// Every row of a listing, in pages of the stem's row bound, under one time budget for the whole read. A search keeps what it read when the budget
// runs out (the array says stopped); any other read fails at the deadline.
function all(sql, params, keepRead) {
    const found = [], started = Date.now();
    for (;;) {
        const left = BUDGET_SECONDS - (Date.now() - started) / 1000;
        let page;
        try {
            if (left <= 0) throw deadline();
            page = host.files.query({path: DB, sql: sql + "\nLIMIT -1 OFFSET " + found.length, params, limit: PAGE_ROWS,
                seconds: Math.max(1, Math.ceil(left))});
        } catch (error) {
            if (keepRead && error.name === "AppError" && error.reason === "deadline") { found.stopped = true; return found; }
            throw error;
        }
        page.rows.forEach(row => found.push(row));
        if (!page.truncated || !page.rows.length) return found;
    }
}

// The indexes and read flag this store exposes, as PRAGMA index_list/index_info and table_info report them.
function shape() {
    const indexes = [];
    once(`SELECT tb.name, il.name, il."unique", il.partial, ii.name
        FROM (SELECT 'chat' AS name UNION ALL SELECT 'chat_message_join' UNION ALL SELECT 'message') tb
        JOIN pragma_index_list(tb.name) il JOIN pragma_index_info(il.name) ii
        ORDER BY tb.name, il.seq, ii.seqno`, []).forEach(row => {
        let last = indexes[indexes.length - 1];
        if (!last || last.table !== row[0] || last.name !== row[1]) {
            last = {table: row[0], name: row[1], unique: row[2] !== 0, partial: row[3] !== 0, columns: []};
            indexes.push(last);
        }
        if (typeof row[4] === "string") last.columns.push(row[4]);
    });
    const unread = once("SELECT count(*) FROM pragma_table_info('message') WHERE name = 'is_read'", [])[0][0] > 0;
    return {indexes, unread};
}
// guid is unique and the join's primary key starts with chat_id. Requiring their actual indexes prevents an unexpected schema from causing a scan.
function index(schema, table, columns, unique) {
    const found = schema.indexes.find(entry => entry.table === table && (!unique || entry.unique) && !entry.partial
        && (unique ? entry.columns.length === columns.length : entry.columns.length >= columns.length)
        && columns.every((column, at) => entry.columns[at] === column));
    return found ? found.name : null;
}

const archived = "CASE WHEN m.text IS NULL AND length(m.attributedBody) <= 65536 THEN m.attributedBody END";
function text(plain, archive) { return plain !== null ? plain : decoded(archive); }

// Word matches carry their newest matching message as the snippet; thread handles retain conversation identity.
function threads(words, threadID, unreadOnly, oldestUnread, since) {
    const notes = {open: OPEN_NOTE, schema: "This Messages database version cannot list its conversations.",
        late: ["history_temporarily_unavailable", LIST_LATE], failed: ["history_read_failed", LIST_LATE]};
    let schema, listed;
    try { schema = shape(); } catch (error) { return readFailure(error, notes); }
    const unread = schema.unread;
    if (!unread && (unreadOnly || oldestUnread)) {
        return unavailable("unread_state_unavailable", "This Messages database does not expose is_read, so unread filtering and ordering are unavailable.");
    }
    const window = column => since === null ? "1" : column + " >= CASE WHEN " + column + " > 100000000000 THEN ?2 ELSE ?3 END";
    const seconds = since === null ? null : referenceSeconds(since);
    const bound = first => since === null ? (first === null ? [] : [first]) : [first, Math.ceil(seconds * 1e9), Math.ceil(seconds)];
    const unreadCount = unread ? `(SELECT count(*) FROM chat_message_join u JOIN message um ON um.ROWID = u.message_id WHERE u.chat_id = c.ROWID
        AND um.is_from_me = 0 AND um.is_read = 0)` : "NULL";
    const unreadJoin = oldestUnread ? `JOIN message u ON u.ROWID = (SELECT um.ROWID FROM chat_message_join uj
        JOIN message um ON um.ROWID = uj.message_id
        WHERE uj.chat_id = c.ROWID AND um.is_from_me = 0 AND um.is_read = 0 AND ${window("um.date")}
        ORDER BY um.date ASC, um.ROWID ASC LIMIT 1)` : "";
    const unreadColumns = oldestUnread ? "u.date, u.ROWID, substr(u.text, 1, 400), " + archived.replace(/m\./g, "u.") : "NULL, NULL, NULL, NULL";
    const filters = [window("j.last")];
    if (threadID !== null) filters.push("c.guid = ?1");
    if (unreadOnly) filters.push("m.is_from_me = 0 AND m.is_read = 0");
    try {
        listed = all(`SELECT c.guid, c.display_name, j.last, m.is_from_me, substr(m.text, 1, 400), ${archived},
               (SELECT group_concat(h.id, char(10)) FROM chat_handle_join ch JOIN handle h ON h.ROWID = ch.handle_id WHERE ch.chat_id = c.ROWID),
               ${unread ? "m.is_read" : "NULL"}, ${unreadCount}, ${unreadColumns}
            FROM chat c
            JOIN (SELECT chat_id, max(message_date) AS last FROM chat_message_join
                  ${threadID === null ? "" : "WHERE chat_id IN (SELECT ROWID FROM chat WHERE guid = ?1)"}
                  GROUP BY chat_id) j ON j.chat_id = c.ROWID
            LEFT JOIN message m ON m.ROWID = (SELECT message_id FROM chat_message_join WHERE chat_id = c.ROWID
                ORDER BY message_date DESC, message_id DESC LIMIT 1)
            ${unreadJoin}
            WHERE ${filters.join(" AND ")}
            ORDER BY ${oldestUnread ? "u.date ASC, u.ROWID ASC, c.guid ASC" : "j.last DESC, c.ROWID ASC"}`, bound(threadID));
    } catch (error) { return readFailure(error, notes); }
    let rows = listed.filter(row => typeof row[0] === "string").map(row => {
        const handles = (row[6] || "").split("\n").filter(handle => handle !== "").map(handle => ({handle, name: ""}));
        const thread = {thread_id: row[0], name: row[1] || "", participants: handles};
        if (unread) {
            thread.latest_message_is_read = row[7] === null ? null : row[7] !== 0;
            thread.unread_count = row[8] === null ? 0 : row[8];
        }
        const date = when(row[2]);
        if (date !== null) thread.date = date;
        const last = text(row[4], row[5]);
        if (last !== null && prefix(last, 160) !== "") thread.preview = (row[3] ? "You: " : "") + prefix(last, 160);
        if (oldestUnread) {
            thread.oldest_unread_message_id = row[10] === null ? 0 : row[10];
            const unreadDate = when(row[9]);
            if (unreadDate !== null) thread.oldest_unread_date = unreadDate;
            const preview = text(row[11], row[12]);
            thread.oldest_unread_preview_status = preview === null ? "unavailable" : "available";
            if (preview !== null) thread.oldest_unread_preview = prefix(preview, 160);
        }
        return thread;
    });
    const result = {unread_state: unread ? "available" : "unavailable",
        unread_note: unread ? "unread_count counts all incoming unread local records in each thread, across all dates. latest_message_is_read describes "
            + "only its latest message." : "Unread state is unavailable: this Messages database does not expose is_read. No unread count is inferred."};
    if (words !== null) {
        // Newest first. Plain text is matched over its whole length in SQL; an archived body whose bytes hold the words is decoded and matched here.
        const found = {}, wanted = fold(words);
        let matches = [];
        try {
            matches = all(`SELECT c.guid, substr(m.text, 1, 400), ${archived}
                FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id JOIN chat c ON c.ROWID = j.chat_id
                WHERE ((m.text IS NOT NULL AND folded_contains(m.text, ?1))
                    OR (m.text IS NULL AND m.attributedBody IS NOT NULL AND folded_contains(m.attributedBody, ?1)))
                  AND ${window("m.date")}
                ORDER BY j.message_date DESC, j.message_id DESC`, bound(wanted), true);
        } catch (error) {
            return readFailure(error, Object.assign({}, notes, {schema: "This Messages database version cannot search its messages."}));
        }
        if (matches.stopped) {
            result.partial = true;
            result.note = "The word search stopped at its time budget; older messages were not searched.";
        }
        matches.forEach(row => {
            if (typeof row[0] !== "string" || found[row[0]] !== undefined) return;
            if (row[1] !== null) { found[row[0]] = prefix(row[1], 160); return; }
            const said = decoded(row[2]);
            if (said !== null && fold(said).includes(wanted)) found[row[0]] = prefix(said, 160);
        });
        rows = rows.map(row => found[row.thread_id] === undefined ? row : Object.assign({}, row, {snippet: found[row.thread_id]}));
    }
    result.threads = rows;
    return result;
}

// A small, read-only window into one conversation, or into sent or received messages across all of them.
function history(threadID, limit, before, fromMe, since) {
    const notes = {open: fromMe === null ? "Conversation metadata is available, but its local history could not be opened. NativeAgent may need macOS "
            + "Full Disk Access. No permission was changed." : OPEN_NOTE,
        schema: "This Messages database version cannot provide this bounded history view.",
        late: ["history_temporarily_unavailable", READ_LATE], failed: ["history_read_failed", READ_FAILED]};
    let schema;
    try { schema = shape(); } catch (error) { return readFailure(error, notes); }
    if (fromMe === null && (index(schema, "chat", ["guid"], true) === null || index(schema, "chat_message_join", ["chat_id", "message_id"], true) === null)) {
        return unavailable("unsupported_history_schema",
            "This Messages database does not expose the exact indexed conversation route needed for a bounded read.");
    }
    const pageSize = Math.min(30, Math.max(1, limit));
    let chatID = 0;
    if (threadID !== null) {
        const unmatched = "The observed Messages conversation could not be matched to local history by its exact ID. No alternate recipient or "
            + "conversation was substituted.";
        let chats;
        try { chats = once("SELECT ROWID FROM chat WHERE guid = ?1 LIMIT 1", [threadID]); }
        catch (error) {
            return readFailure(error, {open: notes.open, schema: "This Messages database could not provide an exact conversation lookup.",
                late: ["history_read_failed", unmatched], failed: ["history_read_failed", unmatched]});
        }
        if (!chats.length) return unavailable("exact_thread_not_found", unmatched);
        chatID = chats[0][0];
    }
    const unread = schema.unread;
    const columns = `SELECT m.ROWID, substr(m.text, 1, 4096), m.date, m.is_from_me,
               substr(h.id, 1, 256), m.cache_has_attachments,
               m.attributedBody IS NOT NULL, length(m.text) > 4096,
               m.associated_message_type, m.item_type,
               CASE WHEN m.text IS NULL AND length(m.attributedBody) <= 65536
                    THEN m.attributedBody ELSE NULL END,
               length(m.attributedBody), ${unread ? "m.is_read" : "NULL"}`;
    let sql, params;
    if (fromMe !== null) {
        const dateIndex = index(schema, "message", ["date"], false);
        if (dateIndex === null || index(schema, "chat_message_join", ["message_id"], false) === null) {
            return unavailable("unsupported_history_schema", "This Messages database does not expose the indexed date and conversation routes needed for a "
                + "bounded sender read.");
        }
        const dated = "message INDEXED BY \"" + dateIndex.replace(/"/g, "\"\"") + "\"";
        // Without since every dated record qualifies, as the lowest 64-bit date does.
        const floor = since === null ? "-9223372036854775808" : `CASE WHEN (SELECT max(date) FROM ${dated}) > 100000000000 THEN ?2 ELSE ?3 END`;
        const filter = `is_from_me = ?1 AND date >= ${floor}
            AND EXISTS (SELECT 1 FROM chat_message_join j JOIN chat c ON c.ROWID = j.chat_id WHERE j.message_id = message.ROWID)`;
        sql = `${columns}, total.n, c.guid, c.display_name,
                (SELECT group_concat(h.id, char(10)) FROM chat_handle_join ch JOIN handle h ON h.ROWID = ch.handle_id WHERE ch.chat_id = c.ROWID)
            FROM (${since === null ? "SELECT NULL AS n" : "SELECT count(*) AS n FROM " + dated + " WHERE " + filter}) total
            LEFT JOIN (SELECT ROWID AS message_id FROM ${dated} WHERE ${filter} ORDER BY date DESC, ROWID DESC LIMIT ?4) page ON 1
            LEFT JOIN message m ON m.ROWID = page.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            LEFT JOIN chat c ON c.ROWID = (SELECT j.chat_id FROM chat_message_join j JOIN chat linked ON linked.ROWID = j.chat_id
                WHERE j.message_id = m.ROWID ORDER BY j.chat_id LIMIT 1)
            ORDER BY m.date DESC, m.ROWID DESC`;
        const seconds = since === null ? null : referenceSeconds(since);
        params = [fromMe ? 1 : 0, since === null ? null : Math.ceil(seconds * 1e9), since === null ? null : Math.ceil(seconds), pageSize];
    } else {
        sql = `${columns}
            FROM (SELECT message_id FROM chat_message_join
                  WHERE chat_id = ?1 AND message_id < ${before === null ? "9223372036854775807" : "?2"} ORDER BY message_id DESC LIMIT ?3) AS page
            JOIN message AS m ON m.ROWID = page.message_id
            LEFT JOIN handle AS h ON h.ROWID = m.handle_id
            ORDER BY m.ROWID DESC`;
        params = [chatID, before, pageSize];
    }
    let found;
    try { found = once(sql, params); } catch (error) { return readFailure(error, notes); }
    const messages = [];
    let remainingBytes = 16 * 1024, oldest = null, stoppedForBudget = false, total = null;
    for (const row of found) {
        if (fromMe !== null) {
            if (since !== null) total = row[13];
            if (row[0] === null) continue;
        }
        if (remainingBytes === 0) { stoppedForBudget = true; break; }
        oldest = row[0];
        const plain = row[1];
        const archiveTooLarge = (row[11] || 0) > ARCHIVE_BYTES;
        const said = plain === null ? decoded(row[10]) : null;
        const original = plain !== null ? plain : said;
        const body = clipped(original === null ? "" : original, remainingBytes);
        remainingBytes -= utf8Length(body);
        const message = {message_id: row[0], from_me: !!row[3], has_attachments: !!row[5],
            text_status: original === null ? (row[6] ? "archived_text_not_decoded" : "no_plain_text") : "available",
            text_source: plain !== null ? "plain_text_column" : said !== null ? "typedstream_foundation_string" : "unavailable",
            text_truncated: !!row[7] || utf8Length(body) < (original === null ? 0 : utf8Length(original)),
            associated_message_type: row[8] === null ? 0 : row[8], item_type: row[9] === null ? 0 : row[9]};
        if (unread) message.is_read = !!row[12];
        if (original === null && row[6]) message.text_unavailable_reason = archiveTooLarge ? "archive_exceeds_64kib_budget" : "unsupported_or_invalid_archive";
        if (original !== null) message.text = body;
        if (fromMe !== null) {
            message.thread_id = row[14] === null ? null : row[14];
            message.name = row[15] || "";
            message.participants = (row[16] || "").split("\n").filter(handle => handle !== "").map(handle => ({handle, name: ""}));
            if (message.has_attachments) message.attachment_label = "Attachment";
        }
        if (row[4] !== null) message.sender = row[4];
        const date = when(row[2]);
        if (date !== null) message.date = date;
        messages.push(message);
    }
    const result = {history_status: "available", messages: fromMe === null ? messages.slice().reverse() : messages,
        unread_state: unread ? "available" : "unavailable",
        unread_note: unread ? "is_read is the local Messages read flag, not a recipient delivery/read receipt."
            : "Unread state is unavailable: this Messages database does not expose is_read. No read flag is inferred.",
        history_ordering: "Recent local message records, displayed oldest to newest within this page; insertion order can differ from delivery time.",
        history_note: "Read-only local history. Plain text and supported Foundation string bodies are shown. Formatting, attachment content and special "
            + "records are not interpreted; unsupported archives are labeled, never treated as empty messages. Full Disk Access remains controlled by macOS."};
    if (fromMe !== null) {
        result.from_me = fromMe;
        result.count = messages.length;
        result.history_ordering = "Newest message date first across all conversations; message ID breaks date ties.";
        if (since !== null && total !== null) {
            result.since = zulu(since);
            result[fromMe ? "sent_count" : "received_count"] = total;
            result.count_note = "Exact local message record count from since (inclusive), independent of the page limit. Includes attachments, reactions "
                + "and special records; not a count of conversations or recipients.";
        }
    } else if ((messages.length === pageSize || stoppedForBudget) && oldest !== null) {
        // A full page permits one bounded older read; it does not assert that older rows exist without reading them.
        result.older_before_message_id = oldest;
    }
    return result;
}

function utf8Length(value) {
    let count = 0;
    for (const character of value) {
        const point = character.codePointAt(0);
        count += point < 0x80 ? 1 : point < 0x800 ? 2 : point < 0x10000 ? 3 : 4;
    }
    return count;
}
// The longest whole-character prefix that fits the remaining UTF-8 byte budget.
function clipped(value, bytes) {
    let out = "", used = 0;
    for (const character of value) {
        const size = utf8Length(character);
        if (used + size > bytes) break;
        out += character;
        used += size;
    }
    return out;
}

// MARK: typedstream

// An archived body of 1 byte through 64 KiB is parsed; empty, larger or malformed archives stay undecoded.
function decoded(blob) {
    if (blob === null || blob === undefined) return null;
    const bytes = base64Bytes(blob.base64);
    if (!bytes.length || bytes.length > ARCHIVE_BYTES) return null;
    return typedString(bytes);
}

function base64Bytes(encoded) {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", bytes = [];
    let value = 0, bits = 0;
    for (const character of encoded) {
        if (character === "=") break;
        const digit = alphabet.indexOf(character);
        if (digit < 0) throw new Error("chat.db returned an archived body that is not base64.");
        value = ((value << 6) | digit) & 0xffffff;
        bits += 6;
        if (bits >= 8) { bits -= 8; bytes.push((value >> bits) & 0xff); }
    }
    return bytes;
}

// Strict UTF-8: overlong forms, surrogates and code points past U+10FFFF are refused.
function utf8(bytes, start, end) {
    let out = "";
    for (let at = start; at < end;) {
        const lead = bytes[at];
        let point, extra;
        if (lead < 0x80) { point = lead; extra = 0; }
        else if (lead >= 0xc2 && lead <= 0xdf) { point = lead & 0x1f; extra = 1; }
        else if (lead >= 0xe0 && lead <= 0xef) { point = lead & 0x0f; extra = 2; }
        else if (lead >= 0xf0 && lead <= 0xf4) { point = lead & 0x07; extra = 3; }
        else return null;
        if (at + extra >= end) return null;
        for (let next = 1; next <= extra; next++) {
            if ((bytes[at + next] & 0xc0) !== 0x80) return null;
            point = (point << 6) | (bytes[at + next] & 0x3f);
        }
        if ((extra === 2 && (point < 0x800 || (point >= 0xd800 && point <= 0xdfff))) || (extra === 3 && (point < 0x10000 || point > 0x10ffff))) return null;
        out += String.fromCodePoint(point);
        at += extra + 1;
    }
    return out;
}

// Independent wire-format reading (chrissardegna.com/blog/reverse-engineering-apples-typedstream-format). Decode only the leading Foundation string;
// never instantiate archived classes or interpret executable objects.
function typedString(bytes) {
    const refused = {};
    let offset = 0;
    const strings = [], classes = [];
    const refuse = () => { throw refused; };
    const byte = () => { if (offset >= bytes.length) refuse(); return bytes[offset++]; };
    const expect = value => { if (byte() !== value) refuse(); };
    const raw = count => {
        if (count < 0 || count > bytes.length - offset) refuse();
        const value = utf8(bytes, offset, offset + count);
        if (value === null) refuse();
        offset += count;
        return value;
    };
    // Only unsigned lengths needed here. Reserved markers, 64-bit numbers, negative lengths and lengths past the archive budget are refused.
    const length = () => {
        const marker = byte();
        if (marker <= 0x7f || marker >= 0x92) return marker;
        const width = marker === 0x81 ? 2 : marker === 0x82 ? 4 : refuse();
        let value = 0;
        for (let shift = 0; shift < width; shift++) value += byte() * 2 ** (shift * 8);
        if (value > ARCHIVE_BYTES) refuse();
        return value;
    };
    const shared = () => {
        const marker = byte();
        if (marker === 0x84) {
            const count = length();
            if (count > 64 || strings.length >= 16) refuse();
            const value = raw(count);
            strings.push(value);
            return value;
        }
        const at = marker - 0x92;
        if (at < 0 || at >= strings.length) refuse();
        return strings[at];
    };
    // Null slots belong to object instances, not classes, so an object reference is refused wherever the grammar requires a class.
    const chain = depth => {
        if (depth >= 4) refuse();
        const marker = byte();
        if (marker === 0x85) return [];
        if (marker !== 0x84) {
            const at = marker - 0x92;
            if (at < 0 || at >= classes.length || classes[at] === null) refuse();
            return classes[at];
        }
        const name = shared(), version = length();
        if (!["NSObject", "NSString", "NSMutableString", "NSAttributedString", "NSMutableAttributedString"].includes(name)
            || version > 1 || classes.length >= 12) refuse();
        const at = classes.length;
        classes.push(null);
        const found = [name + "/" + version].concat(chain(depth + 1));
        if (found.length > 3) refuse();
        classes[at] = found;
        return found;
    };
    const objectClasses = () => {
        expect(0x84);
        if (classes.length >= 12) refuse();
        classes.push(null);
        const found = chain(0);
        if (!found.length) refuse();
        return found.join(",");
    };
    try {
        expect(4);
        expect(11);
        if (raw(11) !== "streamtyped" || length() !== 1000 || shared() !== "@") refuse();
        const plainClasses = ["NSString/1,NSObject/0", "NSMutableString/1,NSString/1,NSObject/0"];
        const root = objectClasses();
        const attributed = root === "NSAttributedString/0,NSObject/0" || root === "NSMutableAttributedString/0,NSAttributedString/0,NSObject/0";
        if (attributed) {
            if (shared() !== "@" || !plainClasses.includes(objectClasses())) refuse();
        } else if (!plainClasses.includes(root)) refuse();
        if (shared() !== "+") refuse();
        const said = raw(length());
        // The exact byte length determines the body boundary. A literal marker within the text cannot stop this read or become metadata.
        expect(0x86);
        // Only the string prefix is decoded. Attribute contents remain uninterpreted; never search them for another plausible string.
        if (attributed ? !(offset < bytes.length && bytes[bytes.length - 1] === 0x86) : offset !== bytes.length) refuse();
        return said;
    } catch (error) {
        if (error === refused) return null;
        throw error;
    }
}

// MARK: messages.send

function escaped(value) {
    return value.replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/\r\n/g, "\\n").replace(/\n/g, "\\n").replace(/\r/g, "\\r");
}

// Send to an explicit recipient, or an exact observed chat after checking its current participants. Never reinterpret a chat identifier as a handle.
function send(input) {
    const to = input.to === undefined ? null : scalar(input.to);
    const threadID = input.thread_id === undefined ? null : scalar(input.thread_id);
    if ((to !== null && to !== "") === (threadID !== null && threadID !== "")) return failed("choose_recipient_or_thread");
    const body = input.body === undefined ? null : scalar(input.body);
    if (body === null || body === "") return failed("missing_body");
    if (to !== null && to !== "" && !to.includes("@") && numerals(to) === "") {
        return {status: "failed", integration: "messages", reason: "recipient_is_a_name",
            message: "\"" + to + "\" is a name, not a phone number or email. Look it up with contacts.search, then send to that number. Nothing was sent."};
    }
    let source;
    if (threadID !== null && threadID !== "") {
        const values = input.expected_participants;
        if (!Array.isArray(values) || !values.length || values.length > 100) return failed("read_thread_before_reply");
        const handles = values.map(scalar);
        if (handles.some(handle => handle === null || handle === "") || new Set(handles).size !== handles.length) {
            return failed("invalid_expected_participants");
        }
        source = `
    set matches to every chat whose id is "${escaped(threadID)}"
    if (count of matches) is not 1 then return "thread_not_found"
    set targetChat to item 1 of matches
    set expectedHandles to {${handles.map(handle => "\"" + escaped(handle) + "\"").join(", ")}}
    set actualPeople to participants of targetChat
    if (count of actualPeople) is not (count of expectedHandles) then return "participants_changed"
    repeat with person in actualPeople
        if expectedHandles does not contain ((handle of person) as text) then return "participants_changed"
    end repeat
    send "${escaped(body)}" to targetChat
    return "sent"
`;
    } else {
        source = `
    set targetService to 1st service whose service type = iMessage
    set targetBuddy to buddy "${escaped(to)}" of targetService
    send "${escaped(body)}" to targetBuddy
    return "sent"
`;
    }
    let reply;
    try { reply = host.apps.call({bundle_id: BUNDLE, script: source, launch: true, read_only: false}); }
    catch (error) { return sendFailure(error); }
    if (typeof reply.value !== "string") {
        return {status: "failed", integration: "messages", error_code: -1700, error: "The integration script did not return text."};
    }
    if (reply.value !== "sent") return failed(reply.value === "participants_changed" ? "participants_changed_read_thread_again" : "thread_not_found");
    const result = {status: "completed", action: "sent"};
    if (threadID !== null && threadID !== "") result.thread_id = threadID;
    else result.to = to;
    return result;
}

// Automation consent the person withheld is a denial with its remedy; every other refusal or unknown outcome keeps the native envelope.
function sendFailure(error) {
    if (error.name !== "AppError" || error.reason === "cancelled") throw error;
    const receipt = error.receipt;
    if (error.reason === "denied" || error.reason === "needs_consent") {
        const denied = {status: "denied", reason: "os_automation_denied", integration: "messages",
            remedy: receipt.remedy === undefined ? null : receipt.remedy};
        if (receipt.result && typeof receipt.result.app_path === "string") denied.app = receipt.result.app_path.split("/").pop().replace(/\.app$/, "");
        return denied;
    }
    return Object.assign({}, receipt, {integration: "messages"});
}
