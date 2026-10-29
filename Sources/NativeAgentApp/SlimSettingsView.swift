// The Settings page's shared presentation rules: Fluid Context labels, the app
// status line, the updater row, and the embeddings status/actions. The rows
// themselves live on the Settings page (SetupView, SetupRestRows,
// SetupFeatureRows).

import SwiftUI
import Context
import MemoryV2
import NativeAgentShared
import NativeAgentCore

// Blueprint: | `SlimSettingsView.swift` | Operational settings presentation: Fluid Context labels, status wording and updater availability shared by settings page rows |

/// The Settings rows share the same words for Fluid Context's two modes.
enum OperationalSettingsControlPresentation {
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
