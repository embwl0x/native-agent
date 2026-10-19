import CryptoKit
import Foundation
import PersistenceCore

/// The artifacts a reply carries: its face's, which every surface renders.
public enum ChatGeneratedImageArtifacts {
    /// What she chose, explicitly: every image her generation made in this
    /// turn (from its receipts), and every image she attached to it with
    /// `reply.attach` (`ReplyChoices`, in the order she chose them).
    public static func attachments(
        from dispatches: [TurnEngineResult.ToolDispatchRecord],
        chosen: [String] = [],
        dataRoot: URL
    ) -> [MultimodalAttachment] {
        var out: [MultimodalAttachment] = []
        var seen: Set<String> = []
        // app image.generate is image_generate too.
        let generated = dispatches.filter { $0.ranCall.tool == "image_generate" }
            .flatMap { attachments(fromToolResult: $0.result, dataRoot: dataRoot) }
        for attachment in generated + chosen.compactMap({ attachment(URL(fileURLWithPath: $0)) })
            where attachment.path.map({ seen.insert($0).inserted }) == true {
            out.append(attachment)
        }
        return out
    }

    public static func attachments(
        fromToolResult value: JSONValue,
        dataRoot: URL
    ) -> [MultimodalAttachment] {
        guard case .object(let object) = value else { return [] }
        guard case .array(let images)? = object["images"] else { return [] }
        let generatedRoot = dataRoot
            .appendingPathComponent("generated_images", isDirectory: true)
            .standardizedFileURL
            .path

        var out: [MultimodalAttachment] = []
        for image in images {
            guard case .object(let imageObject) = image,
                  case .string(let rawPath)? = imageObject["path"] else {
                continue
            }
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.path == generatedRoot || url.path.hasPrefix(generatedRoot + "/") else { continue }
            let name: String?
            if case .string(let filename)? = imageObject["filename"],
               !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                name = nil
            }
            if let attachment = attachment(url, name: name,
                    byteSize: intValue(imageObject["byteSize"]) ?? intValue(imageObject["byte_size"])) {
                out.append(attachment)
            }
        }
        return out
    }

    /// An image file on disk as a reply attachment; nil for anything else.
    public static func attachment(_ url: URL, name: String? = nil, byteSize: Int? = nil) -> MultimodalAttachment? {
        guard FileManager.default.fileExists(atPath: url.path), let mime = imageMimeType(for: url) else { return nil }
        return MultimodalAttachment(
            id: stableAttachmentId(for: url),
            type: "image",
            base64: "",
            mime: mime,
            name: name ?? url.lastPathComponent,
            byteSize: fileByteSize(url) ?? byteSize ?? 0,
            path: url.path
        )
    }

    private static func imageMimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "heic": return "image/heic"
        default: return nil
        }
    }

    private static func fileByteSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    private static func intValue(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let value): return Int(value)
        case .double(let value): return Int(exactly: value.rounded(.towardZero))
        default: return nil
        }
    }

    /// From the whole path: two files of one name are two attachments.
    private static func stableAttachmentId(for url: URL) -> String {
        "image-" + SHA256.hash(data: Data(url.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
