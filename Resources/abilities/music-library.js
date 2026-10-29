/* NativeAgent ability
{"id": "music-library", "kind": "tool", "version": 1, "reach": {"capabilities": ["app_read:com.apple.Music"]}, "face": {"page": "music"}, "record": {"description": "Read Music playback state and observed timing; page typed playlists and sorted, filtered library/search results with totals, without opening Music.", "actions": [], "inputSchema": {"type": "object", "properties": {"operation": {"type": "string", "enum": ["search", "library", "playlists", "now_playing"]}, "input": {"type": "object"}}, "required": ["operation", "input"], "additionalProperties": false, "readOnly": true}}}
*/
const text = value => ["string", "number", "boolean"].includes(typeof value) ? String(value) : "";
const escape = value => value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\r\n/g, "\\n").replace(/\n/g, "\\n").replace(/\r/g, "\\r");
const integer = (value, initial, minimum, maximum) => {
    const raw = typeof value === "string" ? (/^[+-]?\d+$/.test(value.trim()) ? Number(value) : NaN)
        : typeof value === "number" ? Math.trunc(value) : NaN;
    return Math.max(minimum, Math.min(maximum, Number.isInteger(raw) && raw >= -9223372036854775808 && raw < 9223372036854775808 ? raw : initial));
};
const number = value => Number.isFinite(Number(value)) ? Number(value) : 0;
const failed = reason => ({status:"failed", integration:"music", reason, effects:"none"});

function script(source, launch, readOnly = true) {
    return host.apps.call({bundle_id:"com.apple.Music", script:source, launch, read_only:readOnly}).value;
}

function errorResult(error) {
    // The native envelope retains effect evidence, consent cards and unknown outcomes.
    if (error.name !== "AppError" || error.reason === "cancelled") throw error;
    return error.receipt;
}

function tracks(raw, paged, offset) {
    return raw.trim().split("###").filter(e => e.trim()).map((entry, index) => {
        const p = entry.trim().split("|||"), start = paged ? 1 : 0;
        const row = {name:p[start] || "", artist:p[start + 1] || "", album:p[start + 2] || "", duration_seconds:number(p[start + 3])};
        if (paged) Object.assign(row, {index:integer(p[0], offset + index + 1, 0, Number.MAX_SAFE_INTEGER), persistent_id:p[5] || ""});
        return row;
    });
}

function page(raw, operation, offset, limit) {
    const pieces = raw.split(":::PAGE:::"), total = integer(pieces.shift(), 0, 0, Number.MAX_SAFE_INTEGER);
    const records = pieces.join(":::PAGE:::");
    const rows = operation === "library" ? tracks(records, true, offset)
        : records.trim().split("###").filter(e => e.trim()).map((entry, index) => {
            const p = entry.trim().split("|||"), count = /^\d+$/.test(p[2] || "") ? Number(p[2]) : "unknown";
            return {index:integer(p[0], offset + index + 1, 0, Number.MAX_SAFE_INTEGER), name:p[1] || "", track_count:count, persistent_id:p[3] || "", special_kind:p[4] || "", kind:p[5]};
        });
    return Object.assign({status:"completed", offset, limit, total, count:rows.length, has_more:offset + rows.length < total, hasMore:offset + rows.length < total}, {[operation === "library" ? "tracks" : "playlists"]:rows});
}

function playbackRead() {
    let raw;
    try { raw = script(nowScript(), false); }
    catch (error) {
        if (error.reason === "not_running") return {status:"completed", isPlaying:false, playerState:"stopped", track:null, reason:"Music isn't open."};
        const result = error.receipt && error.receipt.result;
        if (result && result.code === -1751) return {status:"completed", isPlaying:false, playerState:"unknown", track:null, reason:"no_current_track"};
        return errorResult(error);
    }
    if (!raw.trim()) return {status:"completed", isPlaying:false, playerState:"unknown", track:null, reason:"no_current_track"};
    const p = raw.split("|||"), state = p[0].trim(), normalized = state.toLowerCase(), isPlaying = normalized === "playing";
    const unparsed = "Music answered in a shape this read does not know, so the track is unknown. Nothing changed; read it again, and if it repeats, look at Music itself.";
    if (!["playing", "paused", "stopped", "fast forwarding", "fast_forwarding", "rewinding", "unknown"].includes(normalized))
        return {status:"failed", integration:"music", track:null, reason:"malformed_now_playing_response", detail:unparsed};
    if (p.length === 2 && p[1] === "NO_TRACK") return {status:"completed", isPlaying:false, playerState:state, track:null, reason:"no_current_track"};
    if (p.length >= 6) return {status:"completed", isPlaying, playerState:state,
        track:{name:p[1], artist:p[2], album:p[3], duration_seconds:number(p[4]), position_seconds:number(p[5])}};
    if (p.length === 2 && p[1].startsWith("ERR:")) {
        const message = p[1].slice(4), lower = message.toLowerCase();
        if (lower.includes("current track") || lower.includes("class ptrk") || lower.includes("track") && ["can't get", "can’t get", "can't make", "can’t make"].some(s => lower.includes(s)))
            return {status:"completed", isPlaying, playerState:state, track:null, reason:"no_current_track"};
        return {status:"failed", integration:"music", reason:"now_playing_applescript_error", detail:"Music could not read the current track: " + message + ". Nothing changed."};
    }
    return {status:"failed", integration:"music", isPlaying, playerState:state, track:null, reason:"malformed_now_playing_response", detail:unparsed};
}

function nowPlaying() {
    const result = playbackRead(), observed_at = new Date().toISOString();
    if (result.status !== "completed") return result;
    const previous = host.state.get(), state = ["fast forwarding", "fast_forwarding", "rewinding"].includes(result.playerState) ? "playing" : result.playerState;
    if (!["playing", "paused", "stopped"].includes(state)) return Object.assign(failed("playback_state_unavailable"), {track:null, observed_at});
    const track_key = result.track ? [result.track.name, result.track.artist, result.track.album].join("\n") : null;
    const observed_since = previous && previous.state === state && previous.track_key === track_key ? previous.observed_since : observed_at;
    // Music supplies no state-transition date. Do not turn a remembered read
    // into a claim that playback continued unseen between observations.
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
    const raw = script(libraryKeysScript(selection, sort), false);
    if (!Array.isArray(raw) || raw.length !== 2 || !raw.every(Array.isArray) || raw[0].length !== raw[1].length)
        return failed("malformed_library_sort_keys");
    const ordered = raw[0].map((id, index) => ({id, key:raw[1][index], index}));
    ordered.sort((a,b) => (sort === "added" ? Number(b.key) - Number(a.key) : String(a.key).localeCompare(String(b.key), undefined, {sensitivity:"base"})) || a.index - b.index);
    const ids = ordered.slice(offset, offset + limit).map(row => row.id);
    const rows = ids.length ? tracks(script(libraryScript(ids, offset), false), true, offset) : [];
    const total = ordered.length, has_more = offset + rows.length < total;
    return {status:"completed", sort, filter, offset, limit, count:rows.length, total, has_more, hasMore:has_more, tracks:rows};
}

function run(request) {
    const input = request.input, operation = request.operation;
    try {
        if (operation === "now_playing") return nowPlaying();
        if (operation === "search") {
            const query = text(input.query), kind = ["string", "number", "boolean"].includes(typeof input.kind) ? text(input.kind).toLowerCase() : "track";
            if (!query) return Object.assign(failed("missing_query"), {message:"Nothing to search for: give a word or phrase in query."});
            if (!["track", "artist", "album"].includes(kind)) return failed("unknown_kind:" + kind);
            const predicate = kind === "artist" ? "artist contains q" : kind === "album" ? "album contains q" : "name contains q or artist contains q or album contains q";
            const offset = integer(input.offset, 0, 0, 1000000), limit = integer(input.limit, 20, 1, 100);
            const raw = script(searchScript(query, predicate, offset, limit), false), pieces = raw.split(":::PAGE:::");
            const total = integer(pieces.shift(), 0, 0, Number.MAX_SAFE_INTEGER), results = tracks(pieces.join(":::PAGE:::"), false, offset);
            const has_more = offset + results.length < total;
            return {status:"completed", offset, limit, count:results.length, total, has_more, hasMore:has_more, results};
        }
        const offset = integer(input.offset, 0, 0, 1000000), limit = integer(input.limit, 50, 1, 100);
        if (operation === "library") return library(input, offset, limit);
        if (operation !== "playlists") return failed("unknown_operation");
        return page(script(playlistsScript(offset, limit), false), operation, offset, limit);
    } catch (error) {
        if (error.reason === "not_running") return {status:"unavailable", count:0, total:null, has_more:null, reason:"Music isn't open; music.control play opens it."};
        return errorResult(error);
    }
}

function searchScript(query, predicate, offset, limit) { return `
with timeout of 10 seconds
        set searchOutputString to ""
        set q to "${escape(query)}"
        set searchHitsList to (every track of library playlist 1 whose ${predicate})
        set totalHits to count of searchHitsList
        set searchCountedNum to 0
        repeat with hitIndex from ${offset + 1} to totalHits
            if searchCountedNum ≥ ${limit} then exit repeat
            set trackItem to item hitIndex of searchHitsList
            set trackNameString to ""
            set trackArtistString to ""
            set trackAlbumString to ""
            set trackDurationString to ""
            try
                set trackNameString to (name of trackItem) as string
            end try
            try
                set trackArtistString to (artist of trackItem) as string
            end try
            try
                set trackAlbumString to (album of trackItem) as string
            end try
            try
                set trackDurationString to ((duration of trackItem) as string)
            end try
            set searchOutputString to searchOutputString & trackNameString & "|||" & trackArtistString & "|||" & trackAlbumString & "|||" & trackDurationString & "###"
            set searchCountedNum to searchCountedNum + 1
        end repeat
        return (totalHits as string) & ":::PAGE:::" & searchOutputString
end timeout
`; }

function libraryKeysScript(selection, sort) { return `
with timeout of 15 seconds
    set libraryIDs to persistent ID of ${selection}
    ${sort === "added" ? `set addedDates to date added of ${selection}
    set sortKeys to {}
    repeat with addedDate in addedDates
        set end of sortKeys to (year of addedDate) * 10000000000 + ((month of addedDate) as integer) * 100000000 + (day of addedDate) * 1000000 + (time of addedDate)
    end repeat` : "set sortKeys to " + (sort === "title" ? "name" : "artist") + " of " + selection}
    return {libraryIDs, sortKeys}
end timeout
`; }

function libraryScript(ids, offset) { return `
with timeout of 15 seconds
        set libraryOutputString to ""
        set selectedIDs to {${ids.map(id => '"' + escape(id) + '"').join(", ")}}
            repeat with selectedIndex from 1 to (count of selectedIDs)
                set selectedID to item selectedIndex of selectedIDs
                set trackIndexNum to ${offset} + selectedIndex
                set trackItem to first track of library playlist 1 whose persistent ID is selectedID
                set trackNameString to ""
                set trackArtistString to ""
                set trackAlbumString to ""
                set trackDurationString to ""
                set trackPersistentIDString to ""
                try
                    set trackNameString to (name of trackItem) as string
                end try
                try
                    set trackArtistString to (artist of trackItem) as string
                end try
                try
                    set trackAlbumString to (album of trackItem) as string
                end try
                try
                    set trackDurationString to ((duration of trackItem) as string)
                end try
                try
                    set trackPersistentIDString to (persistent ID of trackItem) as string
                end try
                set libraryOutputString to libraryOutputString & trackIndexNum & "|||" & trackNameString & "|||" & trackArtistString & "|||" & trackAlbumString & "|||" & trackDurationString & "|||" & trackPersistentIDString & "###"
            end repeat
        return libraryOutputString
end timeout
`; }

function playlistsScript(offset, limit) { return `
with timeout of 15 seconds
        set totalPlaylistCountString to "0"
        set playlistOutputString to ""
        set totalPlaylistCountNum to count of playlists
        set totalPlaylistCountString to totalPlaylistCountNum as string
        set startIndexNum to ${offset + 1}
        set requestedEndIndexNum to ${offset + limit}
        if startIndexNum is less than or equal to totalPlaylistCountNum then
            set endIndexNum to requestedEndIndexNum
            if endIndexNum is greater than totalPlaylistCountNum then set endIndexNum to totalPlaylistCountNum
            repeat with playlistIndexNum from startIndexNum to endIndexNum
                set playlistItem to playlist playlistIndexNum
                set playlistNameString to ""
                set playlistTrackCountString to "unknown"
                set playlistPersistentIDString to ""
                set playlistSpecialKindString to ""
                set playlistKindString to "library"
                if class of playlistItem is user playlist then
                    if smart of playlistItem then
                        set playlistKindString to "smart"
                    else
                        set playlistKindString to "owner"
                    end if
                end if
                try
                    set playlistNameString to (name of playlistItem) as string
                end try
                try
                    set playlistTrackCountString to ((count of tracks of playlistItem) as string)
                end try
                try
                    set playlistPersistentIDString to (persistent ID of playlistItem) as string
                end try
                try
                    set playlistSpecialKindString to (special kind of playlistItem) as string
                end try
                set playlistOutputString to playlistOutputString & playlistIndexNum & "|||" & playlistNameString & "|||" & playlistTrackCountString & "|||" & playlistPersistentIDString & "|||" & playlistSpecialKindString & "|||" & playlistKindString & "###"
            end repeat
        end if
        return totalPlaylistCountString & ":::PAGE:::" & playlistOutputString
end timeout
`; }

function nowScript() { return `
with timeout of 5 seconds
        set stateLabel to "unknown"
        try
            set stateLabel to (player state as text)
        end try
        if stateLabel is "stopped" then
            return stateLabel & "|||NO_TRACK"
        end if

        try
            set currentTrackRef to current track
            set trackNameString to ""
            set trackArtistString to ""
            set trackAlbumString to ""
            set trackDurationString to "0"
            set playerPositionString to "0"

            try
                set trackNameString to (name of currentTrackRef) as text
            end try
            try
                set trackArtistString to (artist of currentTrackRef) as text
            end try
            try
                set trackAlbumString to (album of currentTrackRef) as text
            end try
            try
                set trackDurationString to ((duration of currentTrackRef) as text)
            end try
            try
                set playerPositionString to ((player position) as text)
            end try

            if trackNameString is "" and trackArtistString is "" and trackAlbumString is "" then
                return stateLabel & "|||NO_TRACK"
            end if
            return stateLabel & "|||" & trackNameString & "|||" & trackArtistString & "|||" & trackAlbumString & "|||" & trackDurationString & "|||" & playerPositionString
        on error errMsg number errNum
            return stateLabel & "|||ERR:" & errNum & ":" & errMsg
        end try
end timeout
`; }
