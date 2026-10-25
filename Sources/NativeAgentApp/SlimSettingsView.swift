// The Settings page's shared presentation rules: control owners, the app
// status line, the updater row, and the embeddings status/actions. The rows
// themselves live on the Settings page (SetupView, SetupRestRows,
// SetupFeatureRows).

import SwiftUI
import Context
import MemoryV2
import NativeAgentShared
import NativeAgentCore

// Blueprint: | `SlimSettingsView.swift` | Operational settings presentation: canonical control homes, status wording and updater availability shared by settings page rows |

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
