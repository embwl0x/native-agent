import Foundation

// Blueprint: | `DeviceSyncTransport.swift` | Shared role/message codecs, checked transport and signed phone contact |

/// Cancellation and applied-data observations shared by one recovery operation.
public struct DeviceSyncRecovery: Sendable {
    public let didApplyData: (@Sendable () -> Void)?

    public init(didApplyData: (@Sendable () -> Void)? = nil) {
        self.didApplyData = didApplyData
    }

    public var isActive: Bool { !Task.isCancelled }
}

// MARK: - Device role + direction

public enum NADeviceRole: String, Sendable, Codable, CaseIterable {
    case mac
    case ios

    public var inboundDirection: NAChatDirection {
        self == .mac ? .ios2mac : .mac2ios
    }
}

public enum NAChatDirection: String, Sendable, Codable {
    case mac2ios
    case ios2mac
}

// MARK: - CloudKit record schema (identifiers shared by every transport)

public enum NADeviceSyncRecordType {
    public static let chatMessage = "NAChatMessage"
    /// Explicit user-visible notifications. Kept separate from chat so exactly one CloudKit subscription projects each record into an APNS alert.
    public static let notification = "NANotification"
    public static let pairingDevice = "NAPairingDevice"
    public static let status = "NAStatus"
}

/// Presence renews within the phone's contact window; incoming reads keep their own pace because pushes are hints.
public enum NAMacPresence {
    public static let receiveInterval: TimeInterval = 20
    /// One minute remains for CloudKit acceptance and the foreground phone's next contact read.
    public static let beat: TimeInterval = 240
    public static let phoneWindow: TimeInterval = 300
}

/// Foreground or active-talk phone contact uses the signed CloudKit status singleton so contact never becomes chat.
public enum NAPhoneForegroundPresence {
    public static let statusKey = "phone.foreground"
    public static let beat: TimeInterval = 30
    public static let receiveInterval: TimeInterval = 0.75
    /// Recent contact requests fast reads; older contact cannot prove the phone left.
    public static let window: TimeInterval = 60

    public static func signedValue(secret: Data) throws -> String {
        let message = try BridgeMessage.make(sender: "ios", text: "",
            metadata: ["kind": statusKey]).signed(with: secret)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(message), as: UTF8.self)
    }

    /// Verified contact is a historical fact, dated by CloudKit and bound to this pair.
    public static func activityDate(value: String, writtenAt: Date?, secret: Data) throws -> Date {
        guard let writtenAt else {
            throw DeviceSyncError.underlying(message: "The iPhone contact record has no server date.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(BridgeMessage.self, from: Data(value.utf8))
        guard message.sender == "ios", message.metadata?["kind"] == statusKey,
              message.verifySignature(secret: secret) else {
            throw DeviceSyncError.underlying(message: "The iPhone contact record has no verified signature for this pairing.")
        }
        return writtenAt
    }
}

/// `payloadJSON` owns the encoded message; scalar fields let CloudKit filter and deduplicate without decoding it.
public struct NAChatMessageFields: Sendable, Equatable, Codable {
    public var recordName: String   // CKRecord.ID.recordName == message id
    public var direction: String    // mac2ios | ios2mac
    public var sessionId: String?
    public var text: String
    public var payloadJSON: String  // full encoded BridgeMessage (lossless)
    public var createdAt: String    // ISO 8601
    public var senderDevice: String // "mac" | "ios"
    public var kind: String?        // metadata["kind"], if any
    public var notificationTitle: String?
    public var notificationScreen: String?
    public var notificationEventID: String?

    public init(
        recordName: String,
        direction: String,
        sessionId: String?,
        text: String,
        payloadJSON: String,
        createdAt: String,
        senderDevice: String,
        kind: String?,
        notificationTitle: String? = nil,
        notificationScreen: String? = nil,
        notificationEventID: String? = nil
    ) {
        self.recordName = recordName
        self.direction = direction
        self.sessionId = sessionId
        self.text = text
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.senderDevice = senderDevice
        self.kind = kind
        self.notificationTitle = notificationTitle
        self.notificationScreen = notificationScreen
        self.notificationEventID = notificationEventID
    }
}

// MARK: - BridgeMessage <-> record codec (CloudKit-independent, unit-testable)

public enum NAChatMessageCodec {
    public static let recordIDMetadataKey = "cloudKitRecordID"

    /// Conservative encoded-record ceiling below CloudKit's 1 MB record limit. `payloadJSON` already includes base64 attachment expansion and the
    /// record also duplicates a few query fields, so reserve 224 KiB for those fields and CloudKit record overhead instead of relying on a server
    /// rejection.
    public static let maxCloudKitRecordValueBytes = 800 * 1024
    /// Larger signed chat envelopes travel as encrypted assets, bounded below CloudKit's asset ceiling. Individual files retain the shared chat cap.
    public static let maxAssetPayloadBytes = 48 * 1024 * 1024

    public static func usesAsset(_ fields: NAChatMessageFields) -> Bool {
        if recordValueBytes(fields) > maxCloudKitRecordValueBytes { return true }
        // Even short voice notes keep audio out of scalar record values.
        return (try? decode(fields).attachments?.contains { $0.type == "audio" && !$0.base64.isEmpty }) == true
    }

    public static func recordValueBytes(_ fields: NAChatMessageFields) -> Int {
        fields.payloadJSON.utf8.count + fields.recordName.utf8.count + fields.text.utf8.count
            + (fields.sessionId?.utf8.count ?? 0) + fields.senderDevice.utf8.count
            + (fields.kind?.utf8.count ?? 0) + (fields.notificationTitle?.utf8.count ?? 0)
            + (fields.notificationScreen?.utf8.count ?? 0) + (fields.notificationEventID?.utf8.count ?? 0)
            + 4_096
    }

    public static func direction(forSender sender: String) -> NAChatDirection {
        sender.trimmingCharacters(in: .whitespaces).lowercased() == "mac" ? .mac2ios : .ios2mac
    }

    /// Preserve the complete message in `payloadJSON`; scalar fields are only query projections.
    public static func encode(_ message: BridgeMessage) throws -> NAChatMessageFields {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(message)
        guard let payloadJSON = String(data: data, encoding: .utf8) else {
            throw DeviceSyncError.underlying(message: "BridgeMessage payload was not UTF-8 encodable")
        }
        let fields = NAChatMessageFields(
            recordName: message.metadata?[recordIDMetadataKey] ?? message.id,
            direction: direction(forSender: message.sender).rawValue,
            sessionId: message.sessionID,
            text: message.text,
            payloadJSON: payloadJSON,
            createdAt: NativeTimestampFormat.fractionalZulu(message.timestamp),
            senderDevice: message.sender,
            kind: message.metadata?["kind"],
            notificationTitle: message.metadata?["title"],
            notificationScreen: message.metadata?["userInfo.screen"],
            notificationEventID: message.metadata?["userInfo.eventId"]
        )
        let projectedRecordBytes = recordValueBytes(fields)
        let projectedScalarBytes = projectedRecordBytes - data.count
        let assetEligible = message.attachments?.isEmpty == false
            && message.attachments?.allSatisfy({ $0.byteSize > 0 && $0.byteSize <= ChatAttachmentTypeResolver.fileByteLimit }) == true
        guard projectedScalarBytes <= maxCloudKitRecordValueBytes,
              projectedRecordBytes <= maxCloudKitRecordValueBytes || (assetEligible && data.count <= maxAssetPayloadBytes) else {
            throw DeviceSyncError.payloadTooLarge(
                actualBytes: projectedRecordBytes,
                maximumBytes: assetEligible && projectedScalarBytes <= maxCloudKitRecordValueBytes
                    ? maxAssetPayloadBytes : maxCloudKitRecordValueBytes
            )
        }
        return fields
    }

    /// Decode record fields back into a BridgeMessage. `payloadJSON` is authoritative — the scalar fields are only a query projection.
    public static func decode(_ fields: NAChatMessageFields) throws -> BridgeMessage {
        guard let data = fields.payloadJSON.data(using: .utf8) else {
            throw DeviceSyncError.underlying(message: "record \(fields.recordName) had non-UTF-8 payloadJSON")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BridgeMessage.self, from: data)
    }


}

// MARK: - Device transport errors

/// A submitted save may have reached the server; retry using the same identity.
public struct DeviceSyncSendOutcomeUnknown: Error, LocalizedError, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct DeviceSyncAccountFailure: Error, LocalizedError, Sendable, Codable, Equatable {
    public let code: Int
    public let detail: String

    public static let macMessage = """
        iCloud sign-in needs attention on this Mac (System Settings → Apple Account); \
        phone messages can't arrive until it's fixed
        """
    public static let phoneMessage = "iCloud sign-in needs attention on this iPhone"

    public var errorDescription: String? { detail }
}

/// An empty successful query is different from a failed or skipped query.
public enum DeviceSyncDrainResult: Sendable {
    case success(Int)
    case failure(DeviceSyncError, dispatched: Int = 0)
    case skipped(Int)

    public var dispatchedCount: Int {
        switch self {
        case .success(let count), .skipped(let count), .failure(_, let count): return count
        }
    }
}

public enum DeviceSyncError: Error, LocalizedError, Sendable {
    case notConfigured
    case unauthorized
    case account(DeviceSyncAccountFailure)
    case quotaExceeded
    case conflict
    case payloadTooLarge(actualBytes: Int, maximumBytes: Int)
    case transient(message: String)
    case underlying(message: String)
    /// Another Mac on this Apple Account holds the phone's pairing.
    case pairedElsewhere

    public var snapshotRecoveryMessage: String {
        switch self {
        case .pairedElsewhere:
            return "In Connectors → iPhone on this Mac, choose Use my iPhone with this Mac."
        case .account, .unauthorized:
            return DeviceSyncAccountFailure.macMessage + "."
        case .quotaExceeded:
            return "Free some iCloud storage, then check Connection in Settings."
        case .transient, .conflict:
            return "The Mac will try again on its next update; keep NativeAgent open."
        case .notConfigured, .payloadTooLarge, .underlying:
            return "Open Connection in Settings to check the Mac link."
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "device sync not configured (missing container or entitlements)"
        case .unauthorized: return "iCloud account unavailable"
        case .account(let failure): return failure.localizedDescription
        case .quotaExceeded: return "iCloud quota exceeded"
        case .conflict: return "device sync record conflict"
        case .payloadTooLarge(let actual, let maximum):
            let actualKB = max(1, actual / 1024)
            let maximumKB = maximum / 1024
            return "This message is too large for iCloud delivery (\(actualKB) KB; limit \(maximumKB) KB). Choose a smaller image or attachment."
        case .transient(let m): return "transient device sync error: \(m)"
        case .underlying(let m): return "device sync error: \(m)"
        case .pairedElsewhere: return "Your iPhone is paired with another Mac on this Apple Account."
        }
    }
}

// MARK: - Required transport configuration

public enum DeviceSyncTransportConstructionFailure: Error, LocalizedError, Sendable {
    case unsupportedSelection(String?)
    case missingEntitlement
    case missingContainer(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSelection(let value):
            return "CloudKit transport configuration is invalid (\(value ?? "missing")). Install a NativeAgent build configured for CloudKit."
        case .missingEntitlement:
            return "CloudKit transport cannot start because its iCloud service entitlement is absent. Install a correctly signed NativeAgent build."
        case .missingContainer(let identifier):
            return "CloudKit transport cannot start because container '\(identifier)' is not entitled. Install a NativeAgent build signed for this container."
        }
    }
}

public enum DeviceSyncTransportResolver {
    public static let envKey = "NATIVE_AGENT_DEVICE_SYNC"
    public static let infoKey = "NativeAgentDeviceSync"

    /// The current transport must be explicitly configured. A missing or invalid transport value never selects another data plane.
    public static func requireCloudKitConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoValue: String? = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String
    ) throws {
        let chosen = environment[envKey] ?? infoValue
        guard chosen?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "cloudkit" else {
            throw DeviceSyncTransportConstructionFailure.unsupportedSelection(chosen)
        }
    }
}
