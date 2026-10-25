// PATCH-2026-05-07: ios-sync MacSyncEngine — SnapshotWriter + InboxWatcher (Mac side)
// SnapshotWriter: every N seconds writes app-owned Swift runtime state to iCloud Drive `snapshots/`.
//   Touches KVS key `snapshot_updated` so iOS observes immediately.
// InboxWatcher: NSMetadataQuery on `inbox/`. When iOS drops an action JSON, dispatch to
//   the in-process Swift runtime, write response to `responses/<msg_id>.json`, touch KVS `inbox_response_<msg_id>`.

import AppKit
import Foundation
import NativeAgentShared
import NativeAgentCore
import MemoryV2
import PersistenceCore
// Blueprint: | `MacSyncEngine+Security.swift` | MacSyncEngine pairing rotation and signed responses; complete signed CloudKit action-record budgeting before terminal ledger settlement; oversized readbacks return an explicit processed-action error; BridgeMessage owns HMAC, constant-time comparison and inner-action verification; outer signatures remain case-sensitive |

extension MacSyncEngine {
    // C.1: HMAC pairing secret — loaded lazily on first use via PairingSecretManager (single source of truth).
    // TODO(iOS-side): iOS sender must compute HMAC-SHA256 over the canonical
    // JSON body (fields sorted, "signature" key excluded) and include it as
    // the "signature" field in the JSON.  Until then all unsigned messages are
    // rejected when signature validation is enforced.

    func pairingSecret() throws -> Data {
        guard !pairingSecretRotationInProgress else {
            throw NSError(
                domain: "MacSyncEngine.Security",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "pairing key rotation is in progress"]
            )
        }
        if let s = _pairingSecret { return s }
        let s = try PairingSecretManager.loadOrGenerateSecret()
        _pairingSecret = s
        return s
    }

    /// Close the HMAC boundary before canonical pairing bytes are replaced.
    /// Inbound validation/signing remains unavailable until `finish` installs
    /// the exact bytes returned by durable rotation.
    public func beginPairingSecretRotation() {
        pairingSecretRotationInProgress = true
        _pairingSecret = nil
    }

    public func finishPairingSecretRotation(with persistedSecret: Data?) async {
        _pairingSecret = persistedSecret
        pairingSecretRotationInProgress = false
        // Revoke the old Drive write generation and republish into this key's
        // directory. Late writes remain confined to their captured old URL.
        if inboxDir != nil, let docsURL = activeDocsURL {
            stop()
            await start(docsURL: docsURL)
        }
    }

    func actionResponse(_ response: [String: String], for action: InboxAction) throws -> [String: String] {
        var body = response
        body["msgId"] = action.msgId
        body["transactionId"] = action.transactionId ?? action.msgId
        body["action"] = action.action
        return try signedResponse(body)
    }

    /// Budget the complete signed record before it becomes the terminal ledger
    /// response. Oversized readbacks settle explicitly; delivery never replays
    /// an undeliverable response or repeats its already-processed action.
    func deliverableActionResponse(_ response: [String: String], for action: InboxAction) throws -> [String: String] {
        let signed = try actionResponse(response, for: action)
        let message = try sync.bridge.cloudKitActionResponseMessage(signed, correlationID: action.msgId)
        do {
            _ = try NAChatMessageCodec.encode(message)
            return signed
        } catch DeviceSyncError.payloadTooLarge {
            var terminal = ["status": "error", "ok": "false", "code": "action_readback_too_large",
                "message": "The Mac processed this action, but its readback exceeds the delivery limit. Refresh the page to read its current state. Do not repeat the action."]
            for key in ["approvalId", "resolvedProposalId", "memoryId", "inboxItemId", "decisionAccepted", "decisionStatus", "approvalReadbackRevision", "inboxReadbackRevision", "memoryReadbackRevision"] {
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
        let lower = message.lowercased()
        let code: String
        if lower.contains("hmac") || lower.contains("signature wrong") {
            code = "signature_invalid"
        } else if lower.hasPrefix("message too old:") {
            code = "expired_before_execution"
        } else if lower.contains("timestamp") {
            code = "timestamp_invalid"
        } else {
            code = "signature_required"
        }
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
        // Off-main write, but AWAITED so the kvs signal ordering and caller
        // sequencing are preserved (no fire-and-forget race).
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

    /// Write `data` to `url` with atomic semantics. Returns an error description on failure, nil on success.
    /// Must be nonisolated static — called from detached tasks off the main actor.
    nonisolated static func atomicWrite(data: Data, to url: URL) -> String? {
        do {
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The ±5-minute window on its own, separated from authenticity (2026-09-06)
    /// so the Drive inbox lane can ask the two questions in the order that lane
    /// needs: HMAC first, because anything on the account can write into that
    /// folder, then the ledger, and freshness LAST — an action that already
    /// executed is answered from its ledger row no matter how long the
    /// redelivery took, and freshness only ever gates NEW work.
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

    /// HMAC-SHA256 of the canonical body (JSON with keys sorted, signature excluded)
    /// must match the "signature" field. Freshness gates new work after ledger lookup.
    /// Returns nil on success, or an error string to log/reject.
    func validateInboxAction(
        data: Data,
        action: InboxAction
    ) async -> String? {
        guard let sig = action.signature else {
            // S.2: write an upgrade-required response so old iOS apps get a clear error
            // instead of timing out waiting for a response that never comes.
            let responseURL = responsesDir.flatMap {
                InboxActionFileBoundary.jsonURL(in: $0, validatedID: action.msgId)
            }
            // fix-R9-3 Use [String: String] so iOS's JSONDecoder([String:String]) can parse it.
            guard let upgradeResp = try? signedResponse([
                "msgId":     action.msgId,
                "ok":        "false",
                "error":     "iOS app needs upgrade to enable HMAC signing. Update via App Store / TestFlight.",
                "code":      "signature_required",
                "createdAt": ISO8601DateFormatter().string(from: Date()),
            ]) else {
                return "pairing secret unavailable — could not sign upgrade response"
            }
            // PATCH-2026-05-08: review-fix-r7 Only set KVS after a successful
            // atomic write. Otherwise old iOS gets pinged but finds no
            // response file, and times out anyway.
            var wrote = false
            if let data = try? JSONSerialization.data(withJSONObject: upgradeResp),
               let url = responseURL {
                // crash-class-1: move iCloud write off the MainActor.
                let writeError = await Task.detached(priority: .utility) { [data, url] in
                    Self.atomicWrite(data: data, to: url)
                }.value
                if let writeError {
                    // surface in returned error
                    return "missing signature — failed to write upgrade response: \(writeError)"
                }
                wrote = true
            }
            if wrote {
                let msgId = action.msgId
                _ = await withCKTimeout("MacSyncEngine.validateInboxAction.upgradeResponseKVS") {
                    let kvs = NSUbiquitousKeyValueStore.default
                    kvs.set(msgId, forKey: "inbox_response_\(msgId)")
                    return kvs.synchronize()
                }
            }
            return "missing signature — upgrade response written for iOS client"
        }

        return BridgeMessage.innerActionSignatureError(data: data, signature: sig, secret: pairingSecret)
    }
}
