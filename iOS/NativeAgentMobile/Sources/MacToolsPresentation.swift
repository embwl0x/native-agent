import SwiftUI

enum MacSystemQuickAction: String, CaseIterable, Sendable {
    case lockScreen = "lock_screen"
    case sleepDisplay = "sleep_display"
}

/// A system action may only claim completion after the matching Mac call has
/// been issued successfully. Unknown strings are a failed completion and do
/// not invoke the send closure.
@MainActor
enum MacSystemQuickActionExecution {
    struct Completion: Equatable {
        let state: RemoteActionState
        let status: String
        let detail: String
    }

    static func unsupported(named action: String) -> Completion {
        let message = "Unsupported Mac system action: \(action)"
        return Completion(state: .failed, status: message, detail: message)
    }

    static func execute(
        named action: String,
        send: @MainActor @Sendable (MacSystemQuickAction) async throws -> Void
    ) async -> Completion {
        guard let quickAction = MacSystemQuickAction(rawValue: action) else {
            return unsupported(named: action)
        }
        return await execute(quickAction, send: send)
    }

    static func execute(
        _ action: MacSystemQuickAction,
        send: @MainActor @Sendable (MacSystemQuickAction) async throws -> Void
    ) async -> Completion {
        do {
            try await send(action)
            return Completion(
                state: .ranOnMac,
                status: "Done.",
                detail: "Ran on Mac through iCloud"
            )
        } catch {
            return Completion(
                state: RemoteActionState.forError(error),
                status: error.localizedDescription,
                detail: error.localizedDescription
            )
        }
    }
}

/// The Mac router has distinct remedies for an absent Shortcut and a policy
/// refusal. Preserve that distinction instead of showing both as opaque raw
/// transport errors on the phone.
enum MacShortcutRunnerPresentation {
    struct Failure: Equatable {
        let status: String
        let detail: String
    }

    static func failure(for error: Error, shortcutName: String) -> Failure {
        let detail = error.localizedDescription
        let normalized = detail.lowercased()

        if normalized.contains("shortcut_not_found") || normalized.contains("shortcut not found") {
            return Failure(
                status: "Shortcut \"\(shortcutName)\" was not found on the Mac.",
                detail: "Check the exact Shortcut name in the Mac Shortcuts app."
            )
        }

        if normalized.contains("policy")
            || normalized.contains("denied")
            || normalized.contains("not allowed")
            || normalized.contains("shortcuts_allowed") {
            return Failure(
                status: "Mac Control policy refused this Shortcut.",
                detail: "Enable Shortcuts in the Mac app's Trust settings, then try again."
            )
        }

        return Failure(
            status: "Shortcut \"\(shortcutName)\" could not run.",
            detail: detail
        )
    }
}

/// The iPhone must not treat a missing Mac trust projection as evidence that
/// Mac Control was intentionally disabled. The two cases have different owner
/// actions: wait for publishing versus change a policy on the Mac.
enum MacToolsPolicyGatePresentation {
    enum State: Equatable {
        case snapshotUnavailable
        case macControlDisabled
        case iosRemoteDisabled
        case enabled
    }

    static func state(for policy: TrustMacControlPolicy?) -> State {
        guard let policy else { return .snapshotUnavailable }
        guard policy.enabled else { return .macControlDisabled }
        return policy.remoteFromIosAllowed ? .enabled : .iosRemoteDisabled
    }

    /// A failed targeted refresh must not reuse an older, cached policy to
    /// unlock privileged controls. Until this exact snapshot is proven current,
    /// the safe presentation is the same as an unavailable policy.
    static func policyForGate(
        snapshotLoaded: Bool,
        refreshedPolicy: TrustMacControlPolicy?
    ) -> TrustMacControlPolicy? {
        snapshotLoaded ? refreshedPolicy : nil
    }

    static func disabledDescription(for policy: TrustMacControlPolicy?) -> String {
        switch state(for: policy) {
        case .snapshotUnavailable:
            "No Mac Control policy snapshot yet. Keep the Mac app open until it publishes Trust settings."
        case .macControlDisabled:
            "Mac Control is disabled by policy. Enable Agent Access → Full Mac or turn on Mac Control in the Mac app's Trust tab."
        case .iosRemoteDisabled:
            "iOS remote control is disabled by policy. Enable iOS remote control in the Mac app's Trust tab under Mac Control."
        case .enabled:
            "Mac Tools are available."
        }
    }
}

/// The individual Mac privileges remain independently fail-closed even after
/// the enclosing Mac Control policy has enabled this screen. Keeping their
/// decision and owner-facing explanation together prevents a dimmed control
/// from losing the reason it is unavailable.
enum MacToolsPrivilege: CaseIterable {
    case shortcuts
    case notifications
    case systemControl
    case spotlight
}

enum MacToolsPrivilegePresentation {
    static func isAllowed(_ privilege: MacToolsPrivilege, policy: TrustMacControlPolicy?) -> Bool {
        guard let policy else { return false }
        return switch privilege {
        case .shortcuts: policy.shortcutsAllowed
        case .notifications: policy.notificationsAllowed
        case .systemControl: policy.systemControlAllowed
        case .spotlight: policy.spotlightAllowed
        }
    }

    static func disabledDescription(for privilege: MacToolsPrivilege) -> String {
        switch privilege {
        case .shortcuts: "Shortcuts are disabled by Mac Control policy."
        case .notifications: "Notifications are disabled by Mac Control policy."
        case .systemControl: "System controls are disabled by Mac Control policy."
        case .spotlight: "Spotlight is disabled by Mac Control policy."
        }
    }
}

/// The iPhone can request a volume target, but the Mac control response does
/// not include a current output-volume readback. Keep the control's local
/// target and its post-action wording separate from an observed Mac state.
enum MacVolumeControlPresentation {
    static let defaultTargetFraction = 0.5
    static let currentVolumeDisclosure = "The Mac does not publish its current output volume to iPhone. This is a target to send, not a readback."

    static func targetPercent(for fraction: Double) -> Int {
        guard fraction.isFinite else { return 50 }
        return Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    static func isValid(percent: Int) -> Bool {
        (0...100).contains(percent)
    }

    static func acknowledgement(percent: Int) -> String {
        "The Mac accepted the request to set volume to \(percent)%. Its current output volume is not read back to iPhone."
    }
}

/// Explicit presentation state for the notification composer. A result must
/// identify both the operation and its outcome instead of appearing as an
/// unlabeled line beside a disabled-looking control.
enum MacNotificationSendPresentation {
    enum Feedback: Equatable {
        case sent
        case failed(String)

        var text: String {
            switch self {
            case .sent: "Notification sent to the Mac."
            case .failed(let detail): "Couldn’t send notification: \(detail)"
            }
        }

        var systemImage: String {
            switch self {
            case .sent: "checkmark.circle.fill"
            case .failed: "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .sent: .green
            case .failed: .red
            }
        }
    }
}

/// Spotlight's empty string means the Mac did not provide a search response.
/// That is different from a nonempty response whose lines contain no usable
/// results, which is a completed zero-result search.
enum MacToolsSpotlightPresentation {
    static let collapsedResultLimit = 8

    enum Outcome: Equatable {
        case emptyResponse
        case noResults
        case results([String])

        var rows: [String] {
            switch self {
            case .results(let results): results
            case .emptyResponse, .noResults: []
            }
        }

        var statusText: String {
            switch self {
            case .emptyResponse:
                "Mac returned an empty Spotlight response; results are unavailable."
            case .noResults:
                "No Spotlight results."
            case .results(let results):
                "\(results.count) Spotlight result(s)."
            }
        }

        var resultCount: Int { rows.count }

        func visibleRows(showingAll: Bool) -> [String] {
            guard !showingAll else { return rows }
            return Array(rows.prefix(MacToolsSpotlightPresentation.collapsedResultLimit))
        }

        var hiddenResultCount: Int {
            max(0, resultCount - MacToolsSpotlightPresentation.collapsedResultLimit)
        }

        func truncationText(showingAll: Bool) -> String? {
            guard hiddenResultCount > 0 else { return nil }
            return showingAll
                ? "Showing all \(resultCount) Spotlight results."
                : "Showing \(MacToolsSpotlightPresentation.collapsedResultLimit) of \(resultCount) Spotlight results."
        }
    }

    static func outcome(from rawResponse: String) -> Outcome {
        guard !rawResponse.isEmpty else { return .emptyResponse }

        let results = rawResponse
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return results.isEmpty ? .noResults : .results(results)
    }
}
