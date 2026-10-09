// The Settings page's shared presentation rules: control owners, the app
// status line, the updater row, and the embeddings status/actions. The rows
// themselves live on the Settings page (SetupView, SetupRestRows,
// SetupFeatureRows).

import SwiftUI
import Context
import NativeAgentShared
import NativeAgentCore

/// One canonical owner for each live operational control. Views consume these
/// labels rather than repeating storage-oriented wording, which keeps a
/// control from quietly acquiring a second settings home.
enum OperationalSettingsControlPresentation {
    enum Control: CaseIterable, Hashable, Sendable {
        case providerRoute
        case macIntegrationPermission
        case subconsciousMaster
        case fluidContext
        case softwareUpdate
        case globalHotkey
    }

    enum Owner: String, Hashable, Sendable {
        case providers
        case macIntegration
        case settings
    }

    static func owner(for control: Control) -> Owner {
        switch control {
        case .providerRoute: .providers
        case .macIntegrationPermission: .macIntegration
        case .subconsciousMaster, .fluidContext, .softwareUpdate, .globalHotkey: .settings
        }
    }

    static func title(for control: Control) -> String {
        switch control {
        case .providerRoute: "Provider"
        case .macIntegrationPermission: "Mac Integration"
        case .subconsciousMaster: "Subconscious"
        case .fluidContext: "Fluid Context"
        case .softwareUpdate: "Software Update"
        case .globalHotkey: "Global Shortcut"
        }
    }

    static func fluidContextLabel(_ mode: ContextFlowMode) -> String {
        switch mode {
        case .active: "Active"
        case .off: "Off"
        }
    }
}

/// The About panel must distinguish a live runtime read from the unrelated
/// most-recent UI action. `AppModel.statusText` is intentionally a broad
/// activity feed, so showing it as "Status" could claim an old save result
/// describes the runtime now.
enum SlimSettingsStatusLinePresentation {
    enum Tone: Equatable {
        case neutral
        case success
        case warning
        case failure
    }

    struct State: Equatable {
        let text: String
        let detail: String?
        let tone: Tone
        let systemImage: String
    }

    static func runtimeState(runtimeOK: Bool?, lastRefreshError: String?) -> State {
        let error = normalized(lastRefreshError)

        switch runtimeOK {
        case true:
            if error != nil {
                return State(
                    text: "App is online; some app data is unavailable",
                    detail: refreshDetail,
                    tone: .warning,
                    systemImage: "exclamationmark.triangle.fill"
                )
            }
            return State(
                text: "App is online",
                detail: nil,
                tone: .success,
                systemImage: "checkmark.circle.fill"
            )
        case false:
            return State(
                text: "App reported a problem",
                detail: error == nil ? nil : refreshDetail,
                tone: .failure,
                systemImage: "xmark.octagon.fill"
            )
        case nil:
            if error != nil {
                return State(
                    text: "App status is unavailable",
                    detail: refreshDetail,
                    tone: .failure,
                    systemImage: "xmark.octagon.fill"
                )
            }
            return State(
                text: "App status has not been checked",
                detail: nil,
                tone: .neutral,
                systemImage: "questionmark.circle"
            )
        }
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// The failed reads are named in the log (refreshAll), not here.
    private static let refreshDetail = "Some sections didn't refresh. The details are in the log."
}

/// Feed availability, automatic-check preference and manual-check readiness
/// are independent facts.
/// Keep them separate so a release build that is mid-check never looks like a
/// locally built copy, and a development build never looks checkable.
enum SoftwareUpdateRowPresentation {
    struct State: Equatable {
        let title: String
        let detail: String
        let status: String
        let systemImage: String
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
                status: "ok",
                systemImage: "arrow.down.circle.fill",
                actionEnabled: true
            )
        }
        guard updatesAreAvailable else {
            return State(
                title: "Automatic updates aren’t available in this build",
                detail: unavailableDetail,
                status: "warn",
                systemImage: "info.circle",
                actionEnabled: true
            )
        }
        guard canCheckForUpdates else {
            return State(
                title: "An update check is already in progress",
                detail: (automaticChecksEnabled ? "Automatic checks are on. " : "Automatic checks are off. ")
                    + "Wait for the current signed-feed check to finish before starting another one.",
                status: "info",
                systemImage: "arrow.triangle.2.circlepath",
                actionEnabled: false
            )
        }
        return State(
            title: automaticChecksEnabled ? "Automatic update checks are on" : "Automatic update checks are off",
            detail: automaticChecksEnabled
                ? "NativeAgent checks the signed release feed automatically. You can also check now."
                : "You can check the signed release feed manually.",
            status: automaticChecksEnabled ? "ok" : "info",
            systemImage: automaticChecksEnabled ? "checkmark.circle" : "info.circle",
            actionEnabled: true
        )
    }
}

// MARK: - Embeddings backend

/// Shared state/action mapping for the embeddings controls. The SwiftUI view
/// owns task lifetime, while this value owner keeps retry/release eligibility
/// and the post-action truth in one place.
struct EmbeddingsSettingsActionPresentation {
    struct Controls: Equatable {
        let showsRetryMemoryStatus: Bool
        let showsRetryStatus: Bool
        let showsReleaseNow: Bool
    }

    struct Update {
        let status: EmbeddingsStatus?
        let errorMessage: String?
    }

    static func controls(status: EmbeddingsStatus?, errorMessage: String?) -> Controls {
        Controls(
            showsRetryMemoryStatus: errorMessage != nil,
            showsRetryStatus: status?.installState?.state == "failed",
            showsReleaseNow: status?.modelState?.loaded == true
        )
    }

    static func refreshed(_ status: EmbeddingsStatus) -> Update {
        Update(status: status, errorMessage: nil)
    }

    static func refreshFailed(_ error: any Error, preserving status: EmbeddingsStatus?) -> Update {
        Update(
            status: status,
            errorMessage: UserFacingError.message(error, action: "check memory status")
        )
    }

    static func released(_ result: EmbeddingsToggleResult) -> Update {
        Update(
            status: result.status,
            errorMessage: result.ok == false
                ? (result.error ?? "Embedding memory release could not be confirmed.")
                : result.error
        )
    }

    static func releaseFailed(_ error: any Error, preserving status: EmbeddingsStatus?) -> Update {
        Update(
            status: status,
            errorMessage: UserFacingError.message(error, action: "release memory")
        )
    }
}

/// Shared read-only mapping for the embeddings status panel. It receives the
/// root-scoped run status and gives the view its selected mode and the
/// human-facing explanation without reconstructing either from defaults.
struct EmbeddingsSettingsStatusPresentation: Equatable {
    let memoryMode: String
    let memoryModeLabel: String
    let memoryModeDescription: String

    init(status: EmbeddingsStatus) {
        let mode = Self.normalizedMemoryMode(status.memoryMode)
        self.memoryMode = mode
        switch mode {
        case "performance":
            memoryModeLabel = "Fast"
        case "low_memory":
            memoryModeLabel = "Low"
        default:
            memoryModeLabel = "Balanced"
        }
        if let detail = status.memoryModeDetail?.detail, !detail.isEmpty {
            memoryModeDescription = detail
        } else {
            switch mode {
            case "performance":
                memoryModeDescription = "Keeps the model hot for fastest recall."
            case "low_memory":
                memoryModeDescription = "Allows the model to release sooner when idle."
            default:
                memoryModeDescription = "Balances recall speed and memory use."
            }
        }
    }

    static func normalizedMemoryMode(_ raw: String?) -> String {
        let value = raw ?? "balanced"
        switch value {
        case "performance", "balanced", "low_memory":
            return value
        default:
            return "balanced"
        }
    }
}
