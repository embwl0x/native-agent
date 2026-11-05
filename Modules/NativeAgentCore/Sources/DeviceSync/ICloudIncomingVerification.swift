import Foundation
import CryptoKit
import AppKit
import Cognition
import Combine
import NativeAgentShared
import DeviceSyncState
import NativeAgentCore
import ChatTurnRuntime
import PersistenceCore
import ProviderRouting
import OSLog
import Network
// Blueprint: | `ICloudIncomingVerification.swift` | Incoming message verification and receipt vocabulary |
actor ICloudIncomingVerifier {
    func classify(_ message: BridgeMessage) throws -> (ICloudIncomingMessageDisposition, Data) {
        let key = try PairingSecret.loadOrGenerateSecret()
        return (ICloudIncomingMessageDisposition.classify(message, secret: key, now: Date()), key)
    }
    func admitsControl(_ message: BridgeMessage) -> Bool {
        guard let key = try? PairingSecret.loadOrGenerateSecret() else { return false }
        if message.metadata?["kind"] != "icloud_action",
           UserMessageIntentSignals.isControlHandoff(message.text),
           let session = message.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           NativeAgentChatSessionID.normalizedPathComponent(session) != nil,
           case .deliver = ICloudIncomingMessageDisposition.classify(message, secret: key, now: Date()) {
            return true
        }
        return iCloudBridge.isAuthenticatedControlAction(message, secret: key)
    }
}
/// Receipts describe only observed Mac boundaries; phone fetch, display and acknowledgement require signed return evidence.
enum ChatDeliveryReceiptStatus: String, Sendable {
    case failedBeforeDispatch = "failed_before_dispatch"
    case dispatchReserved = "dispatch_reserved"
    case submissionUnknown = "submission_unknown"
    /// A filesystem write was admitted, but its commit has not been observed.
    case commitUnverified = "commit_unverified"
    /// The Drive file exists locally and still depends on iCloud replication.
    case queuedForICloudSync = "queued_for_icloud_sync"
    /// CloudKit accepted the outbound record, but iOS has not acknowledged it.
    case acceptedByTransport = "accepted_by_transport"
    case deliveredToMac = "delivered_to_mac"
    case confirmedByPeer = "confirmed_by_peer"
    var deliveryConfirmed: Bool {
        switch self {
        case .failedBeforeDispatch, .dispatchReserved, .submissionUnknown, .commitUnverified, .queuedForICloudSync, .acceptedByTransport:
            return false
        case .deliveredToMac, .confirmedByPeer:
            return true
        }
    }
}
