import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ScreenCaptureKit) && os(macOS)
import ScreenCaptureKit
#endif

// MARK: - Production capture source (ScreenCaptureKit)

#if canImport(CoreGraphics)
/// Select in global logical points, never display pixels: neighbouring screens
/// may have different scales, and a window's centre may sit in a desktop gap.
enum MacScreenCaptureDisplaySelection {
    static func selectedID(
        displays: [(id: UInt32, bounds: CGRect)],
        requested: MacAXFrame?,
        mainDisplayID: UInt32
    ) -> UInt32? {
        let fallback = displays.first(where: { $0.id == mainDisplayID })?.id ?? displays.first?.id
        guard let requested, requested.w > 0, requested.h > 0 else { return fallback }
        let rect = CGRect(x: requested.x, y: requested.y, width: requested.w, height: requested.h)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = displays.first(where: { $0.bounds.contains(center) }) { return hit.id }

        var best: (id: UInt32, area: CGFloat)?
        for display in displays {
            let overlap = display.bounds.intersection(rect)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let area = overlap.width * overlap.height
            if let previous = best {
                let preferredTie = display.id == mainDisplayID
                    || (previous.id != mainDisplayID && display.id < previous.id)
                guard area > previous.area || (area == previous.area && preferredTie) else { continue }
            }
            best = (display.id, area)
        }
        return best?.id ?? fallback
    }
}
#endif

#if canImport(ScreenCaptureKit) && os(macOS)

/// Live capture.
///
/// ScreenCaptureKit, not `CGWindowListCreateImage`: that call is OBSOLETED as
/// of macOS 15 and does not compile against the current SDK, so there is no
/// legacy path to fall back to.
///
/// Deliberately NOT reusing `SwiftNativeScreenVision`: that organ captures the
/// whole primary display and returns encoded PNG bytes, which is a different
/// capability from "this sub-rect, as a CGImage I still have to draw markers
/// onto". Sharing it would mean either widening its contract or re-decoding a
/// PNG to annotate it. The permission it reads is the same one.
public struct SystemMacScreenCaptureSource: MacScreenCaptureSource {
    public init() {}

    /// Read-only preflight. Never `CGRequestScreenCaptureAccess` — that shows
    /// the OS prompt, and the grant is User's, not code's, to initiate.
    public func isScreenRecordingTrusted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public func capture(rect: MacAXFrame?) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
        guard isScreenRecordingTrusted() else { return .failure(.screenRecordingNotTrusted) }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            return .failure(.captureFailed)
        }
        // Prefer the display containing the centre. If the centre lies in a
        // desktop gap, retain the largest visible portion on a real display.
        let wanted = rect
        let displays = content.displays
        guard !displays.isEmpty else { return .failure(.noDisplay) }
        let mainID = CGMainDisplayID()
        let selectedID = MacScreenCaptureDisplaySelection.selectedID(
            displays: displays.map { (id: $0.displayID, bounds: CGDisplayBounds($0.displayID)) },
            requested: wanted,
            mainDisplayID: mainID
        )
        guard let display = displays.first(where: { $0.displayID == selectedID }) else {
            return .failure(.noDisplay)
        }

        let displayBounds = CGDisplayBounds(display.displayID)
        // Global (AX) points → this display's local points. Identical for the
        // main display at the origin; not identical for any other.
        let globalRect: CGRect = {
            guard let wanted, wanted.w > 0, wanted.h > 0 else { return displayBounds }
            return CGRect(x: wanted.x, y: wanted.y, width: wanted.w, height: wanted.h)
                .intersection(displayBounds)
        }()
        guard !globalRect.isNull, globalRect.width >= 1, globalRect.height >= 1 else {
            return .failure(.captureFailed)
        }
        let localRect = CGRect(
            x: globalRect.origin.x - displayBounds.origin.x,
            y: globalRect.origin.y - displayBounds.origin.y,
            width: globalRect.width,
            height: globalRect.height
        )
        // Native pixel density of THIS display: physical pixels per point.
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let densityX = (mode?.pixelWidth).map { Double($0) / Double(max(1, display.width)) } ?? 1.0
        let densityY = (mode?.pixelHeight).map { Double($0) / Double(max(1, display.height)) } ?? 1.0
        let density = max(1.0, min(max(densityX, densityY), 4.0))

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = localRect
        configuration.width = max(1, Int((localRect.width * density).rounded()))
        configuration.height = max(1, Int((localRect.height * density).rounded()))
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            return .failure(.captureFailed)
        }
        // The SHOT reports the pixel size that came back, not the size that was
        // asked for. Everything downstream derives its scale from this, so a
        // pipeline that clamped or rounded the request cannot displace a marker.
        return .success(MacScreenShot(
            bounds: MacAXFrame(
                x: Double(globalRect.origin.x),
                y: Double(globalRect.origin.y),
                w: Double(globalRect.width),
                h: Double(globalRect.height)
            ),
            pixelWidth: image.width,
            pixelHeight: image.height,
            cgImage: image
        ))
    }
}

#endif

/// Platform fallback: honest unavailability, never a fabricated picture.
public struct UnavailableMacScreenCaptureSource: MacScreenCaptureSource {
    public init() {}
    public func isScreenRecordingTrusted() -> Bool { false }
    public func capture(rect: MacAXFrame?) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
        .failure(.unavailableOnThisPlatform)
    }
}

public func defaultMacScreenCaptureSource() -> any MacScreenCaptureSource {
    #if canImport(ScreenCaptureKit) && os(macOS)
    return SystemMacScreenCaptureSource()
    #else
    return UnavailableMacScreenCaptureSource()
    #endif
}
