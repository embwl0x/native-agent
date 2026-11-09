import ActivityKit
import CryptoKit
import Foundation
import NativeAgentShared
import SwiftUI

@MainActor
final class PhoneTurnActivity: ObservableObject {
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
        guard let saved = UserDefaults.standard.object(forKey: "NativeAgentMobile.workActivityEnabled") else { return false }
        guard let enabled = saved as? Bool else {
            throw PhoneLocalSetting.failure(
                "The saved Live Activities switch is not a Boolean. Repair Show task names on Lock Screen in iPhone NativeAgent Settings.")
        }
        return enabled
    }
    @Published var workCorrelations: [String: Set<String>] = [:]
    var workingIDs: Set<String> {
        Set(work.values.filter {
            [.preparing, .working, .tool, .retrying].contains($0.content.state)
        }.flatMap { workCorrelations[$0.id] ?? [] })
    }
    @Published private(set) var errorMessage: String?
    @Published var isEnabled = UserDefaults.standard.bool(forKey: "NativeAgentMobile.workActivityEnabled")
    @Published var work: [String: MobileWorkActivity] = [:]
    @Published var turnSessions: TurnSessionsFace?
    var visibleTurnSessions: TurnSessionsFace? {
        guard activityPairing != nil, workPairing == activityPushPairing else { return nil }
        return turnSessions
    }
    var pushConfigured = false
    var acceptedRegistrations: [String: [String: String]] = [:]
    var acceptedRegistrationPairing: String?
    var workUpdates: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    var workPairing: String?
    var tokenObservers: [String: Task<Void, Never>] = [:]
    var activityObserver: Task<Void, Never>?
    var startTokenObserver: Task<Void, Never>?
    var registrationTask: Task<Void, Never>?
    var workReconciliationTask: Task<Void, Never>?
    var workReconciliationIDs: Set<String> = []
    var disableRegistrationInFlight = false
    var disableRegistrationPending = (UserDefaults.standard.object(forKey: "NativeAgentMobile.workActivityDisablePending") as? Bool)
        ?? !UserDefaults.standard.bool(forKey: "NativeAgentMobile.workActivityEnabled") {
        didSet { UserDefaults.standard.set(disableRegistrationPending, forKey: "NativeAgentMobile.workActivityDisablePending") }
    }
    var failedWorkStarts: Set<String> = []
    var activityPairing: String? { AgentNameCache.fingerprint(iCloudBridge.shared.pairingSecretForPhoneRequests) }
    var activityPushPairing: String? {
        guard let secret = iCloudBridge.shared.pairingSecretForPhoneRequests else { return nil }
        return SHA256.hash(data: Data(secret.base64EncodedString().utf8)).map { String(format: "%02x", $0) }.joined()
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
