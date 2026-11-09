import Foundation
import NativeAgentCore
import NativeAgentShared
#if canImport(CryptoKit)
import CryptoKit
#endif

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
// Blueprint: | `MacScreenViewCapture.swift` | `SystemMacVisualObstructionProbe`, `SystemMacScreenCaptureSource`: Exact capture, hit evidence and cancellation |
#endif

// MARK: - Production capture source (ScreenCaptureKit)

#if canImport(CoreGraphics)
/// Select in logical points because adjacent displays may differ in scale or leave a gap under the window centre.
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

/// Sight and watch hands share one stacking read; exclude agent overlays because input passes through them.
struct MacVisualWindowRecord: Sendable, Equatable {
    let number: Int
    let ownerPID: Int32
    let ownerName: String
    let layer: Int
    let frame: MacAXFrame
    let alpha: Double
}

extension MacImageCapture {
    init(windows: [MacVisualWindowRecord], capturedAt: Date = Date()) {
        self.init(capturedAt: capturedAt, windows: windows.map { window in
            Window(number: window.number, pid: window.ownerPID, layer: window.layer, alpha: window.alpha,
                   x: window.frame.x, y: window.frame.y, w: window.frame.w, h: window.frame.h)
        }, targets: nil)
    }

    /// Use the complete AX walk for regions and hit-test identity for ownership; never put field values or raw captions in image metadata.
    public static func pointTargets(nodes: [MacAXNode], pid: Int32, deadline: Date,
                                    source: any MacAXActSource, context: MacOperationContext) -> [PointTarget] {
        // Cap hit reads at 750 ms and a quarter of the remaining read budget so post-capture secret inspection still has time.
        let hitDeadline = min(deadline, Date().addingTimeInterval(min(0.75, max(0, deadline.timeIntervalSinceNow / 4))))
        return context.holding(\.readDeadline, hitDeadline) { context in
            var seen = Set<MacAXFrame>()
            var hits: [MacAXFrame: MacAXActTarget] = [:]
            // Name-bearing inner controls earn the bounded hit reads first.
            let ordered = nodes.sorted {
                let lhs = $0.attributes.title?.isEmpty == false, rhs = $1.attributes.title?.isEmpty == false
                if lhs != rhs { return lhs }
                return ($0.attributes.frame.map { $0.w * $0.h } ?? .infinity)
                    < ($1.attributes.frame.map { $0.w * $0.h } ?? .infinity)
            }
            return ordered.compactMap { node in
                guard let frame = node.attributes.frame, frame.w > 0, frame.h > 0,
                      [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite) else { return nil }
                let x = frame.x + frame.w / 2, y = frame.y + frame.h / 2
                if seen.insert(frame).inserted, node.attributes.title?.isEmpty == false
                    && Date() < hitDeadline && !Task.isCancelled
                    && SystemMacVisualObstructionProbe.hitPID(x: x, y: y) == pid {
                    hits[frame] = source.elementAtPosition(x: x, y: y, pid: pid, context: context)
                }
                let hit = hits[frame]
                // A centre that hits a child cannot vouch for its entire parent.
                let verified = hit?.frame == frame && hit?.role == node.attributes.role
                    && hit?.title == node.attributes.title ? hit : nil
                return PointTarget(pid: pid, role: verified?.role,
                    labelDigest: labelDigest(verified?.title),
                    x: frame.x, y: frame.y, w: frame.w, h: frame.h, path: node.path)
            }
        }
    }

    private static func labelDigest(_ label: String?) -> String? {
        #if canImport(CryptoKit)
        guard let label, !label.isEmpty else { return nil }
        return SHA256.hash(data: Data(label.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    /// Point revalidation requires the captured window and any captured control’s role, label and frame to agree.
    func refusal(at point: MacPointerPosition, now: Date, context: MacOperationContext) -> (code: String, reason: String)? {
        let age = now.timeIntervalSince(capturedAt)
        guard age >= 0, age <= MacLookFrameStore.ttlSeconds, !windows.isEmpty else {
            return (MacLookFrameStore.ResolveFailure.staleFrame.rawValue, "The image has no current capture evidence; look again with pixels:true.")
        }
        let captured = windows.map { window in
            MacVisualWindowRecord(number: window.number, ownerPID: window.pid, ownerName: "",
                                  layer: window.layer, frame: window.frame, alpha: window.alpha)
        }
        guard let expected = SystemMacVisualObstructionProbe.topmost(in: captured, x: point.x, y: point.y),
              let hitPID = SystemMacVisualObstructionProbe.hitPID(x: point.x, y: point.y) else {
            return (MacLookFrameStore.ResolveFailure.staleFrame.rawValue,
                "The image's window cannot be established at that point; look again with pixels:true.")
        }
        let live = SystemMacVisualObstructionProbe.windows()
        // AX input ownership corrects input-transparent window backings through the shared obstruction rule.
        guard let current = SystemMacVisualObstructionProbe.topmost(in: live.filter { $0.ownerPID == hitPID }, x: point.x, y: point.y) else {
            return (MacLookFrameStore.ResolveFailure.staleFrame.rawValue, "The current input window cannot be established; look again with pixels:true.")
        }
        guard current.number == expected.number, current.ownerPID == expected.ownerPID,
              current.frame == expected.frame else {
            return ("window_drifted", "The captured window moved, resized, was replaced or is covered at that point; look again with pixels:true.")
        }
        // Resolve within the captured top owner only; masked or unavailable inner regions cannot borrow another layer’s control identity.
        let regions = (targets ?? []).filter {
            $0.pid == expected.ownerPID && $0.windowNumber == expected.number && point.isInside($0.frame)
        }
        // Canvases and games may lack named controls; checked window identity still permits pixel pointing.
        guard let area = regions.map({ $0.w * $0.h }).min() else { return nil }
        let narrowest = regions.filter { $0.w * $0.h == area }
        guard let target = narrowest.first, let role = target.role, let label = target.labelDigest else { return nil }
        guard narrowest.allSatisfy({ $0 == target }), regions.allSatisfy({ target.path.starts(with: $0.path) }) else {
            return (MacLookFrameStore.ResolveFailure.staleFrame.rawValue,
                "The captured control identity is ambiguous at that point; look again with pixels:true.")
        }
        guard let hit = defaultMacAXActSource().elementAtPosition(x: point.x, y: point.y, pid: hitPID, context: context) else {
            return (MacLookFrameStore.ResolveFailure.staleFrame.rawValue, "The control under the image point cannot be read; look again with pixels:true.")
        }
        guard hit.role == role, Self.labelDigest(hit.title) == label, hit.frame == target.frame else {
            return (MacLookFrameStore.ResolveFailure.staleFrame.rawValue, "The control under the image point changed; look again with pixels:true.")
        }
        return nil
    }
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

    /// Hit-test the target centre for actual input ownership; stacking alone includes input-transparent loginwindow backings.
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

    /// System-wide hits share the dedicated AX thread, leaving this app's window free to answer Accessibility.
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

    /// Only input-owning windows can obstruct a pointer target.
    static func topmost(in windows: [MacVisualWindowRecord], x: Double, y: Double) -> MacVisualWindowRecord? {
        windows.first { covers($0) && x >= $0.frame.x && x < $0.frame.x + $0.frame.w && y >= $0.frame.y && y < $0.frame.y + $0.frame.h }
    }

    /// Names and display-sized geometry cannot prove pass-through; exclude only known person-only windows.
    private static func covers(_ window: MacVisualWindowRecord) -> Bool {
        window.alpha > 0.05 && window.layer >= 0
    }

    static func windows() -> [MacVisualWindowRecord] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return raw.compactMap { value -> MacVisualWindowRecord? in
            // Input passes through the pointer overlay, so it is not an obstruction.
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
            // Keep exact overlap including same-app floating windows; even small dialogs can fully cover a target.
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

/// ScreenCaptureKit offers no cancellation handle: invalidate delivery and resume once, leaving late callbacks no mutation authority. Transfer its unannotated
/// immutable snapshot only through the callback-owned envelope.
struct MacScreenCaptureValue<Value>: @unchecked Sendable {
    let value: Value
}

func macScreenCaptureWait<Value>(
    context: MacOperationContext, issue: (@escaping @Sendable (Value?, Error?) -> Void) -> Void) async throws -> Value {
    try Task.checkCancellation()
    let request = ContinuationOnce<Result<MacScreenCaptureValue<Value>, Error>>()
    issue { value, error in
        if let error { request.resume(.failure(error)) }
        else if let value { request.resume(.success(MacScreenCaptureValue(value: value))) }
        else { request.resume(.failure(CocoaError(.coderValueNotFound))) }
    }
    let result = await request.wait(budget: context.waitBudget, cancellingWith: .failure(context.cancellationError))
    try Task.checkCancellation()
    return try result.get().value
}

/// Window capture retains exact identity; whole-display chat attachments have a separate capture owner with the same permission.
public struct SystemMacScreenCaptureSource: MacScreenCaptureSource {
    public init() {}

    /// Preflight never prompts; only the user may initiate Screen Recording acquisition.
    public func isScreenRecordingTrusted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    private static func windowImage(_ window: SCWindow, maxPixelWidth: Int? = nil, context: MacOperationContext) async throws -> MacScreenShot {
        try Task.checkCancellation()
        guard let owner = window.owningApplication else {
            throw MacScreenCaptureFailure.operationFailed("window capture", "The window's process identity is unavailable; read the app again.")
        }
        guard !PersonOnlyWindows.isOwnProcess(owner.processID) else {
            throw MacScreenCaptureFailure.operationFailed("window capture", "NativeAgent's own window is person-only; use page.screenshot.")
        }
        let capture = MacImageCapture(windows: SystemMacVisualObstructionProbe.windows().filter {
            $0.number == Int(window.windowID)
        })
        guard let capturedWindow = capture.windows.first,
              capturedWindow.pid == window.owningApplication?.processID,
              MacAXWindowIdentity.rectsMatch(capturedWindow.frame,
                  MacAXFrame(x: window.frame.minX, y: window.frame.minY,
                             w: window.frame.width, h: window.frame.height)) else {
            throw MacScreenCaptureFailure.operationFailed("window capture", "The selected window changed before capture; read it again.")
        }
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
        let image: CGImage = try await macScreenCaptureWait(context: context) { receive in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration, completionHandler: receive)
        }
        try Task.checkCancellation()
        return MacScreenShot(bounds: MacAXFrame(
            x: window.frame.minX, y: window.frame.minY, w: window.frame.width, h: window.frame.height),
            pixelWidth: image.width, pixelHeight: image.height, cgImage: image, capture: capture)
    }

    public func capture(window requested: MacAXWindowIdentity, context: MacOperationContext) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
        guard isScreenRecordingTrusted() else { return .failure(.screenRecordingNotTrusted) }
        var operation = "SCShareableContent.getExcludingDesktopWindows"
        do {
            try Task.checkCancellation()
            let content: SCShareableContent = try await macScreenCaptureWait(context: context) { receive in
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
                return .failure(.operationFailed("window selection",
                    "The requested window is absent, ambiguous, or person-only; read the app again for its current window."))
            }
            operation = "SCScreenshotManager.captureImage"
            return .success(try await Self.windowImage(window, context: context))
        } catch {
            return .failure(.operationFailed(operation, error.localizedDescription))
        }
    }

    public func windowCapture(context: MacOperationContext) async -> MacScreenWindowCapture {
        guard isScreenRecordingTrusted() else { return { _, _ in .failure(.screenRecordingNotTrusted) } }
        let content: MacScreenCaptureValue<SCShareableContent>
        do {
            content = MacScreenCaptureValue(value: try await macScreenCaptureWait(context: context) { receive in
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
                    return .failure(.operationFailed("window selection",
                        "The requested window is absent or person-only; read the app again for its current window."))
                }
                return .success(try await Self.windowImage(window, maxPixelWidth: maxPixelWidth, context: context))
            } catch {
                return .failure(.operationFailed("SCScreenshotManager.captureImage", error.localizedDescription))
            }
        }
    }

    public func capture(rect: MacAXFrame?, context: MacOperationContext) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
        guard isScreenRecordingTrusted() else { return .failure(.screenRecordingNotTrusted) }
        let content: SCShareableContent
        do {
            content = try await macScreenCaptureWait(context: context) { receive in
                SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true, completionHandler: receive)
            }
        } catch {
            return .failure(.operationFailed("SCShareableContent.getExcludingDesktopWindows", error.localizedDescription))
        }
        // Prefer the centre’s display; a centre in a desktop gap needs the largest visible portion instead.
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
        // Translate global AX points into the selected display’s local space; secondary displays need a nonzero offset.
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
        // Use this display’s physical pixels per point.
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let densityX = (mode?.pixelWidth).map { Double($0) / Double(max(1, display.width)) } ?? 1.0
        let densityY = (mode?.pixelHeight).map { Double($0) / Double(max(1, display.height)) } ?? 1.0
        let density = max(1.0, min(max(densityX, densityY), 4.0))

        // Exclude the pointer overlay so captures show the underlying scene.
        let filter = SCContentFilter(
            display: display,
            excludingWindows: content.windows.filter {
                PersonOnlyWindows.isOwnProcess($0.owningApplication?.processID) || PersonOnlyWindows.contains(number: Int($0.windowID))
            }
        )
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = localRect
        configuration.width = max(1, Int((localRect.width * density).rounded()))
        configuration.height = max(1, Int((localRect.height * density).rounded()))
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let capture = MacImageCapture(windows: SystemMacVisualObstructionProbe.windows())
        let image: CGImage
        do {
            image = try await macScreenCaptureWait(context: context) { receive in
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration, completionHandler: receive)
            }
        } catch {
            return .failure(.operationFailed("SCScreenshotManager.captureImage", error.localizedDescription))
        }
        // Derive downstream scale from returned pixels rather than requested size so clamping or rounding cannot move markers.
        return .success(MacScreenShot(
            bounds: MacAXFrame(
                x: Double(globalRect.origin.x),
                y: Double(globalRect.origin.y),
                w: Double(globalRect.width),
                h: Double(globalRect.height)
            ),
            pixelWidth: image.width,
            pixelHeight: image.height,
            cgImage: image,
            capture: capture
        ))
    }
}

#endif

/// Unsupported platforms report unavailability rather than fabricated pixels.
public struct UnavailableMacScreenCaptureSource: MacScreenCaptureSource {
    public init() {}
    public func isScreenRecordingTrusted() -> Bool { false }
    public func capture(rect: MacAXFrame?, context: MacOperationContext) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
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
