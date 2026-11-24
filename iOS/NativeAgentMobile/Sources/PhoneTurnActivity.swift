import Observation
import ActivityKit
import Foundation
import NativeAgentShared
import SwiftUI

@MainActor
@Observable
final class PhoneTurnActivity {
    static let shared = PhoneTurnActivity()
    var settingControl: PhoneLocalSetting {
        PhoneLocalSetting(id: "phone.live_activities", label: "Show task names on the iPhone Lock Screen", type: "boolean",
            read: { try self.settingEnabled() ? "true" : "false" }, write: { value, authority in
                let enabled = try PhoneLocalSetting.boolean(value)
                let current = try self.settingEnabled()
                if current == enabled { return }
                try authority.check(raising: enabled && !current)
                self.setEnabled(enabled)
                guard self.isEnabled == enabled else {
                    throw PhoneLocalSetting.failure(self.errorMessage ?? "The Live Activities switch did not change.")
                }
            }, approval: { try PhoneLocalSetting.boolean($0) && !self.settingEnabled() })
    }
    private func settingEnabled() throws -> Bool {
        access(keyPath: \.isEnabled)
        guard let saved = UserDefaults.standard.object(forKey: "NativeAgentMobile.workActivityEnabled") else { return false }
        guard let enabled = saved as? Bool else {
            throw PhoneLocalSetting.failure(
                "The saved Live Activities switch is not a Boolean. Repair Show task names on Lock Screen in iPhone NativeAgent Settings.")
        }
        return enabled
    }
    var workCorrelations: [String: Set<String>] = [:]
    var workingIDs: Set<String> {
        Set(work.values.filter {
            [.preparing, .working, .tool, .retrying].contains($0.content.state)
        }.flatMap { workCorrelations[$0.id] ?? [] })
    }
    private(set) var errorMessage: String?
    var isEnabled = UserDefaults.standard.bool(forKey: "NativeAgentMobile.workActivityEnabled")
    var work: [String: MobileWorkActivity] = [:]
    var turnSessions: TurnSessionsFace?
    var visibleTurnSessions: TurnSessionsFace? {
        guard activityPairing != nil, workPairing == activityPushPairing else { return nil }
        return turnSessions
    }
    @ObservationIgnored var pushConfigured = false
    @ObservationIgnored var acceptedRegistrations: [String: [String: String]] = [:]
    @ObservationIgnored var acceptedRegistrationPairing: String?
    @ObservationIgnored var workUpdates: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    var workPairing: String?
    @ObservationIgnored var tokenObservers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var activityObserver: Task<Void, Never>?
    @ObservationIgnored var startTokenObserver: Task<Void, Never>?
    @ObservationIgnored var registrationTask: Task<Void, Never>?
    @ObservationIgnored var workReconciliationTask: Task<Void, Never>?
    @ObservationIgnored var workReconciliationIDs: Set<String> = []
    @ObservationIgnored var disableRegistrationInFlight = false
    @ObservationIgnored var disableRegistrationPending = (UserDefaults.standard.object(forKey: "NativeAgentMobile.workActivityDisablePending") as? Bool)
        ?? !UserDefaults.standard.bool(forKey: "NativeAgentMobile.workActivityEnabled") {
        didSet { UserDefaults.standard.set(disableRegistrationPending, forKey: "NativeAgentMobile.workActivityDisablePending") }
    }
    @ObservationIgnored var failedWorkStarts: Set<String> = []
    var activityPairing: String? { AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests) }
    var activityPushPairing: String? {
        guard let secret = iCloudBridge.shared.pairingSecretForPhoneRequests else { return nil }
        return SHA256Hex.of(utf8: secret.base64EncodedString())
    }
    /// Retire a pairing's projections before its replacement can make them visible.
    func adoptWorkPairing(_ pairing: String?) {
        guard workPairing != pairing else { return }
        workReconciliationTask?.cancel()
        workReconciliationIDs.removeAll()
        work.removeAll()
        workCorrelations = [:]
        turnSessions = nil
        workPairing = pairing
    }
    func activityError(_ message: String?) { errorMessage = message }
    private init() {}
}
