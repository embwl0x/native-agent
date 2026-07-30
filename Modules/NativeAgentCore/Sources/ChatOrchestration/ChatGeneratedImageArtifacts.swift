import Foundation
import PersistenceCore

public enum ChatGeneratedImageArtifacts {
    public static func attachments(
        from dispatches: [TurnEngineResult.ToolDispatchRecord],
        dataRoot: URL
    ) -> [MultimodalAttachment] {
        var out: [MultimodalAttachment] = []
        var seen: Set<String> = []
        for dispatch in dispatches where dispatch.name == "image_generate" {
            for attachment in attachments(fromToolResult: dispatch.result, dataRoot: dataRoot) {
                guard let path = attachment.path, !seen.contains(path) else { continue }
                seen.insert(path)
                out.append(attachment)
            }
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
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let mime = imageMimeType(for: url) else { continue }

            let byteSize = fileByteSize(url)
                ?? intValue(imageObject["byteSize"])
                ?? intValue(imageObject["byte_size"])
                ?? 0
            let name: String
            if case .string(let filename)? = imageObject["filename"],
               !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                name = url.lastPathComponent
            }
            out.append(MultimodalAttachment(
                id: stableAttachmentId(for: url),
                type: "image",
                base64: "",
                mime: mime,
                name: name,
                byteSize: byteSize,
                path: url.path
            ))
        }
        return out
    }

    public static func imageDataAttachment(
        from attachment: MultimodalAttachment
    ) -> MultimodalAttachment? {
        guard attachment.type.lowercased() == "image" else { return nil }
        guard let path = attachment.path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return MultimodalAttachment(
            id: attachment.id,
            type: attachment.type,
            base64: data.base64EncodedString(),
            mime: attachment.mime,
            name: attachment.name,
            byteSize: data.count,
            path: attachment.path
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
        case .double(let value): return Int(value)
        default: return nil
        }
    }

    private static func stableAttachmentId(for url: URL) -> String {
        "generated-image-\(url.deletingPathExtension().lastPathComponent)"
    }
}
