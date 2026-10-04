import Foundation
import AttentionRouting
@preconcurrency import EventKit
import MacAssistantStatus
import NativeAgentCore
import PersistenceCore
import DeviceSync
import MacIntegration
import Connectors

struct NativeAppLocalPIMStatusProvider: LocalPIMStatusProvider {
    let root: URL

    func localStatus(id: String) async -> [String: JSONValue] {
        let integration: String
        switch id {
        case "local_mail": integration = MacIntegrationID.mail
        case "local_calendar": integration = MacIntegrationID.calendar
        case "local_reminders": integration = MacIntegrationID.reminders
        default: return [:]
        }
        do {
            let permissions = try await MacIntegrationPermissionStore(dataRoot: root).currentChecked()
            guard permissions[integration]?.read == true else {
                return [
                    "status": .string("needs_policy"),
                    "detail": .string("Read access is disabled in Mac Integrations."),
                    "nextStep": .string("Enable read access in Mac Integrations."),
                ]
            }
        } catch {
            return ["status": .string("unavailable"), "detail": .string(error.localizedDescription)]
        }
        return await MainActor.run {
            MacPIMConnectorActions.authorizationStatusPayload(localId: id)
        }
    }
}

/// Gmail / Google Calendar proof = the Connectors page's own row: connected,
/// and health still "ok" after `ConnectorHealthDecay` (a real call succeeded
/// in the last 7 days). Local files only; one registry read per status call.
actor NativeAppConnectorProofProvider: ConnectorProofProvider {
    private let root: URL
    private var rows: [ConnectorRecord]?

    init(root: URL) { self.root = root }

    func proofStatus(provider: String) async -> [String: JSONValue] {
        // The status client says email/calendar; the Google rows are gmail/gcal
        // ("calendar" is the EventKit row).
        let id = ["email": "gmail", "calendar": "gcal"][provider] ?? provider
        if rows == nil { rows = (try? await NativeClient.readConnectorRecords(root: root)) ?? [] }
        let row = rows?.first { $0.id == id }
        if row?.healthStatus == "ok" { return ["verified": .bool(true)] }
        if let row, ["connected", "configured", "connected_unverified"].contains(row.authState ?? "") {
            let name = row.name.isEmpty ? id : row.name
            return [
                "verified": .bool(false),
                "nextStep": .string("You're signed in to \(name), but I haven't had a successful read in the last 7 days, so it isn't verified."),
            ]
        }
        return ["verified": .bool(false), "nextStep": .string("Configure connector proof in the NativeAgent app")]
    }
}

/// iPhone push is ready when a notification can actually reach a phone: the
/// person hasn't switched phone delivery off, and either the paired iPhone
/// advertised CloudKit visual notifications or direct APNs has a target.
struct NativeAppMobilePushStatusProvider: MobilePushStatusProvider {
    func pushStatus() async -> [String: JSONValue] {
        guard NotificationChannelPreference.push() else {
            return ["status": .string("off"), "nextStep": .string("Turn on Deliver to the phone in Settings.")]
        }
        let peerReady = await MainActor.run { NativeAgentEngine.liveDeviceSync.bridge.cloudKitVisualNotificationPeerReady }
        let apnsTargets: Int
        do {
            apnsTargets = try await NativeAgentEngine.liveDeviceSync.apns.deliverableTargetCount()
        } catch {
            return ["status": .string("unavailable"), "nextStep": .string(error.localizedDescription)]
        }
        if peerReady || apnsTargets > 0 {
            return ["status": .string("ready"), "tokenConfigured": .bool(apnsTargets > 0)]
        }
        return ["status": .string("needs_setup"), "nextStep": .string("Configure mobile push in NativeAgent settings")]
    }
}

@MainActor
enum MacPIMConnectorActions {
    enum CalendarAccessIntent: Equatable {
        case read
        case write
    }

    enum CalendarAuthorizationAction: Equatable {
        case ready
        case requestFull
        case requestWriteOnly
        case unavailable
    }

    private typealias Actions = LocalPIMConnectorActions<EventKitPIMStore>

    static func calendarListUpcoming(input: [String: JSONValue]) async throws -> JSONValue {
        try await Actions.calendarListUpcoming(input: input)
    }

    static func calendarCalendars(input: [String: JSONValue]) async throws -> JSONValue {
        try await Actions.calendarCalendars(input: input)
    }

    static func calendarFreeBusy(input: [String: JSONValue]) async throws -> JSONValue {
        try await Actions.calendarFreeBusy(input: input)
    }

    static func remindersQuery(input: [String: JSONValue]) async throws -> JSONValue {
        try await Actions.remindersQuery(input: input)
    }

    static func remindersRead(input: [String: JSONValue]) async throws -> JSONValue {
        try await Actions.remindersRead(input: input)
    }

    static func remindersUpdate(input: [String: JSONValue]) async throws -> JSONValue {
        try await Actions.remindersUpdate(input: input)
    }

    static func remindersListDueToday(input: [String: JSONValue]) async throws -> JSONValue {
        try await Actions.remindersListDueToday(input: input)
    }

    static func calendarCreateEvent(input: [String: JSONValue]) async throws -> JSONValue {
        try await Actions.calendarCreateEvent(input: input)
    }

    static func calendarModifyEvent(input: [String: JSONValue]) async throws -> JSONValue {
        try await Actions.calendarModifyEvent(input: input)
    }

    static func argumentRefusal(tool: String, input: [String: JSONValue]) -> JSONValue? {
        Actions.argumentRefusal(tool: tool, input: input)
    }

    static func calendarDeleteEvent(input: [String: JSONValue]) async throws -> JSONValue {
        try await Actions.calendarDeleteEvent(input: input)
    }

    static func remindersCreate(input: [String: JSONValue]) async throws -> JSONValue {
        try await Actions.remindersCreate(input: input)
    }

    static func remindersComplete(input: [String: JSONValue]) async throws -> JSONValue {
        try await Actions.remindersComplete(input: input)
    }
    static func remindersDelete(input: [String: JSONValue]) async throws -> JSONValue {
        try await Actions.remindersDelete(input: input)
    }

    static func authorizationStatusPayload(localId: String) -> [String: JSONValue] {
        Actions.authorizationStatusPayload(localId: localId)
    }

    // MARK: - TCC status (for Mac Integration permission wizard)

    /// Returns the current Calendar (EKEvent) authorization status in the
    /// wizard vocabulary: "granted" | "denied" | "restricted" | "limited" |
    /// "not_determined". Does NOT trigger a prompt. `.writeOnly` is mapped to
    /// "limited" since it is a partial grant.
    public static func currentCalendarAuthorizationStatus() -> String {
        ekStatusToWizardString(EKEventStore.authorizationStatus(for: .event))
    }

    /// Returns the current Reminders (EKReminder) authorization status in the
    /// wizard vocabulary. Does NOT trigger a prompt.
    public static func currentReminderAuthorizationStatus() -> String {
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
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined, !SkillRunContext.handsBack {
            let store = EKEventStore()
            _ = try? await store.requestFullAccessToReminders()
        }
        return currentReminderAuthorizationStatus()
    }

    private static func ekStatusToWizardString(_ status: EKAuthorizationStatus) -> String {
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

    static func requestCalendarWriteAccessIfNeeded(store: EKEventStore) async throws -> Bool {
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

    static func requestCalendarReadAccess(store: EKEventStore) async throws -> Bool {
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

    static func calendarAuthorizationAction(
        for status: EKAuthorizationStatus,
        intent: CalendarAccessIntent
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

    static func authorizationAllowsRead(_ status: EKAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .fullAccess:
            return true
        default:
            return false
        }
    }

    static func authorizationState(_ status: EKAuthorizationStatus) -> String {
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

}
