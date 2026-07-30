import Foundation
import PersistenceCore

// MARK: - TrustPolicy

/// The complete trust/permission policy shape. Top-level keys include
/// `permissionLevel`, `autonomyDefault`, `updatedAt`, `appDataRoot`,
/// `missionPolicy`, `toolAutonomy` (a long dict of action→autonomy
/// strings), plus surface-specific blocks (macControlPolicy, filePolicy,
/// telegramPolicy, iosRemotePolicy, multimodalPolicy, trainingPolicy,
/// promotionPolicy, skillBuilderPolicy, inboxPolicy, enableAutonomy,
/// etc.). Because the surface dict is large and evolves, we extract only
/// the headline scalars typed and keep `extras` for everything else.
public struct TrustPolicy: Sendable, Codable, Equatable {
    public var permissionLevel: String?
    public var autonomyDefault: String?
    public var updatedAt: String?
    public var appDataRoot: String?
    public var extras: JSONValue?

    public init(
        permissionLevel: String? = nil,
        autonomyDefault: String? = nil,
        updatedAt: String? = nil,
        appDataRoot: String? = nil,
        extras: JSONValue? = nil
    ) {
        self.permissionLevel = permissionLevel
        self.autonomyDefault = autonomyDefault
        self.updatedAt = updatedAt
        self.appDataRoot = appDataRoot
        self.extras = extras
    }

    private static let knownKeys: Set<String> = [
        "permissionLevel", "autonomyDefault", "updatedAt", "appDataRoot",
        "extras",
    ]

    private struct AnyKey: CodingKey, Hashable {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { self.stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func str(_ k: String) throws -> String? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return try c.decodeIfPresent(String.self, forKey: key)
        }
        func jv(_ k: String) throws -> JSONValue? {
            guard let key = AnyKey(stringValue: k) else { return nil }
            return try c.decodeIfPresent(JSONValue.self, forKey: key)
        }
        self.permissionLevel = try str("permissionLevel")
        self.autonomyDefault = try str("autonomyDefault")
        self.updatedAt = try str("updatedAt")
        self.appDataRoot = try str("appDataRoot")

        var unknown: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            if let v = try? c.decode(JSONValue.self, forKey: key) {
                unknown[key.stringValue] = v
            }
        }
        if let explicit = try jv("extras") {
            if case .object(let obj) = explicit {
                for (k, v) in obj { unknown[k] = v }
            } else {
                unknown["_extras_value"] = explicit
            }
        }
        self.extras = unknown.isEmpty ? nil : .object(unknown)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeIfPresent(permissionLevel, forKey: AnyKey("permissionLevel"))
        try c.encodeIfPresent(autonomyDefault, forKey: AnyKey("autonomyDefault"))
        try c.encodeIfPresent(updatedAt, forKey: AnyKey("updatedAt"))
        try c.encodeIfPresent(appDataRoot, forKey: AnyKey("appDataRoot"))
        if case .object(let obj)? = extras {
            for (k, v) in obj where !Self.knownKeys.contains(k) {
                try c.encode(v, forKey: AnyKey(k))
            }
        }
    }
}

// MARK: - AutonomyPolicy

/// Autonomy policy summary. Top-level keys include `status`, `permissionLevel`,
/// `fullMacMode`, and `gates` (array of {id, title, enabled, value,
/// status, detail, source}), plus a long tail of summary/surface fields.
/// We extract the headline scalars typed and keep `rawResponse` so callers
/// can introspect anything off the long tail.
public struct AutonomyPolicy: Sendable, Codable, Equatable {
    public var status: String?
    public var permissionLevel: String?
    public var fullMacMode: String?
    public var gates: [JSONValue]?
    public var rawResponse: JSONValue

    public init(
        status: String? = nil,
        permissionLevel: String? = nil,
        fullMacMode: String? = nil,
        gates: [JSONValue]? = nil,
        rawResponse: JSONValue = .object([:])
    ) {
        self.status = status
        self.permissionLevel = permissionLevel
        self.fullMacMode = fullMacMode
        self.gates = gates
        self.rawResponse = rawResponse
    }
}

// MARK: - Default trusted workspace roots

/// Trust Center roots that should be treated as app-approved workspaces even
/// when broad Full Mac mode is off.
public enum TrustCenterDefaultWorkspaceRoots {
    public static func obsidianDocumentsRoot(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("iCloud~md~obsidian", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
            .standardizedFileURL
    }

    public static func defaultRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        dataRoot: URL = defaultDataRoot()
    ) -> [URL] {
        [
            NativeAgentWorkspaceRoot.resolve(dataRoot: dataRoot),
            obsidianDocumentsRoot(homeDirectory: homeDirectory),
        ]
    }

    public static func defaultRootPaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        dataRoot: URL = defaultDataRoot()
    ) -> [String] {
        defaultRoots(homeDirectory: homeDirectory, dataRoot: dataRoot).map(\.path)
    }
}

// MARK: - TrustSimulationResult

/// Trust simulation result shape:
///   {allowed, requiresApproval, risk, action, reasons, policy}.
/// Preserve verbatim — callers may need any subfield.
public struct TrustSimulationResult: Sendable, Codable, Equatable {
    public var rawResponse: JSONValue
    public init(rawResponse: JSONValue) { self.rawResponse = rawResponse }

    enum CodingKeys: String, CodingKey { case rawResponse = "raw_response" }
}

// MARK: - Errors

public enum TrustCenterError: Error, LocalizedError {
    case invalidRequest
    case invalidResponse(status: Int)
    case unavailable
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "trust: invalid request"
        case .invalidResponse(let s): return "trust: native implementation returned unexpected status \(s)"
        case .unavailable: return "trust: unavailable"
        case .underlying(let m): return "trust: \(m)"
        }
    }
}
