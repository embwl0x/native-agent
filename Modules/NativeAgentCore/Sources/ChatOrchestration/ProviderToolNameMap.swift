import Foundation
import NativeAgentCore

/// Maps NativeAgent's internal tool names to provider-safe names.
///
/// Internal MCP bridge names intentionally preserve server/tool identity
/// (`mcp__server-id__tool.name`). Some providers only accept a narrow
/// `[A-Za-z0-9_]` name at the wire boundary, so the LLM sees aliases while
/// dispatch still receives the original names.
struct ProviderToolNameMap: Sendable {
    let schemas: [LLMToolSchema]
    private let providerToInternal: [String: String]

    init(_ internalSchemas: [LLMToolSchema]) {
        var used: Set<String> = []
        var aliases: [String: String] = [:]
        var publicSchemas: [LLMToolSchema] = []

        for schema in internalSchemas {
            let providerName = Self.uniqueProviderName(for: schema.name, used: &used)
            aliases[providerName] = schema.name
            let description: String
            if providerName == schema.name {
                description = schema.description
            } else {
                description = "\(schema.description) NativeAgent dispatch name: \(schema.name)."
            }
            publicSchemas.append(LLMToolSchema(
                name: providerName,
                description: description,
                parametersJSON: schema.parametersJSON
            ))
        }

        self.schemas = publicSchemas
        self.providerToInternal = aliases
    }

    func internalName(forProviderName providerName: String) -> String {
        providerToInternal[providerName] ?? providerName
    }

    static func providerName(for internalName: String) -> String {
        let filtered = internalName.unicodeScalars.map { scalar -> Character in
            if isASCIIAlnum(scalar) || scalar == "_" {
                return Character(scalar)
            }
            return "_"
        }
        var name = String(filtered)
        while name.contains("__") {
            name = name.replacingOccurrences(of: "__", with: "_")
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if name.isEmpty { name = "tool" }
        if name.count > 128 {
            let suffix = stableSuffix(for: internalName)
            let prefixLength = max(1, 128 - suffix.count - 1)
            name = "\(String(name.prefix(prefixLength)))_\(suffix)"
        }
        return name
    }

    private static func uniqueProviderName(for internalName: String, used: inout Set<String>) -> String {
        let base = providerName(for: internalName)
        if !used.contains(base) {
            used.insert(base)
            return base
        }

        let suffix = stableSuffix(for: internalName)
        let prefixLength = max(1, 128 - suffix.count - 1)
        var candidate = "\(String(base.prefix(prefixLength)))_\(suffix)"
        var attempt = 2
        while used.contains(candidate) {
            let attemptSuffix = "\(suffix)_\(attempt)"
            let attemptPrefixLength = max(1, 128 - attemptSuffix.count - 1)
            candidate = "\(String(base.prefix(attemptPrefixLength)))_\(attemptSuffix)"
            attempt += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func isASCIIAlnum(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }

    private static func stableSuffix(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
