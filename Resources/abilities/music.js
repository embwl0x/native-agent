/* NativeAgent ability
{"id": "music", "kind": "tool", "version": 1, "reach": {"capabilities": ["app_write:com.apple.Music"]}, "face": {"page": "music"}, "record": {"description": "Control Music playback, resolve an exact library track, and verify playback through the read-only music-library part.", "actions": ["authored.music-library"], "inputSchema": {"type": "object", "properties": {"operation": {"type": "string", "enum": ["control"]}, "input": {"type": "object"}}, "required": ["operation", "input"], "additionalProperties": false}}}
*/
const text = value => ["string", "number", "boolean"].includes(typeof value) ? String(value) : "";
const named = value => text(value).trim();
const escape = value => value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\r\n/g, "\\n").replace(/\n/g, "\\n").replace(/\r/g, "\\r");
const failed = reason => ({status:"failed", integration:"music", reason, effects:"none"});

function script(source, launch, readOnly = true) {
    return host.apps.call({bundle_id:"com.apple.Music", script:source, launch, read_only:readOnly}).value;
}

function errorResult(error) {
    // The native envelope retains effect evidence, consent cards and unknown outcomes.
    if (error.name !== "AppError" || error.reason === "cancelled") throw error;
    return error.receipt;
}

// Unicode default full folding, alongside JavaScript's scalar lowercase.
// C/F mappings left after NFD and lowercase; Cherokee folds to uppercase.
// Data: https://www.unicode.org/Public/17.0.0/ucd/CaseFolding.txt
const fullFolds = Object.freeze({
    "\u00b5":"\u03bc", "\u00df":"ss", "\u0149":"\u02bcn", "\u017f":"s", "\u0345":"\u03b9",
    "\u03c2":"\u03c3", "\u03d0":"\u03b2", "\u03d1":"\u03b8", "\u03d5":"\u03c6", "\u03d6":"\u03c0",
    "\u03f0":"\u03ba", "\u03f1":"\u03c1", "\u03f5":"\u03b5", "\u0587":"\u0565\u0582",
    "\u1c80":"\u0432", "\u1c81":"\u0434", "\u1c82":"\u043e", "\u1c83":"\u0441", "\u1c84":"\u0442",
    "\u1c85":"\u0442", "\u1c86":"\u044a", "\u1c87":"\u0463", "\u1c88":"\ua64b", "\u1e9a":"a\u02be",
    "\ufb00":"ff", "\ufb01":"fi", "\ufb02":"fl", "\ufb03":"ffi", "\ufb04":"ffl", "\ufb05":"st", "\ufb06":"st",
    "\ufb13":"\u0574\u0576", "\ufb14":"\u0574\u0565", "\ufb15":"\u0574\u056b", "\ufb16":"\u057e\u0576", "\ufb17":"\u0574\u056d"
});
function folded(value) {
    return Array.from(value.normalize("NFD"), scalar => {
        const lower = scalar.toLowerCase(), code = lower.codePointAt(0);
        if (code >= 0xab70 && code <= 0xabbf) return String.fromCodePoint(code - 0x97d0);
        if (code >= 0x13f8 && code <= 0x13fd) return String.fromCodePoint(code - 8);
        return fullFolds[lower] || lower;
    }).join("").normalize("NFD");
}

function pickTrack(name, artist) {
    const rows = script(pickScript(name), true).split("###").map(entry => entry.split("|||")).filter(p => p.length >= 3)
        .map(p => ({id:p[0].trim(), name:p[1], artist:p[2]}));
    const same = (a,b) => folded(a) === folded(b);
    const exact = rows.filter(row => same(row.name, name) && (!artist || same(row.artist, artist)));
    if (exact.length === 1) return {id:exact[0].id};
    const shown = (exact.length ? exact : rows).slice(0, 6).map(row => '"' + row.name + '" by ' + row.artist).join(", ");
    const fix = exact.length === 0 ? 'No song is named exactly "' + name + '".' + (shown ? " Close: " + shown + ". Give one exactly." : " Search the Apple Music catalog in Music if available, or play it in an existing Chrome tab using browser actions.")
        : exact.length + ' songs are named "' + name + '": ' + shown + ". Add artist to pick one.";
    return {refusal:{status:"failed", integration:"music", reason:exact.length ? "ambiguous" : "not_found", fix}};
}

function control(input) {
    const playlist = named(input.playlist), track = named(input.track === undefined ? (input.song === undefined ? input.query : input.song) : input.track), artist = named(input.artist);
    const action = named(input.action).toLowerCase() || (playlist || track ? "play" : "");
    if (!action) return {status:"completed", action_performed:"none", now_playing:nowPlaying(), actions:"action play/pause/toggle/next/previous, or playlist or track (with artist) to play one by name"};
    let command;
    if (["play", "resume", "start"].includes(action)) {
        if (playlist) command = playlistCommand(playlist);
        else if (track) {
            const pick = pickTrack(track, artist);
            if (pick.refusal) return pick.refusal;
            command = 'play (first track of library playlist 1 whose persistent ID is "' + escape(pick.id) + '")';
        } else command = "play";
    } else if (["pause", "stop"].includes(action)) command = "pause";
    else if (["toggle", "playpause", "play_pause"].includes(action)) command = "playpause";
    else if (["next", "next_track", "skip", "forward"].includes(action)) command = "next track";
    else if (["previous", "prev", "previous_track", "back", "restart"].includes(action)) command = "previous track";
    else return Object.assign(failed("unknown_action"), {fix:"Say play, pause, toggle, next or previous, or give playlist or track to play one by name."});
    let receipt;
    try { receipt = host.apps.call({bundle_id:"com.apple.Music", script:controlScript(command), launch:true, read_only:false}); }
    catch (error) {
        const result = error.receipt && error.receipt.result;
        if (result && result.code === -1728 && (playlist || track)) return {status:"failed", integration:"music", reason:"not_found",
            fix:'Nothing in the library matches "' + (playlist || track) + '". music_list_playlists or music_search_library shows the exact names. Search the Apple Music catalog in Music if available, or play it in an existing Chrome tab using browser actions.', evidence:error.receipt};
        return errorResult(error);
    }
    const raw = receipt.value;
    if (raw.startsWith("missing_playlist|||") || raw.startsWith("ambiguous_playlist|||")) {
        const missing = raw.startsWith("missing_playlist|||"), names = raw.split("|||").slice(1).filter(Boolean);
        return Object.assign(failed(missing ? "playlist_not_found" : "ambiguous_playlist"), {playlists:names,
            fix:missing ? 'No playlist is named "' + playlist + '".' + (names.length ? " Available: " + names.join(", ") + "." : " The library has no playlists.") : 'More than one playlist is named "' + playlist + '". Rename one in Music to select it exactly.'});
    }
    const now = nowPlaying();
    // The act's receipt stays true even when its separate readback fails.
    const result = {status:"completed", action_performed:action, effects:receipt.effects, control_receipt:receipt, now_playing:now};
    if (playlist) result.playlist = playlist;
    if (track) result.track = track;
    if (now.status !== "completed") return result;
    const notStarted = ["play", "resume", "start"].includes(action) && !(now.isPlaying && now.track);
    if (notStarted) Object.assign(result, {status:"failed", reason:"playback_not_started", fix:"Music has not started a track. Open Music and check that the selection is playable."});
    return result;
}

function controlScript(command) { return `
    ${command}
    return "ok"

`; }

function pickScript(name) { return `
with timeout of 10 seconds
        set out to ""
        set hits to (every track of library playlist 1 whose name is "${escape(name)}")
        if (count of hits) is 0 then set hits to (every track of library playlist 1 whose name contains "${escape(name)}")
        set n to 0
        repeat with t in hits
            if n ≥ 12 then exit repeat
            set out to out & (persistent ID of t) & "|||" & (name of t) & "|||" & (artist of t) & "###"
            set n to n + 1
        end repeat
        return out
end timeout
`; }

function playlistCommand(playlist) { return `
set matchingPlaylists to (every playlist whose name is "${escape(playlist)}")
if (count of matchingPlaylists) is 0 then
    set suggestions to ""
    set namesList to name of every playlist
    repeat with i from 1 to (count of namesList)
        if i > 6 then exit repeat
        set suggestions to suggestions & (item i of namesList) & "|||"
    end repeat
    return "missing_playlist|||" & suggestions
end if
if (count of matchingPlaylists) > 1 then return "ambiguous_playlist|||"
play item 1 of matchingPlaylists
`; }
function nowPlaying() {
    const result = part.call("music-library", {operation:"now_playing", input:{}});
    if (!result.ok) return Object.assign(failed(result.error.code), {detail:result.error.message});
    return result.value;
}
function run(request) {
    try { return control(request.input); }
    catch (error) { return errorResult(error); }
}
