import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `ProviderConfiguration.swift` | Byte-checked provider configuration decode under the writer's lock with fresh credential/readiness facts |

extension SwiftNativeProviderRouting {
    nonisolated static func providerConfigurationRevision(_ data: Data?) -> String {
        guard let data else { return "absent" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public nonisolated func confirmsDisconnection(_ id: String) throws -> Bool {
        guard !id.isEmpty, id.allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789_-".contains($0) }) else {
            throw ProviderRoutingError.invalidRequest
        }
        let read = readProviderConfig(id)
        if let issue = read.unreadable { throw ProviderRoutingError.configurationFailed(issue) }
        if id == "openai_oauth_direct" || id == "codex" {
            // These routes share app auth, its access-only child copy and CLI-adoption consent.
            // The independently owned CLI session may remain; it must no longer be admitted here.
            let auth = NativeOAuthFlow.openAIAppOwnedAuthPath(dataRoot: dataRoot)
            let credentialsAbsent = try CredentialFileLock.withLock(auth) {
                let app = try ChatGPTTransport.loadAuthBlob(at: auth)
                let child = try ProviderStateValidation.dataIfPresent(
                    at: ChatGPTTransport.codexChildHome(dataRoot: dataRoot).appendingPathComponent("auth.json"))
                return app == nil && child == nil
            }
            switch ChatGPTTransport.cliAdoptionConsentState(dataRoot: dataRoot) {
            case .allowed: return false
            case .corrupt(let reason): throw ProviderRoutingError.configurationFailed(reason)
            case .missing, .declined: return read.object == nil && credentialsAbsent
            }
        }
        return read.object == nil
    }
    public nonisolated func confirmsConnection(_ request: ProviderConnectionWrite) throws -> Bool {
        let read = readProviderConfig(request.id)
        if let issue = read.unreadable { throw ProviderRoutingError.configurationFailed(issue) }
        guard let object = read.object, object["auth_mode"] as? String == request.authMode else { return false }
        if !request.defaultModel.isEmpty, object["default_model"] as? String != request.defaultModel { return false }
        if let bytes = request.secret, let key = String(data: bytes, encoding: .utf8),
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return object["api_key"] as? String == key.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return true
    }

    public nonisolated func confirmsAnthropicToken(_ bytes: Data) throws -> Bool {
        let read = readProviderConfig("anthropic_oauth_direct")
        if let issue = read.unreadable { throw ProviderRoutingError.configurationFailed(issue) }
        guard let object = read.object, let token = String(data: bytes, encoding: .utf8) else { return false }
        return object["access_token"] as? String == NativeOAuthFlow.normalizedSetupToken(token)
    }
    /// Read config bytes under the writer's lock. Reuse only validated decodes; credentials remain fresh and absent differs from unreadable.
    struct ProviderConfigRead {
        var object: [String: Any]?
        var unreadable: String?
        var revision: String?
    }
    /// Readiness and default-model selection share each provider file's one read under the writer's lock, so a snapshot never combines saved states.
    struct ProviderConfigCache {
        var reads: [String: ProviderConfigRead] = [:]
        var readiness: [String: (ready: Bool, state: String, detail: String)] = [:]
        /// All readiness branches share the snapshot's one checks read.
        var receipts: LLMProviderStatusFeed.Receipts?
    }
    nonisolated func readProviderConfig(_ providerId: String) -> ProviderConfigRead {
        let trimmedId = providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty, !trimmedId.contains("/") else { return ProviderConfigRead() }
        let path = dataRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("\(trimmedId).json")
        do { _ = try FileManager.default.attributesOfItem(atPath: path.path) }
        catch CocoaError.fileReadNoSuchFile { return ProviderConfigRead(revision: Self.providerConfigurationRevision(nil)) }
        catch { return ProviderConfigRead(unreadable: "Provider \(trimmedId) at \(path.path) could not be read: \(error.localizedDescription)") }
        do {
            return try CredentialFileLock.withLock(path) { () -> ProviderConfigRead in
                guard let data = try ProviderStateValidation.dataIfPresent(at: path) else {
                    return ProviderConfigRead(revision: Self.providerConfigurationRevision(nil))
                }
                let read = try configurationGenerations.withLockUnchecked { generations -> ProviderConfigRead in
                    if let generation = generations[trimmedId], generation.bytes == data { return generation.read }
                    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return ProviderConfigRead(unreadable: "provider \(trimmedId) configuration is not a JSON object")
                    }
                    guard case .object(let fields) = JSONValue(fromFoundation: object) else {
                        return ProviderConfigRead(unreadable: "provider configuration is malformed")
                    }
                    try Self.validateProviderConfiguration(fields)
                    if trimmedId == "xai_oauth_direct" { try ProviderStateValidation.credential(object) }
                    let read = ProviderConfigRead(object: object, revision: Self.providerConfigurationRevision(data))
                    if generations[trimmedId] == nil, generations.count >= 32 { generations.removeAll(keepingCapacity: true) }
                    generations[trimmedId] = (data, read)
                    return read
                }
                guard var object = read.object else { return read }
                do {
                    if trimmedId == "xai_oauth_direct" {
                        object = try XAIOAuthCredentialStore.resolve(object, at: path)
                    }
                    // Resolve the Keychain reference under the config writer's lock so readiness and model settings share one credential generation.
                    guard object["api_key"] == nil else {
                        throw ProviderRoutingError.configurationFailed(
                            "Provider \(trimmedId) has plaintext API-key bytes. Save its key in Providers to repair its storage.")
                    }
                    if object[ProviderAPIKeyStore.referenceField] != nil {
                        let key = try LLMCredentialResolver.checkedAPIKey(providerConfigObject: object)
                        object.removeValue(forKey: ProviderAPIKeyStore.referenceField)
                        object["api_key"] = key
                    }
                    return ProviderConfigRead(object: object, revision: read.revision)
                } catch {
                    // A failed grant read does not erase the checked configuration bytes needed to replace that grant.
                    return ProviderConfigRead(unreadable: "provider \(trimmedId) credentials are unavailable: \(error.localizedDescription)",
                        revision: read.revision)
                }
            }
        } catch {
            return ProviderConfigRead(
                unreadable: "provider \(trimmedId) configuration is unavailable: \(error.localizedDescription)"
            )
        }
    }
    /// Pre-read every probe/surface config once; reuse checked bytes while credentials, expiry, PATH and receipt age stay fresh.
    nonisolated func providerConfigCache(
        for providerIds: Set<String>,
        authEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProviderConfigCache {
        var cache = ProviderConfigCache(receipts: LLMProviderStatusFeed.receipts(dataRoot: dataRoot))
        for id in providerIds {
            let trimmedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedId.isEmpty, !trimmedId.contains("/") else { continue }
            cache.reads[trimmedId] = readProviderConfig(trimmedId)
        }
        for id in cache.reads.keys {
            cache.readiness[id] = providerReadiness(id: id, cache: cache, authEnvironment: authEnvironment)
        }
        return cache
    }
}
