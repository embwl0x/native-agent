import Foundation
import NativeAgentCore
import NativeAgentShared

enum MacScreenCaptureWindowSelection {
    static func selectedID(
        windows: [(id: UInt32, pid: Int32, frame: MacAXFrame)],
        requested: MacAXWindowIdentity
    ) -> UInt32? {
        guard let frame = requested.frame, frame.w > 0, frame.h > 0,
              [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite) else { return nil }
        let matches = windows.filter { window in
            window.pid == requested.pid
                && MacAXWindowIdentity.rectsMatch(window.frame, frame)
        }
        return matches.count == 1 ? matches[0].id : nil
    }
}
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(ScreenCaptureKit) && os(macOS)
import ScreenCaptureKit
// Blueprint: | `MacScreenViewCapture.swift` | Window/display capture selection, `SystemMacVisualObstructionProbe` (other apps' windows over a frame, for sight and a watch's hands) and `SystemMacScreenCaptureSource`; exactly-once callback cancellation invalidates results and resumes immediately, with no cancellation-ignoring join on an unabortable ScreenCaptureKit callback |
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

/// One window-server stacking read (Shotgun and her pointer left out: her
/// hand passes through them): what another app's window over a frame covers.
/// The four verbs' sight and a watch's hands share it.
struct MacVisualWindowRecord: Sendable, Equatable {
    let number: Int
    let ownerPID: Int32
    let ownerName: String
    let layer: Int
    let frame: MacAXFrame
    let alpha: Double
}

public struct MacVisualObstruction: Sendable, Equatable {
    public let ownerPID: Int32
    public let ownerName: String
    public let coverage: Double
    public let frame: MacAXFrame

    public func covers(_ other: MacAXFrame) -> Bool {
        min(frame.x + frame.w, other.x + other.w) > max(frame.x, other.x)
            && min(frame.y + frame.h, other.y + other.h) > max(frame.y, other.y)
    }
}

public struct SystemMacVisualObstructionProbe: Sendable {
    public init() {}

    /// What a pointer at the target's centre would land on is the one real
    /// test of cover. The window server's stacking list alone is not: it
    /// carries windows that pass input through (loginwindow's full-screen
    /// backings sit in front of everything, at layers 2001 and 2004, on an
    /// unlocked Mac), so every act would read as obstructed by them.
    public func obstructions(over frame: MacAXFrame, targetPID: Int32) -> [MacVisualObstruction] {
        let windows = Self.windows()
        let listed = Self.obstructions(in: windows, over: frame, targetPID: targetPID)
        guard let hit = Self.hitPID(x: frame.x + frame.w / 2, y: frame.y + frame.h / 2) else { return listed }
        if hit == targetPID { return [] }
        if !listed.isEmpty { return listed }
        #if canImport(AppKit)
        let name = NSRunningApplication(processIdentifier: hit)?.localizedName ?? "another app"
        #else
        let name = "another app"
        #endif
        return [MacVisualObstruction(ownerPID: hit, ownerName: name, coverage: 1, frame: frame)]
    }

    /// The process owning the accessibility element under a screen point;
    /// nil when accessibility cannot answer (no permission, nothing there).
    /// A system-wide hit can land in this process (the point is over her own
    /// window); AppKit then walks her SwiftUI accessibility tree on the calling
    /// thread, which is main-thread work, so the hit runs on the AX main lane
    /// (10-28 23:52: a sight over her own window from a tool's task trapped).
    static func hitPID(x: Double, y: Double) -> Int32? {
        #if canImport(ApplicationServices)
        MacAXExecutionLane.sync {
            var element: AXUIElement?
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(x), Float(y), &element) == .success,
                  let element else { return nil }
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
            return pid
        }
        #else
        return nil
        #endif
    }

    /// The window a pointer at (x, y) lands on: the topmost there that would
    /// cover anything.
    static func topmost(in windows: [MacVisualWindowRecord], x: Double, y: Double) -> MacVisualWindowRecord? {
        windows.first { covers($0) && x >= $0.frame.x && x < $0.frame.x + $0.frame.w && y >= $0.frame.y && y < $0.frame.y + $0.frame.h }
    }

    /// Visible windows above the desktop can take input. Owner names and
    /// display-sized geometry do not establish that input passes through;
    /// known person-only pass-through windows are excluded by `windows()`.
    private static func covers(_ window: MacVisualWindowRecord) -> Bool {
        window.alpha > 0.05 && window.layer >= 0
    }

    /// On-screen windows, front to back.
    static func windows() -> [MacVisualWindowRecord] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return raw.compactMap { value -> MacVisualWindowRecord? in
            // Her clicks pass through Shotgun, so it covers nothing of hers.
            guard let number = value[kCGWindowNumber as String] as? Int,
                  !PersonOnlyWindows.contains(number: number),
                  let pid = value[kCGWindowOwnerPID as String] as? Int,
                  let layer = value[kCGWindowLayer as String] as? Int,
                  let bounds = value[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return MacVisualWindowRecord(
                number: number,
                ownerPID: Int32(pid),
                ownerName: value[kCGWindowOwnerName as String] as? String ?? "another app",
                layer: layer,
                frame: MacAXFrame(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height),
                alpha: value[kCGWindowAlpha as String] as? Double ?? 1
            )
        }
    }

    static func obstructions(
        in windows: [MacVisualWindowRecord],
        over frame: MacAXFrame,
        targetPID: Int32
    ) -> [MacVisualObstruction] {
        let frameArea = frame.w * frame.h
        guard frameArea > 0,
              let targetIndex = windows.indices.first(where: { index in
                  let window = windows[index]
                  return window.ownerPID == targetPID
                      && intersectionArea(window.frame, frame) / frameArea >= 0.5
              }) else { return [] }
        return windows[..<targetIndex].compactMap { window -> MacVisualObstruction? in
            guard covers(window) else { return nil }
            let coverage = intersectionArea(window.frame, frame) / frameArea
            // A small dialog can completely cover a small target. Screen-area
            // thresholds hid real obstructions on large displays. Preserve
            // exact overlap geometry, including same-app floating windows.
            guard coverage > 0 else { return nil }
            return MacVisualObstruction(ownerPID: window.ownerPID, ownerName: window.ownerName, coverage: coverage, frame: window.frame)
        }
    }

    private static func intersectionArea(_ lhs: MacAXFrame, _ rhs: MacAXFrame) -> Double {
        let width = max(0, min(lhs.x + lhs.w, rhs.x + rhs.w) - max(lhs.x, rhs.x))
        let height = max(0, min(lhs.y + lhs.h, rhs.y + rhs.h) - max(lhs.y, rhs.y))
        return width * height
    }
}
#endif

#if canImport(ScreenCaptureKit) && os(macOS)

/// SCScreenshotManager and SCShareableContent have no cancel/stop handle in
/// ScreenCaptureKit. Invalidate the result on cancellation, resume the caller
/// exactly once. A late callback can only consume its immutable OS value;
/// it has no continuation or authority to mutate the cancelled growth job.
// ScreenCaptureKit's immutable content snapshot is not annotated Sendable in
// the SDK. Transfer it only through this callback-owned, immutable envelope.
struct MacScreenCaptureValue<Value>: @unchecked Sendable {
    let value: Value
}

func macScreenCaptureWait<Value>(
    issue: (@escaping @Sendable (Value?, Error?) -> Void) -> Void
) async throws -> Value {
    try Task.checkCancellation()
    let request = ContinuationOnce<Result<MacScreenCaptureValue<Value>, Error>>()
    let result = await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            if request.install(continuation) {
                issue { value, error in
                    if let error { request.resume(.failure(error)) }
                    else if let value { request.resume(.success(MacScreenCaptureValue(value: value))) }
                    else { request.resume(.failure(CocoaError(.coderValueNotFound))) }
                }
            }
        }
    } onCancel: {
        request.resume(.failure(CancellationError()))
    }
    try Task.checkCancellation()
    return try result.get().value
}

/// Live capture.
///
/// Captures window sub-rects for annotation through ScreenCaptureKit.
/// NativeScreenCapture owns whole-primary-display chat attachments;
/// this source retains window identity and reads the same permission.
public struct SystemMacScreenCaptureSource: MacScreenCaptureSource {
    public init() {}

    /// Read-only preflight. Never `CGRequestScreenCaptureAccess` — that shows
    /// the OS prompt, and the grant is User's, not code's, to initiate.
    public func isScreenRecordingTrusted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private static func windowImage(_ window: SCWindow, maxPixelWidth: Int? = nil) async throws -> MacScreenShot {
        try Task.checkCancellation()
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let rect = filter.contentRect
        var scale = max(1, min(Double(filter.pointPixelScale), 4))
        if let maxPixelWidth { scale = min(scale, Double(max(1, maxPixelWidth)) / max(1, rect.width)) }
        configuration.width = max(1, Int((rect.width * scale).rounded()))
        configuration.height = max(1, Int((rect.height * scale).rounded()))
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let image: CGImage = try await macScreenCaptureWait { receive in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration, completionHandler: receive)
        }
        try Task.checkCancellation()
        return MacScreenShot(bounds: MacAXFrame(
            x: window.frame.minX, y: window.frame.minY, w: window.frame.width, h: window.frame.height),
            pixelWidth: image.width, pixelHeight: image.height, cgImage: image)
    }

    public func capture(window requested: MacAXWindowIdentity) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
        guard isScreenRecordingTrusted() else { return .failure(.screenRecordingNotTrusted) }
        var operation = "SCShareableContent.getExcludingDesktopWindows"
        do {
            try Task.checkCancellation()
            let content: SCShareableContent = try await macScreenCaptureWait { receive in
                SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true, completionHandler: receive)
            }
            try Task.checkCancellation()
            // Person-only windows cannot be captured.
            let windows = content.windows.filter { !PersonOnlyWindows.contains(number: Int($0.windowID)) }
            let selected = MacScreenCaptureWindowSelection.selectedID(windows: windows.compactMap { window in
                guard let owner = window.owningApplication else { return nil }
                return (window.windowID, owner.processID, MacAXFrame(
                    x: window.frame.minX, y: window.frame.minY,
                    w: window.frame.width, h: window.frame.height))
            }, requested: requested)
            guard let selected, let window = windows.first(where: { $0.windowID == selected }) else {
                return .failure(.operationFailed("window selection", "The requested window is absent, ambiguous, or person-only; read the app again for its current window."))
            }
            operation = "SCScreenshotManager.captureImage"
            return .success(try await Self.windowImage(window))
        } catch {
            return .failure(.operationFailed(operation, error.localizedDescription))
        }
    }

    public func windowCapture() async -> MacScreenWindowCapture {
        guard isScreenRecordingTrusted() else { return { _, _ in .failure(.screenRecordingNotTrusted) } }
        let content: MacScreenCaptureValue<SCShareableContent>
        do {
            content = MacScreenCaptureValue(value: try await macScreenCaptureWait { receive in
                SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true, completionHandler: receive)
            })
        } catch {
            let failure = MacScreenCaptureFailure.operationFailed("SCShareableContent.getExcludingDesktopWindows", error.localizedDescription)
            return { _, _ in .failure(failure) }
        }
        return { windowNumber, maxPixelWidth in
            do {
                try Task.checkCancellation()
                guard let window = content.value.windows.first(where: { Int($0.windowID) == windowNumber }),
                      !PersonOnlyWindows.contains(number: windowNumber) else {
                    return .failure(.operationFailed("window selection", "The requested window is absent or person-only; read the app again for its current window."))
                }
                return .success(try await Self.windowImage(window, maxPixelWidth: maxPixelWidth))
            } catch {
                return .failure(.operationFailed("SCScreenshotManager.captureImage", error.localizedDescription))
            }
        }
    }

    public func capture(rect: MacAXFrame?) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
        guard isScreenRecordingTrusted() else { return .failure(.screenRecordingNotTrusted) }
        let content: SCShareableContent
        do {
            content = try await macScreenCaptureWait { receive in
                SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true, completionHandler: receive)
            }
        } catch {
            return .failure(.operationFailed("SCShareableContent.getExcludingDesktopWindows", error.localizedDescription))
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
            return .failure(.operationFailed("display region selection", "The requested region does not intersect the selected display."))
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

        // Shotgun stays out of her pictures; she sees what is under it.
        let filter = SCContentFilter(
            display: display,
            excludingWindows: content.windows.filter { PersonOnlyWindows.contains(number: Int($0.windowID)) }
        )
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = localRect
        configuration.width = max(1, Int((localRect.width * density).rounded()))
        configuration.height = max(1, Int((localRect.height * density).rounded()))
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let image: CGImage
        do {
            image = try await macScreenCaptureWait { receive in
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration, completionHandler: receive)
            }
        } catch {
            return .failure(.operationFailed("SCScreenshotManager.captureImage", error.localizedDescription))
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
