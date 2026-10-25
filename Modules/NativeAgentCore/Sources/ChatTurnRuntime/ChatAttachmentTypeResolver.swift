import Foundation
import AppKit
import UniformTypeIdentifiers
import NativeAgentShared

// Blueprint: | `ChatAttachmentTypeResolver.swift` | `ChatAttachmentTypeResolver`: type/size admission, bounded off-main file reads and voice draft attachments |

public typealias ChatAttachmentTypeResolver = NativeAgentShared.ChatAttachmentTypeResolver

public extension ChatAttachmentTypeResolver {
    static let clipboardImageByteLimit = 10 * 1024 * 1024

    static func imageType(in identifiers: [String]) -> String? {
        let preferred = [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier]
        return preferred.first(where: identifiers.contains)
            ?? identifiers.first { UTType($0)?.conforms(to: .image) == true }
    }

    static func localFileURL(_ item: Any?) -> URL? {
        if let value = item as? URL { return value }
        if let value = item as? Data { return URL(dataRepresentation: value, relativeTo: nil) }
        if let value = item as? String { return URL(string: value) }
        return nil
    }

    static func imageAttachment(
        _ data: Data?, typeIdentifier: String
    ) -> Result<NativeAgentShared.MultimodalAttachment, AttachmentRefusal> {
        guard let data else { return .failure(.init(message: "Couldn't read the attached image")) }
        guard data.count <= clipboardImageByteLimit else {
            return .failure(.init(message: "Image too large (limit: 10 MB)"))
        }
        let bytes: Data
        let mime: String
        switch typeIdentifier {
        case UTType.png.identifier: bytes = data; mime = "image/png"
        case UTType.jpeg.identifier: bytes = data; mime = "image/jpeg"
        default:
            guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
                return .failure(.init(message: "Couldn't read the attached image"))
            }
            bytes = png; mime = "image/png"
        }
        guard bytes.count <= clipboardImageByteLimit else {
            return .failure(.init(message: "Image too large (limit: 10 MB)"))
        }
        return .success(NativeAgentShared.MultimodalAttachment(
            type: "image", base64: bytes.base64EncodedString(), mime: mime, byteSize: bytes.count
        ))
    }

    /// Read one overflow byte so a growing file cannot bypass the attachment
    /// cap or allocate an unbounded buffer before it is rejected.
    static func readAttachmentFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bound = fileByteLimit + 1
        var data = Data()
        while data.count < bound {
            guard let chunk = try handle.read(upToCount: bound - data.count),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }

    static func voiceDraft(base: String, transcript: String) -> String {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return spoken }
        if spoken.isEmpty { return base }
        return "\(base) \(spoken)"
    }

    struct AttachmentRefusal: Error, Sendable {
        public let message: String
        public init(message: String) { self.message = message }
    }

    /// Type and size, decided before any read. Shared with the agent's own
    /// composer verbs so a file she attaches meets the same rules.
    static func attachmentKind(
        _ url: URL, resolveType: (String) -> (type: String, mime: String)?
    ) -> Result<(type: String, mime: String), AttachmentRefusal> {
        let ext = url.pathExtension.lowercased()
        guard let attachmentInfo = resolveType(ext) else {
            return .failure(.init(message: "Unsupported file type: \(ext.isEmpty ? "(no extension)" : ext)"))
        }
        if let attrs = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = attrs.fileSize, size > fileByteLimit {
            return .failure(.init(message: "File too large (limit: 10 MB): \(url.lastPathComponent)"))
        }
        return .success(attachmentInfo)
    }

    /// The bounded read, off the main actor.
    static func readAttachment(
        _ url: URL, kind: (type: String, mime: String)
    ) async -> Result<NativeAgentShared.MultimodalAttachment, AttachmentRefusal> {
        let data = await Task.detached(priority: .utility) { () -> Data? in
            try? readAttachmentFile(url)
        }.value
        guard let data else {
            return .failure(.init(message: "Couldn't read file: \(url.lastPathComponent)"))
        }
        guard data.count <= fileByteLimit else {
            return .failure(.init(message: "File too large (limit: 10 MB): \(url.lastPathComponent)"))
        }
        return .success(NativeAgentShared.MultimodalAttachment(
            type: kind.type,
            base64: data.base64EncodedString(),
            mime: kind.mime,
            name: url.lastPathComponent,
            byteSize: data.count
        ))
    }
}
