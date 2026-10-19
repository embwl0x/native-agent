import Foundation
import NativeAgentCore
import PersistenceCore
import Dispatcher
import MacControl
import CoreGraphics

extension SwiftToolDispatcher {
    func impl_mac_screenshot_save(input: [String: JSONValue], surface: String) async throws -> JSONValue {
        let access = await fullMacToolAccess(surface: surface)
        guard access.fileOpsAllowed, access.accessibilityAllowed else {
            if let need = macControlCategoryNeedEnvelope(
                categories: ["accessibility", "file_ops"], mode: .write,
                why: "Screen control and file access let me save a screenshot on your Mac."
            ) { return need }
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
        // The shot waits for the desktop to hold still: two inventories in a row
        // that agree (her own window fading out and Shotgun coming in move it
        // for a moment; so does any app's animation), bounded to 1.5 s.
        guard var windows = desktopWindowInventory() else {
            return failed("The desktop window list could not be read for masking. No image was delivered.")
        }
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(100))
            guard let again = desktopWindowInventory() else { break }
            if NSArray(array: windows).isEqual(to: again) { break }
            windows = again
        }
        let shot: MacScreenShot
        switch await source.capture(rect: nil) {
        case .failure(let failure): return failed(failure.rawValue)
        case .success(let captured): shot = captured
        }
        // The masks describe the windows on screen at the shot: the inventory is
        // read again right after it, before a walk that can take seconds on a
        // busy desktop (checking after the walk refused every live capture, 10-16).
        // A window that appeared since is not in the picture (the system's own
        // recording indicator comes up as the shot is taken); one that vanished
        // or moved may be, unmasked, so that refuses. A window that moves later
        // no longer matches its shot-time frame and is masked in full below.
        guard let settled = desktopWindowInventory(), desktopWindowsHeld(windows, through: settled) else {
            return failed("A desktop window moved or closed as the capture was taken. Retry when they are still. No image was delivered.")
        }
        // A window that appeared as the shot was taken may be in the pixels: it is masked in full.
        let shotWindows = Set(windows.compactMap { $0[kCGWindowNumber as String] as? Int })
        let appeared = settled.filter { !shotWindows.contains($0[kCGWindowNumber as String] as? Int ?? -1) }
        guard !Task.isCancelled else { return failed("Desktop capture cancelled.") }
        guard shot.pixelWidth > 0, shot.pixelHeight > 0,
              Double(shot.pixelWidth) * Double(shot.pixelHeight) <= 40_000_000 else {
            return failed("Desktop capture exceeds the supported 40-megapixel limit.")
        }
        // Small enough that no provider rescales it (long side ≤ 1568, short side
        // ≤ 768, ≤ 1.15 MP): what the model is shown is what the receipt measures,
        // so a point she reads off the picture is the point her hand goes to.
        let long = Double(max(shot.pixelWidth, shot.pixelHeight)), short = Double(min(shot.pixelWidth, shot.pixelHeight))
        let scale = min(1, 1568 / long, 768 / short, (1_150_000 / (long * short)).squareRoot())
        guard let image = shot.cgImage else {
            return failed("Desktop capture returned no image. No image was delivered.")
        }
        // Every window in the picture, front to back, with what it may show: its
        // own pixels with its inspected fields' masks, or nothing (masked whole).
        let layers: [DesktopLayer]
        do { layers = try await desktopLayers(shot: shot, windows: windows, appeared: appeared, scale: scale, source: source, accessibility: accessibility) }
        catch { return failed(ChatToolOutcome.errorMessage(error)) }
        // The picture is composed back to front from each window's OWN pixels
        // (a capture of that window alone, its secret fields masked) or its
        // full mask: nothing about one window is inferred from another, every
        // content footprint is gray before anything is pasted so a translucent
        // window shows gray, and a rear window's field mask never paints over
        // a front window (Sol, 10-16).
        let maskedWindows = layers.filter { $0.image == nil }.count
        guard let masked = composeDesktop(shot: shot, image: image, layers: layers, scale: scale) else {
            return failed("Desktop preview rendering failed while applying safe masks. No image was delivered.")
        }
        let maskedShot = MacScreenShot(bounds: shot.bounds,
            pixelWidth: masked.width, pixelHeight: masked.height, cgImage: masked)
        guard !Task.isCancelled else { return failed("Desktop capture cancelled.") }
        guard let png = renderer.renderPNG(shot: maskedShot, placements: [], secretFrames: [], downscale: 1) else {
            return failed("Desktop image encoding failed.")
        }
        let delivered = LocalToolImage.deliverPNG(png, name: "primary-desktop.png", width: masked.width, height: masked.height)
        guard case .object(var result) = delivered else { return delivered }
        result["capture_scope"] = .string("primary_desktop")
        result["captured_at"] = .string(ISO8601DateFormatter().string(from: Date()))
        result["verification_scope"] = .string("visual_observation_only")
        result["masked_windows"] = .int(Int64(maskedWindows))
        var note = "Primary-display pixels, bounded so the model sees them at the receipt's own size (short side ≤ 768 px). Secret fields are masked; windows whose contents could not be safely inspected are masked in full. Inspect the image to assess the outcome; capture success alone does not verify an action. Protected content may be unavailable."
        if result["status"] == .string("ok") {
            let frame = MacImageFrames.remember(MacScreenViewGeometry(bounds: shot.bounds, pixelWidth: masked.width, pixelHeight: masked.height))
            result["image"] = frame.fields
            note += " " + frame.words
        }
        result["note"] = .string(note)
        return .object(result)
    }

    /// One window of the picture: its frame, and its own pixels with its
    /// secret fields when it was inspected, else masked whole.
    struct DesktopLayer {
        let number: Int
        let frame: MacAXFrame
        let image: CGImage?
        let secrets: [MacAXFrame]
    }

    private static func desktopLayers(
        shot: MacScreenShot, windows: [[String: Any]], appeared: [[String: Any]] = [], scale: Double,
        source: any MacScreenCaptureSource, accessibility: any MacAXElementSource
    ) async throws -> [DesktopLayer] {
        guard shot.bounds.w > 0, shot.bounds.h > 0,
              [shot.bounds.x, shot.bounds.y, shot.bounds.w, shot.bounds.h].allSatisfy(\.isFinite) else {
            throw ToolFailureError("Desktop masking found invalid capture bounds. No image was delivered.", effects: .none)
        }
        guard accessibility.isTrusted() else {
            throw ToolFailureError("Accessibility permission is required for desktop masking. No permission prompt was opened; no image was delivered.", effects: .none)
        }
        let geometry = MacScreenViewGeometry(shot: shot)
        // The composite's own pixels per point: a window is captured no larger than it will be shown.
        let pixelsPerPoint = Double(shot.pixelWidth) / shot.bounds.w
        var layers: [DesktopLayer] = []
        var rootsByPID: [Int32: [MacAXWindowHandle]] = [:]
        // One enumeration of the windows on screen serves every window's capture.
        let capture = await source.windowCapture()
        // Front to back, each window's walks spend from what the windows in
        // front of it left, so the front window is never the one the budget
        // misses; every window past it is masked in full (the safe default
        // below). A hard 32-window cap used to refuse the whole capture on a
        // busy desktop.
        let budget = Date().addingTimeInterval(desktopMaskingBudget)
        var chromeByPID: [Int32: Bool] = [:]
        // Every CG frame of each app, read once, for the reverse match below.
        var framesByPID: [Int32: [MacAXFrame]] = [:]
        for window in windows + appeared {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            framesByPID[pid, default: []].append(MacAXFrame(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height))
        }
        func near(_ a: MacAXFrame, _ b: MacAXFrame) -> Bool {
            abs(a.x - b.x) <= 2 && abs(a.y - b.y) <= 2 && abs(a.w - b.w) <= 2 && abs(a.h - b.h) <= 2
        }
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
            // Apple's own chrome at a raised level, the Dock and the Window
            // Server's menu bar, is not app content: masked whole, the Dock's
            // whole-display window painted every picture gray (10-16). Anything
            // else at a raised level (a banner, a popover) is content and keeps
            // its mask.
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0, isChrome(window, cache: &chromeByPID) { continue }
            // A window wholly under the windows in front of it is not in the
            // picture: no walk, no layer, and the budget goes to what can be seen.
            // Every footprint is painted gray before any window's own pixels, so even under a translucent front window it was already gray (Sol, 10-16).
            let display = CGRect(x: shot.bounds.x, y: shot.bounds.y, width: shot.bounds.w, height: shot.bounds.h)
            if desktopCovered(rect.intersection(display), by: layers.map { CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.w, height: $0.frame.h) }) { continue }
            let number = window[kCGWindowNumber as String] as? Int ?? -1
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32 else {
                throw ToolFailureError("Desktop masking could not identify a window's app. No image was delivered.", effects: .none)
            }
            guard Date() < budget else {
                layers.append(DesktopLayer(number: number, frame: frame, image: nil, secrets: []))
                continue
            }
            // A window may spend half of what the windows in front of it left,
            // every AX message held to it: an app slow to answer (Godot, one
            // element in 1.4 s, 10-16) costs its own window, not every one behind.
            let share = Date().addingTimeInterval(budget.timeIntervalSinceNow / 2)
            if rootsByPID[pid] == nil {
                rootsByPID[pid] = MacAXLimits.$readDeadline.withValue(share) { accessibility.windowRoots(pid: pid) }
            }
            // Root discovery can spend the window's share: nothing more starts past it.
            guard Date() < share else {
                layers.append(DesktopLayer(number: number, frame: frame, image: nil, secrets: []))
                continue
            }
            let matches = rootsByPID[pid, default: []].filter { $0.identity.frame.map { near($0, frame) } ?? false }
            // The match must hold both ways: two CG windows of one app near one
            // frame (a document and a hidden sibling panel) would both match the
            // same AX root, and one window's inspection would then vouch for the
            // other's pixels. The root must match this window alone, else masked whole.
            if matches.count == 1, let root = matches.first, let rootFrame = root.identity.frame,
               framesByPID[pid, default: []].filter({ near($0, rootFrame) }).count == 1 {
                // Its whole tree is walked, its own pixels captured, and the tree
                // walked again: every element is judged, and the secret fields
                // must stand still across the capture while the rest may change
                // (a chat streams text). A walk or judgment that was cut or
                // unreadable, a control that cannot be placed, a root gone or
                // moved, or a secret field that moved masks the whole window. A
                // control of no area paints nothing (hidden window buttons, 10-16).
                func fields() -> [MacAXFrame]? {
                    let snapshot = MacAXLimits.$readDeadline.withValue(share) {
                        MacAccessibilityReader.walk(source: accessibility, root: root.ref, limits: .whole,
                            read: accessibility.maskingAttributes, deadline: share, stopAtCut: true)
                    }
                    guard !snapshot.truncated, !snapshot.nodes.isEmpty,
                          snapshot.nodes.allSatisfy({ node in
                              guard MacScreenViewBuilder.isMarkable(node.attributes) else { return true }
                              guard let frame = node.attributes.frame else { return false }
                              return frame.w >= 0 && frame.h >= 0 && [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite)
                          }) else { return nil }
                    return MacScreenViewTextRedaction.secretFrames(nodes: snapshot.nodes, geometry: geometry, deadline: share)
                }
                // A secret that moved masks the window whole: the capture's instant is unknown, and a union of its two places leaves the pixels between them bare (Sol, 10-16).
                if let before = fields(),
                   case .success(let own) = await capture(number, max(1, Int((frame.w * pixelsPerPoint * scale).rounded()))),
                   let image = own.cgImage,
                   MacAXLimits.$readDeadline.withValue(share, operation: { accessibility.windowRoots(pid: pid) })
                       .contains(where: { $0.identity == root.identity }),
                   let after = fields(), Set(after) == Set(before) {
                    layers.append(DesktopLayer(number: number, frame: frame, image: image, secrets: before))
                    continue
                }
            }
            // Uninspectable content is a sensitive region in its entirety,
            // including our own windows (which AX deliberately cannot read).
            layers.append(DesktopLayer(number: number, frame: frame, image: nil, secrets: []))
        }
        // A window that appeared as the shot was taken may be in the pixels, in
        // front of anything: masked whole, painted last.
        var late: [DesktopLayer] = []
        for window in appeared {
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            let frame = MacAXFrame(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)
            guard [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite), geometry.intersects(frame),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            if (window[kCGWindowLayer as String] as? Int ?? 0) != 0, isChrome(window, cache: &chromeByPID) { continue }
            late.append(DesktopLayer(number: window[kCGWindowNumber as String] as? Int ?? -1, frame: frame, image: nil, secrets: []))
        }
        return late + layers
    }

    /// The composite at delivery size: the desktop shot with every content
    /// window's footprint painted gray, then back to front each window's own
    /// pixels with its field masks, or nothing. Image space is top-left in
    /// global points; the context is bottom-left in pixels.
    static func composeDesktop(shot: MacScreenShot, image: CGImage, layers: [DesktopLayer], scale: Double) -> CGImage? {
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        guard shot.bounds.w > 0, shot.bounds.h > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let scaleX = Double(width) / shot.bounds.w, scaleY = Double(height) / shot.bounds.h
        func rect(_ frame: MacAXFrame) -> CGRect {
            let x = (frame.x - shot.bounds.x) * scaleX, w = frame.w * scaleX, h = frame.h * scaleY
            let y = Double(height) - (frame.y - shot.bounds.y) * scaleY - h
            return CGRect(x: x, y: y, width: w, height: h)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Opaque, not blurred: a blur of a short code is still the code. Every
        // content window's footprint first, so nothing of the shot shows under
        // a translucent paste.
        context.setFillColor(gray: 0.08, alpha: 1)
        for layer in layers { context.fill(rect(layer.frame)) }
        for layer in layers.reversed() {
            guard let own = layer.image else { context.fill(rect(layer.frame)); continue }
            context.draw(own, in: rect(layer.frame))
            for secret in layer.secrets { context.fill(rect(secret)) }
        }
        return context.makeImage()
    }

    /// Nothing of `rect` is left once every cover is cut out of it.
    static func desktopCovered(_ rect: CGRect, by covers: [CGRect]) -> Bool {
        var pieces = [rect]
        for cover in covers {
            pieces = pieces.flatMap { piece -> [CGRect] in
                let cut = piece.intersection(cover)
                guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [piece] }
                return [CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: cut.minY - piece.minY),
                        CGRect(x: piece.minX, y: cut.maxY, width: piece.width, height: piece.maxY - cut.maxY),
                        CGRect(x: piece.minX, y: cut.minY, width: cut.minX - piece.minX, height: cut.height),
                        CGRect(x: cut.maxX, y: cut.minY, width: piece.maxX - cut.maxX, height: cut.height)]
                    .filter { $0.width > 0 && $0.height > 0 }
            }
            if pieces.isEmpty { return true }
        }
        return false
    }

    /// The whole desktop's masking walk, in seconds: the 32 windows of 0.15 s the old cap allowed.
    static let desktopMaskingBudget: TimeInterval = 4.8

    /// Apple's own chrome, by the executable of the process that owns the
    /// window (a name is anyone's to take): the Dock, and the Window Server's
    /// menu bar. Nothing else is exempt from masking.
    static func isChrome(_ window: [String: Any], cache: inout [Int32: Bool]) -> Bool {
        guard let pid = window[kCGWindowOwnerPID as String] as? Int32 else { return false }
        if let known = cache[pid] { return known }
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : ""
        let chrome = path.hasPrefix("/System/Library/CoreServices/Dock.app/")
            || (path.hasPrefix("/System/Library/") && path.hasSuffix("/WindowServer"))
        cache[pid] = chrome
        return chrome
    }


    /// Every window of the shot-time inventory is still there, unmoved, and in
    /// the same front-to-back order: the masks were cut by that order.
    private static func desktopWindowsHeld(_ before: [[String: Any]], through after: [[String: Any]]) -> Bool {
        let now = Dictionary(after.compactMap { window in (window[kCGWindowNumber as String] as? Int).map { ($0, window) } },
                             uniquingKeysWith: { first, _ in first })
        let retained = before.compactMap { $0[kCGWindowNumber as String] as? Int }
        let kept = Set(retained)
        guard retained == after.compactMap({ $0[kCGWindowNumber as String] as? Int }).filter(kept.contains) else { return false }
        return before.allSatisfy { window in
            guard let number = window[kCGWindowNumber as String] as? Int, let held = now[number] else { return false }
            return NSDictionary(dictionary: window).isEqual(to: held)
        }
    }

    private static func desktopWindowInventory() -> [[String: Any]]? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let keys = [kCGWindowNumber, kCGWindowOwnerPID, kCGWindowOwnerName, kCGWindowLayer, kCGWindowBounds, kCGWindowAlpha]
            .map { $0 as String }
        // Shotgun is left out of the capture, so it is left out of the masks.
        return windows.filter { window in
            !((window[kCGWindowNumber as String] as? Int).map(PersonOnlyWindows.contains(number:)) ?? false)
        }.map { window in
            window.filter { keys.contains($0.key) }
        }
    }
}
