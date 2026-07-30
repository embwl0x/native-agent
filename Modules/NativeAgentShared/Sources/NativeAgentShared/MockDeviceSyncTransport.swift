// MockDeviceSyncTransport.swift — in-memory DeviceSyncTransport for tests.
//
// Mirrors MockCloudKitSync (MemoryV2+CloudKit): an actor-isolated in-memory
// store with a deterministic monotonic clock (no Date.now dependence for
// ordering) so LWW / cursor filtering is testable.
//
// Two devices share one `MockDeviceCloud` substrate (the CloudKit stand-in),
// so a send from one role is observable by the other exactly like the real
// two-device topology. Delivery is driven explicitly via `drainIncoming()` for
// deterministic tests (no background timers).

import Foundation

// MARK: - Shared in-memory substrate (the "CloudKit private DB" stand-in)

public actor MockDeviceCloud {
    public struct StoredChat: Sendable, Equatable {
        public var fields: NAChatMessageFields
        public var modTick: Int
    }

    private var chats: [String: StoredChat] = [:]        // recordName -> record
    private var pairing: [String: Data] = [:]            // role.rawValue -> secret
    private var status: [String: String] = [:]           // "role/key" -> value
    // Ongoing-observation model (the silent-push stand-in): observers register
    // keyed by the PEER role/key they watch, and a matching publish notifies them
    // synchronously. This lets a publish AFTER an observe fire the handler, which
    // is exactly what the CloudKit subscription → drain does in production.
    private var pairingObservers: [String: [@Sendable (Data) async -> Void]] = [:]   // watchedRole -> handlers
    private var statusObservers: [String: [@Sendable (String) async -> Void]] = [:]  // "watchedRole/key" -> handlers
    public var simulateAccountStatus: String = "available"
    public var simulateConflictOnSend: Bool = false
    private var clockTick: Int = 0

    public init() {}

    public func setSimulateAccountStatus(_ s: String) { simulateAccountStatus = s }
    public func setSimulateConflictOnSend(_ b: Bool) { simulateConflictOnSend = b }

    func putChat(_ fields: NAChatMessageFields) throws {
        if simulateConflictOnSend { throw DeviceSyncError.conflict }
        clockTick += 1
        // recordName == message id → natural dedup / LWW-by-latest-write.
        chats[fields.recordName] = StoredChat(fields: fields, modTick: clockTick)
    }

    /// Records with modTick strictly greater than `sinceTick`, ascending.
    func chatsSince(_ sinceTick: Int) -> [StoredChat] {
        chats.values
            .filter { $0.modTick > sinceTick }
            .sorted { $0.modTick < $1.modTick }
    }

    /// Store the publisher's pairing secret and fire any observer watching this
    /// role (i.e. the peer's observePairing). Last write wins.
    func putPairing(role: String, secret: Data) async {
        pairing[role] = secret
        for handler in pairingObservers[role] ?? [] { await handler(secret) }
    }
    func pairing(forRole role: String) -> Data? { pairing[role] }

    /// Register an observer for a peer role's pairing writes. `watching` is the
    /// role whose publishes should fire `handler`.
    func registerPairingObserver(watching role: String, handler: @escaping @Sendable (Data) async -> Void) {
        pairingObservers[role, default: []].append(handler)
    }

    /// Store the publisher's status value and fire any observer watching this
    /// (role, key). Last write wins.
    func putStatus(role: String, key: String, value: String) async {
        status["\(role)/\(key)"] = value
        for handler in statusObservers["\(role)/\(key)"] ?? [] { await handler(value) }
    }
    func status(role: String, key: String) -> String? { status["\(role)/\(key)"] }

    /// Register an observer for a peer (role, key)'s status writes.
    func registerStatusObserver(watching role: String, key: String, handler: @escaping @Sendable (String) async -> Void) {
        statusObservers["\(role)/\(key)", default: []].append(handler)
    }

    public func accountStatus() -> String { simulateAccountStatus }
    public func chatCount() -> Int { chats.count }
}

// MARK: - The mock transport

public actor MockDeviceSyncTransport: DeviceSyncTransport {
    public nonisolated let role: NADeviceRole
    private let cloud: MockDeviceCloud

    private var incomingHandler: (@Sendable (BridgeMessage) async -> Bool)?
    private var pairingHandler: (@Sendable (Data) async -> Bool)?
    private var acceptedPairingSecret: Data?
    private var statusHandlers: [String: @Sendable (String) async -> Void] = [:]
    private var lastPullTick: Int = 0
    private var seenMessageIDs: Set<String> = []

    /// Pass a shared `cloud` to two transports (one `.mac`, one `.ios`) to model
    /// a real two-device round trip.
    public init(role: NADeviceRole, cloud: MockDeviceCloud = MockDeviceCloud()) {
        self.role = role
        self.cloud = cloud
    }

    public func send(_ message: BridgeMessage) async throws {
        let fields = try NAChatMessageCodec.encode(message)
        try await cloud.putChat(fields)
    }

    public func observeIncoming(_ onMessage: @escaping @Sendable (BridgeMessage) async -> Bool) async {
        incomingHandler = onMessage  // last registration wins
        await drainIncoming()
    }

    /// Pull-and-dispatch pending incoming messages for this device's role.
    /// Deterministic: call it after a peer `send`. Returns count dispatched.
    @discardableResult
    public func drainIncoming() async -> Int {
        guard let handler = incomingHandler else { return 0 }
        let inbound = role.inboundDirection.rawValue
        let pending = await cloud.chatsSince(lastPullTick)   // already ascending by modTick
        var dispatched = 0
        // Mirror CloudKitDeviceTransport.drainIncoming: the cursor may only
        // advance to the last point BEFORE the first UNDELIVERED inbound record —
        // a rejected message must never be skipped. (Actor-isolated here, so the
        // claim needs no extra lock; the halt semantics still must match.)
        var cursorAdvance: Int? = nil
        var halted = false
        for stored in pending {
            if halted { break }
            let tick = stored.modTick
            guard stored.fields.direction == inbound else {
                cursorAdvance = tick   // our own outbound / other — safe to pass
                continue
            }
            let id = stored.fields.recordName
            if seenMessageIDs.contains(id) {
                cursorAdvance = tick   // already delivered — safe to pass
                continue
            }
            guard let message = try? NAChatMessageCodec.decode(stored.fields) else {
                seenMessageIDs.insert(id)   // poison record — keep it seen, pass
                cursorAdvance = tick
                continue
            }
            if await handler(message) {
                seenMessageIDs.insert(id)
                dispatched += 1
                cursorAdvance = tick
            } else {
                halted = true   // not delivered — do not advance past this record
            }
        }
        if let adv = cursorAdvance {
            lastPullTick = Swift.max(lastPullTick, adv)
        }
        return dispatched
    }

    public func publishPairing(secret: Data) async throws {
        await cloud.putPairing(role: role.rawValue, secret: secret)
    }

    public func observePairing(onChange: @escaping @Sendable (Data) async -> Bool) async {
        pairingHandler = onChange
        let peerRole: NADeviceRole = role == .mac ? .ios : .mac
        // Ongoing: register so a LATER peer publish fires the handler...
        await cloud.registerPairingObserver(watching: peerRole.rawValue) { [weak self] secret in
            _ = await self?.deliverPairingIfNeeded(secret)
        }
        // ...and drain the current value if one was already published.
        _ = await drainPairing()
    }

    @discardableResult
    public func drainPairing() async -> Bool {
        let peerRole: NADeviceRole = role == .mac ? .ios : .mac
        guard let secret = await cloud.pairing(forRole: peerRole.rawValue) else { return false }
        return await deliverPairingIfNeeded(secret)
    }

    private func deliverPairingIfNeeded(_ secret: Data) async -> Bool {
        guard acceptedPairingSecret != secret, let pairingHandler else { return false }
        guard await pairingHandler(secret) else { return false }
        acceptedPairingSecret = secret
        return true
    }

    public func setStatus(key: String, value: String) async throws {
        await cloud.putStatus(role: role.rawValue, key: key, value: value)
    }

    public func observeStatus(key: String, onChange: @escaping @Sendable (String) async -> Void) async {
        statusHandlers[key] = onChange
        let peerRole: NADeviceRole = role == .mac ? .ios : .mac
        // Ongoing: register so a LATER peer status write fires the handler...
        await cloud.registerStatusObserver(watching: peerRole.rawValue, key: key, handler: onChange)
        // ...and drain the current value if one was already set.
        if let value = await cloud.status(role: peerRole.rawValue, key: key) {
            await onChange(value)
        }
    }

    public func accountStatus() async -> String {
        await cloud.accountStatus()
    }
}
