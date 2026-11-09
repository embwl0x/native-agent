import AppKit
import SwiftUI
import Sparkle
import SystemOps
import NativeAgentCore
import NativeAgentShared

// Blueprint: | `UpdateController.swift` | Body Sparkle lifecycle, probes and update requests |

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

    private var updater: SPUUpdater?
    private var userDriver: BodyUpdateUserDriver?
    private var startupFailure: String?
    private var updaterOwner: UUID?
    private final class Probe {
        let done = ScopedWaiter()
        var failure: String?
    }
    /// Record the probe outcome on the actor before waking its caller.
    private var probe: Probe?
    private var canCheckObservation: NSKeyValueObservation?
    private var automaticChecksObservation: NSKeyValueObservation?
    private let unavailability: Unavailability?
    private let info: [String: Any]
    private let preferencesSuiteName: String?
    private var initialization: Task<Void, Never>?
    private var noticeWrite: Task<Void, Never>?

    override convenience init() {
        self.init(
            info: Bundle.main.infoDictionary ?? [:],
            preferencesSuiteName: nil
        )
    }

    init(
        info: [String: Any],
        preferencesSuiteName: String?
    ) {
        let unavailability = SoftwareUpdateState.resolveUnavailability(info: info)
        self.unavailability = unavailability
        self.info = info
        self.preferencesSuiteName = preferencesSuiteName
        self.updater = nil
        super.init()
        initialization = Task { [weak self] in
            guard let self else { return }
            let notice = await SoftwareUpdateState.restoreNotice(
                info: self.info, preferencesSuiteName: self.preferencesSuiteName, isNewer: Self.isVersion)
            self.applyNotice(notice)
            self.startUpdater()
        }
    }

    private func startUpdater() {
        // Restore the saved notice before Sparkle can publish a newer result.
        if unavailability == nil {
            let owner = UUID()
            updaterOwner = owner
            let driver = BodyUpdateUserDriver { [weak self] failure, shutdown in
                guard let self, self.updaterOwner == owner else { return }
                if shutdown { self.stopUpdater(failure: failure) }
                else { self.status.noticeFailure = failure }
            }
            let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
            userDriver = driver
            self.updater = updater
            do { try updater.start() }
            catch { stopUpdater(failure: error.localizedDescription); return }
            canCheckObservation = updater.observe(
                \.canCheckForUpdates, options: [.initial, .new]
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    // Read on the owner actor so a queued callback cannot apply stale state.
                    guard let self else { return }
                    self.status.canCheckForUpdates = self.updater?.canCheckForUpdates == true
                }
            }
            status.canCheckForUpdates = updater.canCheckForUpdates
            automaticChecksObservation = updater.observe(
                \.automaticallyChecksForUpdates, options: [.initial, .new]
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.status.automaticChecksEnabled = self.updater?.automaticallyChecksForUpdates == true
                }
            }
            status.automaticChecksEnabled = updater.automaticallyChecksForUpdates
        }
    }

    private func stopUpdater(failure: String) {
        startupFailure = failure
        status.noticeFailure = failure
        status.canCheckForUpdates = false
        canCheckObservation?.invalidate()
        automaticChecksObservation?.invalidate()
        canCheckObservation = nil
        automaticChecksObservation = nil
        updater = nil
        userDriver = nil
        updaterOwner = nil
    }

    /// Feed availability is fixed at launch; canCheckForUpdates also goes false mid-check and would mislabel the build.
    var updatesAreAvailable: Bool { unavailability == nil }

    var canCheckForUpdates: Bool {
        guard updatesAreAvailable else { return false }
        return status.canCheckForUpdates
    }

    var automaticChecksEnabled: Bool { updatesAreAvailable && status.automaticChecksEnabled }

    var settingsFeedSource: SoftwareUpdateSettingsFace.Source {
        let unavailable: SoftwareUpdateSettingsFace.Unavailability?
        switch unavailability {
        case .feedNotPublished: unavailable = .feedNotPublished
        case .notConfigured: unavailable = .notConfigured
        case nil: unavailable = nil
        }
        return .init(availableVersion: status.availableVersion, canCheck: status.canCheckForUpdates,
                     automaticChecks: status.automaticChecksEnabled, failure: status.noticeFailure, unavailable: unavailable)
    }

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
        Task {
            await initialization?.value
            restartReleasedUpdater()
            showUpdateControl()
        }
    }

    private func restartReleasedUpdater() {
        guard updatesAreAvailable, updater == nil else { return }
        startupFailure = nil
        startUpdater()
    }

    private func showUpdateControl() {
        guard updatesAreAvailable, let updater else {
            presentUnavailableExplanation()
            return
        }
        // Sparkle owns the "a check is already running" case and surfaces it itself.
        updater.checkForUpdates()
    }

    /// Use Sparkle's information-only probe; it shows and installs nothing, leaving installation to the person.
    func probeForUpdate() async -> (detail: String, refusal: (reason: String, detail: String)?) {
        await initialization?.value
        if let startupFailure { return ("", ("updater_unavailable", startupFailure)) }
        guard updatesAreAvailable, let updater else {
            let reason = unavailability ?? .notConfigured
            return ("", ("updates_unavailable", reason.message + " " + reason.detail))
        }
        guard probe == nil, !updater.sessionInProgress, updater.canCheckForUpdates else {
            return ("", ("check_running", "An update check is already running. Ask again in a minute."))
        }
        let response = Probe()
        probe = response
        updater.checkForUpdateInformation()
        let done = response.done
        await done.park()
        await noticeWrite?.value
        if Task.isCancelled {
            return ("", ("check_cancelled", "Stopped waiting for the update check; Sparkle still owns its result."))
        }
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

    func request(_ command: UpdateCommand, presentation: BodyFacePresentation? = nil) async throws -> FaceActReply {
        await initialization?.value
        try Task.checkCancellation()
        if command == .check || command == .showAvailableUpdate { restartReleasedUpdater() }
        switch command {
        case .check, .showAvailableUpdate:
            if let presentation {
                if let startupFailure { throw PartCallError(code: "updater_start_failed", message: startupFailure) }
                guard updatesAreAvailable, let updater, let userDriver else {
                    throw PartCallError(code: "updates_unavailable", message: settingsDetail)
                }
                if try userDriver.bind(presentation, sessionInProgress: updater.sessionInProgress) {
                    try await userDriver.focus()
                } else {
                    updater.checkForUpdates()
                    try await userDriver.confirmPresentation()
                }
                return .acknowledged
            }
            showUpdateControl()
            return .acknowledged
        case .probe:
            let result = await probeForUpdate()
            if let refusal = result.refusal {
                return .refused(.init(code: refusal.reason, message: refusal.detail, cause: nil, effects: .none))
            }
            return .result(.string(result.detail))
        case .setAutomaticChecksOn, .setAutomaticChecksOff:
            guard let updater else {
                throw PartCallError(code: "updates_unavailable", message: settingsDetail)
            }
            let enabled = command == .setAutomaticChecksOn
            if updater.automaticallyChecksForUpdates != enabled { updater.automaticallyChecksForUpdates = enabled }
            return .committed(.init(identities: ["updates"], value: .bool(updater.automaticallyChecksForUpdates),
                revision: nil, effects: .known, publicationFailure: nil))
        }
    }

    func interaction(operation: UUID, action: UpdateInteraction, renderer: UUID) throws -> FaceActReply {
        guard let userDriver else { throw PartCallError(code: "updates_unavailable", message: settingsDetail) }
        try userDriver.interact(operation: operation, action: action, renderer: renderer)
        return .acknowledged
    }

    func disconnect(renderer: UUID?) { userDriver?.disconnect(renderer: renderer) }

    private func presentUnavailableExplanation() {
        if let startupFailure {
            let alert = NSAlert()
            alert.messageText = "Software updates could not start"
            alert.informativeText = startupFailure
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
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
        storeNotice(displayVersion)
    }

    func handleNoUpdate() {
        storeNotice(nil)
    }

    private func storeNotice(_ version: String?) {
        let previous = noticeWrite
        noticeWrite = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            self.applyNotice(await SoftwareUpdateState.storeNotice(
                version, info: self.info, preferencesSuiteName: self.preferencesSuiteName, isNewer: Self.isVersion))
        }
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
        if let startupFailure { status.noticeFailure = startupFailure }
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
