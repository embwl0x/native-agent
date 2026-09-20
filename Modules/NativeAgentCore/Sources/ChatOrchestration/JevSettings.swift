import Foundation
import PersistenceCore

/// The master switch and the six per-lane switches.
///
/// There is exactly ONE control a person ever sees: the paste-key field on the
/// Providers page. A key present is the master ON; no key and every lane is
/// silent. The per-lane flags exist so the agent can turn one lane off itself
/// through `app_setting_set` — they are settings, not extra controls, and they
/// all default ON.
///
/// Jev is NOT a routing provider. It answers questions, it never serves a turn,
/// and it must never be selectable as a chat route.
///
/// That is why the key does NOT live in `<dataRoot>/providers/`. Membership of
/// that directory is what MAKES something a provider: `nativeListProviders`
/// lists every `providers/*.json` it finds and SYNTHESIZES a provider row for
/// any id it has no registry entry for. A key filed there would have put "jev"
/// in the provider list and the model picker — a decision service offered as a
/// chat route, on the strength of where its key was stored. So it lives at
/// `<dataRoot>/jev/credential.json` instead, beside its own log, in a directory
/// nothing scans.
public enum JevSettings {
    /// The credential file, relative to the lane's own directory, and the
    /// environment variable that overrides it.
    public static let configFile = "credential.json"
    public static let environmentVariable = "TYPESAFE_API_KEY"
    /// The helper's per-agent tuning, written and owned by the agent itself.
    public static let profileFile = "profile.md"
    /// Long enough for an agent to say what it wants watched and what it wants
    /// left alone, short enough that it cannot become a second persona file.
    public static let profileCharacterCap = 2000
    /// The most that is ever read off disk to find those characters.
    public static let profileByteCap = 8192

    /// `<dataRoot>/jev/credential.json`.
    public static func credentialPath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("jev", isDirectory: true)
            .appendingPathComponent(configFile)
    }

    /// `<dataRoot>/jev/profile.md`.
    public static func agentProfilePath(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("jev", isDirectory: true)
            .appendingPathComponent(profileFile)
    }

    /// What the agent under this root has asked the helper to do and to leave
    /// alone, or nil when there is no profile.
    ///
    /// The file belongs to the agent, not to the product: the lanes are
    /// agent-blind and anything specific to one agent lives in that agent's own
    /// data root. No file, an empty file or an unreadable one means today's
    /// generic behaviour, byte for byte.
    ///
    /// Memoized the same way `apiKey` is, because the same `ask` path reads it
    /// on every call of every lane. There is no save method to drop the entry,
    /// so the modification time is the invalidator: an agent editing its own
    /// profile is picked up on the next call without a relaunch.
    public static func agentProfile(dataRoot: URL) -> String? {
        let path = agentProfilePath(dataRoot: dataRoot)
        let modified = (try? FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate]) as? Date
        cacheLock.lock()
        let cached = cachedProfiles[path.path]
        cacheLock.unlock()
        if let cached, cached.modified == modified { return cached.value }
        // Read OUTSIDE the lock: a file read is the one thing here that can
        // block, and the key read beside it must not wait behind it.
        let resolved = readProfile(at: path)
        // Compare-and-store. A concurrent reader may have filled the entry
        // first; if it read the same modification time its answer is this one,
        // and if it read a newer one its answer is the fresher of the two.
        cacheLock.lock()
        if cachedProfiles[path.path]?.modified != modified {
            cachedProfiles[path.path] = (modified, resolved)
        }
        cacheLock.unlock()
        return resolved
    }

    /// Bounded read: at most `profileByteCap` bytes are ever pulled off disk,
    /// so a profile that is actually a log, a paste or a whole document costs a
    /// page rather than its own size. A file cut at the cap can end mid-scalar,
    /// which is why the decode is lenient and the character cap is applied to
    /// Characters afterwards — never to bytes.
    private static func readProfile(at path: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: profileByteCap), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return String(trimmed.prefix(profileCharacterCap))
    }

    /// The key, or nil. Never logged, never put in a state payload, never
    /// returned to the agent.
    ///
    /// `dataRoot` is REQUIRED and is the root the caller was built with. A
    /// default of the process root would read one root's key while the
    /// dispatcher and the memory store it runs beside used another.
    ///
    /// Precedence is the same as every other provider key's: the environment
    /// variable first, then the file's `api_key`. The read is unlocked, like
    /// the shared resolver's — the write is an atomic rename, so a reader sees
    /// either the old bytes or the new ones and never a half file.
    public static func apiKey(dataRoot: URL) -> String? {
        // TRIMMED, both sources. A key pasted with a trailing newline, or
        // exported with a stray space, is the same key — sending it verbatim
        // produces an Authorization header the service rejects, and the lane
        // then looks broken rather than misconfigured.
        if let fromEnvironment = ProcessInfo.processInfo.environment[environmentVariable] {
            let trimmed = fromEnvironment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        // Memoized per root. `isConfigured` sits in front of every lane, so
        // this used to open and parse the credential file on every dispatch
        // and every turn — a file read on the hot path to answer a question
        // whose answer only changes when the one field on the Providers page
        // is saved, and `saveAPIKey` drops the entry when it is.
        let path = credentialPath(dataRoot: dataRoot)
        // Lookup, file read and cache fill are ONE critical section. Split
        // apart, a save landing between the read and the fill was invalidated
        // first and then overwritten by the in-flight read's stale bytes — a
        // cleared or replaced key restored for the life of the process. The
        // read is synchronous file I/O and nothing here awaits, so the lock is
        // never held across a suspension.
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedKeys[path.path] { return cached }
        let resolved: String? = {
            guard
                let data = try? Data(contentsOf: path),
                case .object(let body)? = try? JSONValue.parse(data),
                case .string(let key)? = body["api_key"]
            else { return nil }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        cachedKeys[path.path] = resolved
        return resolved
    }

    private static let cacheLock = NSLock()
    /// `path → key or nil`. An entry's ABSENCE means "not read yet"; an entry
    /// holding nil means "read, and there is no key".
    nonisolated(unsafe) private static var cachedKeys: [String: String?] = [:]
    /// `path → (modification time when read, profile or nil)`. A changed or
    /// vanished modification time re-reads.
    nonisolated(unsafe) private static var cachedProfiles: [String: (modified: Date?, value: String?)] = [:]

    private static func invalidateCachedKey(path: URL) {
        cacheLock.lock()
        cachedKeys.removeValue(forKey: path.path)
        cacheLock.unlock()
    }

    /// Master: a key is present under this root.
    public static func isConfigured(dataRoot: URL) -> Bool { apiKey(dataRoot: dataRoot) != nil }

    /// Save or clear the key. Writing an empty string removes the file, which
    /// is how the whole feature is turned off from the one row on the page.
    ///
    /// Through the same machinery every other provider key is written with —
    /// `configureProvider`'s cross-process file lock plus the durable
    /// tmp→fsync→rename write — so a key saved while another process is
    /// reading it cannot be seen half-written, and a crash after the call
    /// cannot lose it. Only the DIRECTORY differs, and deliberately: see the
    /// type's note on why this is not in `providers/`.
    public static func saveAPIKey(
        _ key: String,
        dataRoot: URL,
        persistence: any PersistenceCoreProtocol = SwiftNativePersistenceCore()
    ) async throws {
        let file = credentialPath(dataRoot: dataRoot)
        let directory = file.deletingLastPathComponent()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // Both ways out — saved, cleared, or thrown part-way — drop the
        // memoized read, so the next lane to ask re-reads the file.
        defer { invalidateCachedKey(path: file) }
        // 0700, like the log directory beside it: this one holds a key.
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
        try await persistence.withFileLock(file) {
            guard !trimmed.isEmpty else {
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
                return
            }
            try await persistence.writeJSON(
                .object(["api_key": .string(trimmed), "auth_mode": .string("api_key")]),
                to: file
            )
            // The durable write renames a fresh temp file into place, so the
            // mode is set after it and its failure is reported rather than
            // swallowed: a key readable by every local process is not a save.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path
            )
        }
    }

    /// The `UserDefaults` key behind a lane's switch. The settings registry
    /// row and this read share it, so a write through `app_setting_set` takes
    /// effect on the very next turn with nothing to reload.
    public static func defaultsKey(for lane: JevLane) -> String {
        switch lane {
        case .preTurn: return "jevLanePreTurn"
        case .toolCall: return "jevLaneToolCall"
        case .postTurn: return "jevLanePostTurn"
        case .memoryDedup: return "jevLaneMemoryDedup"
        case .shadowRank: return "jevLaneShadowRank"
        case .secondOpinion: return "jevLaneSecondOpinion"
        }
    }

    /// A lane runs when a key is present and its own switch is on. Default is
    /// on for every lane.
    public static func isEnabled(_ lane: JevLane, dataRoot: URL) -> Bool {
        guard isConfigured(dataRoot: dataRoot) else { return false }
        let store = UserDefaults.standard
        let key = defaultsKey(for: lane)
        return store.object(forKey: key) == nil ? true : store.bool(forKey: key)
    }
}
