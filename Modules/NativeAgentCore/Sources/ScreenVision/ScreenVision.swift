// MARK: - SwiftNativeScreenVision
//
// v1 of NativeAgent's vision pipeline: capture the primary display as PNG
// using ScreenCaptureKit, fail-closed on permission denial or capture failure.
// No Python, no daemon HTTP fallback, no mock data — if ScreenCaptureKit
// refuses we throw a typed error so the caller can surface a real message
// in chat.
//
// The capture pipeline previously lived inline in the macOS app as a private
// `NativeScreenCapture` enum (Sources/NativeAgentApp/ContentView.swift). This
// module extracts that work into a Swift-native subsystem so it's reusable
// from NativeClient, future vision-decision loops, and tests.
//
// Out of scope for v1 (defer to v2): window-by-window capture, multi-display
// selection, streaming SCStream output. (OCR lives in MacControl and
// runs on the four-verb path; this file still does no text extraction.)

import Foundation
import NativeAgentCore
import ScreenCaptureKit
import CoreGraphics
#if canImport(AppKit)
import AppKit
// Blueprint: | `ScreenVision.swift` | Screen vision owner; NativeScreenCapture encoding and capture error mapping |
#endif

// MARK: - Errors

public enum ScreenVisionError: Error, LocalizedError {
    /// Screen Recording permission was denied or has never been granted.
    /// The OS prompt fires the first time we ask; subsequent calls preflight
    /// the existing TCC decision. Surface this to the user with instructions
    /// to enable Screen Recording in System Settings.
    case permissionDenied
    /// SCShareableContent returned no displays. Rare — would indicate the
    /// app is running with no attached display.
    case noDisplay
    /// ScreenCaptureKit accepted the request but the capture or encode step
    /// failed. The associated string is the underlying reason.
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is required for NativeAgent. Enable it in System Settings → Privacy & Security → Screen Recording, then restart NativeAgent."
        case .noDisplay:
            return "NativeAgent could not find a display to capture."
        case .captureFailed(let reason):
            return "Screen capture failed: \(reason)"
        }
    }
}

// MARK: - Public actor

/// Swift-native screen-capture surface. Single public entry point for v1:
/// `captureScreen()` returns raw PNG bytes for the primary display, or
/// throws a `ScreenVisionError` on permission / display / encoding failure.
public actor SwiftNativeScreenVision {
    public init() {}

    /// Capture the primary display as PNG-encoded `Data`. Fails closed.
    ///
    /// - Throws: `ScreenVisionError.permissionDenied` if the user has not
    ///   granted Screen Recording permission (preflight false AND the
    ///   subsequent request returns false).
    /// - Throws: `ScreenVisionError.noDisplay` if `SCShareableContent.current`
    ///   reports no displays.
    /// - Throws: `ScreenVisionError.captureFailed(_)` if ScreenCaptureKit or
    ///   the PNG encode step fails.
    public func captureScreen() async throws -> Data {
        // Preflight + request. CGRequestScreenCaptureAccess returns the
        // CURRENT state on subsequent calls (it only triggers the prompt
        // the first time), so it's safe to call here unconditionally if
        // preflight is false.
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw ScreenVisionError.permissionDenied
        }

        // Discover displays. The spec asks for the *primary* (first) display.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw ScreenVisionError.captureFailed("SCShareableContent: \(error.localizedDescription)")
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
            throw ScreenVisionError.noDisplay
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
            throw ScreenVisionError.captureFailed("SCScreenshotManager: \(error.localizedDescription)")
        }

        // Encode CGImage -> PNG via NSBitmapImageRep (AppKit, macOS-only).
        // NSBitmapImageRep is the simplest path that handles colorspace and
        // alpha correctly without us hand-rolling a CGImageDestination.
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenVisionError.captureFailed("PNG encoding failed")
        }
        return png
    }
}

public enum NativeScreenCapture {
    public enum CaptureError: LocalizedError {
        case permissionRequired
        case noDisplay
        case encodingFailed
        case tooLarge
        // ScreenVision v1 (2026-06-06): carries the underlying
        // ScreenCaptureKit reason when SwiftNativeScreenVision throws
        // .captureFailed(_). The reason goes to the log; the toast says it
        // plainly.
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
        // v1 vision pipeline (2026-06-06): the capture itself is delegated to
        // the Swift-native ScreenVision module. The size-cap / re-encode path
        // below stays here because ScreenVision returns raw PNG bytes; the
        // chat surface still wants a JPEG-with-quality-ladder fallback for
        // anything that would exceed `maxCaptureBytes`.
        //
        // ScreenVision v1 captures the primary display only. There is no
        // display-selection argument here because accepting one we cannot
        // honor would silently send the wrong screen on a multi-display Mac.

        let png: Data
        do {
            png = try await SwiftNativeScreenVision().captureScreen()
        } catch let e as ScreenVisionError {
            // Map the ScreenVision error surface back onto the existing
            // CaptureError cases. The underlying ScreenCaptureKit reason is
            // logged here rather than shown in the toast.
            switch e {
            case .permissionDenied:
                throw CaptureError.permissionRequired
            case .noDisplay:
                throw CaptureError.noDisplay
            case .captureFailed(let reason):
                ModuleLog.app("%@", "[screen-capture] failed: \(reason)")
                throw CaptureError.captureFailed(reason)
            }
        }

        // Decode the PNG back into a CGImage so the existing encodeForChat
        // ladder (JPEG quality fallbacks, then PNG, then tooLarge) can run
        // unchanged.
        guard let provider = CGDataProvider(data: png as CFData),
              let cg = CGImage(
                pngDataProviderSource: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw CaptureError.encodingFailed
        }
        let encoded = try encodeForChat(cg)
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
