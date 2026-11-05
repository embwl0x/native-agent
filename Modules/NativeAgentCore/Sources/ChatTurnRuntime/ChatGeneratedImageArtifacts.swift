import CryptoKit
import Foundation
import PersistenceCore
import ToolRegistry

// Blueprint: | `ChatGeneratedImageArtifacts.swift` | `ChatGeneratedImageArtifacts`; Receipt-backed reply images |

public enum ChatGeneratedImageArtifacts {
    /// Use generation receipts and explicit reply choices so every surface renders the images selected for this reply.
    public static func attachments(
        from dispatches: [TurnEngineResult.ToolDispatchRecord],
        chosen: [String] = [],
        dataRoot: URL
    ) -> [MultimodalAttachment] {
        var out: [MultimodalAttachment] = []
        var seen: Set<String> = []
        let generated = dispatches.flatMap { generations($0.ranCall.tool, $0.ranCall.input, $0.result) }
            .flatMap { attachments(fromToolResult: $0, dataRoot: dataRoot) }
        for attachment in generated + chosen.compactMap({ attachment(URL(fileURLWithPath: $0)) })
            where attachment.path.map({ seen.insert($0).inserted }) == true {
            out.append(attachment)
        }
        return out
    }

    /// Pair action-list receipts by order; fan-out and script ledgers retain each call's action identity.
    private static func generations(_ tool: String, _ input: [String: JSONValue], _ result: JSONValue) -> [JSONValue] {
        guard case .object(let fields) = result else { return [] }
        // Preserve artifacts before bounding a saved receipt so recovery retains them.
        if let kept = fields["generatedImages"] { return [.object(["images": kept])] }
        if case .array(let calls)? = fields["calls"] {
            return calls.flatMap { row -> [JSONValue] in
                guard case .object(let ran) = row, let action = ran["call"] else { return [] }
                return generations(ToolNameAliases.ranTool("app", input: ["action": action]), [:], row)
            }
        }
        guard case .array(let receipts)? = fields["receipts"] else {
            return tool == "image_generate" ? [result] : []
        }
        guard case .array(let entries)? = input["actions"] else {
            return receipts.flatMap { generations(tool, input, $0) }
        }
        return zip(entries, receipts).flatMap { entry, receipt -> [JSONValue] in
            guard case .object(let call) = entry else { return [] }
            let ran = ToolNameAliases.ranCall("app", input: call)
            return generations(ran.tool, ran.input, receipt)
        }
    }

    /// Preserve all generated images before bounding the receipt so resumed turns retain them.
    public static func generatedImages(_ tool: String, _ input: [String: JSONValue], _ result: JSONValue) -> [JSONValue] {
        generations(tool, input, result).flatMap { generation -> [JSONValue] in
            guard case .object(let fields) = generation, case .array(let images)? = fields["images"] else { return [] }
            return images
        }
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
            guard NativeAgentWorkspaceRoot.relativePath(url.path, under: generatedRoot) != nil else { continue }
            let name: String?
            if case .string(let filename)? = imageObject["filename"],
               !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                name = nil
            }
            if let attachment = attachment(url, name: name,
                    byteSize: imageObject["byteSize"]?.integerValue.flatMap(Int.init(exactly:)) ?? imageObject["byte_size"]?.integerValue.flatMap(Int.init(
                        exactly:))) {
                out.append(attachment)
            }
        }
        return out
    }

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

    /// Use the whole path so equal filenames remain distinct attachments.
    private static func stableAttachmentId(for url: URL) -> String {
        "image-" + SHA256.hash(data: Data(url.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
