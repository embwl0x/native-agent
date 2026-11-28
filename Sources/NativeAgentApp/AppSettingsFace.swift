import AppKit
import BodyRuntime
import Foundation
import NativeAgentCore
import NativeAgentShared
import Observation
import PersistenceCore
// Blueprint: | `AppSettingsFace.swift` | Settings face platform rows and their Mac verbs: the updater, data reference, clipboard and live app status |

extension AppQuietSettingsHost: SettingsFaceHost {
    func settingsFaceExtrasSnapshot() -> any SettingsFaceExtrasSnapshot {
        let updater = UpdateController.shared
        return MacSettingsFaceSnapshot(availableVersion: updater.status.availableVersion, updatesAreAvailable: updater.updatesAreAvailable,
            automaticChecksEnabled: updater.automaticChecksEnabled, canCheckForUpdates: updater.canCheckForUpdates,
            settingsDetail: updater.settingsDetail, menuTitle: updater.menuTitle,
            health: appModel.engine.doctor.health, refreshError: appModel.lastRefreshError,
            shortcutTitle: ShotgunController.shared.shortcutTaken?.title)
    }

    /// The Mac's own Settings buttons, run as the person's verbs (`settings.update`, `settings.data_limits`, `settings.copy_build_identity`).
    static func settingsMacVerb(_ verb: String) -> (ok: Bool, detail: String, fields: [String: JSONValue])? {
        switch verb {
        case "settings_update":
            let updater = UpdateController.shared
            guard !updater.updatesAreAvailable || updater.canCheckForUpdates else {
                return (false, "An update check is already in progress. Wait for it to finish.", [:])
            }
            updater.checkForUpdates()
            return (true, "Opened the software update control.", [:])
        case "settings_data_limits":
            guard let url = Bundle.main.url(forResource: "data-bounds", withExtension: "md", subdirectory: "docs") else {
                return (false, "The data-limits reference is missing from this copy of NativeAgent.", [:])
            }
            guard NSWorkspace.shared.open(url) else {
                return (false, "macOS could not open the data-limits reference in the installed app bundle.", [:])
            }
            return (true, "Opened data limits on the Mac.", [:])
        case "settings_copy_build_identity":
            ChatClipboard.copy(settingsBuildIdentity)
            return (true, "Copied the running build identity on the Mac.", [:])
        default: return nil
        }
    }

    nonisolated static var settingsBuildIdentity: String {
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

private struct MacSettingsFaceSnapshot: SettingsFaceExtrasSnapshot {
    let availableVersion: String?
    let updatesAreAvailable: Bool
    let automaticChecksEnabled: Bool
    let canCheckForUpdates: Bool
    let settingsDetail: String
    let menuTitle: String
    let health: RuntimeHealth?
    let refreshError: String?
    let shortcutTitle: String?

    func sections() -> [PartFace.Section] {
        let status = RuntimeStatusFace.project(health: health, lastRefreshError: refreshError)
        let updates = SoftwareUpdateRowPresentation.resolve(
            availableVersion: availableVersion, updatesAreAvailable: updatesAreAvailable,
            automaticChecksEnabled: automaticChecksEnabled, canCheckForUpdates: canCheckForUpdates,
            unavailableDetail: settingsDetail)
        let statusTone: PartFace.Tone
        switch status.tone {
        case .neutral: statusTone = .quiet
        case .success: statusTone = .live
        case .warning: statusTone = .attention
        case .failure: statusTone = .failed
        }
        // These open or copy on this Mac, so they run from the Mac's door.
        let mac = ["mac"]
        var rows: [PartFace.Row] = [
            .init(id: "updates", title: "Updates", detail: updates.detail, value: updates.title,
                  actions: updates.actionEnabled ? [.init(id: "check-updates", label: menuTitle, doors: mac,
                                                          call: PartFace.Call("settings.update"))] : nil),
            .init(id: "data-limits", title: "Data limits", detail: "What the app keeps and for how long.",
                  actions: [.init(id: "show-data-limits", label: "Show data limits", doors: mac, call: PartFace.Call("settings.data_limits"))]),
            .init(id: "about", title: "About", value: AppQuietSettingsHost.settingsBuildIdentity,
                  actions: [.init(id: "copy-build-identity", label: "Copy build identity", doors: mac,
                                  call: PartFace.Call("settings.copy_build_identity"))]),
            .init(id: "app-status", title: "App status", detail: status.detail, value: status.text,
                  symbol: status.systemImage, tone: statusTone),
        ]
        if let shortcutTitle {
            rows.append(.init(id: "shortcut-status", title: "Shotgun shortcut unavailable",
                              detail: "\(shortcutTitle) is taken by another app. Pick another, or use View ▸ Show Shotgun.", tone: .attention))
        }
        // Folded until opened, unless a row in it needs the person: a fold never hides a failure or a conflict.
        return [.init(id: "app", title: "Updates and help", style: .list, rows: rows,
                      folded: rows.contains { $0.tone == .attention || $0.tone == .failed } ? nil : true)]
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
    private let embeddings: Task<Void, Never>

    private struct Reading: Equatable {
        let updates: SoftwareUpdateSettingsFace.Source
        let version: String?
        let canCheck: Bool
        let automatic: Bool
        let failure: String?
        let shortcut: String?
        let health: RuntimeHealth?
        let refreshError: String?
        let embeddingsError: String?
    }

    init(_ appModel: AppModel) {
        let changes = Observations { [weak appModel] in appModel.map(Self.read) }
        task = Task { [weak appModel] in
            var previous: Reading?
            for await reading in changes {
                guard !Task.isCancelled, let reading else { return }
                appModel?.engine.settingsFeed.updateUpdates(reading.updates)
                if previous != reading {
                    NotificationCenter.default.post(SettingsFaceChange.PlatformDidChange())
                }
                previous = reading
            }
        }
        embeddings = Task { [memory = appModel.engine.memory] in
            var previous: [String?]?
            for await snapshot in await memory.embeddingSnapshots() {
                guard !Task.isCancelled else { return }
                let current = [snapshot?.requestedBackend, snapshot?.effectiveBackend, snapshot?.lastLoadError]
                if previous != current {
                    previous = current
                    NotificationCenter.default.post(SettingsFaceChange.PlatformDidChange())
                }
            }
        }
        let declared = Self.preferenceDefaults
        let keys = Set(QuietSettings.defaultsKeys(host: AppQuietSettingsHost(appModel))).union(declared.keys)
        let feed = appModel.engine.settingsFeed
        preferences = Task.detached {
            let changes = EventDeadlinePhysiology.storeAndFileEvents(paths: [], notifications: [UserDefaults.didChangeNotification])
            var previous = await BodySettingsPreferences.readPreferences(keys, declared: declared)
            feed.updatePreferences(previous.values, issues: previous.issues, declared: declared)
            for await _ in changes {
                guard !Task.isCancelled else { return }
                let current = await BodySettingsPreferences.readPreferences(keys, declared: declared)
                guard previous != current else { continue }
                previous = current
                feed.updatePreferences(current.values, issues: current.issues, declared: declared)
                NotificationCenter.default.post(SettingsFaceChange.PlatformDidChange())
            }
        }
    }

    deinit { task.cancel(); preferences.cancel(); embeddings.cancel() }

    private static var preferenceDefaults: [String: PartFace.Value] {
        [SimpleViewMode.key: .string(SimpleViewMode.simple), HazeColor.key: .string(HazeColor.defaultValue.rawValue),
         AppearanceController.preferenceKey: .bool(true),
         WorkPaneState.openKey: .bool(false), WorkPaneState.sidebarsHiddenKey: .bool(false),
         WorkPaneState.widthKey: .double(WorkPane.defaultWidth), "voiceAutoRead": .bool(false),
         "nativeagent.showTour": .bool(false), ShotgunController.enabledKey: .bool(true),
         ShotgunShortcut.storageKey: .string(ShotgunShortcut.optionSpace.rawValue), MoodTintPreference.key: .bool(true),
         "studioWanderEnabled": .bool(true), "cognitiveSubstrateEnabled": .bool(true), "chatFileAccess": .string("auto"),
         WindowFollowsPreference.key: .bool(true)]
    }

    private static func read(_ appModel: AppModel) -> Reading {
        let updater = UpdateController.shared
        return Reading(updates: updater.settingsFeedSource, version: updater.status.availableVersion, canCheck: updater.status.canCheckForUpdates,
                       automatic: updater.status.automaticChecksEnabled, failure: updater.status.noticeFailure,
                       shortcut: ShotgunController.shared.shortcutTaken?.rawValue,
                       health: appModel.engine.doctor.health, refreshError: appModel.lastRefreshError,
                       embeddingsError: appModel.engine.memory.embeddingsError)
    }
}
