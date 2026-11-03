import Foundation
// Blueprint: | `SoftwareUpdateState.swift` | checked update-notice persistence: absent, available, stale or byte-preserved unreadable evidence |

/// Persisted updater evidence; the host supplies Sparkle's version comparison.
@MainActor
public enum SoftwareUpdateState {
    /// Why a manual update check cannot run. `nil` == updates are really available.
    public enum Unavailability: Equatable {
        /// No appcast was published for this build (the normal state today).
        case feedNotPublished
        /// The bundle carries no usable Sparkle configuration at all (dev builds).
        case notConfigured

        /// Deliberately identical for both cases: the user's takeaway is the same,
        /// and only `detail` explains which build they are holding.
        public var message: String { "Automatic updates aren’t available in this build." }

        public var detail: String {
            switch self {
            case .feedNotPublished:
                return "This build has no published update feed, so NativeAgent can’t "
                    + "check for new versions. Install newer builds by downloading the "
                    + "latest release disk image and dragging it to Applications."
            case .notConfigured:
                return "This is a locally-built copy of NativeAgent, which ships without "
                    + "updater configuration. Rebuild from source to update, or install a "
                    + "signed release build."
            }
        }
    }

    private struct PersistedNotice: Codable, Equatable {
        static let schemaVersion = 1
        var schemaVersion: Int
        var availableVersion: String
        var feedURL: String
        var publicKey: String
    }

    public static let persistedNoticeKey = "NativeAgent.updateNotice.v1"

    public enum NoticeState: Equatable {
        case absent
        case available(String)
        case stale
        case unreadable(String)
    }

    /// Configuration boundary used by the app.
    /// `nil` means Sparkle has a complete, published, non-placeholder feed.
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
        // The build must assert the feed at that URL was actually published.
        // Absent key == not published; a valid-looking URL proves nothing.
        guard (info["NativeAgentUpdateFeedPublished"] as? Bool) == true else {
            return .feedNotPublished
        }
        return nil
    }

    /// Persistence boundary used by launch. A notice survives
    /// only for the exact published HTTPS feed/key and only while the offered
    /// version is newer than the currently installed build.
    private static func persistedNoticeData(
        availableVersion: String,
        info: [String: Any],
        isNewer: @MainActor (String, String) -> Bool
    ) throws -> Data? {
        let offered = availableVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolveUnavailability(info: info) == nil,
              let context = updateContext(info: info),
              !offered.isEmpty,
              isNewer(offered, context.installedVersion)
        else { return nil }
        return try JSONEncoder().encode(PersistedNotice(
            schemaVersion: PersistedNotice.schemaVersion,
            availableVersion: offered,
            feedURL: context.feedURL,
            publicKey: context.publicKey
        ))
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

    public static func restoreNotice(
        info: [String: Any], preferences: UserDefaults,
        isNewer: @MainActor (String, String) -> Bool
    ) -> NoticeState {
        guard let value = preferences.object(forKey: persistedNoticeKey) else { return .absent }
        guard let data = value as? Data else {
            return .unreadable("Saved update notice has the wrong preference type; preserved unchanged. Run Check for Updates to obtain fresh evidence.")
        }
        let notice: PersistedNotice
        do { notice = try JSONDecoder().decode(PersistedNotice.self, from: data) }
        catch {
            return .unreadable("Saved update notice could not be read: \(error.localizedDescription) Preserved unchanged. Run Check for Updates to obtain fresh evidence.")
        }
        guard notice.schemaVersion == PersistedNotice.schemaVersion,
              !notice.availableVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: notice.feedURL), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              let key = Data(base64Encoded: notice.publicKey), key.count == 32 else {
            return .unreadable("Saved update notice has an unsupported or incomplete shape; preserved unchanged. Run Check for Updates to obtain fresh evidence.")
        }
        guard resolveUnavailability(info: info) == nil,
              let context = updateContext(info: info),
              notice.feedURL == context.feedURL,
              notice.publicKey == context.publicKey,
              isNewer(notice.availableVersion, context.installedVersion) else {
            preferences.removeObject(forKey: persistedNoticeKey)
            return .stale
        }
        return .available(notice.availableVersion)
    }

    public static func storeNotice(
        _ version: String?, info: [String: Any], preferences: UserDefaults,
        isNewer: @MainActor (String, String) -> Bool
    ) -> NoticeState {
        guard let version else {
            preferences.removeObject(forKey: persistedNoticeKey)
            return .absent
        }
        do {
            guard let data = try persistedNoticeData(availableVersion: version, info: info, isNewer: isNewer) else {
                preferences.removeObject(forKey: persistedNoticeKey)
                return .stale
            }
            preferences.set(data, forKey: persistedNoticeKey)
            return .available(version)
        } catch {
            return .unreadable("Update notice could not be encoded: \(error.localizedDescription) Previous evidence preserved.")
        }
    }

    /// Hosts that only ever appear in placeholder/dry-run configuration. A build
    /// carrying one of these has no real feed no matter what else it claims.
    private static let placeholderHosts: Set<String> = [
        "example.com", "www.example.com", "example.org", "example.net", "localhost",
    ]
}
