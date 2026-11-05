import AppKit
import AppToolRuntime
import ChatSessionWork
import EngineRuntime
import Foundation
import NativeAgentCore
import NativeAgentShared
import Cognition
import Observation
// Blueprint: | `AppSettingsFace.swift` | Settings face platform rows and actions use the updater, data reference, clipboard and live app status |

extension AppQuietSettingsHost: SettingsFaceHost {
    func settingsFaceExtras() async throws -> [PartFace.Section] {
        let updater = UpdateController.shared
        let updates = SoftwareUpdateRowPresentation.resolve(
            availableVersion: updater.status.availableVersion, updatesAreAvailable: updater.updatesAreAvailable,
            automaticChecksEnabled: updater.automaticChecksEnabled, canCheckForUpdates: updater.canCheckForUpdates,
            unavailableDetail: updater.settingsDetail)
        let status = appModel.engine.doctor.runtimeStatus(lastRefreshError: appModel.lastRefreshError)
        let statusTone: PartFace.Tone
        switch status.tone {
        case .neutral: statusTone = .quiet
        case .success: statusTone = .live
        case .warning: statusTone = .attention
        case .failure: statusTone = .failed
        }
        var rows: [PartFace.Row] = [
            .init(id: "updates", title: "Updates", detail: updates.detail, value: updates.title,
                  actions: updates.actionEnabled ? [.init(id: "check-updates", label: updater.menuTitle)] : nil),
            .init(id: "data-limits", title: "Data limits", detail: "What the app keeps and for how long.",
                  actions: [.init(id: "show-data-limits", label: "Show data limits")]),
            .init(id: "about", title: "About", value: settingsBuildIdentity,
                  actions: [.init(id: "copy-build-identity", label: "Copy build identity")]),
            .init(id: "app-status", title: "App status", detail: status.detail, value: status.text, symbol: status.systemImage, tone: statusTone),
        ]
        if let taken = ShotgunController.shared.shortcutTaken {
            rows.append(.init(id: "shortcut-status", title: "Shotgun shortcut unavailable",
                              detail: "\(taken.title) is taken by another app. Pick another, or use View ▸ Show Shotgun.", tone: .attention))
        }
        return [.init(id: "app", title: "Updates and help", style: .list, rows: rows)]
    }

    func settingsFaceAction(row: String, action: String) async throws -> String? {
        switch (row, action) {
        case ("updates", "check-updates"):
            let updater = UpdateController.shared
            guard !updater.updatesAreAvailable || updater.canCheckForUpdates else {
                throw PartCallError(code: "update_in_progress", message: "An update check is already in progress. Wait for it to finish.")
            }
            updater.checkForUpdates()
            return "Opened the software update control."
        case ("data-limits", "show-data-limits"):
            guard let url = Bundle.main.url(forResource: "data-bounds", withExtension: "md", subdirectory: "docs") else {
                throw PartCallError(code: "reference_missing", message: "The data-limits reference is missing from this copy of NativeAgent.")
            }
            guard NSWorkspace.shared.open(url) else {
                throw PartCallError(code: "reference_unavailable", message: "macOS could not open the data-limits reference in the installed app bundle.")
            }
            return "Opened data limits on the Mac."
        case ("about", "copy-build-identity"):
            ChatClipboard.copy(settingsBuildIdentity)
            return "Copied the running build identity on the Mac."
        default:
            throw PartCallError(code: "unknown_action", message: "This Settings row no longer offers that action. Read Settings again.")
        }
    }

    private var settingsBuildIdentity: String {
        let identity = NativeAgentBuildIdentity.current
        if identity.unavailableReason != nil { return identity.description }
        var line = "NativeAgent " + identity.version
        var parts: [String] = []
        if let revision = identity.sourceRevision, !revision.isEmpty { parts.append(String(revision.prefix(7))) }
        if identity.sourceDirty == true { parts.append("modified") }
        if !parts.isEmpty { line += " (" + parts.joined(separator: ", ") + ")" }
        if identity.build != identity.version { line += " build " + identity.build }
        return line
    }
}

// MARK: - Software update row

/// Keep feed availability, preference and readiness separate so an in-flight check cannot resemble a local build.
enum SoftwareUpdateRowPresentation {
    struct State: Equatable {
        let title: String
        let detail: String
        let actionEnabled: Bool
    }

    static func resolve(
        availableVersion: String?,
        updatesAreAvailable: Bool,
        automaticChecksEnabled: Bool,
        canCheckForUpdates: Bool,
        unavailableDetail: String
    ) -> State {
        if let version = availableVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
            return State(
                title: "NativeAgent \(version) is available",
                detail: "Select Update Available to review and install the signed release.",
                actionEnabled: true
            )
        }
        guard updatesAreAvailable else {
            return State(
                title: "Automatic updates aren’t available in this build",
                detail: unavailableDetail,
                actionEnabled: true
            )
        }
        guard canCheckForUpdates else {
            return State(
                title: "An update check is already in progress",
                detail: (automaticChecksEnabled ? "Automatic checks are on. " : "Automatic checks are off. ")
                    + "Wait for the current signed-feed check to finish before starting another one.",
                actionEnabled: false
            )
        }
        return State(
            title: automaticChecksEnabled ? "Automatic update checks are on" : "Automatic update checks are off",
            detail: automaticChecksEnabled
                ? "NativeAgent checks the signed release feed automatically. You can also check now."
                : "You can check the signed release feed manually.",
            actionEnabled: true
        )
    }
}

// MARK: - Settings face updates

/// Platform owners have no files to watch. Observe their actual values even when no Settings view exists.
@MainActor
final class SettingsFaceUpdates {
    private let task: Task<Void, Never>
    private let preferences: Task<Void, Never>

    private struct Reading: Equatable {
        let version: String?
        let canCheck: Bool
        let automatic: Bool
        let failure: String?
        let shortcut: String?
        let status: DoctorFacade.RuntimeStatus
        let embedding: [String?]
    }

    init(_ appModel: AppModel) {
        task = Task { @MainActor [weak appModel] in
            var previous: Reading?
            while !Task.isCancelled {
                let changed = ScopedWaiter()
                guard let reading = Self.observe(appModel, changed: changed) else { return }
                if previous != reading {
                    NotificationCenter.default.post(name: SettingsFaceChange.platform, object: nil)
                }
                previous = reading
                await changed.park()
            }
        }
        let keys = QuietSettings.defaultsKeys(forPage: "settings", host: AppQuietSettingsHost(appModel))
        preferences = Task { @MainActor in
            let changes = EventDeadlinePhysiology.storeAndFileEvents(paths: [], notifications: [UserDefaults.didChangeNotification])
            var previous = Self.preferenceValues(keys)
            for await _ in changes {
                guard !Task.isCancelled else { return }
                let current = Self.preferenceValues(keys)
                guard !previous.isEqual(current) else { continue }
                previous = current
                NotificationCenter.default.post(name: SettingsFaceChange.platform, object: nil)
            }
        }
    }

    deinit { task.cancel(); preferences.cancel() }

    private static func preferenceValues(_ keys: [String]) -> NSDictionary {
        var values: [String: Any] = [:]
        for key in keys { values[key] = UserDefaults.standard.object(forKey: key) }
        return NSDictionary(dictionary: values)
    }

    private static func observe(_ appModel: AppModel?, changed: ScopedWaiter) -> Reading? {
        guard let appModel else { return nil }
        return withObservationTracking {
            let updater = UpdateController.shared
            let embedding = appModel.engine.memory.embeddingSnapshot
            return Reading(version: updater.status.availableVersion, canCheck: updater.status.canCheckForUpdates,
                           automatic: updater.status.automaticChecksEnabled, failure: updater.status.noticeFailure,
                           shortcut: ShotgunController.shared.shortcutTaken?.rawValue,
                           status: appModel.engine.doctor.runtimeStatus(lastRefreshError: appModel.lastRefreshError),
                           embedding: [embedding?.requestedBackend, embedding?.effectiveBackend,
                                       embedding?.lastLoadError, appModel.engine.memory.embeddingsError])
        } onChange: { _ = changed.resume() }
    }
}
