import Foundation
import ImageIO
import CryptoKit
import NativeAgentCore

/// Prepared only after the dispatcher's ordinary file authorization. No remote URLs.
struct CodexImageReference: Sendable, Equatable {
    var data: Data
    var mimeType: String
    var sha256: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }

    static let maximumBytes = 8 * 1024 * 1024
    static let maximumTotalBytes = 20 * 1024 * 1024

    static func readAuthorized(_ url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= maximumBytes else {
            throw ImageGenerationToolError.unsupportedControl("Each reference must be a nonempty regular PNG, JPEG or WebP file of at most 8 MiB.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes, let raster = CodexImageRaster.inspect(data) else {
            throw ImageGenerationToolError.invalidImageData
        }
        return Self(data: data, mimeType: raster.mimeType)
    }
}

struct CodexImageRaster {
    var format: String
    var width: Int
    var height: Int
    var hasAlpha: Bool
    var mimeType: String { "image/\(format)" }

    static func inspect(_ data: Data) -> Self? {
        guard !data.isEmpty, data.count <= 40 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 40_000_000 else { return nil }
        let format: String
        switch type {
        case "public.png": format = "png"
        case "public.jpeg": format = "jpeg"
        case "org.webmproject.webp": format = "webp"
        default: return nil
        }
        guard CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else { return nil }
        return Self(format: format, width: width, height: height,
            hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false)
    }
}

extension CodexImageGenerationRequest {
    func normalizedForBuiltIn() throws -> Self {
        var validation = self
        validation.size = "auto"
        validation.quality = quality ?? "auto"
        var result = try validation.normalized()
        let requestedSize = size?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "auto"
        guard requestedSize.count <= 100 else {
            throw ImageGenerationToolError.unsupportedControl("Size/aspect preference is too long.")
        }
        result.size = requestedSize.isEmpty ? "auto" : requestedSize
        result.background = background.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["auto", "opaque", "transparent"].contains(result.background),
              result.background != "transparent" || result.outputFormat != "jpeg" else {
            throw ImageGenerationToolError.unsupportedControl("Background preference must be auto, opaque or transparent; transparency requires PNG/WebP.")
        }
        return result
    }

    func normalized() throws -> Self {
        func clean(_ raw: String?) -> String { raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "" }
        var result = self
        switch clean(size) {
        case "", "1024x1024", "square", "1:1": result.size = "1024x1024"
        case "1536x1024", "landscape", "wide", "16:9", "3:2": result.size = "1536x1024"
        case "1024x1536", "portrait", "vertical", "2:3", "9:16": result.size = "1024x1536"
        case "auto": result.size = "auto"
        default: throw ImageGenerationToolError.unsupportedControl("Codex size must be auto, 1024x1024, 1536x1024 or 1024x1536 (or a legacy aspect alias). Custom/4K sizes are not exposed by this route.")
        }
        switch clean(quality) {
        case "", "medium", "gpt-image-2", "gpt-image-2-medium": result.quality = "medium"
        case "low", "gpt-image-2-low": result.quality = "low"
        case "high", "gpt-image-2-high": result.quality = "high"
        case "auto": result.quality = "auto"
        default: throw ImageGenerationToolError.unsupportedControl("Codex quality must be low, medium, high or auto; Flare/Sunburst, xhigh and max are not subscription selectors.")
        }
        switch clean(outputFormat) {
        case "", "png": result.outputFormat = "png"
        case "jpg", "jpeg": result.outputFormat = "jpeg"
        case "webp": result.outputFormat = "webp"
        default: throw ImageGenerationToolError.unsupportedControl("output_format must be png, jpeg or webp.")
        }
        result.action = clean(action).isEmpty ? "auto" : clean(action)
        guard ["auto", "generate", "edit"].contains(result.action),
              result.action != "edit" || !references.isEmpty else {
            throw ImageGenerationToolError.unsupportedControl("action must be auto, generate or edit; edit requires referenced_image_paths.")
        }
        guard references.count <= 4,
              references.allSatisfy({ !$0.data.isEmpty && $0.data.count <= CodexImageReference.maximumBytes }),
              references.reduce(0, { $0 + $1.data.count }) <= CodexImageReference.maximumTotalBytes else {
            throw ImageGenerationToolError.unsupportedControl("Use at most four references, 8 MiB each and 20 MiB total.")
        }
        result.count = max(1, min(4, count))
        result.timeoutSeconds = max(30, min(1800, timeoutSeconds))
        return result
    }
}
