import Foundation
import AppKit
import PersistenceCore

extension MacAppleScriptBridge {
    // MARK: MUSIC

    /// Search Music.app library by name / artist / album. Required: "query".
    /// Optional: "kind" (one of "track" | "artist" | "album", default
    /// "track"), "limit" (default 20, max 100).
    /// Returns: {status, count, results: [{name, artist, album, duration_seconds}]}.
    public static func musicSearchLibrary(input: [String: JSONValue]) async throws -> JSONValue {
        guard let query = inputString(input["query"]), !query.isEmpty else {
            return failedEnvelope(integration: "music", reason: "missing_query")
        }
        let kindRaw = inputString(input["kind"])?.lowercased() ?? "track"
        let kind: String
        switch kindRaw {
        case "track", "artist", "album": kind = kindRaw
        default: return failedEnvelope(integration: "music", reason: "unknown_kind:\(kindRaw)")
        }
        let limit = clampedInt(input["limit"], defaultValue: 20, min: 1, max: 100)
        let queryAS = escapeForAppleScript(query)
        // For all three kinds the underlying collection is `every track` —
        // we just narrow the `whose` predicate so callers can filter to a
        // single field. Track is the broad default (name OR artist OR album).
        let predicate: String
        switch kind {
        case "artist":
            predicate = "artist contains q"
        case "album":
            predicate = "album contains q"
        default: // "track"
            predicate = "name contains q or artist contains q or album contains q"
        }
        // 2026-06-07 the user: same -2741 fix as musicNowPlaying. The whole
        // tell-block was unwrapped, so `every track whose <pred>` could
        // throw and abort the script before the per-track try blocks
        // could fire (empty library, predicate eval error, Music still
        // initializing). Outer try returns "" on any failure → 0 hits
        // result instead of crashing the chat tool.
        // Same long-variable-name discipline as musicNowPlaying — inside
        // the Music tell-block, short names risk colliding with the app's
        // scripting dictionary tokens (AS error -2741 "Expected expression
        // but found '<token>'."). q→searchQueryString, t→trackItem, etc.
        // The predicate string interpolated above still uses `q` because
        // it's parsed as part of the AppleScript `whose` clause, not as
        // a variable reference — but its value is bound to
        // searchQueryString below via `set q to ...` ... we DO need the
        // identifier `q` inside the whose clause to match the predicate.
        // So q stays as the predicate's bound name; rename everything
        // else.
        let source = """
        with timeout of 10 seconds
            tell application "Music"
                set searchOutputString to ""
                try
                    set q to "\(queryAS)"
                    set searchHitsList to (every track whose \(predicate))
                    set searchCountedNum to 0
                    repeat with trackItem in searchHitsList
                        if searchCountedNum ≥ \(limit) then exit repeat
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
                end try
                return searchOutputString
            end tell
        end timeout
        """
        do {
            let raw = try await runAppleScript(source)
            let results = parseMusicTrackRecords(raw)
            return .object([
                "status": .string("completed"),
                "count": .int(Int64(results.count)),
                "results": .array(results),
            ])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "music", app: app)
        } catch {
            return failedEnvelope(integration: "music", error: error)
        }
    }

    public static func musicListLibrary(input: [String: JSONValue]) async throws -> JSONValue {
        let offset = clampedInt(input["offset"], defaultValue: 0, min: 0, max: 1_000_000)
        let limit = clampedInt(input["limit"], defaultValue: 50, min: 1, max: 100)
        let startIndex = offset + 1
        let requestedEndIndex = offset + limit
        let source = """
        with timeout of 15 seconds
            tell application "Music"
                set totalTrackCountString to "0"
                set libraryOutputString to ""
                try
                    set libraryTracksList to every track
                    set totalTrackCountNum to count of libraryTracksList
                    set totalTrackCountString to totalTrackCountNum as string
                    set startIndexNum to \(startIndex)
                    set requestedEndIndexNum to \(requestedEndIndex)
                    if startIndexNum is less than or equal to totalTrackCountNum then
                        set endIndexNum to requestedEndIndexNum
                        if endIndexNum is greater than totalTrackCountNum then set endIndexNum to totalTrackCountNum
                        repeat with trackIndexNum from startIndexNum to endIndexNum
                            set trackItem to item trackIndexNum of libraryTracksList
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
                    end if
                end try
                return totalTrackCountString & ":::PAGE:::" & libraryOutputString
            end tell
        end timeout
        """
        do {
            let raw = try await runAppleScript(source)
            let page = parseMusicPagedTrackRecords(raw, offset: offset, limit: limit)
            return .object([
                "status": .string("completed"),
                "offset": .int(Int64(offset)),
                "limit": .int(Int64(limit)),
                "total": .int(Int64(page.total)),
                "count": .int(Int64(page.tracks.count)),
                "hasMore": .bool(offset + page.tracks.count < page.total),
                "tracks": .array(page.tracks),
            ])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "music", app: app)
        } catch {
            return failedEnvelope(integration: "music", error: error)
        }
    }

    public static func musicListPlaylists(input: [String: JSONValue]) async throws -> JSONValue {
        let offset = clampedInt(input["offset"], defaultValue: 0, min: 0, max: 1_000_000)
        let limit = clampedInt(input["limit"], defaultValue: 50, min: 1, max: 100)
        let startIndex = offset + 1
        let requestedEndIndex = offset + limit
        let source = """
        with timeout of 15 seconds
            tell application "Music"
                set totalPlaylistCountString to "0"
                set playlistOutputString to ""
                try
                    set playlistsList to every playlist
                    set totalPlaylistCountNum to count of playlistsList
                    set totalPlaylistCountString to totalPlaylistCountNum as string
                    set startIndexNum to \(startIndex)
                    set requestedEndIndexNum to \(requestedEndIndex)
                    if startIndexNum is less than or equal to totalPlaylistCountNum then
                        set endIndexNum to requestedEndIndexNum
                        if endIndexNum is greater than totalPlaylistCountNum then set endIndexNum to totalPlaylistCountNum
                        repeat with playlistIndexNum from startIndexNum to endIndexNum
                            set playlistItem to item playlistIndexNum of playlistsList
                            set playlistNameString to ""
                            set playlistTrackCountString to "0"
                            set playlistPersistentIDString to ""
                            set playlistSpecialKindString to ""
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
                            set playlistOutputString to playlistOutputString & playlistIndexNum & "|||" & playlistNameString & "|||" & playlistTrackCountString & "|||" & playlistPersistentIDString & "|||" & playlistSpecialKindString & "###"
                        end repeat
                    end if
                end try
                return totalPlaylistCountString & ":::PAGE:::" & playlistOutputString
            end tell
        end timeout
        """
        do {
            let raw = try await runAppleScript(source)
            let page = parseMusicPlaylistRecords(raw, offset: offset, limit: limit)
            return .object([
                "status": .string("completed"),
                "offset": .int(Int64(offset)),
                "limit": .int(Int64(limit)),
                "total": .int(Int64(page.total)),
                "count": .int(Int64(page.playlists.count)),
                "hasMore": .bool(offset + page.playlists.count < page.total),
                "playlists": .array(page.playlists),
            ])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "music", app: app)
        } catch {
            return failedEnvelope(integration: "music", error: error)
        }
    }

    /// Get current track + playback state. No required input.
    /// Returns: {status, isPlaying, track: {name, artist, album, duration_seconds, position_seconds} | null}.
    public static func musicNowPlaying(input: [String: JSONValue]) async throws -> JSONValue {
        // 2026-06-07 ITERATION 5 — Agent's theory: my state gate was too
        // narrow. `player state` can return fast forwarding / rewinding /
        // (queue-driven states on AirPlay or remote sessions). Comparing
        // only to playing/paused fell through to "stopped|||" even when a
        // track was clearly current.
        //
        // Better shape: just try to read `current track` properties no
        // matter what the player state says. If the track read fails,
        // THEN bail. Player state becomes informational, not a gate. This
        // also handles the "as text" coercion issue for player state by
        // simply checking each constant in turn for the label.
        let source = """
        with timeout of 5 seconds
            tell application "Music"
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
            end tell
        end timeout
        """
        do {
            let raw = try await runAppleScript(source)
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .object([
                    "status": .string("completed"),
                    "isPlaying": .bool(false),
                    "playerState": .string("unknown"),
                    "track": .null,
                    "reason": .string("no_current_track"),
                ])
            }
            let parts = raw.components(separatedBy: "|||")
            let state = parts.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let normalizedState = state.lowercased()
            let knownStates: Set<String> = [
                "playing", "paused", "stopped", "fast forwarding",
                "fast_forwarding", "rewinding", "unknown",
            ]
            guard knownStates.contains(normalizedState) else {
                return .object([
                    "status": .string("failed"),
                    "integration": .string("music"),
                    "track": .null,
                    "reason": .string("malformed_now_playing_response"),
                ])
            }
            let isPlaying = normalizedState == "playing"
            if parts.count == 2, parts[1] == "NO_TRACK" {
                return .object([
                    "status": .string("completed"),
                    "isPlaying": .bool(false),
                    "playerState": .string(state),
                    "track": .null,
                    "reason": .string("no_current_track"),
                ])
            }
            if parts.count >= 6 {
                let name = parts[1]
                let artist = parts[2]
                let album = parts[3]
                let duration = Double(parts[4].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                let position = Double(parts[5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                let track: JSONValue = .object([
                    "name": .string(name),
                    "artist": .string(artist),
                    "album": .string(album),
                    "duration_seconds": .double(duration),
                    "position_seconds": .double(position),
                ])
                return .object([
                    "status": .string("completed"),
                    "isPlaying": .bool(isPlaying),
                    "playerState": .string(state),
                    "track": track,
                ])
            }
            // 2026-06-07 diagnostic: surface the AppleScript error that
            // caused the track read to fail so Agent can see WHY in chat
            // instead of just a null track. parts.count == 2 means the
            // script returned "<state>|||ERR:<errMsg>" — extract the
            // error and surface it. The track stays null but at least
            // we name what blocked us.
            if parts.count == 2, parts[1].hasPrefix("ERR:") {
                let msg = String(parts[1].dropFirst("ERR:".count))
                if isMusicNoCurrentTrackError(msg) {
                    return .object([
                        "status": .string("completed"),
                        "isPlaying": .bool(isPlaying),
                        "playerState": .string(state),
                        "track": .null,
                        "reason": .string("no_current_track"),
                    ])
                }
                return .object([
                    "status": .string("failed"),
                    "integration": .string("music"),
                    "reason": .string("now_playing_applescript_error"),
                    "applescript_error": .string(msg),
                ])
            }
            return .object([
                "status": .string("failed"),
                "integration": .string("music"),
                "isPlaying": .bool(isPlaying),
                "playerState": .string(state),
                "track": .null,
                "reason": .string("malformed_now_playing_response"),
            ])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "music", app: app)
        } catch {
            let ns = error as NSError
            if ns.domain == "NativeAgentAppleScript", ns.code == -1751 {
                return .object([
                    "status": .string("completed"),
                    "isPlaying": .bool(false),
                    "playerState": .string("unknown"),
                    "track": .null,
                    "reason": .string("no_current_track"),
                ])
            }
            return failedEnvelope(integration: "music", error: error)
        }
    }

    /// Control playback. Required: "action" (one of: "play", "pause", "toggle",
    /// "next", "previous").
    /// Returns: {status, action_performed}.
    public static func musicControl(input: [String: JSONValue]) async throws -> JSONValue {
        guard let action = inputString(input["action"])?.lowercased() else {
            return failedEnvelope(integration: "music", reason: "missing_action")
        }
        let command: String
        switch action {
        case "play": command = "play"
        case "pause": command = "pause"
        case "toggle", "playpause", "play_pause": command = "playpause"
        case "next", "next_track": command = "next track"
        case "previous", "prev", "previous_track": command = "previous track"
        default:
            return failedEnvelope(integration: "music", reason: "unknown_action:\(action)")
        }
        let source = """
        tell application "Music"
            \(command)
            return "ok"
        end tell
        """
        do {
            _ = try await runAppleScript(source)
            return .object([
                "status": .string("completed"),
                "action_performed": .string(action),
            ])
        } catch let AppleScriptError.permissionDenied(app) {
            return deniedEnvelope(integration: "music", app: app)
        } catch {
            return failedEnvelope(integration: "music", error: error)
        }
    }
}
