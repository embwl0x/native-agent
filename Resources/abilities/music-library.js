/* NativeAgent ability
{"id": "music-library", "kind": "ability", "version": 2, "reach": {"capabilities": ["app_read:com.apple.Music"]}, "face": {"page": "music"},
 "record": {"description": "Read Music playback state and observed timing; page typed playlists and sorted, filtered library/search results with totals, without opening Music.", "actions": []},
 "answers": {
 "music.now_playing": {"summary": "Playing, paused or stopped, with first-observed time and current track", "description": "Report playing / paused / stopped first, track and position, since (first observed, not an inferred transition time), and observed_at. Music closed is stopped. Read-only; requires Music → Read permission.", "class": "read", "irreversible": false, "screen": false, "args": {"type": "object", "properties": {}, "required": []}},
 "music.search": {"summary": "Search library tracks with count, total and has_more", "description": "Search the user's Apple Music library by query; returns tracks with count, total and has_more. Read-only; requires Music -> Read permission.", "class": "read", "irreversible": false, "screen": false, "args": {"type": "object", "properties": {"query": {"type": "string", "description": "Search string (required)."}, "kind": {"type": "string", "enum": ["track", "artist", "album"], "description": "What to search for — one of track / artist / album. Defaults to track."}, "limit": {"type": "integer", "description": "Maximum results to return (1-100, default 20)."}, "offset": {"type": "integer", "description": "Zero-based match offset. Defaults to 0."}}, "required": ["query"]}},
 "music.library": {"summary": "Page library tracks; sort title/artist/added and filter artist/album/genre", "description": "Page the Apple Music library with sort and filter applied before paging; returns count, filtered total and has_more. Read-only; requires Music -> Read permission.", "class": "read", "irreversible": false, "screen": false, "args": {"type": "object", "properties": {"offset": {"type": "integer", "description": "Zero-based track offset. Defaults to 0."}, "limit": {"type": "integer", "description": "Maximum tracks to return (1-100, default 50)."}, "sort": {"type": "string", "enum": ["title", "artist", "added"], "description": "Title or artist ascending, or newest added first. Defaults to title; ties retain library order."}, "filter": {"type": "object", "additionalProperties": false, "properties": {"artist": {"type": "string", "description": "Artist contains this text, ignoring case."}, "album": {"type": "string", "description": "Album contains this text, ignoring case."}, "genre": {"type": "string", "description": "Genre contains this text, ignoring case."}}}}, "required": []}},
 "music.playlists": {"summary": "Page playlists labeled owner, smart or library with count and total", "description": "Page Apple Music playlists with names, track counts and kind: owner / smart / library; returns count, total and has_more. Read-only; requires Music -> Read permission.", "class": "read", "irreversible": false, "screen": false, "args": {"type": "object", "properties": {"offset": {"type": "integer", "description": "Zero-based playlist offset. Defaults to 0."}, "limit": {"type": "integer", "description": "Maximum playlists to return (1-100, default 50)."}}, "required": []}}
 }}
*/
const escape = value => value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n").replace(/\r/g, "\\r");
const failed = reason => ({status:"failed", integration:"music", reason, effects:"none"});

function script(source) {
    return host.apps.call({bundle_id:"com.apple.Music", script:source, launch:false, read_only:true}).value;
}

function checked(condition, field) {
    if (!condition) {
        const error = new Error("Music returned an invalid " + field + ". Nothing changed; inspect Music's library before reading again.");
        error.name = "MusicReadError";
        throw error;
    }
}
const tuple = (value, size, field) => checked(Array.isArray(value) && value.length === size, field);
const count = (value, field) => checked(Number.isSafeInteger(value) && value >= 0, field);
const string = (value, field) => checked(typeof value === "string", field);
const id = (value, field) => checked(typeof value === "string" && /^[0-9A-Fa-f]{16}$/.test(value), field);

// Every track read has this one metadata record: [name, artist, album, duration].
// Empty text is real metadata; missing values and failed reads are not text/zero.
function track(raw, field) {
    tuple(raw, 4, field);
    ["name", "artist", "album"].forEach((key, i) => string(raw[i], field + "." + key));
    checked(typeof raw[3] === "number" && Number.isFinite(raw[3]) && raw[3] >= 0, field + ".duration");
    return {name:raw[0], artist:raw[1], album:raw[2], duration_seconds:raw[3]};
}

function page(raw, operation, offset, limit) {
    tuple(raw, 2, operation + " page");
    const total = raw[0], records = raw[1];
    count(total, operation + ".total");
    checked(Array.isArray(records) && records.length === Math.min(limit, Math.max(0, total - offset)), operation + ".rows");
    const rows = records.map((row, i) => {
        const field = operation + ".row[" + (offset + i + 1) + "]";
        if (operation !== "playlists") {
            tuple(row, 2, field);
            id(row[0], field + ".persistent_id");
            const result = Object.assign(track(row[1], field), {persistent_id:row[0]});
            if (operation === "library") result.index = offset + i + 1;
            return result;
        }
        tuple(row, 5, field);
        id(row[0], field + ".persistent_id");
        string(row[1], field + ".name");
        count(row[2], field + ".track_count");
        string(row[3], field + ".special_kind");
        checked(["owner", "smart", "library"].includes(row[4]), field + ".kind");
        return {index:offset + i + 1, persistent_id:row[0], name:row[1], track_count:row[2], special_kind:row[3], kind:row[4]};
    });
    return Object.assign({status:"completed", offset, limit, total, count:rows.length, has_more:offset + rows.length < total},
        {[operation === "search" ? "results" : operation === "library" ? "tracks" : "playlists"]:rows});
}

function playbackRead() {
    let raw;
    try { raw = script(nowScript()); }
    catch (error) {
        // Process absence is observed by the native owner, not inferred from a failed property.
        if (error.reason === "not_running") return {status:"completed", isPlaying:false, playerState:"stopped", track:null, reason:"Music isn't open."};
        throw error;
    }
    tuple(raw, 3, "now_playing");
    const state = raw[0];
    checked(["playing", "paused", "stopped", "fast forwarding", "rewinding"].includes(state), "now_playing.playerState");
    if (state === "stopped") {
        tuple(raw[1], 0, "now_playing.stopped.track");
        tuple(raw[2], 0, "now_playing.stopped.position");
        return {status:"completed", isPlaying:false, playerState:state, track:null, reason:"no_current_track"};
    }
    const current = track(raw[1], "now_playing.track");
    checked(typeof raw[2] === "number" && Number.isFinite(raw[2]) && raw[2] >= 0, "now_playing.position");
    current.position_seconds = raw[2];
    return {status:"completed", isPlaying:state === "playing", playerState:state, track:current};
}

function nowPlaying() {
    const result = playbackRead(), observed_at = new Date().toISOString();
    const previous = host.state.get(), state = ["fast forwarding", "rewinding"].includes(result.playerState) ? "playing" : result.playerState;
    const track_key = result.track ? JSON.stringify([result.track.name, result.track.artist, result.track.album]) : null;
    const observed_since = previous && previous.state === state && previous.track_key === track_key ? previous.observed_since : observed_at;
    // A remembered read is not evidence of playback continuing between reads.
    host.state.set({state, track_key, observed_since});
    return Object.assign({state, since:observed_since, since_basis:"first observed; Music supplies no transition time and continuity between reads is unknown", observed_since, observed_at}, result);
}

function library(input, offset, limit) {
    const sort = input.sort === undefined ? "title" : input.sort;
    if (!["title", "artist", "added"].includes(sort)) return failed("unknown_sort");
    const filter = input.filter === undefined ? {} : input.filter;
    if (!filter || typeof filter !== "object" || Array.isArray(filter) || Object.keys(filter).some(k => !["artist", "album", "genre"].includes(k) || typeof filter[k] !== "string"))
        return Object.assign(failed("invalid_filter"), {message:"filter takes artist, album and/or genre text; matching ignores case and contains all supplied values."});
    const terms = Object.keys(filter).map(k => k + ' contains "' + escape(filter[k]) + '"');
    const selection = "(every track of library playlist 1" + (terms.length ? " whose " + terms.join(" and ") : "") + ")";
    const raw = script(libraryKeysScript(selection, sort));
    tuple(raw, 2, "library sort keys");
    checked(raw.every(Array.isArray) && raw[0].length === raw[1].length, "library sort keys");
    const ordered = raw[0].map((value, index) => {
        id(value, "library.sort.persistent_id[" + index + "]");
        const key = raw[1][index];
        if (sort === "added") count(key, "library.sort.added[" + index + "]");
        else string(key, "library.sort." + sort + "[" + index + "]");
        return {id:value, key, index};
    });
    ordered.sort((a,b) => (sort === "added" ? b.key - a.key : a.key.localeCompare(b.key, undefined, {sensitivity:"base"})) || a.index - b.index);
    const ids = ordered.slice(offset, offset + limit).map(row => row.id);
    const records = ids.length ? script(libraryScript(ids)) : [];
    checked(Array.isArray(records) && records.length === ids.length && records.every((row, i) => Array.isArray(row) && row[0] === ids[i]), "library selected identities");
    return Object.assign(page([ordered.length, records], "library", offset, limit), {sort, filter});
}

// Each answered verb names one read; its args arrive beside the verb.
const operations = {"music.now_playing":"now_playing", "music.search":"search", "music.library":"library", "music.playlists":"playlists"};
function run(input) {
    const operation = operations[input.verb];
    try {
        if (operation === "now_playing") return nowPlaying();
        const offset = input.offset === undefined ? 0 : input.offset, limit = input.limit === undefined ? (operation === "search" ? 20 : 50) : input.limit;
        if (!Number.isInteger(offset) || offset < 0 || offset > 1000000 || !Number.isInteger(limit) || limit < 1 || limit > 100) return failed("invalid_pagination");
        if (operation === "search") {
            const query = input.query, kind = input.kind === undefined ? "track" : input.kind;
            if (typeof query !== "string" || !query) return failed("missing_query");
            if (!["track", "artist", "album"].includes(kind)) return failed("unknown_kind");
            const predicate = kind === "artist" ? "artist contains q" : kind === "album" ? "album contains q" : "name contains q or artist contains q or album contains q";
            return page(script(searchScript(query, predicate, offset, limit)), operation, offset, limit);
        }
        if (operation === "library") return library(input, offset, limit);
        if (operation !== "playlists") return failed("unknown_operation");
        return page(script(playlistsScript(offset, limit)), operation, offset, limit);
    } catch (error) {
        if (error.name === "MusicReadError") return Object.assign(failed("malformed_music_response"), {detail:error.message});
        if (error.name !== "AppError" || error.reason === "cancelled") throw error;
        if (error.reason === "not_running") return {status:"unavailable", reason:"Music isn't open; music.control play opens it.", effects:"none"};
        return error.receipt;
    }
}

// A failed property retains its AppleScript error code and names its row/property.
function property(variable, expression, label) { return `
    try
        set ${variable} to ${expression}
    on error errMsg number errNum
        error ("Music " & ${label} & ": " & errMsg) number errNum
    end try
`; }
function metadata(item, label) { return `
    ${property("trackName", "name of " + item, label + ' & ".name"')}
    ${property("trackArtist", "artist of " + item, label + ' & ".artist"')}
    ${property("trackAlbum", "album of " + item, label + ' & ".album"')}
    ${property("trackDuration", "duration of " + item, label + ' & ".duration"')}
`; }
function trackRow(item, label) { return `
    ${property("trackID", "persistent ID of " + item, label + ' & ".persistent_id"')}
    ${metadata(item, label)}
    set end of rows to {trackID, {trackName, trackArtist, trackAlbum, trackDuration}}
`; }

function searchScript(query, predicate, offset, limit) { return `
with timeout of 10 seconds
    set q to "${escape(query)}"
    set hits to (every track of library playlist 1 whose ${predicate})
    set totalHits to count of hits
    set rows to {}
    repeat with rowIndex from ${offset + 1} to (totalHits)
        if (count of rows) ≥ ${limit} then exit repeat
        set trackItem to item rowIndex of hits
        ${trackRow("trackItem", '"search row " & rowIndex')}
    end repeat
    return {totalHits, rows}
end timeout
`; }

function libraryKeysScript(selection, sort) { return `
with timeout of 15 seconds
    -- Read plural properties from the query, not from a materialized list.
    set libraryIDs to persistent ID of ${selection}
    ${sort === "added" ? `set addedDates to date added of ${selection}
    set sortKeys to {}
    repeat with addedDate in addedDates
        set end of sortKeys to (year of addedDate) * 10000000000 + ((month of addedDate) as integer) * 100000000 + (day of addedDate) * 1000000 + (time of addedDate)
    end repeat` : "set sortKeys to " + (sort === "title" ? "name" : "artist") + " of " + selection}
    return {libraryIDs, sortKeys}
end timeout
`; }

function libraryScript(ids) { return `
with timeout of 15 seconds
    set rows to {}
    set selectedIDs to {${ids.map(value => '"' + escape(value) + '"').join(", ")}}
    repeat with selectedID in selectedIDs
        set trackItem to first track of library playlist 1 whose persistent ID is selectedID
        ${trackRow("trackItem", '"library track " & selectedID')}
    end repeat
    return rows
end timeout
`; }

function playlistsScript(offset, limit) { return `
with timeout of 15 seconds
    set totalPlaylists to count of playlists
    set rows to {}
    repeat with rowIndex from ${offset + 1} to totalPlaylists
        if (count of rows) ≥ ${limit} then exit repeat
        set playlistItem to playlist rowIndex
        set playlistKind to "library"
        if class of playlistItem is user playlist then
            if smart of playlistItem then
                set playlistKind to "smart"
            else
                set playlistKind to "owner"
            end if
        end if
        ${property("playlistID", "persistent ID of playlistItem", '"playlist row " & rowIndex & ".persistent_id"')}
        ${property("playlistName", "name of playlistItem", '"playlist row " & rowIndex & ".name"')}
        ${property("trackCount", "count of tracks of playlistItem", '"playlist row " & rowIndex & ".track_count"')}
        ${property("specialKind", "(special kind of playlistItem) as text", '"playlist row " & rowIndex & ".special_kind"')}
        set end of rows to {playlistID, playlistName, trackCount, specialKind, playlistKind}
    end repeat
    return {totalPlaylists, rows}
end timeout
`; }

function nowScript() { return `
with timeout of 5 seconds
    set stateLabel to player state as text
    if stateLabel is "stopped" then return {stateLabel, {}, {}}
    set trackItem to current track
    ${metadata("trackItem", '"current track"')}
    ${property("trackPosition", "player position", '"current track.position"')}
    return {stateLabel, {trackName, trackArtist, trackAlbum, trackDuration}, trackPosition}
end timeout
`; }
