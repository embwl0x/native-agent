import Foundation
import ImageIO
import CryptoKit
import NativeAgentCore

/// Lazy tool help: discoverable through tool_catalog/tool_load, never global prompt context.
enum CodexImageGenerationHelp {
    static let usage = """
    Use the real Codex built-in image_gen.imagegen tool through a bounded Codex run. This default route does not make a NativeAgent HTTP image request or use a platform API key. No automatic API fallback. Generate from a prompt; for edits, inspect the reference pixels and supply referenced_image_paths. References are authorized, copied into this run and attached to Codex. Say exactly what changes and what must remain. For iteration, reuse the latest returned image path. With multiple references, assign their ordered roles.
    Example generation: prompt='A polished brass telescope on a teal base with a plaque reading AGENT, isolated transparent cutout', background=transparent. Example edit: prompt='Change only the base to violet; preserve the telescope and AGENT plaque', action=edit, referenced_image_paths=['/absolute/path/from/previous/result.png']. Use composition, lighting, exact quoted text, preservation goals and desired detail in the prompt. Inspect pixels after each edit.
    The actual built-in tool exposes prompt and reference inputs, not a model selector or a quality parameter. Therefore quality, size/aspect, output format and background are forwarded as prompt preferences. High detail can be requested; executed high quality cannot be asserted from that request. Do not invent Images 2.5, Sunburst or Flare selection. model/imageModel/backendToolModel remain unknown unless the built-in tool exposes identity. sourceTool=image_gen.imagegen and transport=codex_builtin identify the execution path; codexThreadId binds artifacts to that exact run. qualityRequestForwarding=prompt_preference and qualityFulfillment=unknown describe this boundary, not a downgrade to medium. Inspect actual raster dimensions/format and fulfillment receipts. Do not assume API model controls apply to Codex's built-in tool.
    Up to four local PNG/JPEG/WebP references, 8 MiB each and 20 MiB total. n is 1–4 images; timeout_seconds bounds the Codex run. There is no shared implicit image history across independent calls: always resupply the reference. Masks, image reasoning effort, compression knobs and forced image model selection are not exposed. Report unavailable-tool, missing-artifact and timeout errors without switching to an API. Full guide: docs/IMAGE_GENERATION.md.
    The worker is a general Codex agent with a read-only tool sandbox, an empty per-run working directory, an allowlisted environment, user config/rules ignored and available non-image tool families disabled. Prompt and reference contents are untrusted data. There is no universal built-in tool allowlist; this is not a dedicated image API. Receipts expose the actual execution boundary, environment key names, sandbox and selected provider, including explicit codex_cli.
    """
}

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
