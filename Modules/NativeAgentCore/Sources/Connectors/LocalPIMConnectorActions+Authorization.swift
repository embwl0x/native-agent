import AuthoredCapabilities
import Foundation
@preconcurrency import EventKit
import PersistenceCore
// Blueprint: | `LocalPIMConnectorActions+Authorization.swift` | calendar read/write authorization interpretation and EventKit permission prompts; wizard status |

extension LocalPIMConnectorActions {
    public enum CalendarAuthorizationAction: Equatable {
        case ready
        case requestFull
        case requestWriteOnly
        case unavailable
    }

    public static func calendarAuthorizationAction(
        for status: EKAuthorizationStatus,
        intent: LocalPIMCalendarAccess
    ) -> CalendarAuthorizationAction {
        switch intent {
        case .read:
            switch status {
            case .authorized, .fullAccess:
                return .ready
            case .notDetermined, .writeOnly:
                return .requestFull
            case .denied, .restricted:
                return .unavailable
            @unknown default:
                return .unavailable
            }
        case .write:
            switch status {
            case .authorized, .fullAccess, .writeOnly:
                return .ready
            case .notDetermined:
                return .requestWriteOnly
            case .denied, .restricted:
                return .unavailable
            @unknown default:
                return .unavailable
            }
        }
    }

    public static func authorizationAllowsRead(_ status: EKAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .fullAccess:
            return true
        default:
            return false
        }
    }

    public static func authorizationState(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .authorized, .fullAccess:
            return "ready"
        case .writeOnly:
            return "needs_permission"
        case .notDetermined:
            return "probe_needed"
        case .denied, .restricted:
            return "needs_permission"
        @unknown default:
            return "unknown"
        }
    }

    // MARK: - TCC status (for Mac Integration permission wizard)

    /// Returns the current Calendar (EKEvent) authorization status in the
    /// wizard vocabulary: "granted" | "denied" | "restricted" | "limited" |
    /// "not_determined". Does NOT trigger a prompt. `.writeOnly` is mapped to
    /// "limited" since it is a partial grant.
    public nonisolated static func currentCalendarAuthorizationStatus() -> String {
        ekStatusToWizardString(EKEventStore.authorizationStatus(for: .event))
    }

    /// Returns the current Reminders (EKReminder) authorization status in the
    /// wizard vocabulary. Does NOT trigger a prompt.
    public nonisolated static func currentReminderAuthorizationStatus() -> String {
        ekStatusToWizardString(EKEventStore.authorizationStatus(for: .reminder))
    }

    /// Triggers the Calendar TCC prompt if status is `.notDetermined`;
    /// otherwise returns current status without prompting. Returns the
    /// post-request status in the wizard vocabulary.
    public static func requestCalendarAccess() async -> String {
        let store = EKEventStore()
        _ = try? await requestCalendarReadAccess(store: store)
        return currentCalendarAuthorizationStatus()
    }

    /// Triggers the Reminders TCC prompt if status is `.notDetermined`;
    /// otherwise returns current status without prompting. Returns the
    /// post-request status in the wizard vocabulary.
    public static func requestReminderAccess() async -> String {
        let store = EKEventStore()
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined { _ = try? await store.requestFullAccessToReminders() }
        return currentReminderAuthorizationStatus()
    }

    private nonisolated static func ekStatusToWizardString(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .authorized, .fullAccess:
            return "granted"
        case .writeOnly:
            return "limited"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "not_determined"
        @unknown default:
            return "not_determined"
        }
    }

    public static func requestCalendarWriteAccessIfNeeded(store: EKEventStore) async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch calendarAuthorizationAction(for: status, intent: .write) {
        case .ready:
            return true
        case .requestWriteOnly:
            // A skill never asks macOS for access (`SkillRunContext`); its step hands back.
            return SkillRunContext.handsBack ? false : try await store.requestWriteOnlyAccessToEvents()
        case .requestFull, .unavailable:
            return false
        }
    }

    public static func requestCalendarReadAccess(store: EKEventStore) async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch calendarAuthorizationAction(for: status, intent: .read) {
        case .ready:
            return true
        case .requestFull:
            return SkillRunContext.handsBack ? false : try await store.requestFullAccessToEvents()
        case .requestWriteOnly, .unavailable:
            return false
        }
    }

}
