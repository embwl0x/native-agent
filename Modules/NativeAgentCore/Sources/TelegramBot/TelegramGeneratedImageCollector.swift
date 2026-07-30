import Foundation
import PersistenceCore

actor TelegramGeneratedImageCollector {
    private var paths: [String] = []

    func record(_ event: TelegramChatProgressEvent) {
        guard case .toolResult(let name, let output?) = event else { return }
        guard name == "image_generate" else { return }
        for path in Self.imagePaths(from: output) {
            guard Self.isSendableGeneratedImagePath(path) else { continue }
            guard !paths.contains(path) else { continue }
            paths.append(path)
        }
    }

    func snapshot() -> [String] {
        paths
    }

    private static func imagePaths(from value: JSONValue) -> [String] {
        guard case .object(let object) = value else { return [] }
        guard case .array(let images)? = object["images"] else { return [] }
        return images.compactMap { image in
            guard case .object(let imageObject) = image,
                  case .string(let path)? = imageObject["path"] else {
                return nil
            }
            return path.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
    }

    private static func isSendableGeneratedImagePath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path.contains("/generated_images/") else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic":
            return true
        default:
            return false
        }
    }
}
