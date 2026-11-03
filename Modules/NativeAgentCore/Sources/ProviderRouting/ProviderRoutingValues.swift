import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `ProviderRoutingValues.swift` | Provider and surface scalar interpretation with stable saved JSON vocabulary; saved reasoning-effort projection normalizes spelling and checks the exact route descriptor without substituting another effort; declared OpenRouter no-selector rows admit omission only |

extension SwiftNativeProviderRouting {
    nonisolated static func normalizeProviderId(_ raw: String) -> String {
        ProviderFamilyIdentity.normalize(raw)
    }
    /// Reads `providers/surfaces.json` and returns the explicitly-pinned model for `surface` only when the key is present (and non-empty). Returns nil for any unpinned surface, so dream / REM can fall back to the chat-surface picker
    /// without confusing a catalog seed for a user pin. Parse `providers/surfaces.json` as nested model/effort/tier controls only as objects. The checked state boundary has already validated string-valued controls.
    nonisolated static func parseSurfacesFile(_ raw: JSONValue) -> (JSONValue, JSONValue, JSONValue) {
        guard case .object(let obj) = raw, !obj.isEmpty else {
            return (.object([:]), .object([:]), .object([:]))
        }
        var models: [String: JSONValue] = [:]
        var efforts: [String: JSONValue] = [:]
        var tiers: [String: JSONValue] = [:]
        for (surface, entry) in obj {
            switch entry {
            case .object(let inner):
                if let m = Self.stringFrom(.object(inner), key: "model") {
                    models[surface] = .string(m)
                }
                if case .string(let e)? = inner["reasoningEffort"], !e.isEmpty {
                    efforts[surface] = .string(e)
                }
                if case .string(let tier)? = inner["serviceTier"], !tier.isEmpty {
                    tiers[surface] = .string(tier)
                }
            default:
                continue
            }
        }
        return (.object(models), .object(efforts), .object(tiers))
    }
    /// Identify surfaces with catalog-retired picks so their whole tuple is removed. Unknown OpenRouter/self-hosted IDs remain admitted by this check.
    nonisolated static func surfacesWithRetiredPicks(
        _ models: JSONValue,
        accountModels: [String: Set<String>] = [:],
        routeForSurface: (String, String) -> String?
    ) -> Set<String> {
        guard case .object(let obj) = models else { return [] }
        var retired: Set<String> = []
        for (surface, value) in obj {
            guard case .string(let model) = value,
                  !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let route = routeForSurface(surface, model)
            let carried = route.flatMap {
                accountModels[$0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
            }.map {
                $0.contains(model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            } ?? FirstPartyModelCatalog.routeCarries(model, providerID: route)
            if !carried {
                retired.insert(surface)
            }
        }
        return retired
    }
    nonisolated static func dropping(_ surfaces: Set<String>, from value: JSONValue) -> JSONValue {
        guard case .object(let obj) = value, !surfaces.isEmpty else { return value }
        return .object(obj.filter { !surfaces.contains($0.key) })
    }
    nonisolated static func normalizeModelIdStatic(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        if trimmed.count > 100 { return fallback }
        // Model syntax admits only [A-Za-z0-9._:/+-], at most 100 characters.
        let allowed: Set<Character> = {
            var s: Set<Character> = []
            for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:/+-" {
                s.insert(c)
            }
            return s
        }()
        for ch in trimmed {
            if !allowed.contains(ch) { return fallback }
        }
        // Normalization checks syntax only; catalog admission belongs to routing reads.
        return trimmed
    }
    nonisolated static func normalizeReasoningEffortStatic(
        _ raw: String,
        model: String?,
        providerID: String? = nil,
        supportedReasoningEfforts: [String]? = nil
    ) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let model, !model.isEmpty else { return normalized }
        let supported = supportedReasoningEfforts
            ?? FirstPartyModelCatalog.routeSupportedEfforts(model, providerID: providerID ?? "")
        guard let supported else {
            throw ProviderRoutingError.configurationFailed("The Think controls for \(model) on \(providerID ?? "the selected account") are unknown. Refresh its catalog in Providers.")
        }
        if providerID == "openrouter", supported.isEmpty,
           normalized.isEmpty || normalized == "default" { return normalized }
        guard supported.contains(normalized) else {
            throw ProviderRoutingError.configurationFailed("Think level '\(raw)' is unsupported for \(model). Choose one of \(supported.joined(separator: ", ")) in Providers.")
        }
        return normalized
    }
    nonisolated static func normalizeServiceTierStatic(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    /// Read a nonempty string from already checked routing state.
    nonisolated static func stringFrom(_ node: JSONValue, key: String) -> String? {
        guard case .object(let obj) = node, case .string(let value)? = obj[key], !value.isEmpty else { return nil }
        return value
    }
    nonisolated static func firstString(
        _ obj: [String: JSONValue],
        keys: [String]
    ) -> String? {
        for key in keys {
            if case .string(let s)? = obj[key] {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}
