import Foundation
@preconcurrency import EventKit
import PersistenceCore
// Blueprint: | `LocalPIMConnectorActions+Authorization.swift` | EventKit read/write grants, permission prompts and wizard status |

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
            case .fullAccess:
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
            case .fullAccess, .writeOnly:
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
        case .fullAccess:
            return true
        default:
            return false
        }
    }

    public static func authorizationState(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess:
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

    /// Read wizard status without prompting; writeOnly is limited because it grants only partial access.
    public nonisolated static func currentCalendarAuthorizationStatus() -> String {
        ekStatusToWizardString(EKEventStore.authorizationStatus(for: .event))
    }

    /// Read Reminders wizard status without prompting.
    public nonisolated static func currentReminderAuthorizationStatus() -> String {
        ekStatusToWizardString(EKEventStore.authorizationStatus(for: .reminder))
    }

    /// Prompt only while undetermined; return the resulting wizard status.
    public static func requestCalendarAccess() async throws -> String {
        let store = EKEventStore()
        _ = try await requestCalendarReadAccess(store: store)
        return currentCalendarAuthorizationStatus()
    }

    /// Prompt only while undetermined; return the resulting wizard status.
    public static func requestReminderAccess() async throws -> String {
        let store = EKEventStore()
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined { _ = try await store.requestFullAccessToReminders() }
        return currentReminderAuthorizationStatus()
    }

    private nonisolated static func ekStatusToWizardString(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess:
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
            // Only the foreground permission owner calls this prompting API.
            return try await store.requestWriteOnlyAccessToEvents()
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
            return try await store.requestFullAccessToEvents()
        case .requestWriteOnly, .unavailable:
            return false
        }
    }

}
