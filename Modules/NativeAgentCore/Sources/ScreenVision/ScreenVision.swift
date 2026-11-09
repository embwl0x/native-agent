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
        // CGRequestScreenCaptureAccess returns current access after its first prompt, so a failed preflight can safely request it.
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.permissionRequired
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            let reason = "SCShareableContent: \(error.localizedDescription)"
            ModuleLog.app("%@", "[screen-capture] failed: \(reason)")
            throw CaptureError.captureFailed(reason)
        }
        // ScreenCaptureKit display order is unspecified; match CGMainDisplayID and refuse a missing primary rather than capture another screen.
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) else {
            throw CaptureError.noDisplay
        }

        // The pixel-format hint affects live streams; SCScreenshotManager returns a CGImage regardless. Shotgun is the person's window; it never shows in the
        // agent's captures.
        let filter = SCContentFilter(
            display: display,
            excludingWindows: content.windows.filter {
                PersonOnlyWindows.isOwnProcess($0.owningApplication?.processID) || PersonOnlyWindows.contains(number: Int($0.windowID))
            }
        )
        let configuration = SCStreamConfiguration()
        // SCDisplay dimensions are points; physical mode dimensions preserve Retina resolution. Transport consumers downscale as needed.
        guard let mode = CGDisplayCopyDisplayMode(mainID), mode.pixelWidth > 0, mode.pixelHeight > 0 else {
            throw CaptureError.geometryUnavailable
        }
        configuration.width = mode.pixelWidth
        configuration.height = mode.pixelHeight
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

        guard image.width == configuration.width, image.height == configuration.height else {
            throw CaptureError.geometryUnavailable
        }
        return image
    }
    public enum CaptureError: LocalizedError {
        case permissionRequired
        case noDisplay
        case geometryUnavailable
        case resizeFailed
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
            case .geometryUnavailable:
                return "NativeAgent could not establish the screen's physical pixel dimensions."
            case .resizeFailed:
                return "NativeAgent captured the screen but could not resize it for chat."
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
        let image = try resizedForChat(source)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.78]),
              !data.isEmpty else { throw CaptureError.encodingFailed }
        guard data.count <= maxCaptureBytes else { throw CaptureError.tooLarge }
        return (data, "image/jpeg", "screen.jpg")
    }

    private static func resizedForChat(_ source: CGImage) throws -> CGImage {
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
            throw CaptureError.resizeFailed
        }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let image = context.makeImage() else { throw CaptureError.resizeFailed }
        return image
    }

}
