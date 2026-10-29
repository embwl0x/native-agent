import Foundation
import NativeAgentShared
import NativeAgentCore
import ScreenCaptureKit
import CoreGraphics
#if canImport(AppKit)
import AppKit
// Blueprint: | `ScreenVision.swift` | Screen vision owner; NativeScreenCapture encoding and capture error mapping |
#endif

public enum NativeScreenCapture {
    private static func captureScreen() async throws -> CGImage {
        // Preflight + request. CGRequestScreenCaptureAccess returns the
        // CURRENT state on subsequent calls (it only triggers the prompt
        // the first time), so it's safe to call here unconditionally if
        // preflight is false.
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.permissionRequired
        }

        // Discover displays. The spec asks for the *primary* (first) display.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            let reason = "SCShareableContent: \(error.localizedDescription)"
            ModuleLog.app("%@", "[screen-capture] failed: \(reason)")
            throw CaptureError.captureFailed(reason)
        }
        // Select the PRIMARY display strictly by CGMainDisplayID match —
        // ScreenCaptureKit's display order is not guaranteed to put the
        // primary first, especially in multi-monitor setups. If
        // CGMainDisplayID() is not present in SCShareableContent (extremely
        // unusual — would indicate a TCC/CG state mismatch), fail-closed
        // with .noDisplay rather than silently capturing whatever display
        // happens to be first in the list.
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) else {
            throw CaptureError.noDisplay
        }

        // Configure a one-shot screenshot. `pixelFormat` is set for parity
        // with the spec; SCScreenshotManager returns a CGImage regardless of
        // pixel-format hint (the hint matters for live SCStream feeds).
        // Shotgun is the person's window; it never shows in her captures.
        let filter = SCContentFilter(
            display: display,
            excludingWindows: content.windows.filter { PersonOnlyWindows.contains(number: Int($0.windowID)) }
        )
        let configuration = SCStreamConfiguration()
        // SCDisplay.width/height are POINTS. Configuring the output size in
        // points downsamples Retina displays to 1x; use the display mode's
        // physical pixel dimensions so the capture is native-resolution.
        // Consumers that need smaller transports (chat's 1600px ladder)
        // downscale on their side.
        let mode = CGDisplayCopyDisplayMode(mainID)
        configuration.width = mode?.pixelWidth ?? display.width
        configuration.height = mode?.pixelHeight ?? display.height
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            let reason = "SCScreenshotManager: \(error.localizedDescription)"
            ModuleLog.app("%@", "[screen-capture] failed: \(reason)")
            throw CaptureError.captureFailed(reason)
        }

        return image
    }
    public enum CaptureError: LocalizedError {
        case permissionRequired
        case noDisplay
        case encodingFailed
        case tooLarge
        // The underlying capture reason is logged; chat receives a short message.
        case captureFailed(String)

        public var errorDescription: String? {
            switch self {
            case .permissionRequired:
                return "Screen Recording permission is required for NativeAgent. Enable it in System Settings, then restart NativeAgent if macOS asks."
            case .noDisplay:
                return "NativeAgent could not find a display to capture."
            case .encodingFailed:
                return "NativeAgent captured the screen but could not encode it as an image."
            case .tooLarge:
                return "NativeAgent captured the screen, but the image was too large to send."
            case .captureFailed:
                return "NativeAgent couldn't capture the screen. Try again in a moment."
            }
        }
    }

    public static let maxCaptureDimension = 1600
    public static let maxCaptureBytes = 6 * 1024 * 1024

    public static func captureImageBase64() async throws -> (base64: String, mime: String, name: String, byteSize: Int) {
        let image = try await captureScreen()
        let encoded = try encodeForChat(image)
        return (
            encoded.data.base64EncodedString(),
            encoded.mime,
            encoded.name,
            encoded.data.count
        )
    }

    public static func encodeForChat(_ source: CGImage) throws -> (data: Data, mime: String, name: String) {
        let image = resizedForChat(source)
        let bitmap = NSBitmapImageRep(cgImage: image)
        return try fittingEncodedPayload(
            maxBytes: maxCaptureBytes,
            jpegData: { quality in
                bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
            },
            pngData: { bitmap.representation(using: .png, properties: [:]) }
        )
    }

    public static func fittingEncodedPayload(
        maxBytes: Int,
        jpegData: (Double) -> Data?,
        pngData: () -> Data?
    ) throws -> (data: Data, mime: String, name: String) {
        for quality in [0.78, 0.65, 0.52, 0.40] {
            if let jpeg = jpegData(quality), jpeg.count <= maxBytes {
                return (jpeg, "image/jpeg", "screen.jpg")
            }
        }
        if let png = pngData(), png.count <= maxBytes {
            return (png, "image/png", "screen.png")
        }
        throw CaptureError.tooLarge
    }

    public static func resizedForChat(_ source: CGImage) -> CGImage {
        let width = source.width
        let height = source.height
        let largest = max(width, height)
        guard largest > maxCaptureDimension else { return source }
        let scale = CGFloat(maxCaptureDimension) / CGFloat(largest)
        let targetWidth = max(1, Int(CGFloat(width) * scale))
        let targetHeight = max(1, Int(CGFloat(height) * scale))
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return source
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? source
    }

}
