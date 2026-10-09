import Foundation
import CryptoKit
import UniformTypeIdentifiers
import ToolRegistry
import PersistenceCore

/// Whole-file write receipts shared by live delivery and canonical recovery.
public enum ChatWrittenFileArtifacts {
    public struct File {
        public let name: String
        public let mime: String
        public let bytes: Data
        public let reference: JSONValue
    }

    public static func files(from dispatches: [TurnEngineResult.ToolDispatchRecord],
                             maximumBytes: Int = 10_000_000) -> [File] {
        dispatches.compactMap { dispatch in
            guard ToolNameAliases.ranTool(dispatch.name, input: dispatch.input) == "write_file" else { return nil }
            let input = ToolNameAliases.ranInput(dispatch.name, input: dispatch.input)
            guard case .object(let receipt) = dispatch.result, receipt["ok"] == .bool(true),
                  receipt["append"] == .bool(false), case .string(let content)? = input["content"],
                  receipt["bytes_written"] == .int(Int64(content.utf8.count)),
                  case .string(let path)? = input["path"], content.utf8.count <= maximumBytes else { return nil }
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard !name.isEmpty, name.utf8.count <= 255, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\\"),
                  name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            let mime = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let bytes = Data(content.utf8)
            var reference: [String: JSONValue] = [
                "type": .string("file"), "name": .string(name), "mime": .string(mime),
                "byteSize": .int(Int64(bytes.count)),
                "sha256": .string(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()),
            ]
            // Use the writer's resolved path, never the input's relative alias.
            // A missing reference remains visible to recovery as incomplete.
            if case .string(let savedPath)? = receipt["path"], savedPath.hasPrefix("/") {
                reference["path"] = .string(savedPath)
            }
            return File(name: name, mime: mime, bytes: bytes, reference: .object(reference))
        }
    }
}
