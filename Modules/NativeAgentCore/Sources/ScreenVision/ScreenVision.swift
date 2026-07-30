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
// selection, streaming SCStream output, OCR / text extraction.

import Foundation
import ScreenCaptureKit
import CoreGraphics
#if canImport(AppKit)
import AppKit
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
        guard ScreenVisionPermissions.requestAccess() else {
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
        let filter = SCContentFilter(display: display, excludingWindows: [])
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

    /// Returns one of: `"granted"`, `"denied"`, or `"not_determined"`.
    ///
    /// macOS Screen Recording is a single boolean in TCC (granted / not),
    /// not a tri-state like camera/mic. We map preflight true → `"granted"`
    /// and preflight false → `"denied"`. The `"not_determined"` arm is kept
    /// in the API shape for future cross-platform parity but is never
    /// returned on the current Mac runtime.
    nonisolated public func permissionStatus() -> String {
        return ScreenVisionPermissions.isAuthorized() ? "granted" : "denied"
    }

    /// Trigger the OS Screen Recording prompt if needed. Returns true iff
    /// permission is granted after the call returns.
    ///
    /// `CGRequestScreenCaptureAccess` fires the system prompt on first call
    /// and returns the current decision on subsequent calls.
    public func requestPermission() async -> Bool {
        return ScreenVisionPermissions.requestAccess()
    }
}
