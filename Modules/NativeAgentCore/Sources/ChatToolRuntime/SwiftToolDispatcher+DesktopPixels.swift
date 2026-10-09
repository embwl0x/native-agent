import Foundation
import NativeAgentCore
import PersistenceCore
import Dispatcher
import MacControl
import AgentWorkspace
import CoreGraphics

extension SwiftToolDispatcher {
    func impl_mac_screenshot_save(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let access = await fullMacToolAccess(surface: surface)
        guard access.fileOpsAllowed, access.accessibilityReadAllowed else {
            throw AutonomyGateError.toolDenied(reason: "Saving screenshots requires Trust Center Full Mac file access and the Accessibility category.")
        }
        guard defaultMacScreenCaptureSource().isScreenRecordingTrusted() else {
            throw AutonomyGateError.toolDenied(reason: "Screen Recording permission is required to save a screenshot.")
        }
        let selectors = ["window_id", "app", "region"].filter { input[$0] != nil && input[$0] != .null }
        guard selectors.count <= 1 else {
            throw AutonomyGateError.toolDenied(reason: "Choose only one of window_id, app or region.")
        }
        var args = ["-x", "-t", "png"]
        if let window = input["window_id"] {
            guard case .int(let id) = window, id > 0, id <= Int64(UInt32.max) else {
                throw AutonomyGateError.toolDenied(reason: "window_id must be a positive window number.")
            }
            args += ["-l", String(id)]
        } else if let app = optionalString(input, "app") {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let matches = windows.filter {
                ($0[kCGWindowOwnerName as String] as? String)?.caseInsensitiveCompare(app) == .orderedSame
                    && ($0[kCGWindowLayer as String] as? Int) == 0
            }
            guard Set(matches.compactMap { $0[kCGWindowOwnerPID as String] as? Int }).count == 1,
                  let id = matches.first?[kCGWindowNumber as String] as? Int else {
                throw AutonomyGateError.toolDenied(reason: "No unique visible app named '\(app)'; supply window_id for an exact window.")
            }
            args += ["-l", String(id)]
        } else if let region = optionalString(input, "region") {
            let parts = region.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let values = parts.compactMap(Int.init)
            guard parts.count == 4, values.count == 4, values[2] > 0, values[3] > 0 else {
                throw AutonomyGateError.toolDenied(reason: "region must be x,y,width,height in screen points with positive width and height.")
            }
            args += ["-R", values.map(String.init).joined(separator: ",")]
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        let requested = optionalString(input, "path") ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/Screenshot \(formatter.string(from: Date())).png").path
        let path = URL(fileURLWithPath: (requested as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        guard path.pathExtension.lowercased() == "png", !connectorPathIsSensitiveData(path, dataRoot: dataRoot) else {
            throw AutonomyGateError.toolDenied(reason: "Choose a PNG path outside sensitive app data.")
        }
        var paths = [path]
        if selectors.isEmpty {
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
                throw AutonomyGateError.toolDenied(reason: "The active displays could not be read.")
            }
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
                throw AutonomyGateError.toolDenied(reason: "The active displays could not be read.")
            }
            let screens = displays.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }.count
            for screen in 1..<max(1, screens) {
                paths.append(path.deletingPathExtension().appendingPathExtension("\(screen + 1).png"))
            }
        }
        guard paths.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
            throw AutonomyGateError.toolDenied(reason: "A screenshot path already exists; choose another path.")
        }
        let arguments = args + paths.map(\.path)
        let output: (Int32, String) = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(), errors = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = errors
                do {
                    try process.run()
                    let error = errors.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (process.terminationStatus, String(decoding: error, as: UTF8.self)))
                } catch { continuation.resume(throwing: error) }
            }
        }
        let saved = paths.filter { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }
        return .object(["status": .string(output.0 == 0 && saved.count == paths.count ? "saved" : "failed"),
            "path": .string(path.path), "paths": .array(saved.map { .string($0.path) }),
            "detail": .string(output.0 == 0 && saved.count == paths.count
                ? "System screenshot saved; pixels were not delivered to the model."
                : "screencapture exited \(output.0): \(output.1); saved \(saved.count) of \(paths.count) files."),
            "image_pixels": .bool(false)])
    }

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
            return failed("The desktop window list could not be read for masking. No image was delivered.")
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
        guard let image = shot.cgImage else {
            return failed("Desktop capture returned no image. No image was delivered.")
        }
        let masking: (marks: [JSONValue], maskedWindows: Int)
        do { masking = try desktopMaskingMarks(shot: shot, windows: windows, accessibility: accessibility) }
        catch { return failed(ChatToolOutcome.errorMessage(error)) }
        guard let masked = MacScreenPreviewFrame.previewImage(from: image, marks: masking.marks,
                origin: (x: shot.bounds.x, y: shot.bounds.y),
                logicalSize: (w: shot.bounds.w, h: shot.bounds.h), maximumWidth: shot.pixelWidth) else {
            return failed("Desktop preview rendering failed while applying safe masks. No image was delivered.")
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
    ) throws -> (marks: [JSONValue], maskedWindows: Int) {
        guard shot.bounds.w > 0, shot.bounds.h > 0,
              [shot.bounds.x, shot.bounds.y, shot.bounds.w, shot.bounds.h].allSatisfy(\.isFinite) else {
            throw ToolFailureError("Desktop masking found invalid capture bounds. No image was delivered.", effects: .none)
        }
        guard accessibility.isTrusted() else {
            throw ToolFailureError("Accessibility permission is required for desktop masking. No permission prompt was opened; no image was delivered.", effects: .none)
        }
        let geometry = MacScreenViewGeometry(shot: shot)
        var marks: [JSONValue] = []
        var maskedWindows = 0
        var rootsByPID: [Int32: [MacAXWindowHandle]] = [:]
        var count = 0
        for window in windows {
            guard !Task.isCancelled else { throw ToolFailureError("Desktop capture cancelled.", effects: .none) }
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else {
                throw ToolFailureError("Desktop masking could not read a window's bounds. No image was delivered.", effects: .none)
            }
            let frame = MacAXFrame(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)
            guard [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite) else {
                throw ToolFailureError("Desktop masking found invalid window bounds. No image was delivered.", effects: .none)
            }
            guard geometry.intersects(frame),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            count += 1
            guard count <= 32 else {
                throw ToolFailureError("Desktop masking exceeds the supported 32-window limit. No image was delivered.", effects: .none)
            }
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32 else {
                throw ToolFailureError("Desktop masking could not identify a window's app. No image was delivered.", effects: .none)
            }
            if rootsByPID[pid] == nil { rootsByPID[pid] = accessibility.windowRoots(pid: pid) }
            let matches = rootsByPID[pid, default: []].filter { handle in
                guard let ax = handle.identity.frame else { return false }
                return abs(ax.x - frame.x) <= 2 && abs(ax.y - frame.y) <= 2
                    && abs(ax.w - frame.w) <= 2 && abs(ax.h - frame.h) <= 2
            }
            if matches.count == 1, let root = matches.first {
                // The full secret predicate over a walk that reads only what it
                // needs, with a time slice so one slow app cannot hold the
                // capture. A cut or unreadable walk masks the whole window.
                let snapshot = MacAccessibilityReader.walk(source: accessibility, root: root.ref,
                    read: accessibility.maskingAttributes, deadline: Date().addingTimeInterval(desktopWindowSlice),
                    stopAtCut: true)
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
        guard let current = desktopWindowInventory() else {
            throw ToolFailureError("The desktop window inventory could not be reread after masking. No image was delivered.", effects: .none)
        }
        guard NSArray(array: windows).isEqual(to: current) else {
            throw ToolFailureError("The desktop window inventory changed during capture. Retry when the windows are stable. No image was delivered.", effects: .none)
        }
        return (marks, maskedWindows)
    }

    /// One window's share of the masking walk, in seconds.
    static let desktopWindowSlice: TimeInterval = 0.15

    private static func desktopWindowInventory() -> [[String: Any]]? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let keys = [kCGWindowNumber, kCGWindowOwnerPID, kCGWindowLayer, kCGWindowBounds, kCGWindowAlpha]
            .map { $0 as String }
        // Shotgun is left out of the capture, so it is left out of the masks.
        return windows.filter { window in
            !((window[kCGWindowNumber as String] as? Int).map(PersonOnlyWindows.contains(number:)) ?? false)
        }.map { window in
            window.filter { keys.contains($0.key) }
        }
    }
}
