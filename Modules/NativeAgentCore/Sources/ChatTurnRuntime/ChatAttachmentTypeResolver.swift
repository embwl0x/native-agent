import Foundation
import NativeAgentShared

// Blueprint: | `ChatAttachmentTypeResolver.swift` | `ChatAttachmentTypeResolver`; Bounded off-main attachment admission |

public typealias ChatAttachmentTypeResolver = NativeAgentShared.ChatAttachmentTypeResolver

public extension ChatAttachmentTypeResolver {
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

    struct AttachmentRefusal: Error, Sendable {
        public let message: String
        public init(message: String) { self.message = message }
    }

    /// Shared admission keeps composer attachments under the same type and size rules.
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

    /// Keep bounded file reads off the main actor.
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
