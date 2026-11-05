import AppKit
import SwiftUI
import Sparkle
import SystemOps
import NativeAgentCore

// Blueprint: | `UpdateController.swift` | `UpdateController`: configured Sparkle lifecycle, version probes and explicit unavailable/update presentation |

// Start Sparkle on MainActor only for configured bundles with a published feed.

@MainActor
final class UpdateController: NSObject {
    /// Release links leave the app; require absolute HTTPS URLs with a host.
    static func releasePageURL(in info: [String: Any]) -> URL? {
        let rawValue = (info["NativeAgentReleasePageURL"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawValue),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty
        else {
            return nil
        }
        return url
    }

    /// Share one updater so menus and Settings cannot start competing Sparkle schedulers.
    static let shared = UpdateController()

    /// Retain found-update state after Sparkle's prompt closes; Sparkle still owns download, verification and install.
    @Observable
    @MainActor
    final class Status {
        var availableVersion: String? = nil
        var noticeFailure: String? = nil
        var canCheckForUpdates = false
        var automaticChecksEnabled = false
    }

    typealias Unavailability = SoftwareUpdateState.Unavailability

    let status = Status()

    private var updaterController: SPUStandardUpdaterController?
    private final class Probe {
        let done = ScopedWaiter()
        var failure: String?
    }
    /// Record the probe outcome on the actor before waking its caller.
    private var probe: Probe?
    private var probeGeneration = 0
    private var canCheckObservation: NSKeyValueObservation?
    private var automaticChecksObservation: NSKeyValueObservation?
    private let unavailability: Unavailability?
    private let info: [String: Any]
    private let preferences: UserDefaults

    override convenience init() {
        self.init(
            info: Bundle.main.infoDictionary ?? [:],
            preferences: .standard
        )
    }

    init(
        info: [String: Any],
        preferences: UserDefaults
    ) {
        let unavailability = SoftwareUpdateState.resolveUnavailability(info: info)
        self.unavailability = unavailability
        self.info = info
        self.preferences = preferences
        self.updaterController = nil
        super.init()
        applyNotice(SoftwareUpdateState.restoreNotice(
            info: info, preferences: preferences, isNewer: Self.isVersion))
        // Create after super.init so self can serve as the updater delegate.
        if unavailability == nil {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: nil
            )
            canCheckObservation = updaterController?.updater.observe(
                \.canCheckForUpdates, options: [.initial, .new]
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    // Read on the owner actor so a queued callback cannot apply stale state.
                    guard let self else { return }
                    self.status.canCheckForUpdates = self.updaterController?.updater.canCheckForUpdates ?? false
                }
            }
            status.canCheckForUpdates = updaterController?.updater.canCheckForUpdates ?? false
            automaticChecksObservation = updaterController?.updater.observe(
                \.automaticallyChecksForUpdates, options: [.initial, .new]
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.status.automaticChecksEnabled = self.updaterController?.updater.automaticallyChecksForUpdates ?? false
                }
            }
            status.automaticChecksEnabled = updaterController?.updater.automaticallyChecksForUpdates ?? false
        }
    }

    /// Feed availability is fixed at launch; canCheckForUpdates also goes false mid-check and would mislabel the build.
    var updatesAreAvailable: Bool { unavailability == nil }

    var canCheckForUpdates: Bool {
        guard updatesAreAvailable else { return false }
        return status.canCheckForUpdates
    }

    var automaticChecksEnabled: Bool { updatesAreAvailable && status.automaticChecksEnabled }

    /// Offer Check for Updates only when a check can run; name a known update directly.
    var menuTitle: String {
        if let version = status.availableVersion {
            return "Update Available — \(version)…"
        }
        return updatesAreAvailable ? "Check for Updates…" : "About Software Updates…"
    }

    /// Share settings copy so the row and footer cannot disagree.
    var settingsDetail: String {
        let detail = Self.settingsDetail(for: unavailability, automaticChecksEnabled: automaticChecksEnabled)
        if let failure = status.noticeFailure { return failure + " " + detail }
        return detail
    }

    /// Separate presentation from Sparkle so deriving status cannot start network activity.
    static func settingsDetail(for unavailability: Unavailability?, automaticChecksEnabled: Bool) -> String {
        guard let unavailability else {
            return automaticChecksEnabled
                ? "NativeAgent checks the signed release feed automatically. You can also check manually."
                : "Automatic update checks are off. You can still check the signed release feed manually."
        }
        return unavailability.detail
    }

    /// Without a published feed, explain immediately instead of starting a check known to fail.
    func checkForUpdates() {
        guard updatesAreAvailable, let updaterController else {
            presentUnavailableExplanation()
            return
        }
        // Sparkle owns the "a check is already running" case and surfaces it itself.
        updaterController.checkForUpdates(nil)
    }

    /// Use Sparkle's information-only probe; it shows and installs nothing, leaving installation to the person.
    func probeForUpdate() async -> (detail: String, refusal: (reason: String, detail: String)?) {
        guard updatesAreAvailable, let updater = updaterController?.updater else {
            let reason = unavailability ?? .notConfigured
            return ("", ("updates_unavailable", reason.message + " " + reason.detail))
        }
        guard probe == nil, !updater.sessionInProgress, updater.canCheckForUpdates else {
            return ("", ("check_running", "An update check is already running. Ask again in a minute."))
        }
        probeGeneration &+= 1
        let generation = probeGeneration
        let response = Probe()
        probe = response
        updater.checkForUpdateInformation()
        // A probe Sparkle never finishes must not hold `probe` forever.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, self.probeGeneration == generation, let probe = self.probe else { return }
            self.probe = nil
            probe.failure = "No answer from the update feed within 45 seconds."
            probe.done.resume()
        }
        let done = response.done
        await Task { await done.park() }.value
        let failure = response.failure
        if let failure {
            return ("", ("check_failed", "The update check failed: \(failure) Try again later."))
        }
        if let failure = status.noticeFailure {
            return ("", ("notice_unreadable", failure))
        }
        guard let version = status.availableVersion else {
            let installed = info["CFBundleShortVersionString"] as? String ?? "this version"
            return ("NativeAgent is up to date (\(installed)).", nil)
        }
        return ("NativeAgent \(version) is available. Installing it is the owner's: \"\(menuTitle)\" in the app menu.", nil)
    }

    private func presentUnavailableExplanation() {
        let reason = unavailability ?? .notConfigured
        let rawVersion = (info["CFBundleShortVersionString"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let version = rawVersion.isEmpty ? "this version" : rawVersion
        let releaseURL = Self.releasePageURL(in: info)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = reason.message
        alert.informativeText = "NativeAgent \(version)\n\n\(reason.detail)"
        alert.addButton(withTitle: "OK")
        if releaseURL != nil { alert.addButton(withTitle: "Open Releases") }

        if alert.runModal() == .alertSecondButtonReturn, let releaseURL {
            NSWorkspace.shared.open(releaseURL)
        }
    }

    private static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        SUStandardVersionComparator.default.compareVersion(
            candidate,
            toVersion: installed
        ) == .orderedDescending
    }

    func handleFoundUpdate(displayVersion: String) {
        applyNotice(SoftwareUpdateState.storeNotice(
            displayVersion, info: info, preferences: preferences, isNewer: Self.isVersion))
    }

    func handleNoUpdate() {
        applyNotice(SoftwareUpdateState.storeNotice(
            nil, info: info, preferences: preferences, isNewer: Self.isVersion))
    }

    private func applyNotice(_ notice: SoftwareUpdateState.NoticeState) {
        switch notice {
        case .available(let version):
            status.availableVersion = version
            status.noticeFailure = nil
        case .absent, .stale:
            status.availableVersion = nil
            status.noticeFailure = nil
        case .unreadable(let failure):
            status.availableVersion = nil
            status.noticeFailure = failure
        }
    }

}

// Retain found-update state for scheduled and manual checks after Sparkle dismisses its prompt.
// SPUUpdaterDelegate is main-actor isolated; assign directly to avoid reordering against a later check.
extension UpdateController: SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if choice == .skip { handleNoUpdate() }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        handleFoundUpdate(displayVersion: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        handleNoUpdate()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if updateCheck == .updateInformation, let probe {
            self.probe = nil
            let failure = error as NSError?
            let noUpdate = failure?.domain == SUSparkleErrorDomain && failure?.code == Int(SUError.noUpdateError.rawValue)
            probe.failure = noUpdate ? nil : failure?.localizedDescription
            probe.done.resume()
            return
        }
    }
}
