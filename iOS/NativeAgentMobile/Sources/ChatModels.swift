import SwiftUI
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
    /// No row for this session in the newest snapshot (still downloading, the
    /// session is not in the published set, or the read failed). Hold last-good.
    case unavailable
    /// The Mac's transcript for this session, possibly empty. `generation` is
    /// the session's transcript version at publication — a counter the Mac
    /// bumps on every clear and every transcript write. An empty transcript
    /// only clears the phone when that counter is strictly greater than the
    /// last one applied for the session.
    case published([ChatMessage], generation: Int?)

    /// The rows the Mac published — empty both for `.unavailable` and for an
    /// explicit empty transcript, so never branch on this alone.
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
    /// Tools/skills this assistant turn used (assistant messages only). Drives
    /// the live flip-box while streaming and the collapsed summary when done.
    var toolEvents: [ToolEvent] = []
    /// A settled bridge receipt that the Mac transcript has not yet published.
    /// Kept in the shared projection until the matching Mac run is published.
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

    nonisolated static func projectChatRecords(_ records: [ChatMessageRecord]) -> [ChatMessage] {
        // Project metadata.attachments into chat summaries so snapshot refresh preserves attachments.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return records.compactMap { rec in
            let roleStr = rec.role
            let interaction = rec.interactionJSON.flatMap { try? decoder.decode(InlineInteraction.self, from: Data($0.utf8)) }
            let descriptor = rec.interactionDescriptorJSON.flatMap { try? decoder.decode(InlineInteractionDescriptor.self, from: Data($0.utf8)) }
            guard roleStr == "user" || roleStr == "assistant" || interaction != nil else { return nil }
            let role: ChatMessage.Role = roleStr == "user" ? .user : .assistant
            let uuid = UUID(uuidString: rec.id) ?? UUID()
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
        /// The derived conversation-anchor tab. It is NOT a pin: nobody wrote it
        /// into a pin list, so there is nothing to unpin and no close control.
        case anchor(String)
    }

    var id: String
    var title: String
    var systemImage: String
    var sessionID: String?
    var kind: Kind

    /// The session a close control may unpin — real Mac-owned pins only.
    /// The anchor tab returns nil: an unpin request for it would name a row
    /// the human may never have pinned, and would drop the live conversation
    /// off the strip until the next publish put it back.
    var closableSessionID: String? {
        if case .pinned(let sessionID) = kind { return sessionID }
        return nil
    }
}

/// An explicit session choice lasts this launch; nil follows main.
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

/// Pure projection for the iOS tab strip. The phone has one current mobile
/// session plus the exact ordered Mac-owned pinned snapshot—never a second
/// source-based definition of what counts as a tab. The conversation anchor,
/// when there is one, rides at the front of the pinned run as a derived tab.
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
