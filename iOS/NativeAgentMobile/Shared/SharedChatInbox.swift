import Foundation
import NativeAgentShared

struct SharedChatItem: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let text: String
    let attachments: [MultimodalAttachment]
}

enum SharedChatInbox {
    static let maxItems = 4
    static let maxTextBytes = 64 * 1024

    static func container() throws -> URL {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "NativeAgentAppGroupID") as? String,
              let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw failure("Shared storage is unavailable. Check NativeAgent's App Group signing.")
        }
        return url
    }

    static func directory() throws -> URL {
        let url = try container().appendingPathComponent("ChatShareInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func pendingFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func save(_ item: SharedChatItem) throws {
        guard try pendingFiles().count < 20 else {
            throw failure("Open NativeAgent to send your waiting shares before adding more.")
        }
        guard (!item.text.isEmpty || !item.attachments.isEmpty), item.text.utf8.count <= maxTextBytes,
              item.attachments.count <= maxItems,
              item.attachments.reduce(0, { $0 + $1.byteSize }) <= MobileChatAttachmentPreparation.payloadBudgetBytes else {
            throw failure("This share is too large. Use less text or a smaller file.")
        }
        // The codec counts escaped JSON/base64 and the duplicated text field.
        // Reserve 16 KiB for controls, session identity and signing added by
        // the app, which the extension does not know when saving the share.
        let envelope = BridgeMessage.make(
            id: item.id.uuidString, sender: "ios", text: item.text,
            metadata: ["shareEnvelopeReserve": String(repeating: "x", count: 16 * 1024)],
            attachments: item.attachments.isEmpty ? nil : item.attachments
        )
        do {
            _ = try NAChatMessageCodec.encode(envelope)
        } catch DeviceSyncError.payloadTooLarge {
            throw failure("This share is too large to send. Use less text or a smaller file.")
        }
        let url = try directory().appendingPathComponent(item.id.uuidString + ".json")
        try JSONEncoder().encode(item).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func agentName() throws -> String {
        let url = try container().appendingPathComponent("ShareAgentName.txt")
        guard FileManager.default.fileExists(atPath: url.path) else { return "NativeAgent" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func rememberAgentName(_ name: String) throws {
        try Data(name.utf8).write(to: container().appendingPathComponent("ShareAgentName.txt"), options: .atomic)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "NativeAgentShare", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
