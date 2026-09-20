import Foundation
import Darwin
import ChatOrchestration
import PersistenceCore

struct AgentContactFailure: Error, Sendable {
    let code: Int
    let message: String
    static let missing = Self(code: -32001, message: "Task not found")
}

/// Protocol-independent content. A future binding maps these values without
/// changing turn admission, attribution, file policy or task ownership.
enum AgentContactPart: Codable, Sendable, Equatable {
    case text(String)
    case file(name: String, mediaType: String, bytes: Data, metadata: JSONValue)
    case data(JSONValue, metadata: JSONValue)

    static let maximumFileBytes = 10_000_000 // Same ceiling as the Mac composer.
    static let maximumOutputBytes = 16_000_000
    static let inputModes = ["text/plain", "application/json", "image/png", "image/jpeg", "image/heic",
        "image/webp", "image/gif", "application/pdf"]

    var isAttachment: Bool { if case .text = self { return false }; return true }

    func accepted(in modes: [String]) -> AgentContactPart? {
        if modes.contains("*/*") { return self }
        switch self {
        case .text: return self // Admission requires text/plain support.
        case .data: return modes.contains("application/json") ? self : nil
        case .file(_, let mediaType, let bytes, _):
            if mediaType == "text/plain" {
                return String(data: bytes, encoding: .utf8).map(AgentContactPart.text)
            }
            return modes.contains(mediaType) || modes.contains(mediaType.components(separatedBy: "/")[0] + "/*") ? self : nil
        }
    }

    static func decode03(_ object: [String: Any]) throws -> Self {
        try decode(object, version: "0.3")
    }

    static func decode(_ object: [String: Any], version: String) throws -> Self {
        if version == "0.3", let kind = object["kind"] as? String, !["text", "file", "data"].contains(kind) {
            throw AgentContactFailure(code: -32005, message: "This kind of content is not supported")
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: object))
        let canonical = try AgentA2AWire.canonicalPart(value, version: version)
        guard var object = Self.object(try AgentA2AWire.wirePart(canonical, version: "0.3")) as? [String: Any] else { throw invalidPart }
        // Admission keeps the original Value; wrapping is only a 0.3 output
        // compatibility rule, not a mutation of the internal attachment.
        if case .object(let fields) = canonical, let data = fields["data"] { object["data"] = Self.object(data) }
        let metadata: JSONValue
        if let value = object["metadata"] {
            guard value is [String: Any] else { throw AgentContactFailure(code: -32602, message: "Invalid part details") }
            metadata = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
        } else { metadata = .object([:]) }
        switch object["kind"] as? String {
        case "text":
            guard let text = object["text"] as? String else { throw invalidPart }
            return .text(text)
        case "data":
            guard let object = object["data"] else { throw invalidPart }
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
            guard bytes.count <= 64000 else { throw AgentContactFailure(code: -32602, message: "Data is too large") }
            return .data(try JSONDecoder().decode(JSONValue.self, from: bytes), metadata: metadata)
        case "file":
            guard let file = object["file"] as? [String: Any] else { throw invalidPart }
            if let uri = file["uri"] {
                guard file["bytes"] == nil, let uri = uri as? String, uri.utf8.count <= 2048,
                      let url = URL(string: uri), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else { throw invalidPart }
                // Fetching a link can itself be an effect. Never read a caller's
                // local path, attach port credentials, follow redirects, or
                // fetch remote content outside the ordinary approval path.
                throw AgentContactFailure(code: -32005, message: "Send the file's bytes instead of a link")
            }
            guard let encoded = file["bytes"] as? String, encoded.utf8.count <= 13_333_336,
                  let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= maximumFileBytes else { throw invalidPart }
            let mediaType = file["mimeType"] as? String ?? "application/octet-stream"
            guard inputModes.contains(mediaType), mediaType != "application/json" else {
                throw AgentContactFailure(code: -32005, message: "This file type cannot be attached")
            }
            let fallback = ["image/png": "attachment.png", "image/jpeg": "attachment.jpg", "image/heic": "attachment.heic",
                "image/webp": "attachment.webp", "image/gif": "attachment.gif", "application/pdf": "attachment.pdf",
                "text/plain": "attachment.txt"]
            let name = file["name"] as? String ?? fallback[mediaType] ?? "attachment"
            guard safeName(name), let type = ChatAttachmentTypeResolver.typeAndMime(forExtension: (name as NSString).pathExtension.lowercased()),
                  type.mime == mediaType else { throw invalidPart }
            return .file(name: name, mediaType: mediaType, bytes: bytes, metadata: metadata)
        default: throw AgentContactFailure(code: -32005, message: "This kind of content is not supported")
        }
    }

    private static var invalidPart: AgentContactFailure { .init(code: -32602, message: "Invalid attachment") }
    static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    var wire03: [String: Any] {
        switch self {
        case .text(let text): return ["kind": "text", "text": text]
        case .file(let name, let mediaType, let bytes, let metadata):
            return ["kind": "file", "file": ["name": name, "mimeType": mediaType, "bytes": bytes.base64EncodedString()], "metadata": Self.object(metadata)]
        case .data(let value, let metadata): return ["kind": "data", "data": Self.object(value), "metadata": Self.object(metadata)]
        }
    }
    static func object(_ value: JSONValue) -> Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])) ?? NSNull()
    }

    var attachment: ChatOrchestration.MultimodalAttachment? {
        switch self {
        case .text: return nil
        case .file(let name, let mediaType, let bytes, _):
            return .init(type: mediaType.hasPrefix("image/") ? "image" : "file", base64: bytes.base64EncodedString(),
                         mime: mediaType, name: name, byteSize: bytes.count)
        case .data(let value, _):
            let bytes = (try? JSONEncoder().encode(value)) ?? Data()
            // The ordinary text attachment extractor handles this without
            // adding a new tool or treating fields as executable instructions.
            return .init(type: "file", base64: bytes.base64EncodedString(), mime: "application/json", name: "data.txt", byteSize: bytes.count)
        }
    }

    static func output(_ attachment: ChatOrchestration.MultimodalAttachment, taskID: String) throws -> Self {
        let bytes: Data
        if !attachment.base64.isEmpty {
            guard let decoded = Data(base64Encoded: attachment.base64), decoded.count <= maximumFileBytes else { throw invalidPart }
            bytes = decoded
        } else if let path = attachment.path {
            // Only the canonical turn's produced attachments reach here, never
            // a path supplied by a peer. Open once, refuse symlinks/devices and
            // bound the read; the wire carries bytes, never this private path.
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw AgentContactFailure(code: -32603, message: "The produced file could not be read") }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximumFileBytes else { throw invalidPart }
            var collected = Data(), buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count == 0 { break }
                guard count > 0, collected.count + count <= maximumFileBytes else { throw invalidPart }
                collected.append(contentsOf: buffer.prefix(count))
            }
            bytes = collected
        } else { throw invalidPart }
        let name = attachment.name.flatMap { safeName($0) ? $0 : nil } ?? "attachment"
        return .file(name: name, mediaType: attachment.mime, bytes: bytes,
                     metadata: .object(["source": .string("agent"), "taskId": .string(taskID)]))
    }
}
