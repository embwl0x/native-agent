import Foundation

extension MacSyncActionRouter {
    /// dispatch has already checked the HMAC and the approved phone signature.
    /// Keep plaintext scoped to this call; the original envelope stays sealed.
    func configureEncryptedProvider(_ action: InboxAction) async -> [String: String] {
        do {
            guard action.payload.count == 1,
                  let sealed = action.payload[SecretActionEnvelope.field],
                  let encodedSecret = try PairingSecretManager.existingSecretBase64(),
                  let secret = Data(base64Encoded: encodedSecret) else {
                return providerFailure("Could not decrypt the credential. Check pairing and try again.")
            }
            let fields = try SecretActionEnvelope.open(
                sealed, secret: secret, actionID: action.msgId, actionName: action.action
            )
            guard Set(fields.keys) == ["providerId", "api_key"],
                  let id = fields["providerId"],
                  ["openai", "anthropic", "openrouter", "moonshot", "kimi-code"].contains(id),
                  let key = fields["api_key"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty, key.utf8.count <= 8_192,
                  !key.contains(where: { $0.isNewline }) else {
                return providerFailure("A supported provider and a nonempty API key are required.")
            }
            try await sync.host.configureProvider(id, apiKey: key, authMode: "api_key", defaultModel: nil)
            let probe = try await sync.host.testProvider(id)
            let verified = probe.tested == true && probe.status == "ok"
            return ["status": "ok", "ok": "true", "provider_id": id,
                    "connection_state": verified ? "verified" : "unverified",
                    "message": verified ? "Key saved. Connection verified on Mac."
                        : "Key saved, but the Mac could not verify the connection. Check the key and try Test connection."]
        } catch {
            // Provider/network errors can contain server-controlled text. Never
            // forward them, decrypted input, or credential-owner errors to iCloud.
            return providerFailure("The Mac could not save and verify the provider credential.")
        }
    }

    func startProviderSignIn(_ action: InboxAction) async -> [String: String] {
        let id = action.payload["providerId"] ?? ""
        guard ["openai_oauth_direct", "anthropic_oauth_direct", "xai_oauth_direct"].contains(id) else {
            return providerFailure("This provider’s sign-in must be managed on the Mac.")
        }
        return sync.host.startProviderSignIn(id, requestID: action.msgId)
    }

    private func providerFailure(_ message: String) -> [String: String] {
        ["status": "error", "ok": "false", "connection_state": "unverified", "message": message]
    }
}
