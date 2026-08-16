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
    case offline
    case macUnreachable
    case stale(minutesAgo: Int)
    case connecting

    var displayName: String {
        switch self {
        case .online:
            return "Connected via iCloud"
        case .offline:
            return "iCloud unreachable"
        case .macUnreachable:
            return "Mac unreachable"
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
        case .offline, .macUnreachable:
            return .red
        case .stale, .connecting:
            return .orange
        }
    }
}

@MainActor
final class MacBridgeClient: ObservableObject {
    @Published var bridgeStatus: BridgeStatus = .offline
    @Published var lastSeenAt: Date? {
        didSet { refreshBridgeStatus() }
    }

    private var reconnectTask: Task<Void, Never>?
    private var bridgeAvailabilityCancellable: AnyCancellable?
    private var bridgeStatusPollCancellable: AnyCancellable?
    private var connectingStartedAt: Date?
    private var bridgeUnavailableSince: Date?
    /// F4: when paired and the bridge stays unavailable >30s, status flips to
    /// `.macUnreachable` instead of the generic `.offline`.
    weak var pairingStore: PairingStore?

    private static let recentLastSeenInterval: TimeInterval = 60
    private static let initialConnectingInterval: TimeInterval = 30
    private static let macUnreachableThreshold: TimeInterval = 30

    init() {
        bridgeAvailabilityCancellable = iCloudBridge.shared.$available
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshBridgeStatus() }
            }
        bridgeStatusPollCancellable = Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshBridgeStatus() }
            }
        refreshBridgeStatus()
    }

    func configureICloud() {
        connectingStartedAt = Date()
        let bridge = iCloudBridge.shared
        bridge.setup()
        refreshBridgeStatus()
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor in
            var attempts = 0
            while !Task.isCancelled {
                bridge.setup()
                refreshBridgeStatus()
                if bridge.available { return }
                attempts += 1
                let delay: UInt64 = attempts < 60 ? 500_000_000 : 5_000_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    func connect() {
        configureICloud()
    }

    func disconnect() {
        reconnectTask?.cancel()
        connectingStartedAt = nil
        iCloudBridge.shared.tearDown()
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
        let msg = try await iCloudBridge.shared.sendChatMessage(
            text: text,
            sessionID: sessionID,
            metadata: metadata,
            attachments: attachments
        )
        markBridgeActivity()
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
        markBridgeActivity()
    }

    @discardableResult
    func observeICloudReplies(onMessage: @escaping (BridgeMessage) -> Void) -> UUID? {
        return iCloudBridge.shared.observeIncomingMessages { [weak self] msg in
            Task { @MainActor in self?.markBridgeActivity() }
            onMessage(msg)
        }
    }

    @discardableResult
    func observeICloudReplyRejections(onReject: @escaping (ICloudBridgeRejectedMessage) -> Void) -> UUID? {
        return iCloudBridge.shared.observeRejectedMessages { [weak self] rejection in
            Task { @MainActor in self?.markBridgeActivity() }
            onReject(rejection)
        }
    }

    /// Phase 14e-iCloud HMAC self-heal: observe unsigned signature_invalid_resync
    /// hints from Mac so ChatView can refresh + retry the most recent unACK'd send.
    @discardableResult
    func observeICloudResyncHints(onHint: @escaping (BridgeMessage) -> Void) -> UUID? {
        return iCloudBridge.shared.observeResyncHints { [weak self] hint in
            Task { @MainActor in self?.markBridgeActivity() }
            onHint(hint)
        }
    }

    func removeICloudResyncHintObserver(_ id: UUID?) {
        iCloudBridge.shared.removeResyncObserver(id)
    }

    func removeICloudReplyObserver(_ id: UUID?) {
        iCloudBridge.shared.removeIncomingObserver(id)
    }

    func removeICloudReplyRejectionObserver(_ id: UUID?) {
        iCloudBridge.shared.removeRejectedObserver(id)
    }

    func pollICloudRepliesNow() async {
        await iCloudBridge.shared.pollIncomingNow()
        refreshBridgeStatus()
    }

    private func markBridgeActivity() {
        connectingStartedAt = nil
        lastSeenAt = Date()
    }

    private func refreshBridgeStatus(now: Date = Date()) {
        let next = computedBridgeStatus(now: now)
        if bridgeStatus != next {
            bridgeStatus = next
        }
    }

    private func computedBridgeStatus(now: Date) -> BridgeStatus {
        let bridgeAvailable = iCloudBridge.shared.available
        if bridgeAvailable {
            bridgeUnavailableSince = nil
        } else if bridgeUnavailableSince == nil {
            bridgeUnavailableSince = now
        }
        if bridgeAvailable, let lastSeenAt {
            let age = now.timeIntervalSince(lastSeenAt)
            if age <= Self.recentLastSeenInterval {
                return .online
            }
            return .stale(minutesAgo: Self.minutesAgo(since: lastSeenAt, now: now))
        }
        if let connectingStartedAt,
           now.timeIntervalSince(connectingStartedAt) <= Self.initialConnectingInterval {
            return .connecting
        }
        if bridgeAvailable {
            return .stale(minutesAgo: 1)
        }
        // F4: paired but bridge has been unavailable for more than 30 s → Mac
        // process is the likely culprit (iCloud is the transport, not the agent).
        if let pairingStore, pairingStore.isPaired,
           let start = bridgeUnavailableSince,
           now.timeIntervalSince(start) >= Self.macUnreachableThreshold {
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
