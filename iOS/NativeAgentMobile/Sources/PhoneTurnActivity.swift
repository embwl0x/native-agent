import ActivityKit
import CryptoKit
import NativeAgentShared
import SwiftUI

@MainActor
final class PhoneTurnActivity: ObservableObject {
    static let shared = PhoneTurnActivity()
    @Published var workCorrelations: [String: Set<String>] = [:]
    var workingIDs: Set<String> {
        Set(work.values.filter {
            $0.staleDate.addingTimeInterval(10 * 60) > Date()
                && [.preparing, .working, .tool, .retrying].contains($0.content.state)
        }.flatMap { workCorrelations[$0.id] ?? [] })
    }
    @Published private(set) var errorMessage: String?
    @Published var isEnabled = UserDefaults.standard.bool(forKey: "NativeAgentMobile.workActivityEnabled")
    @Published var work: [String: MobileWorkActivity] = [:]
    var pushConfigured = false
    var workUpdates: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    var workPairing: String?
    var workExpirations: [String: Task<Void, Never>] = [:]
    var tokenObservers: [String: Task<Void, Never>] = [:]
    var activityObserver: Task<Void, Never>?
    var startTokenObserver: Task<Void, Never>?
    var registrationTask: Task<Void, Never>?
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
    func activityError(_ message: String?) { errorMessage = message }
    private init() {}
}
