import SwiftUI
import CryptoKit
import UIKit
import PhotosUI
import NativeAgentShared
import os
// Blueprint: | `ChatModels.swift` | Chat values, runtime controls and Mac transcript projection onto ChatMessage |

struct ChatRuntimeControls: Equatable, Sendable, Codable {
    var model: String
    var reasoningEffort: String
    var serviceTier: String = "default"
    var fileAccess: String
    var providerId: String = ""

    /// An empty model leaves resolution to the Mac's Chat group.
    static let defaults = ChatRuntimeControls(model: "", reasoningEffort: "high", serviceTier: "default", fileAccess: "auto")

    var normalized: ChatRuntimeControls {
        ChatRuntimeControls(
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            reasoningEffort: reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines),
            serviceTier: serviceTier.trimmingCharacters(in: .whitespacesAndNewlines),
            fileAccess: fileAccess.trimmingCharacters(in: .whitespacesAndNewlines),
            providerId: providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func metadata(transport: String) throws -> [String: String] {
        let clean = normalized
        var out: [String: String] = [
            "clientSurface": "iphone",
            "source": "ios",
            "transport": transport,
            "sourceKey": try NativeAgentICloudBridgeConstants.mobileSourceKey,
            "routeKey": Self.deviceSourceKey
        ]
        if !clean.model.isEmpty { out["model"] = clean.model }
        if !clean.reasoningEffort.isEmpty { out["reasoningEffort"] = clean.reasoningEffort }
        if !clean.serviceTier.isEmpty { out["serviceTier"] = clean.serviceTier }
        // Preserve supplied blank controls so Mac ingress refuses malformed input rather than inferring Auto.
        out["fileAccess"] = clean.fileAccess
        if !clean.providerId.isEmpty { out["providerId"] = clean.providerId }
        return out
    }

    private static let deviceSourceKeyCache = OSAllocatedUnfairLock<String?>(initialState: nil)

    static func makeDeviceSourceKey(deviceName: String) -> String {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "iphone" : "iphone:\(name)"
    }

    @MainActor
    static func primeDeviceSourceKey() {
        #if canImport(UIKit)
        let value = makeDeviceSourceKey(deviceName: UIDevice.current.name)
        #else
        let value = "iphone"
        #endif
        deviceSourceKeyCache.withLock { $0 = value }
    }

    // Background scanners read the launch-primed key without entering UIKit.
    static var deviceSourceKey: String {
        deviceSourceKeyCache.withLock { $0 } ?? "iphone"
    }
}

/// Only an explicitly published, newer empty Mac transcript can clear the phone's copy.
enum MacTranscriptRead: Equatable {
    /// Missing, failed or unpublished rows are unavailable, so retain the last admitted transcript.
    case unavailable
    /// Only a strictly newer Mac generation can clear the phone with an explicit empty transcript; every clear/write advances that generation.
    case published([ChatMessage], generation: Int?)

    /// Unavailable and published-empty reads both yield empty rows; the rows alone cannot authorize clearing.
    var messages: [ChatMessage] {
        guard case .published(let messages, _) = self else { return [] }
        return messages
    }
}

struct ChatAttachmentSummary: Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var type: String
    var mime: String?
    var base64: String?
    var byteSize: Int?
    var utterance: SpeechUtterance?

    init(_ attachment: MultimodalAttachment, fallbackName: String) {
        self.init(
            id: attachment.id,
            name: attachment.name ?? fallbackName,
            type: attachment.type,
            mime: attachment.mime,
            base64: attachment.base64,
            byteSize: attachment.byteSize,
            utterance: attachment.utterance
        )
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        type: String,
        mime: String? = nil,
        base64: String? = nil,
        byteSize: Int? = nil,
        utterance: SpeechUtterance? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.mime = mime
        self.base64 = base64
        self.byteSize = byteSize
        self.utterance = utterance
    }
}

extension ToolEvent: @retroactive Identifiable {
    public var id: String { "\(seq)-\(name)" }
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String { case user, assistant }
    let id: UUID
    let role: Role
    var text: String
    var isStreaming: Bool = false
    var attachments: [ChatAttachmentSummary] = []
    var toolEvents: [ToolEvent] = []
    /// Retain settled bridge receipts until the matching Mac run is published.
    var awaitingMacTranscript: Bool = false
    var runId: String?
    var turnID: String?
    var failureDetail: String?
    var interaction: InlineInteraction?
    var interactionDescriptor: InlineInteractionDescriptor?
    var interactionSessionID: String?
    var completionState: String? = nil

    var isTerminalReply: Bool {
        role == .assistant && interaction == nil && interactionDescriptor == nil && !isStreaming
            && (completionState == "completed" || completionState == "incomplete" || completionState == "failed")
    }

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        isStreaming: Bool = false,
        attachments: [ChatAttachmentSummary] = [],
        toolEvents: [ToolEvent] = [],
        awaitingMacTranscript: Bool = false,
        runId: String? = nil,
        failureDetail: String? = nil,
        interaction: InlineInteraction? = nil,
        interactionDescriptor: InlineInteractionDescriptor? = nil,
        interactionSessionID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
        self.attachments = attachments
        self.toolEvents = toolEvents
        self.awaitingMacTranscript = awaitingMacTranscript
        self.runId = runId
        self.failureDetail = failureDetail
        self.interaction = interaction
        self.interactionDescriptor = interactionDescriptor
        self.interactionSessionID = interactionSessionID
    }

    nonisolated static func derivedMessageID(_ id: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("nativeagent.message:" + id).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    nonisolated static func projectChatRecords(_ records: [ChatMessageRecord]) throws -> [ChatMessage] {
        // Project metadata.attachments into chat summaries so snapshot refresh preserves attachments.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try records.compactMap { rec in
            let roleStr = rec.role
            let interaction = try rec.interactionJSON.map { try decoder.decode(InlineInteraction.self, from: Data($0.utf8)) }
            let descriptor = try rec.interactionDescriptorJSON.map { try decoder.decode(InlineInteractionDescriptor.self, from: Data($0.utf8)) }
            guard roleStr == "user" || roleStr == "assistant" || interaction != nil else { return nil }
            let role: ChatMessage.Role = roleStr == "user" ? .user : .assistant
            // Derive non-UUID interaction/approval row IDs exactly as the Mac does so each row retains one stable identity.
            let uuid = UUID(uuidString: rec.id) ?? Self.derivedMessageID(rec.id)
            let attachments: [ChatAttachmentSummary] = (rec.metadata?.attachments ?? []).map { a in
                ChatAttachmentSummary(
                    id: a.id,
                    name: a.name ?? "attachment",
                    type: a.type,
                    mime: a.mime,
                    base64: a.preview?.png?.base64EncodedString(),
                    byteSize: a.byteSize.map(Int.init),
                    utterance: a.utterance
                )
            }
            var message = ChatMessage(id: uuid, role: role, text: interaction == nil ? rec.content : "", attachments: attachments, runId: rec.runId,
                interaction: interaction, interactionDescriptor: descriptor, interactionSessionID: rec.interactionSessionID)
            message.toolEvents = rec.toolEvents ?? []
            if roleStr == "assistant" {
                message.turnID = rec.metadata?.turnTraceId
                message.failureDetail = rec.metadata?.error
                message.completionState = rec.metadata?.failureWork != nil || rec.metadata?.error != nil ? "failed"
                    : rec.metadata?.partial == true || rec.metadata?.cancelled == true ? "incomplete" : rec.metadata?.completionState
            }
            return message
        }
    }
}

struct PendingPhotoAttachment: Identifiable, Equatable {
    let id: String
    var attachment: MultimodalAttachment
    var thumbnail: UIImage
    var pickerItem: PhotosPickerItem? = nil

    static func == (lhs: PendingPhotoAttachment, rhs: PendingPhotoAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

struct ChatSessionTab: Identifiable, Hashable {
    enum Kind: Hashable {
        case main
        case pinned(String)
        /// Derived conversation anchors are not pins and must not expose an unpin control.
        case anchor(String)
    }

    var id: String
    var title: String
    var systemImage: String
    var sessionID: String?
    var kind: Kind

    /// Only Mac-owned pins may unpin; closing a derived anchor could remove a conversation the user never pinned.
    var closableSessionID: String? {
        if case .pinned(let sessionID) = kind { return sessionID }
        return nil
    }
}

@MainActor
enum MobileChatSelectionIntent {
    private(set) static var explicitlySelectedSessionID: String?

    static func followMain() {
        explicitlySelectedSessionID = nil
    }

    static func selectSession(_ sessionID: String) {
        let clean = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        explicitlySelectedSessionID = clean.isEmpty ? nil : clean
    }
}

/// Use the exact ordered Mac pin snapshot, with the derived anchor first; source-based tab rules would create a second owner.
enum ChatSessionTabs {
    static func make(
        mainSessionID: String?,
        mainTitle: String,
        navigationRows: [ChatSessionNavigation.Row],
        openedSession: ChatSession?
    ) -> [ChatSessionTab] {
        var tabs: [ChatSessionTab] = [
            ChatSessionTab(
                id: "ios-main",
                title: cleanTitle(mainTitle, fallback: "iPhone"),
                systemImage: "iphone",
                sessionID: mainSessionID,
                kind: .main
            )
        ]
        var seen = Set([mainSessionID].compactMap { $0 })
        for row in navigationRows {
            let session = row.session
            guard seen.insert(session.id).inserted else { continue }
            tabs.append(ChatSessionTab(
                id: session.id,
                title: session.displayTitle,
                systemImage: row.isAnchor ? "clock" : "pin.fill",
                sessionID: session.id,
                kind: row.isPinned ? .pinned(session.id) : .anchor(session.id)
            ))
        }
        if let session = openedSession, seen.insert(session.id).inserted {
            tabs.append(.init(id: session.id, title: session.displayTitle, systemImage: "clock",
                sessionID: session.id, kind: .anchor(session.id)))
        }
        return tabs
    }

    private static func cleanTitle(_ title: String, fallback: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallback : clean
    }
}
