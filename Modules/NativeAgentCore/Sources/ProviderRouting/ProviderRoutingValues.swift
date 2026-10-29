import Foundation
import NativeAgentShared
import CryptoKit
import NativeAgentCore
import PersistenceCore
import os
// Blueprint: | `ProviderRoutingValues.swift` | Provider and surface scalar interpretation with stable saved JSON vocabulary |

extension SwiftNativeProviderRouting {
    nonisolated static func normalizeProviderId(_ raw: String) -> String {
        ProviderFamilyIdentity.normalize(raw)
    }
    /// Reads `providers/surfaces.json` and returns the explicitly-pinned model for `surface` only when the key is present (and non-empty). Returns nil for any unpinned surface, so dream / REM can fall back to the chat-surface picker
    /// without confusing a catalog seed for a user pin. Parse `providers/surfaces.json` as nested model/effort/tier controls or flat model strings. The checked state boundary has already validated string-valued controls.
    nonisolated static func parseSurfacesFile(_ raw: JSONValue) -> (JSONValue, JSONValue, JSONValue) {
        guard case .object(let obj) = raw, !obj.isEmpty else {
            return (.object([:]), .object([:]), .object([:]))
        }
        var models: [String: JSONValue] = [:]
        var efforts: [String: JSONValue] = [:]
        var tiers: [String: JSONValue] = [:]
        for (surface, entry) in obj {
            switch entry {
            case .string(let s):
                if !s.isEmpty { models[surface] = .string(s) }
            case .object(let inner):
                if let m = Self.stringFrom(.object(inner), key: "model") {
                    models[surface] = .string(m)
                }
                if case .string(let e)? = inner["reasoningEffort"], !e.isEmpty {
                    efforts[surface] = .string(e)
                } else if case .string(let e)? = inner["reasoning_effort"], !e.isEmpty {
                    efforts[surface] = .string(e)
                }
                if case .string(let tier)? = inner["serviceTier"], !tier.isEmpty {
                    tiers[surface] = .string(tier)
                } else if case .string(let tier)? = inner["service_tier"], !tier.isEmpty {
                    tiers[surface] = .string(tier)
                } else if case .bool(let fast)? = inner["fastMode"] {
                    tiers[surface] = .string(fast ? "priority" : "default")
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
        fallback: String,
        model: String?,
        providerID: String? = nil,
        supportedReasoningEfforts: [String]? = nil
    ) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard REASONING_EFFORT_OPTIONS.contains(normalized) else { return fallback }
        let lowerModel = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let route = providerID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        // The model's row declares its efforts, never its spelling: the account's own row when the caller has it, else the route's shipped row (Moonshot's live-only ids from its catalog), else any shipped row.
        let supported = Set(supportedReasoningEfforts
            ?? FirstPartyModelCatalog.routeSupportedEfforts(lowerModel, providerID: route)
            ?? (route == "moonshot" ? MoonshotModelCatalog.supportedReasoningEfforts(for: lowerModel) : nil)
            ?? FirstPartyModelCatalog.descriptor(for: lowerModel)?.supportedReasoningEfforts
            ?? ["low", "medium", "high", "xhigh"])
        guard supported.contains(normalized) else {
            let cleanFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if supported.contains(cleanFallback) { return cleanFallback }
            if supported.contains("high") { return "high" }
            for candidate in REASONING_EFFORT_OPTIONS where supported.contains(candidate) {
                return candidate
            }
            return "high"
        }
        return normalized
    }
    nonisolated static func normalizeServiceTierStatic(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "priority", "fast": return "priority"
        default: return "default"
        }
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
