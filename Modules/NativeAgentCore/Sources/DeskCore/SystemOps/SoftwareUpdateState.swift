import Foundation
import NativeAgentShared
// Blueprint: | `SoftwareUpdateState.swift` | checked update-notice persistence: absent, available, stale or byte-preserved unreadable evidence |

/// Inject Sparkle comparison so persisted notices and host update availability agree.
public enum SoftwareUpdateState {
    /// Why a manual update check cannot run. `nil` == updates are really available.
    public enum Unavailability: Equatable, Sendable {
        /// No published appcast means no available update feed.
        case feedNotPublished
        /// The bundle carries no usable Sparkle configuration at all (dev builds).
        case notConfigured

        /// Deliberately identical for both cases: the user's takeaway is the same, and only `detail` explains which build they are holding.
        public var message: String { "Automatic updates aren’t available in this build." }

        public var detail: String {
            switch self {
            case .feedNotPublished:
                return SoftwareUpdateSettingsFace.Unavailability.feedNotPublished.detail
            case .notConfigured:
                return SoftwareUpdateSettingsFace.Unavailability.notConfigured.detail
            }
        }
    }

    private struct PersistedNotice: Codable, Equatable, Sendable {
        static let schemaVersion = 1
        var schemaVersion: Int
        var availableVersion: String
        var feedURL: String
        var publicKey: String
    }

    public static let persistedNoticeKey = "NativeAgent.updateNotice.v1"

    public enum NoticeState: Equatable, Sendable {
        case absent
        case available(String)
        case stale
        case unreadable(String)
    }

    /// Only a complete, published, non-placeholder feed counts as configured.
    public static func resolveUnavailability(info: [String: Any]) -> Unavailability? {
        let feedURL = (info["SUFeedURL"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKey = (info["SUPublicEDKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: feedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host?.lowercased(),
              !Self.placeholderHosts.contains(host)
        else {
            return .notConfigured
        }
        guard !publicKey.isEmpty,
              !publicKey.contains("$"),
              let decodedKey = Data(base64Encoded: publicKey),
              decodedKey.count == 32
        else {
            return .notConfigured
        }
        // The build must assert the feed at that URL was actually published. Absent key == not published; a valid-looking URL proves nothing.
        guard (info["NativeAgentUpdateFeedPublished"] as? Bool) == true else {
            return .feedNotPublished
        }
        return nil
    }

    /// Persistence boundary used by launch. A notice survives only for the exact published HTTPS feed/key and only while the offered version is newer than the
    /// currently installed build.
    @MainActor private static func persistedNotice(
        availableVersion: String,
        info: [String: Any],
        isNewer: @MainActor (String, String) -> Bool
    ) -> PersistedNotice? {
        let offered = availableVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolveUnavailability(info: info) == nil,
              let context = updateContext(info: info),
              !offered.isEmpty,
              isNewer(offered, context.installedVersion)
        else { return nil }
        return PersistedNotice(
            schemaVersion: PersistedNotice.schemaVersion,
            availableVersion: offered,
            feedURL: context.feedURL,
            publicKey: context.publicKey
        )
    }

    private static func updateContext(
        info: [String: Any]
    ) -> (installedVersion: String, feedURL: String, publicKey: String)? {
        let installed = (info["CFBundleShortVersionString"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let feed = (info["SUFeedURL"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (info["SUPublicEDKey"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !installed.isEmpty, !feed.isEmpty, !key.isEmpty else { return nil }
        return (installed, feed, key)
    }

    @MainActor public static func restoreNotice(
        info: [String: Any], preferencesSuiteName: String? = nil,
        isNewer: @MainActor (String, String) -> Bool
    ) async -> NoticeState {
        let reading = await readNotice(suiteName: preferencesSuiteName)
        let notice: PersistedNotice
        switch reading {
        case .absent: return .absent
        case .unreadable(let issue): return .unreadable(issue)
        case .notice(let saved): notice = saved
        }
        guard resolveUnavailability(info: info) == nil,
              let context = updateContext(info: info),
              notice.feedURL == context.feedURL,
              notice.publicKey == context.publicKey,
              isNewer(notice.availableVersion, context.installedVersion) else {
            if let failure = await eraseNotice(suiteName: preferencesSuiteName) { return failure }
            return .stale
        }
        return .available(notice.availableVersion)
    }

    private enum NoticeReading: Sendable {
        case absent
        case notice(PersistedNotice)
        case unreadable(String)
    }

    @concurrent private static func readNotice(suiteName: String?) async -> NoticeReading {
        let preferences: UserDefaults
        do { preferences = try noticePreferences(suiteName: suiteName) }
        catch { return .unreadable(error.localizedDescription) }
        guard let value = preferences.object(forKey: persistedNoticeKey) else { return .absent }
        guard let data = value as? Data else {
            return .unreadable("Saved update notice has the wrong preference type; preserved unchanged. Run Check for Updates to obtain fresh evidence.")
        }
        let notice: PersistedNotice
        do { notice = try JSONDecoder().decode(PersistedNotice.self, from: data) }
        catch {
            return .unreadable(
                "Saved update notice could not be read: \(error.localizedDescription) Preserved unchanged. Run Check for Updates to obtain fresh evidence.")
        }
        guard notice.schemaVersion == PersistedNotice.schemaVersion,
              !notice.availableVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: notice.feedURL), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              let key = Data(base64Encoded: notice.publicKey), key.count == 32 else {
            return .unreadable(
                "Saved update notice has an unsupported or incomplete shape; preserved unchanged. Run Check for Updates to obtain fresh evidence.")
        }
        return .notice(notice)
    }

    @MainActor public static func storeNotice(
        _ version: String?, info: [String: Any], preferencesSuiteName: String? = nil,
        isNewer: @MainActor (String, String) -> Bool
    ) async -> NoticeState {
        guard let version else {
            if let failure = await eraseNotice(suiteName: preferencesSuiteName) { return failure }
            return .absent
        }
        guard let notice = persistedNotice(availableVersion: version, info: info, isNewer: isNewer) else {
            if let failure = await eraseNotice(suiteName: preferencesSuiteName) { return failure }
            return .stale
        }
        return await writeNotice(notice, suiteName: preferencesSuiteName)
    }

    @concurrent private static func writeNotice(_ notice: PersistedNotice, suiteName: String?) async -> NoticeState {
        do {
            let preferences = try noticePreferences(suiteName: suiteName)
            let data = try JSONEncoder().encode(notice)
            if preferences.data(forKey: persistedNoticeKey) != data { preferences.set(data, forKey: persistedNoticeKey) }
            return .available(notice.availableVersion)
        } catch {
            return .unreadable("Update notice could not be saved: \(error.localizedDescription) Previous evidence preserved.")
        }
    }

    @concurrent private static func eraseNotice(suiteName: String?) async -> NoticeState? {
        do {
            let preferences = try noticePreferences(suiteName: suiteName)
            if preferences.object(forKey: persistedNoticeKey) != nil { preferences.removeObject(forKey: persistedNoticeKey) }
            return nil
        } catch { return .unreadable(error.localizedDescription) }
    }

    private static func noticePreferences(suiteName: String?) throws -> UserDefaults {
        guard let suiteName else { return .standard }
        guard let preferences = UserDefaults(suiteName: suiteName) else {
            throw PartCallError(code: "update_preferences_unavailable", message: "The update-notice preference suite could not be opened.")
        }
        return preferences
    }

    /// Hosts that only ever appear in placeholder/dry-run configuration. A build carrying one of these has no real feed no matter what else it claims.
    private static let placeholderHosts: Set<String> = [
        "example.com", "www.example.com", "example.org", "example.net", "localhost",
    ]
}
