import AppKit
import Foundation
import NativeAgentShared
import NativeAgentCore
import MemoryV2
import PersistenceCore
// Blueprint: | `MacSyncEngine+Security.swift` | Pairing verification gates signing; bounded signed responses settle ledger outcomes. |

extension MacSyncEngine {
    func pairingSecret() throws -> Data {
        guard !pairingSecretRotationInProgress else {
            throw NSError(
                domain: "MacSyncEngine.Security",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "pairing key rotation is in progress"]
            )
        }
        if let s = _pairingSecret { return s }
        let s = try sync.bridge.pairingPublicationOwed
            ? PairingSecret.requireExistingSecret() : PairingSecret.loadOrGenerateSecret()
        _pairingSecret = s
        return s
    }

    /// Close signing and validation before key replacement; reopen only on exact canonical readback.
    public func beginPairingSecretRotation() {
        pairingSecretRotation = .writing
        _pairingSecret = nil
    }

    /// The write has exited, but signing stays closed until its exact item is read.
    public func awaitPairingSecretVerification() {
        pairingSecretRotation = .awaitingVerification
    }

    public func finishPairingSecretRotation(with persistedSecret: Data?) async {
        _pairingSecret = persistedSecret
        pairingSecretRotation = nil
        // Revoke the old write generation; captured URLs confine late writes to the old key's directory.
        if inboxDir != nil, let docsURL = activeDocsURL {
            stop()
            await start(docsURL: docsURL)
        }
    }

    func actionResponse(_ response: [String: String], for action: InboxAction) throws -> [String: String] {
        var body = response
        body["result_class"] = InboxAction.responseResultClass(response)
        body["msgId"] = action.msgId
        body["transactionId"] = action.transactionId ?? action.msgId
        body["action"] = action.action
        return try signedResponse(body)
    }

    /// Budget the full signed terminal response so oversized readbacks cannot cause undeliverable replay or repeated actions.
    func deliverableActionResponse(_ response: [String: String], for action: InboxAction) throws -> [String: String] {
        let signed = try actionResponse(response, for: action)
        let message = try sync.bridge.cloudKitActionResponseMessage(signed, correlationID: action.msgId)
        do {
            _ = try NAChatMessageCodec.encode(message)
            return signed
        } catch DeviceSyncError.payloadTooLarge {
            var terminal = ["status": "error", "ok": "false", "code": "action_readback_too_large",
                "message": """
                    The Mac processed this action, but its readback exceeds the delivery limit. Refresh the page to read its current state. Do not \
                    repeat the action.
                    """]
            for key in [
                "approvalId",
                "resolvedProposalId",
                "memoryId",
                "inboxItemId",
                "decisionAccepted",
                "decisionStatus",
                "approvalReadbackRevision",
                "inboxReadbackRevision",
                "memoryReadbackRevision"] {
                terminal[key] = response[key].map { String($0.prefix(512)) }
            }
            terminal["effectStatus"] = response["status"].map { String($0.prefix(80)) }
            let bounded = try actionResponse(terminal, for: action)
            _ = try NAChatMessageCodec.encode(sync.bridge.cloudKitActionResponseMessage(bounded, correlationID: action.msgId))
            return bounded
        }
    }

    func signedResponse(_ response: [String: String]) throws -> [String: String] {
        var body = response
        body.removeValue(forKey: "signature")
        guard let canonical = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            throw NSError(
                domain: "MacSyncEngine.Security",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "response could not be canonicalized"]
            )
        }
        body["signature"] = BridgeMessage.hmacHex(of: canonical, secret: try pairingSecret())
        return body
    }

    func authenticateInboxResponse(_ response: [String: String]) -> Bool {
        guard let signature = response["signature"],
              let expected = try? signedResponse(response)["signature"] else { return false }
        return BridgeMessage.constantTimeEqual(signature.lowercased(), expected)
    }

    @discardableResult
    func writeRejectedResponseIfNeeded(
        action: InboxAction,
        transactionId: String,
        message: String
    ) async -> Bool {
        guard let responsesDir,
              let responseURL = InboxActionFileBoundary.jsonURL(
                in: responsesDir,
                validatedID: action.msgId
              ) else { return false }
        guard !FileManager.default.fileExists(atPath: responseURL.path) else { return true }
        let code = message.hasPrefix("message too old:") ? "expired_before_execution" : "timestamp_invalid"
        guard let response = try? signedResponse([
            "status": "error",
            "ok": "false",
            "code": code,
            "message": message,
            "msgId": action.msgId,
            "transactionId": transactionId,
            "action": action.action,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ]) else {
            syncError = "Pairing secret unavailable; rejection response was not written."
            return false
        }
        guard let responseData = try? JSONEncoder().encode(response) else { return false }
        let msgId = action.msgId
        // Await off-main writes so KVS signalling and caller transitions remain ordered.
        let writeError = await Task.detached(priority: .utility) { [responseURL, responseData] in
            Self.atomicWrite(data: responseData, to: responseURL)
        }.value
        if let writeError {
            syncError = "Could not write rejection response for \(msgId): \(writeError)"
            return false
        } else {
            _ = await withCKTimeout("MacSyncEngine.writeRejectedResponse.kvsSignal") {
                let kvs = NSUbiquitousKeyValueStore.default
                kvs.set(msgId, forKey: "inbox_response_\(msgId)")
                return kvs.synchronize()
            }
            return true
        }
    }

    /// Nonisolated for detached storage work; report atomic write failure rather than losing it.
    nonisolated static func atomicWrite(data: Data, to url: URL) -> String? {
        do {
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Apply the ±5-minute freshness window only to new work, after HMAC verification and ledger lookup.
    func inboxActionFreshnessError(_ action: InboxAction) -> String? {
        guard let ts = NativeTimestampFormat.parseISO8601FractionalFirst(action.createdAt) else {
            return "invalid timestamp: \(action.createdAt)"
        }
        let age = Date().timeIntervalSince(ts)
        if age > 300 {
            return "message too old: \(Int(age))s"
        }
        if age < -300 {
            return "timestamp is too far in the future: \(Int(-age))s"
        }
        return nil
    }

}
