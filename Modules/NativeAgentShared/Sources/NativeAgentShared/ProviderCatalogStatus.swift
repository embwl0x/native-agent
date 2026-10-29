import Foundation

// Blueprint: | `ProviderCatalogStatus.swift` | `NAProviderCatalogStatusCodec`: credential-free provider/model/surface metadata over existing device status transport |

/// Credential-free provider/model metadata projected from the authoritative Mac
/// into the paired iOS companion. This rides the existing NAStatus transport so
/// public CloudKit builds do not depend on an iCloud Drive snapshot mount.
public struct NAProviderCatalogStatus: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var routingRevision: Double
    public var providers: [NAProviderCatalogProvider]
    public var surfaces: [String: NAProviderSurfaceSelection]

    public init(
        version: Int = currentVersion,
        providers: [NAProviderCatalogProvider],
        surfaces: [String: NAProviderSurfaceSelection],
        routingRevision: Double
    ) {
        self.version = version
        self.routingRevision = routingRevision
        self.providers = providers
        self.surfaces = surfaces
    }
}

public struct NAProviderCatalogProvider: Codable, Equatable, Sendable {
    public var providerID: String
    public var displayName: String
    public var authState: String
    /// ProviderRouting's published eligibility; nil from an older Mac, whose
    /// "ready" authState meant eligible.
    public var eligible: Bool?
    public var authModes: [String]
    public var models: [NAProviderCatalogModel]

    public init(
        providerID: String,
        displayName: String,
        authState: String,
        eligible: Bool,
        authModes: [String],
        models: [NAProviderCatalogModel]
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.authState = authState
        self.eligible = eligible
        self.authModes = authModes
        self.models = models
    }
}

public struct NAProviderCatalogModel: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var contextLength: Int
    public var supportsStreaming: Bool
    public var supportsVision: Bool
    public var supportsTools: Bool
    public var supportsJSONMode: Bool
    public var defaultReasoningEffort: String?
    public var supportedReasoningEfforts: [String]?
    public var supportsFast: Bool?

    public init(
        id: String,
        name: String,
        contextLength: Int,
        supportsStreaming: Bool,
        supportsVision: Bool,
        supportsTools: Bool,
        supportsJSONMode: Bool,
        defaultReasoningEffort: String?,
        supportedReasoningEfforts: [String]?,
        supportsFast: Bool?
    ) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
        self.supportsStreaming = supportsStreaming
        self.supportsVision = supportsVision
        self.supportsTools = supportsTools
        self.supportsJSONMode = supportsJSONMode
        self.defaultReasoningEffort = defaultReasoningEffort
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.supportsFast = supportsFast
    }
}

public struct NAProviderSurfaceSelection: Codable, Equatable, Sendable {
    public var providerID: String?
    public var model: String
    public var reasoningEffort: String?
    public var serviceTier: String?

    public init(
        providerID: String?,
        model: String,
        reasoningEffort: String?,
        serviceTier: String?
    ) {
        self.providerID = providerID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
    }
}

extension NAProviderSurfaceSelection {
    private enum CodingKeys: String, CodingKey { case providerID, model, reasoningEffort, serviceTier }
    private enum SnapshotKeys: String, CodingKey { case providerId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let snapshot = try decoder.container(keyedBy: SnapshotKeys.self)
        providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
            ?? snapshot.decodeIfPresent(String.self, forKey: .providerId)
        model = try c.decode(String.self, forKey: .model)
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort)
        serviceTier = try c.decodeIfPresent(String.self, forKey: .serviceTier)
    }
}

public enum NAProviderCatalogStatusCodec {
    public static let statusKey = "provider_catalog_v1"
    public static let maximumBytes = 256 * 1024

    public static func encode(_ catalog: NAProviderCatalogStatus) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(catalog)
        guard data.count <= maximumBytes else {
            throw DeviceSyncError.payloadTooLarge(
                actualBytes: data.count,
                maximumBytes: maximumBytes
            )
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw DeviceSyncError.underlying(message: "provider catalog was not UTF-8 encodable")
        }
        return value
    }

    public static func decode(_ value: String) throws -> NAProviderCatalogStatus {
        let data = Data(value.utf8)
        guard data.count <= maximumBytes else {
            throw DeviceSyncError.payloadTooLarge(
                actualBytes: data.count,
                maximumBytes: maximumBytes
            )
        }
        let catalog = try JSONDecoder().decode(NAProviderCatalogStatus.self, from: data)
        guard catalog.version == NAProviderCatalogStatus.currentVersion else {
            throw DeviceSyncError.underlying(
                message: "unsupported provider catalog version \(catalog.version)"
            )
        }
        return catalog
    }
}
