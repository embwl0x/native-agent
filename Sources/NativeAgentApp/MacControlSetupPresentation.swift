import MacIntegration
import NativeAgentCore
import AppToolRuntime
import ChatToolParsing
import PersistenceCore
import AppKit
import MacControl
import NativeAgentShared
import SwiftUI
import TrustCenter
// Blueprint: | `MacControlSetupPresentation.swift` | Mac integration preset labels and badges derived only from checked saved policy |
extension MacIntegrationPreset {
    var title: String {
        switch self {
        case .off: return "Off"
        case .watch: return "Watch"
        case .assistant: return "Assistant"
        case .full: return "Full Mac"
        }
    }
    var subtitle: String {
        switch self {
        case .off: return "Read only"
        case .watch: return "Notifications and watches"
        case .assistant: return "Mac work, asks before risky steps"
        case .full: return "Files anywhere, shell"
        }
    }
}
/// Setup badges describe only a policy that was successfully read or saved.
/// The controls can still show an editable draft, but a draft must never make
/// the setup panel claim that Mac Control is already configured.
enum MacControlSetupStatusBadges {
    enum PolicyReadState: Equatable {
        case loading
        case available
        case unavailable
    }
    struct Badge: Equatable {
        let text: String
        let status: String
    }
    struct State: Equatable {
        let access: Badge
        let iOSRemote: Badge
        let receipts: Badge
        let detail: String
    }
    static func resolve(readState: PolicyReadState, savedPolicy: TrustPolicy?) -> State {
        switch readState {
        case .loading:
            return State(
                access: Badge(text: "Checking…", status: "unknown"),
                iOSRemote: Badge(text: "iPhone remote control unknown", status: "unknown"),
                receipts: Badge(text: "notifications unknown", status: "unknown"),
                detail: "Checking your saved Mac control settings."
            )
        case .unavailable:
            return State(
                access: Badge(text: "Setup unavailable", status: "failed"),
                iOSRemote: Badge(text: "iPhone remote control unknown", status: "failed"),
                receipts: Badge(text: "notifications unknown", status: "failed"),
                detail: "I could not read your saved Mac control settings, so I am not claiming any of it is ready."
            )
        case .available:
            guard let savedPolicy,
                  let effective = TrustAccessModeCapabilityCatalog.effectiveMacControlPolicy(savedPolicy) else {
                return State(
                    access: Badge(text: "Setup unavailable", status: "failed"),
                    iOSRemote: Badge(text: "iPhone remote control unknown", status: "failed"),
                    receipts: Badge(text: "notifications unknown", status: "failed"),
                    detail: "Your saved Trust settings did not include Mac control."
                )
            }
            let access: Badge
            let detail: String
            if TrustAccessModeCapabilityCatalog.fullMacGrantIsActive(savedPolicy) {
                access = Badge(text: "Full Mac", status: "ready")
                detail = "Full Mac is active. Advanced switches save restricted-mode settings; they do not turn off Full Mac. macOS permissions and explicit blocks still apply."
            } else if TrustAccessModeCapabilityCatalog.macIntegrationPreset(for: effective) == .off {
                access = Badge(text: "Mac control is off", status: "disabled")
                detail = "I can read app data, but I cannot act on this Mac."
            } else if TrustAccessModeCapabilityCatalog.macIntegrationPreset(for: effective) != .watch {
                access = Badge(text: "Assistant", status: "ready")
                detail = "I can do workspace-safe Mac work and send results to your iPhone, and I ask before anything risky."
            } else {
                access = Badge(text: "Watch", status: "ready")
                detail = "I can post notifications, search with Spotlight and run background watches. No shell commands and no file writes."
            }
            return State(
                access: access,
                iOSRemote: Badge(
                    text: effective.remoteFromIosAllowed ? "iPhone remote control on" : "iPhone remote control off",
                    status: effective.remoteFromIosAllowed ? "ready" : "disabled"
                ),
                receipts: Badge(
                    text: effective.notificationsAllowed && effective.enabled ? "notifications on" : "notifications off",
                    status: effective.notificationsAllowed && effective.enabled ? "ready" : "disabled"
                ),
                detail: detail
            )
        }
    }
}
