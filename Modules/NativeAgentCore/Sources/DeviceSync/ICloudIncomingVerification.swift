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
/// A chat receipt describes the furthest boundary this Mac actually observed.
/// Neither state implies that iOS fetched, displayed, or acknowledged the
/// message; that would require a separate signed return receipt from iOS.
enum ChatDeliveryReceiptStatus: String, Sendable {
    case failedBeforeDispatch = "failed_before_dispatch"
    /// The Drive file exists locally and still depends on iCloud replication.
    case queuedForICloudSync = "queued_for_icloud_sync"
    /// CloudKit accepted the outbound record, but iOS has not acknowledged it.
    case acceptedByTransport = "accepted_by_transport"
    /// The Mac verified and delivered the inbound peer message to the runtime.
    case deliveredToMac = "delivered_to_mac"
    /// The peer later confirmed delivery of a Mac-originated notification.
    case confirmedByPeer = "confirmed_by_peer"
    var deliveryConfirmed: Bool {
        switch self {
        case .failedBeforeDispatch, .queuedForICloudSync, .acceptedByTransport:
            return false
        case .deliveredToMac, .confirmedByPeer:
            return true
        }
    }
}
