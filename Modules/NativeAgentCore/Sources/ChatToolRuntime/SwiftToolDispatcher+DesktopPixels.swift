import Foundation
import NativeAgentCore
import PersistenceCore
import Dispatcher
import MacControl
import AgentWorkspace
import CoreGraphics

extension SwiftToolDispatcher {
    /// Strict provider schemas may spell omitted optional fields as null.
    /// Blank string selectors are also absent, matching the four-verb reader.
    static func desktopPixelsRequested(_ input: [String: JSONValue]) throws -> Bool {
        guard let value = input["pixels"], value != .null else { return false }
        guard case .bool(let requested) = value else {
            throw AutonomyGateError.toolDenied(reason: "screen pixels must be true or false")
        }
        guard requested else { return false }
        // Her-screen Phase 6: pixels:true WITH app or part is that window's
        // (or region's) image through the ordinary screen read, not the desktop.
        for key in ["app", "part"] {
            guard let selector = input[key], selector != .null else { continue }
            if case .string(let text) = selector,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            return false
        }
        return true
    }

    /// Reached only after the ordinary screen read authority gate. A bounded AX
    /// read supplies the same secret-field masking as app-window captures. No
    /// focus change, permission request, persistent file, or action verification.
    static func desktopPixels(
        input: [String: JSONValue],
        source: any MacScreenCaptureSource = defaultMacScreenCaptureSource(),
        renderer: any MacScreenImageRenderer = defaultMacScreenImageRenderer(),
        accessibility: any MacAXElementSource = defaultMacAXElementSource()
    ) async -> JSONValue {
        func failed(_ reason: String) -> JSONValue {
            .object(["status": .string("failed"), "error": .string(reason), "image_pixels": .bool(false)])
        }
        guard LocalToolImage.sink != nil else {
            return failed("Desktop pixels require a model tool turn; this text-only call cannot display an image.")
        }
        guard !Task.isCancelled else { return failed("Desktop capture cancelled.") }
        guard source.isScreenRecordingTrusted() else {
            return failed("Screen Recording permission is required. No permission prompt was opened.")
        }
        do {
            if let refusal = try await SwiftNativeMacControl().wakeScreenIfCovered(action: "view", body: input) {
                return refusal.output
            }
        } catch {
            return failed((error as? MacScreenLock.Covered)?.detail ?? error.localizedDescription)
        }
        guard let windows = desktopWindowInventory() else {
            return failed("The desktop capture could not be safely masked. No image was delivered.")
        }
        let shot: MacScreenShot
        switch await source.capture(rect: nil) {
        case .failure(let failure): return failed(failure.rawValue)
        case .success(let captured): shot = captured
        }
        guard !Task.isCancelled else { return failed("Desktop capture cancelled.") }
        guard shot.pixelWidth > 0, shot.pixelHeight > 0,
              Double(shot.pixelWidth) * Double(shot.pixelHeight) <= 40_000_000 else {
            return failed("Desktop capture exceeds the supported 40-megapixel limit.")
        }
        let scale = min(1, 1600 / Double(max(shot.pixelWidth, shot.pixelHeight)))
        guard let image = shot.cgImage,
              let masking = desktopMaskingMarks(shot: shot, windows: windows, accessibility: accessibility),
              let masked = MacScreenPreviewFrame.previewImage(from: image, marks: masking.marks,
                origin: (x: shot.bounds.x, y: shot.bounds.y),
                logicalSize: (w: shot.bounds.w, h: shot.bounds.h), maximumWidth: shot.pixelWidth) else {
            return failed("The desktop capture could not be safely masked. No image was delivered.")
        }
        let maskedShot = MacScreenShot(bounds: shot.bounds,
            pixelWidth: masked.width, pixelHeight: masked.height, cgImage: masked)
        guard !Task.isCancelled else { return failed("Desktop capture cancelled.") }
        guard let png = renderer.renderPNG(shot: maskedShot, placements: [], downscale: scale) else {
            return failed("Desktop image encoding failed.")
        }
        let delivered = LocalToolImage.deliverPNG(png, name: "primary-desktop.png",
            width: max(1, Int((Double(shot.pixelWidth) * scale).rounded())),
            height: max(1, Int((Double(shot.pixelHeight) * scale).rounded())))
        guard case .object(var result) = delivered else { return delivered }
        result["capture_scope"] = .string("primary_desktop")
        result["captured_at"] = .string(ISO8601DateFormatter().string(from: Date()))
        result["verification_scope"] = .string("visual_observation_only")
        result["masked_windows"] = .int(Int64(masking.maskedWindows))
        result["note"] = .string("Primary-display pixels, bounded to 1600px. Secret fields are masked; windows whose contents could not be safely inspected are masked in full. Inspect the image to assess the outcome; capture success alone does not verify an action. Protected content may be unavailable.")
        return .object(result)
    }

    private static func desktopMaskingMarks(
        shot: MacScreenShot, windows: [[String: Any]], accessibility: any MacAXElementSource
    ) -> (marks: [JSONValue], maskedWindows: Int)? {
        guard shot.bounds.w > 0, shot.bounds.h > 0,
              [shot.bounds.x, shot.bounds.y, shot.bounds.w, shot.bounds.h].allSatisfy(\.isFinite),
              accessibility.isTrusted() else { return nil }
        let geometry = MacScreenViewGeometry(shot: shot)
        var marks: [JSONValue] = []
        var maskedWindows = 0
        var rootsByPID: [Int32: [MacAXWindowHandle]] = [:]
        var count = 0
        for window in windows {
            guard !Task.isCancelled,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            let frame = MacAXFrame(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)
            guard [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite) else { return nil }
            guard geometry.intersects(frame),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            count += 1
            guard count <= 32, let pid = window[kCGWindowOwnerPID as String] as? Int32 else { return nil }
            if rootsByPID[pid] == nil { rootsByPID[pid] = accessibility.windowRoots(pid: pid) }
            let matches = rootsByPID[pid, default: []].filter { handle in
                guard let ax = handle.identity.frame else { return false }
                return abs(ax.x - frame.x) <= 2 && abs(ax.y - frame.y) <= 2
                    && abs(ax.w - frame.w) <= 2 && abs(ax.h - frame.h) <= 2
            }
            if matches.count == 1, let root = matches.first {
                let snapshot = MacAccessibilityReader.walk(source: accessibility, root: root.ref)
                let selection = MacScreenViewBuilder.select(nodes: snapshot.nodes, geometry: geometry)
                if !snapshot.truncated, !snapshot.nodes.isEmpty, !selection.truncated,
                   snapshot.nodes.allSatisfy({ node in
                       guard MacScreenViewBuilder.isMarkable(node.attributes) else { return true }
                       guard let frame = node.attributes.frame else { return false }
                       return frame.w > 0 && frame.h > 0
                           && [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite)
                   }) {
                    marks.append(contentsOf: selection.marks.map { $0.toJSON() })
                    continue
                }
            }
            // Uninspectable content is a sensitive region in its entirety,
            // including our own windows (which AX deliberately cannot read).
            marks.append(.object([
                "role": .string("AXWindow"), "secret_field": .bool(true),
                "frame": .object(["x": .double(frame.x), "y": .double(frame.y),
                    "w": .double(frame.w), "h": .double(frame.h)]),
            ]))
            maskedWindows += 1
        }
        // A disappearing or moving window must not leave its captured content
        // outside the regions inspected after capture.
        guard let current = desktopWindowInventory(), NSArray(array: windows).isEqual(to: current) else { return nil }
        return (marks, maskedWindows)
    }

    private static func desktopWindowInventory() -> [[String: Any]]? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let keys = [kCGWindowNumber, kCGWindowOwnerPID, kCGWindowLayer, kCGWindowBounds, kCGWindowAlpha]
            .map { $0 as String }
        return windows.map { window in
            window.filter { keys.contains($0.key) }
        }
    }
}
