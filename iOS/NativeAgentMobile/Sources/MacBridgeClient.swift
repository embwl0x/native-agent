// PATCH-2026-06-02: iOS iCloud-only flow — HTTP transport stripped.
// MacBridgeClient is now iCloud-only. URLSession, bearer-token, and all /v1/*
// HTTP fallbacks are removed; iOS talks to the Mac through signed iCloud
// messages and snapshots. Public surface preserved for view compatibility:
//   - chat: sendMessage / cancelChat / observeICloudReplies → iCloudBridge
//   - reads (get) / writes (postDict) → throw a clean transportRemoved error;
//     views that wrap calls in `try?` degrade to empty/nil states.
//   - refreshChatHistory → reads from iCloudSyncEngine snapshots.

import Foundation
import Combine
import SwiftUI
import NativeAgentShared
#if canImport(UIKit)
import UIKit
#endif

private final class DeviceSourceKeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func store(_ value: String) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

struct ChatRuntimeControls: Equatable, Sendable, Codable {
    var model: String
    var reasoningEffort: String
    var serviceTier: String = "default"
    var fileAccess: String
    var providerId: String = ""

    static let defaults = ChatRuntimeControls(model: "gpt-5.6-sol", reasoningEffort: "high", serviceTier: "default", fileAccess: "auto")

    var normalized: ChatRuntimeControls {
        ChatRuntimeControls(
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            reasoningEffort: reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines),
            serviceTier: serviceTier.trimmingCharacters(in: .whitespacesAndNewlines),
            fileAccess: fileAccess.trimmingCharacters(in: .whitespacesAndNewlines),
            providerId: providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func metadata(transport: String) -> [String: String] {
        let clean = normalized
        var out: [String: String] = [
            "clientSurface": "iphone",
            "source": "ios",
            "transport": transport,
            "sourceKey": NativeAgentICloudBridgeConstants.mobileSourceKey,
            "routeKey": Self.deviceSourceKey
        ]
        if !clean.model.isEmpty { out["model"] = clean.model }
        if !clean.reasoningEffort.isEmpty { out["reasoningEffort"] = clean.reasoningEffort }
        if !clean.serviceTier.isEmpty { out["serviceTier"] = clean.serviceTier }
        if !clean.fileAccess.isEmpty { out["fileAccess"] = clean.fileAccess }
        if !clean.providerId.isEmpty { out["providerId"] = clean.providerId }
        return out
    }

    private static let deviceSourceKeyCache = DeviceSourceKeyCache()

    static func makeDeviceSourceKey(deviceName: String) -> String {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "iphone" : "iphone:\(name)"
    }

    @MainActor
    static func primeDeviceSourceKey() {
        #if canImport(UIKit)
        deviceSourceKeyCache.store(makeDeviceSourceKey(deviceName: UIDevice.current.name))
        #else
        deviceSourceKeyCache.store("iphone")
        #endif
    }

    // Background iCloud scanners read only the launch-primed value. They never
    // cross into UIKit actor isolation and therefore cannot race device metadata.
    static var deviceSourceKey: String {
        deviceSourceKeyCache.load() ?? "iphone"
    }
}

enum BridgeStatus: Equatable {
    case online
    case awaitingMacActivity
    case offline
    case macUnreachable
    /// E8: this phone has no usable network path. Distinct from every other
    /// case, all of which blame the Mac or iCloud for a local outage.
    case deviceOffline
    case stale(minutesAgo: Int)
    case connecting

    var displayName: String {
        switch self {
        case .online:
            return "Connected via iCloud"
        case .awaitingMacActivity:
            return "Waiting for Mac activity"
        case .offline:
            return "iCloud unreachable"
        case .macUnreachable:
            return "Mac unreachable"
        case .deviceOffline:
            return "iPhone offline"
        case .stale(let minutesAgo):
            return "Last seen \(minutesAgo)m ago"
        case .connecting:
            return "Connecting via iCloud…"
        }
    }

    var color: Color {
        switch self {
        case .online:
            return .green
        case .offline, .macUnreachable, .deviceOffline:
            return .red
        case .awaitingMacActivity, .stale, .connecting:
            return .orange
        }
    }
}

@MainActor
enum MacBridgeReconnectPolicy {
    static func delayNanoseconds(afterAttempt attempt: Int) -> UInt64 {
        attempt < 60 ? 500_000_000 : 5_000_000_000
    }
}

/// E8: the status chip used to be recomputed by a 5s timer that ran for the
/// life of the process, including on a phone that had been idle and settled for
/// hours. `bridgeStatusDecision` is a pure function of three ages, so the timer
/// is only needed while one of those ages can still cross a boundary.
enum MacBridgeStatusRefreshPolicy {
    /// Cadence while a boundary is imminent (online → stale, connecting →
    /// offline, offline → macUnreachable).
    static let activeInterval: TimeInterval = 5
    /// Cadence once the only thing still changing is the displayed minute count.
    static let minuteCounterInterval: TimeInterval = 60

    /// Seconds until the next recompute, or nil when nothing time-dependent
    /// remains — the availability publisher and any Mac confirmation re-arm it.
    static func refreshInterval(
        now: Date,
        lastSeenAt: Date?,
        connectingStartedAt: Date?,
        bridgeUnavailableSince: Date?,
        isPaired: Bool,
        recentLastSeenInterval: TimeInterval,
        initialConnectingInterval: TimeInterval,
        macUnreachableThreshold: TimeInterval
    ) -> TimeInterval? {
        if let connectingStartedAt,
           now.timeIntervalSince(connectingStartedAt) <= initialConnectingInterval {
            return activeInterval
        }
        // Paired + unavailable is still counting up to the .macUnreachable flip.
        if isPaired, let bridgeUnavailableSince,
           now.timeIntervalSince(bridgeUnavailableSince) < macUnreachableThreshold {
            return activeInterval
        }
        if let lastSeenAt {
            // Still recent: the online → stale boundary is imminent. Past it,
            // only the "Nm ago" counter moves — once a minute while minutes
            // are what the label shows, hourly once it reads in hours
            // (review fix, 2026-08-28: a long-settled stale state kept a 60s
            // wakeup forever; the label's own granularity is the honest tick).
            let age = now.timeIntervalSince(lastSeenAt)
            if age <= recentLastSeenInterval { return activeInterval }
            return age < 3600 ? minuteCounterInterval : 3600
        }
        // Never seen, not connecting, already past the unreachable threshold:
        // the projection is settled until an event changes an input.
        return nil
    }
}

@MainActor
final class MacBridgeClient: ObservableObject {
    private let bridge: iCloudBridge
    @Published var bridgeStatus: BridgeStatus = .offline
    @Published var lastSeenAt: Date? {
        didSet { refreshBridgeStatus() }
    }

    private var reconnectTask: Task<Void, Never>?
    private var reconnectGeneration = 0
    private var bridgeAvailabilityCancellable: AnyCancellable?
    private var networkPathCancellable: AnyCancellable?
    private var statusRefreshTask: Task<Void, Never>?
    private let pathObserver: NetworkPathObserver = .shared
    /// E8: fired when the device's network path comes back, so the chat store
    /// can auto-resume its durable queued sends.
    var onNetworkPathRestored: (() -> Void)?
    /// nil until NWPathMonitor reports; nil never paints an outage. Republished
    /// here so views observing the client see the transition.
    @Published private(set) var deviceIsOffline: Bool?
    /// Banner copy for the offline case, or nil when there is nothing to say.
    var offlineBannerMessage: String? {
        NetworkPathObserver.offlineBannerMessage(isOffline: deviceIsOffline)
    }
    var connectingStartedAt: Date?
    private var bridgeUnavailableSince: Date?
    /// F4: when paired and the bridge stays unavailable >30s, status flips to
    /// `.macUnreachable` instead of the generic `.offline`.
    weak var pairingStore: PairingStore?

    private static let recentLastSeenInterval: TimeInterval = 60
    private static let initialConnectingInterval: TimeInterval = 30
    private static let macUnreachableThreshold: TimeInterval = 30

    init(bridge: iCloudBridge = .shared) {
        self.bridge = bridge
        bridgeAvailabilityCancellable = bridge.$available
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshBridgeStatus() }
            }
        // E8: replaces the unconditional 5s forever-timer. refreshBridgeStatus
        // re-arms this with an interval derived from the current ages, and
        // stops arming it entirely once the projection is settled.
        networkPathCancellable = pathObserver.$isOffline
            .sink { [weak self] offline in
                Task { @MainActor in
                    self?.deviceIsOffline = offline
                    self?.refreshBridgeStatus()
                }
            }
        pathObserver.onPathRestored = { [weak self] in
            self?.onNetworkPathRestored?()
        }
        pathObserver.start()
        refreshBridgeStatus()
    }

    func configureICloud() {
        connectingStartedAt = Date()
        bridge.setup()
        refreshBridgeStatus()
        reconnectGeneration += 1
        let generation = reconnectGeneration
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var attempts = 0
            while !Task.isCancelled, generation == self.reconnectGeneration {
                self.bridge.setup()
                self.refreshBridgeStatus()
                if self.bridge.available { break }
                attempts += 1
                try? await Task.sleep(
                    nanoseconds: MacBridgeReconnectPolicy.delayNanoseconds(afterAttempt: attempts)
                )
            }
            guard generation == self.reconnectGeneration else { return }
            self.reconnectTask = nil
        }
    }

    func connect() {
        configureICloud()
    }

    func disconnect() {
        reconnectGeneration += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        connectingStartedAt = nil
        bridge.tearDown()
        refreshBridgeStatus()
    }

    // MARK: - Chat

    enum ChatSendResult {
        case queuedMessageId(String)
        case reply(text: String, sessionID: String?)
    }

    func sendMessage(
        _ text: String,
        sessionID: String?,
        controls: ChatRuntimeControls = .defaults,
        attachments: [MultimodalAttachment] = [],
        suppressRemoteUserAppend: Bool = false,
        replacementAssistantMessageID: UUID? = nil
    ) async throws -> ChatSendResult {
        let metadata = Self.chatSendMetadata(
            controls: controls,
            suppressRemoteUserAppend: suppressRemoteUserAppend,
            replacementAssistantMessageID: replacementAssistantMessageID
        )
        let msg = try await bridge.sendChatMessage(
            text: text,
            sessionID: sessionID,
            metadata: metadata,
            attachments: attachments
        )
        return .queuedMessageId(msg.id)
    }

    static func chatSendMetadata(
        controls: ChatRuntimeControls,
        suppressRemoteUserAppend: Bool,
        replacementAssistantMessageID: UUID?
    ) -> [String: String] {
        var metadata = controls.metadata(transport: "icloud")
        if suppressRemoteUserAppend, let replacementAssistantMessageID {
            metadata["suppressUserAppend"] = "true"
            metadata["replacementAssistantMessageId"] = replacementAssistantMessageID.uuidString
        }
        return metadata
    }

    func cancelChat(sessionID: String?) async throws {
        let hasExplicitSession = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        _ = try await iCloudSyncEngine.shared.cancelChat(
            sessionId: sessionID,
            source: "ios_icloud",
            sourceKey: hasExplicitSession ? nil : NativeAgentICloudBridgeConstants.mobileSourceKey
        )
        recordMacConfirmation()
    }

    @discardableResult
    func observeICloudReplies(onMessage: @escaping (BridgeMessage) -> Void) -> UUID? {
        return bridge.observeIncomingMessages { [weak self] msg in
            Task { @MainActor in self?.recordMacConfirmation() }
            onMessage(msg)
        }
    }

    @discardableResult
    func observeICloudReplyRejections(onReject: @escaping (ICloudBridgeRejectedMessage) -> Void) -> UUID? {
        return bridge.observeRejectedMessages { [weak self] rejection in
            Task { @MainActor in self?.recordMacConfirmation() }
            onReject(rejection)
        }
    }

    /// Phase 14e-iCloud HMAC self-heal: observe unsigned signature_invalid_resync
    /// hints from Mac so ChatView can refresh + retry the most recent unACK'd send.
    @discardableResult
    func observeICloudResyncHints(onHint: @escaping (BridgeMessage) -> Void) -> UUID? {
        return bridge.observeResyncHints { [weak self] hint in
            Task { @MainActor in self?.recordMacConfirmation() }
            onHint(hint)
        }
    }

    func removeICloudResyncHintObserver(_ id: UUID?) {
        bridge.removeResyncObserver(id)
    }

    func removeICloudReplyObserver(_ id: UUID?) {
        bridge.removeIncomingObserver(id)
    }

    func removeICloudReplyRejectionObserver(_ id: UUID?) {
        bridge.removeRejectedObserver(id)
    }

    func pollICloudRepliesNow() async {
        await bridge.pollIncomingNow()
        refreshBridgeStatus()
    }

    /// Only Mac-originated activity or a confirmed Mac action may refresh the
    /// status chip. Queuing an iPhone message proves iCloud accepted it, not
    /// that the Mac is awake to process it.
    private func recordMacConfirmation() {
        connectingStartedAt = nil
        lastSeenAt = Date()
    }

    func refreshBridgeStatus(now: Date = Date()) {
        let next = computedBridgeStatus(now: now)
        if bridgeStatus != next {
            bridgeStatus = next
        }
        rescheduleStatusRefresh(now: now)
    }

    /// E8: arm exactly one recompute, at the cadence the current ages justify.
    private func rescheduleStatusRefresh(now: Date) {
        statusRefreshTask?.cancel()
        guard let interval = MacBridgeStatusRefreshPolicy.refreshInterval(
            now: now,
            lastSeenAt: lastSeenAt,
            connectingStartedAt: connectingStartedAt,
            bridgeUnavailableSince: bridgeUnavailableSince,
            isPaired: pairingStore?.isPaired == true,
            recentLastSeenInterval: Self.recentLastSeenInterval,
            initialConnectingInterval: Self.initialConnectingInterval,
            macUnreachableThreshold: Self.macUnreachableThreshold
        ) else {
            statusRefreshTask = nil
            return
        }
        statusRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.refreshBridgeStatus()
        }
    }

    private func computedBridgeStatus(now: Date) -> BridgeStatus {
        let bridgeAvailable = bridge.available
        if bridgeAvailable {
            bridgeUnavailableSince = nil
        } else if bridgeUnavailableSince == nil {
            bridgeUnavailableSince = now
        }
        // E8: a phone with no network path must say so rather than blaming the
        // Mac. Only an observed outage overrides; an unknown path does not.
        if deviceIsOffline == true { return .deviceOffline }
        return Self.bridgeStatusDecision(
            bridgeAvailable: bridgeAvailable,
            lastSeenAt: lastSeenAt,
            connectingStartedAt: connectingStartedAt,
            bridgeUnavailableSince: bridgeUnavailableSince,
            isPaired: pairingStore?.isPaired == true,
            now: now
        )
    }

    /// The status surface is a compact projection of real bridge, pairing, and
    /// recency evidence. Keeping its table value-only lets every caller use
    /// the same boundaries; it does not create a second health owner.
    static func bridgeStatusDecision(
        bridgeAvailable: Bool,
        lastSeenAt: Date?,
        connectingStartedAt: Date?,
        bridgeUnavailableSince: Date?,
        isPaired: Bool,
        now: Date
    ) -> BridgeStatus {
        if bridgeAvailable, let lastSeenAt {
            let age = now.timeIntervalSince(lastSeenAt)
            if age <= recentLastSeenInterval { return .online }
            return .stale(minutesAgo: minutesAgo(since: lastSeenAt, now: now))
        }
        if let connectingStartedAt,
           now.timeIntervalSince(connectingStartedAt) <= initialConnectingInterval {
            return .connecting
        }
        if bridgeAvailable { return .awaitingMacActivity }
        // Paired + unavailable means the transport is reachable enough to
        // diagnose, but the Mac has not resumed its side of the boundary.
        if isPaired, let start = bridgeUnavailableSince,
           now.timeIntervalSince(start) >= macUnreachableThreshold {
            return .macUnreachable
        }
        return .offline
    }

    private static func minutesAgo(since date: Date, now: Date) -> Int {
        max(1, Int(now.timeIntervalSince(date) / 60))
    }

    // MARK: - Generic read/write (HTTP transport removed)
    //
    // Direct Mac HTTP routes are no longer reachable from iOS.
    // `get` / `postDict` throw `transportRemoved`; views that wrap calls in `try?`
    // degrade to nil/empty rather than hanging on a dead network call.

    static let transportRemoved = NSError(
        domain: "NativeAgentMobile",
        code: -42,
        userInfo: [NSLocalizedDescriptionKey:
            "Direct HTTP transport removed. iCloud is the only iOS transport."]
    )

    func get<T: Decodable>(_ path: String) async throws -> T {
        _ = path
        throw Self.transportRemoved
    }

    func postDict(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        _ = path
        _ = body
        throw Self.transportRemoved
    }

    // MARK: - Chat history refresh (iCloud snapshot read)

    func refreshChatHistory(sessionID: String?) async -> [ChatMessage]? {
        let engine = iCloudSyncEngine.shared
        let sid: String
        if let sessionID, !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sid = sessionID
        } else {
            return nil
        }
        if let cached = engine.transcriptRecords(for: sid) {
            return Self.projectChatRecords(cached)
        }
        await engine.refreshChatTranscriptsSnapshot()
        guard let records = engine.transcriptRecords(for: sid) else { return nil }
        return Self.projectChatRecords(records)
    }

    static func projectChatRecords(_ records: [ChatMessageRecord]) -> [ChatMessage] {
        // eval3/T3 data-flow:
        // iOS send → BridgeMessage.attachments → Mac Swift runtime forwarding
        //   → ChatOrchestrationClient.appendMessage writes
        //     `metadata.attachments=[{id,type,mime,name,byteSize}]` into
        //     data/chat/messages/<sid>.jsonl
        //   → NativeClient.getChatMessages decodes into ChatMessageMetadata
        //     (which now carries `attachments`)
        //   → MacSyncEngine snapshots [ChatMessage] into
        //     iCloud chat_transcripts.json
        //   → iCloudSyncEngine.refreshChatTranscriptsSnapshot reads it as
        //     [ChatMessageRecord] (carries `metadata.attachments`)
        //   → here: project metadata.attachments → [ChatAttachmentSummary]
        //     so the rebuilt ChatMessage on refresh preserves attachments.
        return records.compactMap { rec in
            let roleStr = rec.role
            guard roleStr == "user" || roleStr == "assistant" else { return nil }
            let role: ChatMessage.Role = roleStr == "user" ? .user : .assistant
            let uuid = UUID(uuidString: rec.id) ?? UUID()
            let attachments: [ChatAttachmentSummary] = (rec.metadata?.attachments ?? []).map { a in
                ChatAttachmentSummary(
                    id: a.id,
                    name: a.name ?? "attachment",
                    type: a.type,
                    mime: a.mime,
                    byteSize: a.byteSize.map(Int.init)
                )
            }
            return ChatMessage(id: uuid, role: role, text: rec.content, attachments: attachments)
        }
    }

    static let shared = MacBridgeClient()
}
