import AppKit
import SwiftUI
import Sparkle

// RELEASE-2026-05-06: thin Sparkle 2.x wrapper — Task 4.3
// Sparkle is enabled only for release bundles with a complete updater config.
// Developer installs intentionally omit SUFeedURL/SUPublicEDKey; starting Sparkle
// in that state shows a blocking "updater failed to start" modal on every launch.
// @MainActor required for Swift 6 strict concurrency + Sparkle's ObjC bridge.
//
// A2.1 (2026-07-24): a syntactically-valid SUFeedURL is NOT evidence that a feed
// exists. Every full release before today stamped a REQUIRED appcast URL that had
// never been published, which enabled "Check for Updates…" and turned a user click
// into a hopeful spinner that resolved into a 404. The updater now additionally
// requires `NativeAgentUpdateFeedPublished`, which script/release.sh sets to true
// only for a release that actually generated, signed, and published an appcast.
// When it is false the updater is never started (no background 404s either) and
// the menu tells the truth instead of pretending to check.

@MainActor
final class UpdateController: NSObject {
    /// One updater owns the host app. The app menu and both Settings surfaces
    /// must not each start an independent Sparkle scheduler.
    static let shared = UpdateController()

    /// Why a manual update check cannot run. `nil` == updates are really available.
    enum Unavailability: Equatable {
        /// No appcast was published for this build (the normal state today).
        case feedNotPublished
        /// The bundle carries no usable Sparkle configuration at all (dev builds).
        case notConfigured

        /// Deliberately identical for both cases: the user's takeaway is the same,
        /// and only `detail` explains which build they are holding.
        var message: String { "Automatic updates aren’t available in this build." }

        var detail: String {
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

    /// Observable found-update state. Sparkle's own scheduled prompt shows
    /// once and can be dismissed; this keeps a persistent, gentle notice in
    /// Settings and the app menu until the update is installed (or a later
    /// check finds none). Display-only — Sparkle retains the entire
    /// download/verify/install authority.
    @Observable
    @MainActor
    final class Status {
        /// Display version of the update Sparkle found; nil when none known.
        var availableVersion: String? = nil
    }

    struct PersistedNotice: Codable, Equatable {
        static let schemaVersion = 1
        var schemaVersion: Int
        var availableVersion: String
        var installedVersionAtDiscovery: String
        var feedURL: String
        var publicKey: String
    }

    private static let persistedNoticeKey = "NativeAgent.updateNotice.v1"

    let status = Status()

    private var updaterController: SPUStandardUpdaterController?
    private let unavailability: Unavailability?

    override init() {
        let unavailability = Self.resolveUnavailability(
            info: Bundle.main.infoDictionary ?? [:]
        )
        self.unavailability = unavailability
        self.updaterController = nil
        super.init()
        restorePersistedNotice(info: Bundle.main.infoDictionary ?? [:])
        // Created after super.init so the controller can carry `self` as the
        // updater delegate (found/not-found mirror into `status`).
        if unavailability == nil {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: nil
            )
        }
    }

    /// Whether this build has a real, published feed. Fixed at launch — deliberately
    /// NOT Sparkle's `canCheckForUpdates`, which also goes false while a check is
    /// already running. Basing the menu on that would relabel the item mid-check and
    /// then answer a click with "updates aren't available", which is its own lie.
    var updatesAreAvailable: Bool { unavailability == nil }

    /// Whether a manual update check can be initiated right now (config + Sparkle state).
    var canCheckForUpdates: Bool {
        guard updatesAreAvailable else { return false }
        return updaterController?.updater.canCheckForUpdates ?? false
    }

    /// Menu title. It never says "Check for Updates…" unless a check will actually run,
    /// and it names a known-available update outright.
    var menuTitle: String {
        if let version = status.availableVersion {
            return "Update Available — \(version)…"
        }
        return updatesAreAvailable ? "Check for Updates…" : "About Software Updates…"
    }

    /// One-line notice for the Settings row; nil when no update is known.
    var updateNoticeText: String? {
        status.availableVersion.map { "NativeAgent \($0) is available." }
    }

    /// Compact copy shared by the visible Settings row and its footer.
    var settingsDetail: String {
        if updatesAreAvailable {
            return "NativeAgent checks the signed release feed automatically. "
                + "You can also check now."
        }
        return (unavailability ?? .notConfigured).detail
    }

    /// Call from the "Check for Updates…" menu item.
    ///
    /// When no feed is published this presents a truthful, immediate explanation
    /// instead of starting a network check that is known in advance to fail.
    func checkForUpdates() {
        guard updatesAreAvailable, let updaterController else {
            presentUnavailableExplanation()
            return
        }
        // Sparkle owns the "a check is already running" case and surfaces it itself.
        updaterController.checkForUpdates(nil)
    }

    private func presentUnavailableExplanation() {
        let reason = unavailability ?? .notConfigured
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String) ?? "this version"

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = reason.message
        alert.informativeText = "NativeAgent \(version)\n\n\(reason.detail)"
        alert.addButton(withTitle: "OK")

        // Only offer the release page when the build actually carries one — never
        // invent a destination just to make the dialog look more finished.
        let releasePage = (info["NativeAgentReleasePageURL"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let releaseURL = URL(string: releasePage).flatMap { url -> URL? in
            guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return nil }
            return url
        }
        if releaseURL != nil {
            alert.addButton(withTitle: "Open Releases")
        }

        if alert.runModal() == .alertSecondButtonReturn, let releaseURL {
            NSWorkspace.shared.open(releaseURL)
        }
    }

    /// Pure configuration boundary used by the app and release-contract tests.
    /// `nil` means Sparkle has a complete, published, non-placeholder feed.
    static func resolveUnavailability(info: [String: Any]) -> Unavailability? {
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

    /// Pure persistence boundary used by launch and tests. A notice survives
    /// only for the exact published HTTPS feed/key and only while the offered
    /// version is newer than the currently installed build.
    static func persistedNoticeData(
        availableVersion: String,
        info: [String: Any]
    ) -> Data? {
        let offered = availableVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolveUnavailability(info: info) == nil,
              let context = updateContext(info: info),
              !offered.isEmpty,
              isVersion(offered, newerThan: context.installedVersion)
        else { return nil }
        return try? JSONEncoder().encode(PersistedNotice(
            schemaVersion: PersistedNotice.schemaVersion,
            availableVersion: offered,
            installedVersionAtDiscovery: context.installedVersion,
            feedURL: context.feedURL,
            publicKey: context.publicKey
        ))
    }

    static func restoredNoticeVersion(
        data: Data,
        info: [String: Any]
    ) -> String? {
        guard resolveUnavailability(info: info) == nil,
              let context = updateContext(info: info),
              let notice = try? JSONDecoder().decode(PersistedNotice.self, from: data),
              notice.schemaVersion == PersistedNotice.schemaVersion,
              notice.feedURL == context.feedURL,
              notice.publicKey == context.publicKey,
              isVersion(notice.availableVersion, newerThan: context.installedVersion)
        else { return nil }
        return notice.availableVersion
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

    private static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        SUStandardVersionComparator.default.compareVersion(
            candidate,
            toVersion: installed
        ) == .orderedDescending
    }

    private func restorePersistedNotice(info: [String: Any]) {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.persistedNoticeKey),
              let version = Self.restoredNoticeVersion(data: data, info: info) else {
            // Corrupt, stale, installed, or feed-mismatched display state has
            // no authority and must not linger indefinitely.
            defaults.removeObject(forKey: Self.persistedNoticeKey)
            status.availableVersion = nil
            return
        }
        status.availableVersion = version
    }

    private func setAvailableVersion(_ version: String?) {
        let info = Bundle.main.infoDictionary ?? [:]
        let defaults = UserDefaults.standard
        guard let version,
              let data = Self.persistedNoticeData(
                availableVersion: version,
                info: info
              ) else {
            defaults.removeObject(forKey: Self.persistedNoticeKey)
            status.availableVersion = nil
            return
        }
        defaults.set(data, forKey: Self.persistedNoticeKey)
        status.availableVersion = version
    }

    /// Hosts that only ever appear in placeholder/dry-run configuration. A build
    /// carrying one of these has no real feed no matter what else it claims.
    private static let placeholderHosts: Set<String> = [
        "example.com", "www.example.com", "example.org", "example.net", "localhost",
    ]
}

// Mirrors Sparkle's found/not-found signals into the observable `status` so
// the notice persists after Sparkle's own prompt is dismissed. Fires for both
// scheduled and manual checks. SPUUpdaterDelegate is main-actor annotated
// (NS_SWIFT_UI_ACTOR), so these run on the main actor and assign directly —
// no async hop that could reorder against a subsequent check.
extension UpdateController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        setAvailableVersion(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        setAvailableVersion(nil)
    }
}
