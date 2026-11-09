/* NativeAgent ability
{"id": "music", "kind": "ability", "version": 2, "reach": {"capabilities": ["app_write:com.apple.Music"]}, "face": {"page": "music"},
 "record": {"description": "Play, pause, stop or skip Music; bound play with seconds through the native player call, resolve an exact library track, and read playback through music-library.", "actions": ["music.now_playing"]},
 "answers": {
 "music.control": {"summary": "Play, pause, stop or skip; play takes seconds (1–30) and stops itself", "description": "Play, pause, stop or skip in Apple Music. Play a playlist or exact song by name; seconds bounds play and stops Music itself before returning. Returns playback afterward. Requires Music → Write permission.", "class": "write", "irreversible": false, "screen": true, "args": {"type": "object", "properties": {"action": {"type": "string", "enum": ["play", "pause", "stop", "toggle", "next", "previous"], "description": "play / pause / stop / toggle / next / previous. Stop ends playback; pause retains its position. Default play when playlist or track is given; with nothing given it only reports what's playing."}, "playlist": {"type": "string", "description": "Playlist name to play."}, "track": {"type": "string", "description": "Exact song name to play; several with that name play nothing and are listed."}, "artist": {"type": "string", "description": "Artist, to pick among songs with the same name."}, "seconds": {"type": "integer", "minimum": 1, "maximum": 30, "description": "Play only: 1–30 whole seconds, then stop through Music's player before returning. Starts the selected song (or the first song of playlist) at the beginning. Stop/cancellation also settles the stop; a different track taken over by someone else is left alone."}}, "required": []}}
 }}
*/
const escape = value => value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n").replace(/\r/g, "\\r");
const failed = reason => ({status:"failed", integration:"music", reason, effects:"none"});

function script(source) {
    return host.apps.call({bundle_id:"com.apple.Music", script:source, launch:true, read_only:true}).value;
}

function errorResult(error) {
    if (error.name === "MusicReadError") return Object.assign(failed("malformed_music_selection"), {detail:error.message});
    // The native envelope retains effect evidence, consent cards and unknown outcomes.
    if (error.name !== "AppError" || error.reason === "cancelled") throw error;
    return error.receipt;
}

function checked(condition, field) {
    if (!condition) {
        const error = new Error("Music returned an invalid " + field + "; nothing was selected or played.");
        error.name = "MusicReadError";
        throw error;
    }
}
function selection(raw, width, field) {
    checked(Array.isArray(raw) && raw.length === 2 && Number.isSafeInteger(raw[0]) && raw[0] >= 0 && Array.isArray(raw[1]), field);
    const total = raw[0], rows = raw[1];
    checked(rows.length === Math.min(total, 6), field + ".rows");
    rows.forEach((row, index) => {
        checked(Array.isArray(row) && row.length === width, field + ".row[" + index + "]");
        checked(typeof row[0] === "string" && /^[0-9A-Fa-f]{16}$/.test(row[0]), field + ".persistent_id[" + index + "]");
        checked(row.slice(1).every(value => typeof value === "string"), field + ".metadata[" + index + "]");
    });
    return {total, rows};
}

function pickTrack(name, artist) {
    const {total, rows} = selection(script(pickScript(name, artist)), 3, "track selection");
    if (total === 1) return {id:rows[0][0]};
    const shown = rows.map(row => '"' + row[1] + '" by ' + row[2]).join(", ");
    return {refusal:Object.assign(failed(total ? "ambiguous" : "not_found"), {matches:total,
        fix:total ? total + ' tracks match "' + name + '"' + (artist ? ' by "' + artist + '"' : "") + ': ' + shown + ". Select a unique title and artist in Music."
            : 'No library track matches the exact title "' + name + '"' + (artist ? ' and artist "' + artist + '"' : "") + ". music.search shows library names."})};
}

function pickPlaylist(name) {
    const {total, rows} = selection(script(playlistScript(name)), 2, "playlist selection");
    if (total === 1) return {id:rows[0][0]};
    return {refusal:Object.assign(failed(total ? "ambiguous_playlist" : "playlist_not_found"), {matches:total, playlists:rows.map(row => row[1]),
        fix:total ? 'More than one playlist is named "' + name + '". Rename one in Music to select it exactly.' : 'No playlist is named "' + name + '". music.playlists shows library names.'})};
}

function control(input) {
    if (Object.keys(input).some(key => !["action", "playlist", "track", "artist", "seconds"].includes(key))) return failed("unknown_input_field");
    if (["action", "playlist", "track", "artist"].some(key => input[key] !== undefined && typeof input[key] !== "string")) return failed("invalid_input");
    const playlist = input.playlist === undefined ? "" : input.playlist, track = input.track === undefined ? "" : input.track, artist = input.artist === undefined ? "" : input.artist;
    const action = input.action === undefined ? (playlist || track ? "play" : "") : input.action;
    const seconds = input.seconds;
    if (seconds !== undefined && (!Number.isInteger(seconds) || seconds < 1 || seconds > 30 || action !== "play"))
        return Object.assign(failed("invalid_seconds"), {fix:"seconds takes a whole number from 1 through 30 with play only."});
    if ((playlist && track) || (artist && !track) || (action !== "play" && (playlist || track))) return failed("conflicting_selection");
    if (input.action === undefined && !playlist && !track) return {status:"completed", action_performed:"none", now_playing:nowPlaying(), actions:"action play/pause/stop/toggle/next/previous, or playlist or track (with artist) to play one by name; play takes seconds (1–30) and stops itself"};
    if (!["play", "pause", "stop", "toggle", "next", "previous"].includes(action)) return failed("unknown_action");
    let command, selectedID;
    if (action === "play") {
        if (playlist) {
            const pick = pickPlaylist(playlist);
            if (pick.refusal) return pick.refusal;
            const target = 'first playlist whose persistent ID is "' + escape(pick.id) + '"';
            if (seconds !== undefined) selectedID = script('return persistent ID of track 1 of (' + target + ')');
            else command = 'play (' + target + ')';
        } else if (track) {
            const pick = pickTrack(track, artist);
            if (pick.refusal) return pick.refusal;
            selectedID = pick.id;
            command = 'play (first track of library playlist 1 whose persistent ID is "' + escape(selectedID) + '")';
        } else if (seconds !== undefined) selectedID = script('return persistent ID of current track');
        else command = "play";
    } else if (action === "pause") command = "pause";
    else if (action === "stop") command = "stop";
    else if (action === "toggle") command = "playpause";
    else if (action === "next") command = "next track";
    else if (action === "previous") command = "previous track";
    if (seconds !== undefined) {
        checked(typeof selectedID === "string" && /^[0-9A-Fa-f]{16}$/.test(selectedID), "bounded track identity");
        command = 'play (first track of library playlist 1 whose persistent ID is "' + escape(selectedID) + '") with once';
    }
    const call = {bundle_id:"com.apple.Music", script:controlScript(command, seconds !== undefined), launch:true, read_only:false};
    // The stem holds the player for seconds, then settles; Stop ends the wait early and the settle still runs.
    if (seconds !== undefined) call.hold = {seconds, settle:settleScript(selectedID)};
    const receipt = host.apps.call(call), now = nowPlaying();
    // The act's receipt stays true even when its separate readback fails.
    const result = {status:"completed", action_performed:action, effects:receipt.effects, control_receipt:receipt, now_playing:now};
    if (seconds !== undefined) {
        result.seconds = seconds;
        if (receipt.hold && receipt.hold.state === "settle_failed") return Object.assign(result, {status:"failed", reason:"bounded_stop_failed",
            fix:"Music started, but its bounded stop could not be confirmed. Read Music before doing anything again."});
        // A play that sent no write event holds nothing: no hold receipt, nothing bounded.
        result.bounded_outcome = receipt.hold ? receipt.hold.outcome : "not_started";
        if (receipt.hold && receipt.hold.cancelled) Object.assign(result, {status:"cancelled", reason:"cancelled"});
    }
    if (playlist) result.playlist = playlist;
    if (track) result.track = track;
    if (now.status !== "completed") return result;
    const notStarted = action === "play" && (seconds !== undefined ? receipt.value !== "ok|||" + selectedID : !(now.isPlaying && now.track));
    if (notStarted) Object.assign(result, {status:"failed", reason:"playback_not_started", fix:"Music has not started a track. Open Music and check that the selection is playable."});
    return result;
}

function controlScript(command, bounded) { return `
    ${command}
    ${bounded ? 'repeat 30 times\n        if player state is playing then exit repeat\n        delay 0.1\n    end repeat\n    if player state is not playing then return "not_started"\n    set player position to 0\n    return "ok|||" & (persistent ID of current track)' : 'return "ok"'}
`; }

// The settle stops only the track this call started; a different track belongs to whoever took over.
function settleScript(trackID) { return `
if player state is stopped then return "already_stopped"
if (persistent ID of current track) is not "${escape(trackID)}" then return "playback_changed"
stop
return "stopped"
`; }

// Music owns exact, case-insensitive title/artist equality and the COMPLETE count.
// Only the refusal's display rows are limited. No contains-query retry.
function pickScript(name, artist) { return `
with timeout of 10 seconds
    ignoring case
        set hits to (every track of library playlist 1 whose name is "${escape(name)}"${artist ? ' and artist is "' + escape(artist) + '"' : ""})
    end ignoring
    set totalHits to count of hits
    set rows to {}
    repeat with rowIndex from 1 to totalHits
        if (count of rows) ≥ 6 then exit repeat
        set trackItem to item rowIndex of hits
        set end of rows to {persistent ID of trackItem, name of trackItem, artist of trackItem}
    end repeat
    return {totalHits, rows}
end timeout
`; }

function playlistScript(name) { return `
with timeout of 10 seconds
    ignoring case
        set hits to (every playlist whose name is "${escape(name)}")
    end ignoring
    set totalHits to count of hits
    set rows to {}
    repeat with rowIndex from 1 to totalHits
        if (count of rows) ≥ 6 then exit repeat
        set playlistItem to item rowIndex of hits
        set end of rows to {persistent ID of playlistItem, name of playlistItem}
    end repeat
    return {totalHits, rows}
end timeout
`; }
function nowPlaying() {
    // The read is the door's music.now_playing, answered by music-library.
    try { return app.call("music.now_playing", {}); }
    catch (error) {
        if (error.name !== "AppError" || error.stopped || error.reason === "cancelled") throw error;
        return Object.assign(failed(error.reason), {detail:error.message});
    }
}
function run(input) {
    const args = Object.assign({}, input);
    delete args.verb;
    try { return control(args); }
    catch (error) { return errorResult(error); }
}
