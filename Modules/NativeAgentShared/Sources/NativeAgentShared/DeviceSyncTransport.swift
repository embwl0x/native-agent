import Foundation

// Blueprint: | `DeviceSyncTransport.swift` | Shared device-sync role/message codecs, account/recovery outcomes and transport resolution |

/// A background recovery caller can bound reads without changing the transport
/// operations. Foreground callers retain their ordinary per-operation budgets.
public enum NADeviceSyncRecoveryBudget {
    @TaskLocal public static var deadline: Date?
    @TaskLocal public static var didApplyData: (@Sendable () -> Void)?

    public static var hasTime: Bool {
        !Task.isCancelled && (deadline.map { $0.timeIntervalSinceNow > 0 } ?? true)
    }

    public static func seconds(upTo maximum: TimeInterval) -> TimeInterval {
        max(0, min(maximum, deadline?.timeIntervalSinceNow ?? maximum))
    }
}

// MARK: - Device role + direction

/// Which physical side this transport instance runs on. Mirrors the two-sided
/// `iCloudBridge` topology: the Mac app is `.mac`, the iOS companion is `.ios`.
public enum NADeviceRole: String, Sendable, Codable, CaseIterable {
    case mac
    case ios

    /// The direction of a message this role RECEIVES.
    public var inboundDirection: NAChatDirection {
        self == .mac ? .ios2mac : .mac2ios
    }
}

/// Direction of an `NAChatMessage` record, matching the design's field values.
public enum NAChatDirection: String, Sendable, Codable {
    case mac2ios
    case ios2mac
}

// MARK: - CloudKit record schema (identifiers shared by every transport)

public enum NADeviceSyncRecordType {
    /// Chat message payloads. Record identity defaults to BridgeMessage.id.
    public static let chatMessage = "NAChatMessage"
    /// Explicit user-visible notifications. Kept separate from chat so exactly
    /// one CloudKit subscription projects each record into an APNS alert.
    public static let notification = "NANotification"
    /// Pairing / device records (replaces the KVS pairing-secret plane).
    public static let pairingDevice = "NAPairingDevice"
    /// Short status/progress records (replaces the KVS status keys).
    public static let status = "NAStatus"
}

/// The Mac's presence beat. The Mac publishes snapshots only when something
/// changes, so a quiet Mac said nothing for minutes and the phone read that
/// as unreachable. The Mac rewrites one record every `beat`; nothing pushes
/// it, the phone reads it when it opens. The phone counts the Mac as here
/// while the newest Mac record it has seen is younger than `phoneWindow`.
public enum NAMacPresence {
    public static let beat: TimeInterval = 120
    public static let phoneWindow: TimeInterval = 300
}

/// Flat, CloudKit-queryable projection of a `BridgeMessage`.
///
/// `payloadJSON` is the authoritative copy of the encoded BridgeMessage; the
/// scalar fields exist so CloudKit can filter (`direction`, `sessionId`,
/// `createdAt`) and de-duplicate (`recordName`) without decoding the payload.
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

    /// Conservative encoded-record ceiling below CloudKit's 1 MB record limit.
    /// `payloadJSON` already includes base64 attachment expansion and the record
    /// also duplicates a few query fields, so reserve 224 KiB for those fields
    /// and CloudKit record overhead instead of relying on a server rejection.
    public static let maxCloudKitRecordValueBytes = 800 * 1024
    /// Larger signed chat envelopes travel as encrypted assets, bounded below
    /// CloudKit's asset ceiling. Individual files retain the shared chat cap.
    public static let maxAssetPayloadBytes = 48 * 1024 * 1024

    public static func usesAsset(_ fields: NAChatMessageFields) -> Bool {
        recordValueBytes(fields) > maxCloudKitRecordValueBytes
    }

    public static func recordValueBytes(_ fields: NAChatMessageFields) -> Int {
        fields.payloadJSON.utf8.count + fields.recordName.utf8.count + fields.text.utf8.count
            + (fields.sessionId?.utf8.count ?? 0) + fields.senderDevice.utf8.count
            + (fields.kind?.utf8.count ?? 0) + (fields.notificationTitle?.utf8.count ?? 0)
            + (fields.notificationScreen?.utf8.count ?? 0) + (fields.notificationEventID?.utf8.count ?? 0)
            + 4_096
    }

    /// Direction a message travels, derived from its sender. "mac" → mac2ios,
    /// anything else (e.g. "ios") → ios2mac.
    public static func direction(forSender sender: String) -> NAChatDirection {
        sender.trimmingCharacters(in: .whitespaces).lowercased() == "mac" ? .mac2ios : .ios2mac
    }

    /// Encode a BridgeMessage into flat record fields. The full message is
    /// preserved verbatim in `payloadJSON` so decode is lossless.
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

    /// Decode record fields back into a BridgeMessage. `payloadJSON` is
    /// authoritative — the scalar fields are only a query projection.
    public static func decode(_ fields: NAChatMessageFields) throws -> BridgeMessage {
        guard let data = fields.payloadJSON.data(using: .utf8) else {
            throw DeviceSyncError.underlying(message: "record \(fields.recordName) had non-UTF-8 payloadJSON")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BridgeMessage.self, from: data)
    }

    /// Exact replay proof for a stable CloudKit record id. A retry is accepted
    /// as success only when the server's authoritative payload and direction
    /// are equal after JSON key canonicalization; an id collision with different
    /// content remains a conflict.
    public static func isExactIdempotentReplay(
        existingPayloadJSON: String?,
        existingDirection: String?,
        intended: NAChatMessageFields
    ) -> Bool {
        // Compare all JSON fields, including signatures and unknown fields, without decoding into BridgeMessage.
        guard existingDirection == intended.direction,
              let existingPayloadJSON,
              let existing = canonicalPayload(existingPayloadJSON),
              let proposed = canonicalPayload(intended.payloadJSON) else { return false }
        return existing == proposed
    }

    private static func canonicalPayload(_ json: String) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              object is [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
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

    public static let macMessage = "iCloud sign-in needs attention on this Mac (System Settings → Apple Account); phone messages can't arrive until it's fixed"
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

// MARK: - Build/runtime flag + resolver (deliverable 4)

/// Which transport a build selects. `NATIVE_AGENT_DEVICE_SYNC` env var:
/// "cloudkit" | "kvs". DEFAULT is `.kvs` — with nothing set, runtime behavior
/// is unchanged from today.
public enum DeviceSyncTransportKind: String, Sendable {
    case cloudkit
    case kvs
}

public enum DeviceSyncTransportResolver {
    public static let envKey = "NATIVE_AGENT_DEVICE_SYNC"
    /// Info.plist key baked into a build to select the transport when no env var
    /// is present. This is REQUIRED on iOS: a shipped/standalone iOS app has no
    /// per-process env-var mechanism (LSEnvironment is macOS-only; a scheme env
    /// var applies only when Xcode launches the app), so the iOS build selects
    /// its transport HERE. On macOS the env var (launchctl/LSEnvironment) still
    /// works and takes precedence, so a test can always override a baked value.
    public static let infoKey = "NativeAgentDeviceSync"

    /// Resolve the selected transport kind. Precedence: env var (runtime/test
    /// override) → baked Info.plist value → `.kvs` (fail-safe: never silently
    /// switch a live build to CloudKit on an unknown/typo value).
    public static func resolvedKind(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoValue: String? = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String
    ) -> DeviceSyncTransportKind {
        let envRaw = environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Env var wins only when non-empty; otherwise fall back to the baked value.
        let chosen = ((envRaw?.isEmpty == false) ? envRaw : infoValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch chosen {
        case "cloudkit": return .cloudkit
        case "kvs", "", nil: return .kvs
        default: return .kvs
        }
    }
}
