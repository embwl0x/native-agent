/* NativeAgent ability
{"id":"native-notes","kind":"ability","version":1,
 "reach":{"capabilities":["app_write:com.apple.Notes"]},
 "face":{"page":"notes"},
 "answers":{
 "notes.search":{"description":"Find and read Apple Notes: blank query lists recent notes, query matches title or text, title (exact) or id returns a body page. Each note reports truncated; continue with its id and next_body_offset as body_offset until false. Read-only; requires Notes → Read permission.","class":"read","irreversible":false,"screen":false,"args":{"type":"object","properties":{"query":{"type":"string","description":"Words to find in titles or text; blank lists recent notes."},"title":{"type":"string","description":"Exact note title: returns a body page."},"id":{"type":"string","description":"A note's id from an earlier result: returns a body page of that exact note."},"body_offset":{"type":"integer","description":"UTF-16 offset from next_body_offset; requires the same note id. Omit to read from the start."},"limit":{"type":"integer","description":"Maximum notes to return (1-50, default 10)."}},"required":[],"additionalProperties":false}},
 "notes.create":{"description":"Create a new Apple Note with title + body, optionally in a named folder. Requires Notes → Write permission (off by default).","class":"write","irreversible":false,"screen":false,"args":{"type":"object","properties":{"title":{"type":"string","description":"Note title (required)."},"body":{"type":"string","description":"Note body content (required)."},"folder":{"type":"string","description":"Optional folder name; created in the default folder when omitted. A named folder that does not exist is an error listing the folders that do — it is never silently swapped for the default."}},"required":["title","body"],"additionalProperties":false}},
 "notes.update":{"description":"Update one Apple Note by id from notes.search or a unique exact title. Supply body, append, new_title or clear_fields:[\"body\"]. Clearing empties the body and cannot be combined with body/append. Requires Notes → Write permission (off by default).","class":"write","irreversible":false,"screen":false,"args":{"type":"object","properties":{"id":{"type":"string","description":"The note's id from notes.search; use it when two notes share a title."},"title":{"type":"string","description":"Exact title of the note to update (as notes.search shows it)."},"body":{"type":"string","description":"Replace the note's text under its title; the title stays unless new_title is given."},"append":{"type":"string","description":"Add this as a new line at the end of the note."},"new_title":{"type":"string","description":"Rename the note to this title."},"clear_fields":{"type":"array","items":{"type":"string","enum":["body"]},"description":"[\"body\"] is a valid update by itself; empties the body. Cannot combine with body or append."}},"required":[],"additionalProperties":false}},
 "notes.delete":{"description":"Delete one Apple Note by id or an exact title only one note has. Moves it to Recently Deleted, where it can be restored; returns that reversible outcome. Requires Notes → Write permission (off by default).","class":"write","irreversible":false,"screen":false,"args":{"type":"object","properties":{"id":{"type":"string","description":"The note's id from notes.search; use it when two notes share a title."},"title":{"type":"string","description":"Exact title of the note to delete; duplicate titles refuse without changing anything."}},"required":[],"additionalProperties":false,"allOf":[{"anyOf":[{"required":["id"]},{"required":["title"]}]}]}}},
 "record":{"description":"Apple Notes: find, read, create, update and delete notes through the app's own scripting, with named read gaps and recovery wording for every refusal.","actions":[]}}
*/
const NOTES = "com.apple.Notes";
// Setup and folder refusals travel as these markers because a script's reply is one value.
const NOT_CONFIGURED = "__NATIVEAGENT_NOTES_NOT_CONFIGURED__";
const FOLDER_MISSING = "__NATIVEAGENT_NOTES_FOLDER_MISSING__";
// Notes' own failures the script must pass up unchanged: permission, timeout and cancellation codes.
const PASSED_UP = "{-1743, -1744, -600, -609, -1712, -128}";
const WORDS = {
    "missing_body": "Nothing to send or save: put the text in body.",
    "missing_title": "Give the note's title.",
    "no_matching_note": "No note has that exact id or title; find it with notes.search and copy its full id or title.",
    "invalid_note_body_offset": "Use body_offset with the same note id and next_body_offset from its last read; the offset must be within the current text.",
    "missing_body_append_or_new_title": "Say what to change: body (replace), append, or new_title.",
    "body_and_append_mutually_exclusive": "Use body to replace or append to add, not both."
};
const NO_DEFAULT_FOLDER = "The default Notes account has no default folder; make that destination available in Notes before creating a note.";
// Foundation's whitespaceAndNewlineCharacterSet and newlines set.
const SPACE = "\\t\\n\\u000b\\f\\r \\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000";
const TRIM = new RegExp("^[" + SPACE + "]+|[" + SPACE + "]+$", "g");
const TRIM_NEWLINES = /^[\n\u000b\f\r\u0085\u2028\u2029]+|[\n\u000b\f\r\u0085\u2028\u2029]+$/g;

const trim = value => value.replace(TRIM, "");
const text = value => typeof value === "string" ? value : typeof value === "number" || typeof value === "boolean" ? String(value) : undefined;
// Text becomes literal AppleScript content: backslashes first, then quotes and line breaks.
const escape = value => value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\r\n/g, "\\n").replace(/\n/g, "\\n").replace(/\r/g, "\\r");
const html = value => value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;")
    .replace(/\r\n/g, "\n").replace(/\r/g, "\n").replace(/\n/g, "<br>");

function failed(reason, message) {
    const words = WORDS[reason] === undefined ? message : WORDS[reason];
    const result = {status:"failed", integration:"notes", reason, effects:"none"};
    if (words !== undefined) result.message = words;
    return result;
}

// The runner's receipt keeps effect evidence, consent cards and unknown outcomes.
function appFailure(error) {
    if (error.name !== "AppError" || error.reason === "cancelled" || !error.receipt || typeof error.receipt !== "object") throw error;
    return Object.assign({integration:"notes"}, error.receipt);
}

function script(source, readOnly) {
    return host.apps.call({bundle_id:NOTES, script:source, launch:true, read_only:readOnly}).value;
}

// A supplied number must be an integer; the default applies only when it is omitted.
function clamp(raw, fallback, min, max) {
    let value = fallback;
    if (raw !== undefined && raw !== null) {
        value = typeof raw === "number" ? raw : typeof raw === "string" && /^\s*[+-]?\d+\s*$/.test(raw) ? Number(raw.trim()) : NaN;
        if (!Number.isInteger(value)) {
            throw new Error("A supplied numeric limit, offset or duration is not an integer. Correct the argument; defaults apply only when omitted.");
        }
    }
    return Math.max(min, Math.min(max, value));
}

// An AppleScript date crosses as numbers, {year, month, day, seconds since midnight} (DATE_PARTS), never as the Mac's localized text, so it
// reads the same on every Mac whatever its language or region. The instant is built in the Mac's time zone, as Notes shows it.
const DATE_PARTS = date => `{year of ${date}, (month of ${date}) as integer, day of ${date}, time of ${date}}`;

// The four numbers become an ISO instant, or this throws with what came back; a caller keeps its row and marks that date unknown.
function appleDate(parts) {
    if (typeof parts === "string") throw new Error(parts === "" ? "Notes returned no date." : parts);
    if (!Array.isArray(parts) || parts.length !== 4 || !parts.every(Number.isInteger)) {
        throw new Error("Notes returned a date that is not four whole numbers (year, month, day, seconds since midnight).");
    }
    const [year, month, day, seconds] = parts;
    const hour = Math.floor(seconds / 3600), minute = Math.floor(seconds % 3600 / 60), second = seconds % 60;
    const built = new Date(year, month - 1, day, hour, minute, second);
    if (year < 1 || year > 9999 || month < 1 || month > 12 || seconds < 0 || seconds > 86399 || Number.isNaN(built.getTime())
        || built.getFullYear() !== year || built.getMonth() !== month - 1 || built.getDate() !== day) {
        throw new Error("Notes returned an impossible date: " + parts.join(", ") + ".");
    }
    return built.toISOString().replace(/\.\d{3}Z$/, "Z");
}

// The first line's length counting its terminator, as Foundation's line range does.
function firstLineLength(value) {
    const match = /[\n\r\u0085\u2028\u2029]/.exec(value);
    if (!match) return value.length;
    return match.index + (value[match.index] === "\r" && value[match.index + 1] === "\n" ? 2 : 1);
}

// A page starts after the stored title line and ends on a whole composed character, so Unicode is never split.
// Offsets and totals count UTF-16 units, including the title line.
function pageOf(body, name, offset, previewChars) {
    const total = body.length;
    if (offset > total) return undefined;
    let start = offset, elided = false;
    if (total > 0) {
        const line = firstLineLength(body);
        if (trim(body.slice(0, line)) === trim(name) && start < line) {
            start = line;
            elided = true;
        }
    }
    let end = start + Math.min(total - start, previewChars);
    if (end > start) {
        const edges = [0];
        for (const part of new Intl.Segmenter("en", {granularity:"grapheme"}).segment(body)) edges.push(part.index + part.segment.length);
        start = edges.reduce((best, edge) => edge <= start ? edge : best, 0);
        end = edges.find(edge => edge >= end);
    }
    return {start, end, total, elided};
}

function readScript(selection, limit) { return `
if (count of accounts) is 0 then return "${NOT_CONFIGURED}"
if (count of folders) is 0 then return "${NOT_CONFIGURED}"
set gaps to {}
set hits to ${selection}
-- A deleted note stays readable in Recently Deleted; it is not one of the person's notes.
-- A note's folder comes from the folders' own note ids: Notes can't coerce
-- "name of container" of an account note (-1700), so that read was never a source.
set folderNames to {}
set folderNoteIDs to {}
repeat with fi from 1 to (count of folders)
    try
        set f to folder fi
        set fName to (name of f) as string
        set fIDs to (id of notes of f)
        set end of folderNames to fName
        set end of folderNoteIDs to fIDs
    on error errorText number errorNumber
        if errorNumber is in ${PASSED_UP} then error errorText number errorNumber
        set end of gaps to ("folders[" & fi & "]: " & errorText & " (" & errorNumber & ")")
    end try
end repeat
set keptHits to {}
repeat with i from 1 to (count of hits)
    try
        set h to item i of hits
        set hid to (id of h) as string
        set fd to missing value
        repeat with k from 1 to (count of folderNames)
            if (item k of folderNoteIDs) contains hid then
                set fd to item k of folderNames
                exit repeat
            end if
        end repeat
        if fd is missing value then
            set end of gaps to ("notes[" & i & "].folder: in no readable folder, so it can't be told apart from a deleted note")
        else if fd is not "Recently Deleted" then
            set end of keptHits to {contents of h, fd}
        end if
    on error errorText number errorNumber
        if errorNumber is in ${PASSED_UP} then error errorText number errorNumber
        set end of gaps to ("notes[" & i & "]: " & errorText & " (" & errorNumber & ")")
    end try
end repeat
set hits to keptHits
set totalHits to count of hits
set rows to {}
set countNote to 0
repeat with i from 1 to totalHits
    if countNote ≥ ${limit} then exit repeat
    try
        set candidate to item i of hits
        set n to item 1 of candidate
        set fd to item 2 of candidate
        set nid to (id of n) as string
        set nm to (name of n) as string
        -- A date that cannot be read travels as its error text, so the note is kept with its date unknown.
        try
            set modifiedDate to modification date of n
            set md to ${DATE_PARTS("modifiedDate")}
        on error errorText number errorNumber
            if errorNumber is in ${PASSED_UP} then error errorText number errorNumber
            set md to ("modification date: " & errorText & " (" & errorNumber & ")")
        end try
        set end of rows to {nid, nm, md, fd, ((plaintext of n) as string)}
        set countNote to countNote + 1
    on error errorText number errorNumber
        if errorNumber is in ${PASSED_UP} then error errorText number errorNumber
        set end of gaps to ("kept_notes[" & i & "]: " & errorText & " (" & errorNumber & ")")
    end try
end repeat
return {totalHits, rows, gaps}
`; }

// Read gaps stay named: a note that cannot be read never hides the others, and the total is then incomplete. A note whose date cannot be
// read is not a gap: it returns with modified_at null and modified_at_unknown saying why.
function read(selection, limit, whole, offset) {
    const value = script(readScript(selection, limit), true);
    if (typeof value === "string" && trim(value) === NOT_CONFIGURED) {
        return {status:"failed", integration:"notes", reason:"not_configured", fix:"Open Notes and enable an iCloud or local Notes account."};
    }
    if (!Array.isArray(value) || value.length !== 3 || !Number.isInteger(value[0]) || value[0] < 0 || !Array.isArray(value[1])
        || value[1].length > value[0] || !Array.isArray(value[2]) || !value[2].every(gap => typeof gap === "string" && gap !== "")) {
        return {status:"failed", integration:"notes", error_code:-1, error:"Notes returned invalid JSON records."};
    }
    const total = value[0], gaps = value[2].slice(), rows = [];
    const wide = whole || total === 1;
    for (const [index, row] of value[1].entries()) {
        // Every field is text except the modification date, which is its numbers or the text of why it could not be read.
        if (!Array.isArray(row) || row.length !== 5 || ![0, 1, 3, 4].every(at => typeof row[at] === "string") || row[0] === ""
            || !(typeof row[2] === "string" || Array.isArray(row[2]))) {
            gaps.push("notes[" + index + "]: Notes returned an incomplete JSON record.");
            continue;
        }
        const [id, name, modified, folder, body] = row;
        const page = pageOf(body, name, offset, wide ? 4000 : 200);
        if (!page) return failed("invalid_note_body_offset");
        // A date that does not read keeps its note: the date is unknown, never a guess, and the note is not a missing note.
        let modifiedAt = null, dateUnknown;
        try { modifiedAt = appleDate(modified); }
        catch (error) { dateUnknown = error.message; }
        const note = {name, [wide ? "body" : "body_preview"]:body.slice(page.start, page.end), modified_at:modifiedAt, folder, id,
            body_offset:page.start, body_total:page.total, title_line_elided:page.elided, truncated:page.end < page.total};
        if (dateUnknown !== undefined) note.modified_at_unknown = dateUnknown;
        if (page.end < page.total) note.next_body_offset = page.end;
        rows.push(note);
    }
    const result = {status:gaps.length ? "partial" : "completed", source:"applescript",
        access:{automation:"confirmed", operation:"read", note_records:rows.length},
        count:rows.length, total, notes:rows, gaps, total_is_complete:gaps.length === 0};
    if (total > rows.length) result.message = "Showing " + rows.length + " of " + total + "; narrow with query, or read one with title.";
    // No matching title or id is a successful empty read.
    if (whole && rows.length === 0 && gaps.length === 0) result.message = "No note has that title or id.";
    if (gaps.length) result.message = "Readable notes returned with named gaps. Missing notes and the complete match total are unknown; "
        + "repair the reported Notes reads.";
    return result;
}

// A continuation names the exact note id, so paging can never switch between identically titled notes.
function search(input) {
    const limit = clamp(input.limit, 10, 1, 50);
    const id = trim(text(input.id) || "");
    let offset = 0;
    if (input.body_offset !== undefined && input.body_offset !== null) {
        if (id === "" || !Number.isInteger(input.body_offset) || input.body_offset < 0) return failed("invalid_note_body_offset");
        offset = input.body_offset;
    }
    // A note's own id reads exactly that note, whatever else shares its title.
    if (id !== "") return read('notes whose id is "' + escape(id) + '"', 1, true, offset);
    const title = trim(text(input.title) || "");
    if (title !== "") return read('notes whose name is "' + escape(title) + '"', 1, true, 0);
    const query = trim(text(input.query) || "");
    if (query === "") return read("notes", limit, false, 0);
    const q = escape(query);
    return read('notes whose (name contains "' + q + '") or (body contains "' + q + '")', limit, false, 0);
}

// An omitted or blank folder uses Notes' default; a named folder that cannot be resolved never does.
function create(input) {
    const title = text(input.title);
    if (!title) return failed("missing_title");
    const body = text(input.body);
    if (body === undefined) return failed("missing_body");
    const given = text(input.folder);
    const requested = given === undefined ? undefined : trim(given);
    const named = requested !== undefined && requested !== "";
    const destination = named ? `
set matchingFolders to folders whose name is "${escape(requested)}"
if (count of matchingFolders) is 0 then
    set folderNames to ""
    repeat with f in folders
        set fName to (name of f as string)
        if fName is not "Recently Deleted" then
            set folderNames to folderNames & fName & "###"
        end if
    end repeat
    return "${FOLDER_MISSING}" & folderNames
end if
if (count of matchingFolders) is not 1 then error "Several Notes folders have that name; no note was created. Choose a unique folder name."
set targetFolder to item 1 of matchingFolders` : `
set targetAccount to default account
if targetAccount is missing value then error "Notes has no default account; choose its default account in Notes before creating a note."
set targetFolder to default folder of targetAccount
if targetFolder is missing value then error "${NO_DEFAULT_FOLDER}"`;
    const value = script(`${destination}
-- Resolve the destination before the single create command.
set destinationID to (id of targetFolder) as text
tell targetFolder
    set newNote to make new note with properties {name:"${escape(title)}", body:"${escape(html(body))}"}
end tell
return "created|" & (id of newNote as string)`, false);
    if (named && typeof value === "string" && value.startsWith(FOLDER_MISSING)) {
        const names = value.slice(FOLDER_MISSING.length).split("###").map(trim).filter(name => name !== "");
        return {status:"failed", integration:"notes", effects:"none", reason:"folder_not_found",
            detail:"No Notes folder is named that, so nothing changed; use one of available_folders.",
            requested_folder:requested, available_folders:names};
    }
    // The new note's own id is returned so later reads and changes cannot select another note.
    if (typeof value !== "string" || !value.startsWith("created|") || value.length <= "created|".length) {
        return {status:"outcome_unknown", integration:"notes", effects:"unknown", reason:"unexpected_note_create_result",
            message:"Notes returned an unrecognized creation result. Read the intended folder before trying again."};
    }
    return {status:"completed", action:"created", title, id:value.slice("created|".length)};
}

function mutationUnknown(input, deleting) {
    const requested = {};
    for (const key of ["id", "title"]) if (input[key] !== undefined) requested[key] = input[key];
    return {status:"outcome_unknown", integration:"notes", effects:"unknown", reason:"unexpected_note_mutation_result", requested_note:requested,
        action:deleting ? "moved_to_recently_deleted" : "updated",
        message:"Notes returned an unrecognized change result. Check the note" + (deleting ? " and Recently Deleted" : "") + " before trying again."};
}

// Notes derives its name from the first HTML line, so a body write keeps that line (read from the exact note by id)
// unless the new body already starts with the note's name.
const TITLE_HTML = `
set titleHTML to ""
repeat with titleCharacter in characters of ((name of targetNote) as text)
    set titleText to titleCharacter as text
    if titleText is "&" then
        set titleText to "&amp;"
    else if titleText is "<" then
        set titleText to "&lt;"
    else if titleText is ">" then
        set titleText to "&gt;"
    end if
    set titleHTML to titleHTML & titleText
end repeat`;

// The first line ends at a lone line feed; a carriage return and line feed pair is one character.
function firstLine(value) {
    for (let index = 0; index < value.length; index++) if (value[index] === "\n" && value[index - 1] !== "\r") return value.slice(0, index);
    return value;
}

// Updates and reversible deletion require one exact note. The whole change happens inside one script, so no note text
// is ever read into the part and written back.
function modify(input, deleting) {
    const id = trim(text(input.id) || "");
    const title = text(input.title) === undefined ? "" : text(input.title);
    if (id === "" && title === "") return failed("missing_title");
    let body = text(input.body);
    const append = text(input.append), newTitle = text(input.new_title);
    // A declared clear of the body is an empty body.
    if (!deleting && body === undefined && Array.isArray(input.clear_fields) && input.clear_fields.includes("body")) body = "";
    if (!deleting && body === undefined && append === undefined && (newTitle === undefined || newTitle === "")) {
        return failed("missing_body_append_or_new_title");
    }
    if (body !== undefined && append !== undefined) return failed("body_and_append_mutually_exclusive");
    let bodyStatement = "";
    if (body !== undefined) {
        if (body === "") bodyStatement = TITLE_HTML + '\nset body of targetNote to "<div>" & titleHTML & "</div>"';
        else {
            const bodyText = escape(html(body));
            bodyStatement = TITLE_HTML + `
if "${escape(firstLine(body))}" is ((name of targetNote) as text) then
    set body of targetNote to "<div>${bodyText}</div>"
else
    set body of targetNote to "<div>" & titleHTML & "</div><div>${bodyText}</div>"
end if`;
        }
    } else if (append !== undefined) {
        // One new line after the existing body, however many newlines the caller added.
        bodyStatement = 'set body of targetNote to ((body of targetNote) as string) & "<div>' + escape(html(append.replace(TRIM_NEWLINES, ""))) + '</div>"';
    }
    const renameStatement = newTitle !== undefined && newTitle !== "" ? 'set name of targetNote to "' + escape(newTitle) + '"' : "";
    const value = script(`
set hits to ${id === "" ? '(notes whose name is "' + escape(title) + '")' : '(notes whose id is "' + escape(id) + '")'}
if (count of hits) is 0 then return "0"
if (count of hits) > 1 then return "-3|" & ((count of hits) as text)
set targetNote to first item of hits
set targetID to (id of targetNote) as text
if ${deleting} then
    set finalName to (name of targetNote) as text
    delete targetNote
    return {targetID, "ok", finalName}
else
    ${bodyStatement}
    ${renameStatement}
    try
        set finalName to (name of targetNote) as text
    on error errText number errNum
        return {targetID, "readback_failed", errText, errNum}
    end try
    return {targetID, "ok", finalName}
end if`, false);
    const raw = typeof value === "string" ? trim(value) : undefined;
    if (raw === "0") return failed("no_matching_note");
    // Ambiguous note titles leave every match unchanged.
    const several = raw === undefined ? null : /^-3\|(\d+)$/.exec(raw);
    if (several && Number(several[1]) > 1) {
        return {status:"failed", integration:"notes", reason:"several_notes_match",
            message:several[1] + ' notes are titled "' + title + '", so nothing changed. Pass the id of one from notes.search.'};
    }
    // This is after the effect: a reply of any other shape cannot prove no match or no change.
    if (!Array.isArray(value) || typeof value[0] !== "string" || value[0] === "") return mutationUnknown(input, deleting);
    const result = {id:value[0]};
    if (value.length === 3 && value[1] === "ok" && typeof value[2] === "string") result.title = value[2];
    else if (!deleting && value.length === 4 && value[1] === "readback_failed" && typeof value[2] === "string" && Number.isInteger(value[3])) {
        result.readback = {status:"failed", error:value[2], error_code:value[3]};
        result.message = "The note was updated, but Notes could not read its resulting title. Read this exact id before relying on its current "
            + "metadata; do not repeat the update.";
    } else return mutationUnknown(input, deleting);
    result.status = "completed";
    result.action = deleting ? "moved_to_recently_deleted" : "updated";
    result.recovery = deleting ? "Restore the note from Recently Deleted in Notes." : null;
    return result;
}

function run(input) {
    try {
        if (input.verb === "notes.search") return search(input);
        if (input.verb === "notes.create") return create(input);
        if (input.verb === "notes.update") return modify(input, false);
        if (input.verb === "notes.delete") return modify(input, true);
    } catch (error) { return appFailure(error); }
    throw new Error("native-notes answers notes.search, notes.create, notes.update and notes.delete.");
}
