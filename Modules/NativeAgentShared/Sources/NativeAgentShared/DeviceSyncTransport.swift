// DeviceSyncTransport.swift — the device-sync transport SEAM (CK-1).
//
// This introduces the abstraction that does NOT exist today: `iCloudBridge`
// (Mac) and its iOS twin hardcode the iCloud KVS control plane + ubiquity/Drive
// data plane on both sides. This protocol is the single swap point between that
// KVS/ubiquity transport (personal build) and a CloudKit transport (public,
// Developer-ID direct-download build).
//
// The method shapes mirror the CURRENT Mac `iCloudBridge` public API so the
// existing KVS/ubiquity code can later implement this same protocol without a
// signature rewrite:
//   sendChatMessage(...)        -> send(_:)
//   observeIncomingMessages(_:) -> observeIncoming(_:)
//   sendShortStatus(key:value:) -> setStatus(key:value:)
//   observeStatusKey(_:onChange:) -> observeStatus(key:onChange:)
//   PairingSecretManager publish/observe -> publishPairing(secret:) / observePairing(onChange:)
//
// CK-1 lands the compiling, unit-testable seam + a CloudKit implementation +
// an in-memory mock. It does NOT wire any of this into `iCloudBridge` and does
// NOT change runtime behavior — the resolver defaults to `.kvs` so nothing
// switches. Wiring is CK-2 / CK-3.
//
// BridgeMessage stays the wire model end-to-end. The CloudKit record carries a
// verbatim `payloadJSON` copy of the encoded BridgeMessage (lossless — signature,
// attachments, and metadata survive), plus flat scalar fields for CloudKit
// querying / dedup / last-write-wins.

import Foundation

// MARK: - Device role + direction

/// Which physical side this transport instance runs on. Mirrors the two-sided
/// `iCloudBridge` topology: the Mac app is `.mac`, the iOS companion is `.ios`.
public enum NADeviceRole: String, Sendable, Codable, CaseIterable {
    case mac
    case ios

    /// The direction of a message this role SENDS.
    public var outboundDirection: NAChatDirection {
        self == .mac ? .mac2ios : .ios2mac
    }

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
    /// Chat message payloads. `recordName` == BridgeMessage.id (natural dedup).
    public static let chatMessage = "NAChatMessage"
    /// Explicit user-visible notifications. Kept separate from chat so exactly
    /// one CloudKit subscription projects each record into an APNS alert.
    public static let notification = "NANotification"
    /// Pairing / device records (replaces the KVS pairing-secret plane).
    public static let pairingDevice = "NAPairingDevice"
    /// Short status/progress records (replaces the KVS status keys).
    public static let status = "NAStatus"
}

/// Cross-device proof that the iOS peer successfully installed the exact
/// Apple-presented CloudKit notification subscription expected by this build.
///
/// The contract identifier changes whenever the visible subscription shape
/// changes. A stale status row from an older build therefore cannot make the
/// Mac claim that the current route is eligible.
public enum NAVisualNotificationCapability {
    public static let statusKey = "notification.visual.capability"
    public static let contract = "nanotification-v2-max-three-desired-keys"

    public static func encoded(ready: Bool) -> String {
        "\(contract):\(ready ? "ready" : "unavailable")"
    }

    public static func isReady(_ value: String) -> Bool {
        value == encoded(ready: true)
    }
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
    /// Conservative encoded-record ceiling below CloudKit's 1 MB record limit.
    /// `payloadJSON` already includes base64 attachment expansion and the record
    /// also duplicates a few query fields, so reserve 224 KiB for those fields
    /// and CloudKit record overhead instead of relying on a server rejection.
    public static let maxCloudKitRecordValueBytes = 800 * 1024

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
        let data = try encoder.encode(message)
        guard let payloadJSON = String(data: data, encoding: .utf8) else {
            throw DeviceSyncError.underlying(message: "BridgeMessage payload was not UTF-8 encodable")
        }
        let projectedScalarBytes =
            message.id.utf8.count
            + message.text.utf8.count
            + (message.sessionID?.utf8.count ?? 0)
            + message.sender.utf8.count
            + (message.metadata?["kind"]?.utf8.count ?? 0)
            + (message.metadata?["title"]?.utf8.count ?? 0)
            + (message.metadata?["userInfo.screen"]?.utf8.count ?? 0)
            + (message.metadata?["userInfo.eventId"]?.utf8.count ?? 0)
            + 4_096
        let projectedRecordBytes = data.count + projectedScalarBytes
        guard projectedRecordBytes <= maxCloudKitRecordValueBytes else {
            throw DeviceSyncError.payloadTooLarge(
                actualBytes: projectedRecordBytes,
                maximumBytes: maxCloudKitRecordValueBytes
            )
        }
        return NAChatMessageFields(
            recordName: message.id,
            direction: direction(forSender: message.sender).rawValue,
            sessionId: message.sessionID,
            text: message.text,
            payloadJSON: payloadJSON,
            createdAt: isoString(message.timestamp),
            senderDevice: message.sender,
            kind: message.metadata?["kind"],
            notificationTitle: message.metadata?["title"],
            notificationScreen: message.metadata?["userInfo.screen"],
            notificationEventID: message.metadata?["userInfo.eventId"]
        )
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
    /// are byte-for-byte the intended write; an id collision with different
    /// content remains a conflict.
    public static func isExactIdempotentReplay(
        existingPayloadJSON: String?,
        existingDirection: String?,
        intended: NAChatMessageFields
    ) -> Bool {
        existingPayloadJSON == intended.payloadJSON
            && existingDirection == intended.direction
    }

    private static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

// MARK: - Errors (mirror CloudKitSyncError from MemoryV2+CloudKit)

public enum DeviceSyncError: Error, LocalizedError, Sendable {
    case notConfigured
    case unauthorized
    case quotaExceeded
    case conflict
    case payloadTooLarge(actualBytes: Int, maximumBytes: Int)
    case transient(message: String)
    case underlying(message: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "device sync not configured (missing container or entitlements)"
        case .unauthorized: return "iCloud account unavailable"
        case .quotaExceeded: return "iCloud quota exceeded"
        case .conflict: return "device sync record conflict"
        case .payloadTooLarge(let actual, let maximum):
            let actualKB = max(1, actual / 1024)
            let maximumKB = maximum / 1024
            return "This message is too large for iCloud delivery (\(actualKB) KB; limit \(maximumKB) KB). Choose a smaller image or attachment."
        case .transient(let m): return "transient device sync error: \(m)"
        case .underlying(let m): return "device sync error: \(m)"
        }
    }

    /// True iff this is the `.notConfigured` case — the crash-guard signal that
    /// the CloudKit entitlement is absent and no `CKContainer` was touched.
    /// (Enum has associated values so it isn't auto-Equatable; this is the
    /// precise-match helper the crash-guard tests assert on.)
    public var isNotConfigured: Bool {
        if case .notConfigured = self { return true }
        return false
    }
}

// MARK: - The seam

/// A device-sync transport: the swap point between the KVS/ubiquity bridge and
/// CloudKit. All members are async so an `actor` (the mock) and a lock-guarded
/// `final class` (the CloudKit impl) can both satisfy it.
public protocol DeviceSyncTransport: Sendable {
    /// Which side this transport instance runs on.
    var role: NADeviceRole { get }

    /// True only after this transport has registered an Apple-presented visual
    /// notification route. Callers use this to avoid scheduling a second local
    /// copy when CloudKit already owns presentation.
    var presentsVisualNotifications: Bool { get }

    /// Ensure the live CloudKit subscription set exists and matches this
    /// build's exact shape. Event-driven callers use this at startup and on
    /// foreground activation; it is not an idle poll.
    func ensurePushSubscriptions() async -> Bool

    /// Push one chat message to the other device. Mirrors
    /// `iCloudBridge.sendChatMessage`.
    func send(_ message: BridgeMessage) async throws

    /// Register the single forwarder for messages arriving FROM the other
    /// device. Mirrors `iCloudBridge.observeIncomingMessages`. Idempotent —
    /// last registration wins (there is exactly one logical forwarder).
    /// The handler returns `true` when the message was accepted/delivered.
    func observeIncoming(_ onMessage: @escaping @Sendable (BridgeMessage) async -> Bool) async

    /// Publish this device's pairing secret. Mirrors
    /// `PairingSecretManager.publishMaterialToKVS`.
    func publishPairing(secret: Data) async throws

    /// Observe the peer device's published pairing secret.
    /// The handler returns true only after the canonical pairing owner has
    /// durably accepted the secret. A false result keeps the record eligible
    /// for a later drain (for example, while Keychain is temporarily locked).
    func observePairing(onChange: @escaping @Sendable (Data) async -> Bool) async

    /// Set a short status/progress value. Mirrors `iCloudBridge.sendShortStatus`.
    func setStatus(key: String, value: String) async throws

    /// Observe a status key. Mirrors `iCloudBridge.observeStatusKey`.
    func observeStatus(key: String, onChange: @escaping @Sendable (String) async -> Void) async

    /// iCloud account availability: "available" | "noAccount" | "restricted" |
    /// "temporarilyUnavailable" | "unknown". Defaulted for transports (KVS)
    /// that don't model an account.
    func accountStatus() async -> String

    /// Pull any pending inbound messages NOW and dispatch to the `observeIncoming`
    /// handler; returns the count dispatched. The wakeup for a pull-based
    /// transport (CloudKit) — called after a late handler registration and on an
    /// APNs silent push (CK-3c). Push-driven transports (a future KVS impl) can
    /// no-op via the default. Idempotent per message id.
    @discardableResult
    func drainIncoming() async -> Int

    /// Pull the peer's pairing singleton now; returns true if the handler fired.
    @discardableResult
    func drainPairing() async -> Bool

    /// Pull the peer's status singletons now; returns the number of handlers fired.
    @discardableResult
    func drainStatus() async -> Int
}

public extension DeviceSyncTransport {
    var presentsVisualNotifications: Bool { false }
    func ensurePushSubscriptions() async -> Bool { presentsVisualNotifications }

    func accountStatus() async -> String { "available" }

    // Default no-ops: a push-driven transport that delivers via observe* alone
    // (e.g. a future KVS/ubiquity impl) needs no explicit pull. The CloudKit
    // transport and the mock override these with real pulls.
    @discardableResult func drainIncoming() async -> Int { 0 }
    @discardableResult func drainPairing() async -> Bool { false }
    @discardableResult func drainStatus() async -> Int { 0 }
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

    /// Whether the device bridge has a usable transport after startup.
    ///
    /// CloudKit and iCloud Drive are separate iCloud services. Public
    /// Developer ID/App Store builds may be provisioned for CloudKit without a
    /// mounted ubiquity Documents container, while personal builds continue to
    /// use KVS/Drive. A bridge is therefore usable when either its checked
    /// CloudKit transport exists or the legacy ubiquity container exists.
    ///
    /// This value owns no transport and grants no entitlement authority; the
    /// CloudKit crash guard remains `makeCloudKitTransport`.
    public static func bridgeCanStart(
        cloudKitTransportActive: Bool,
        ubiquityContainerAvailable: Bool
    ) -> Bool {
        cloudKitTransportActive || ubiquityContainerAvailable
    }
}
