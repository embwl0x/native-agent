import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Dispatcher
import MacControl
import NativeAgentCore
import PersistenceCore
import Senses
// Blueprint: | `SwiftToolDispatcher+FourVerbPerception.swift` | `SwiftToolDispatcherFourVerbPerceptionSource` struct; whole native masked observation through recognition, region crop and JPEG fitting only at model delivery; window obstructions from MacControl's `SystemMacVisualObstructionProbe` |

/// The assembly bridge between MacControl's live fused capture and its pure
/// VisionPerceptionCompiler;
/// the four-verb surface receives one additive, source-neutral supplement.
struct SwiftToolDispatcherFourVerbPerceptionSource: MacFourVerbsSupplementalPerceptionSource {
    let host: any MacControlClient
    let liveScene: SwiftToolDispatcherFourVerbLiveScene
    let obstructionProbe = SystemMacVisualObstructionProbe()
    /// Words for the verb this observation belongs to, for the chat's live
    /// computer pane. Carried per call rather than read from ambient state so a
    /// caption and a frame can never come from different verbs. `nil` means
    /// "name the app you resolved", which is what a bare `screen` wants.
    let previewCaption: String?
    /// Her-screen Phase 6 — set by `screen` only. Records the frame this look
    /// already captured and why its words are thin; the dispatcher attaches it.
    let pixels: FourVerbPixelAttachment?

    init(
        host: any MacControlClient,
        liveScene: SwiftToolDispatcherFourVerbLiveScene,
        previewCaption: String? = nil,
        pixels: FourVerbPixelAttachment? = nil
    ) {
        self.host = host
        self.liveScene = liveScene
        self.previewCaption = previewCaption
        self.pixels = pixels
    }

    func rejected() { pixels?.discard(); SenseAppReadCapture.current?.discardWindowText() }

    func observe(app requestedApp: String?) async -> MacFourVerbsSupplement? {
        let observationStartedNs = DispatchTime.now().uptimeNanoseconds
        let result: MacControlResult
        do {
            var body: [String: JSONValue] = [
                "max_marks": .int(80),
                "max_text_items": .int(160),
                "semantic_raw_frame": .bool(true),
                "semantic_focus_visual_surface": .bool(true),
            ]
            // The view decides the picture from its own AX read: a forced
            // attachment and the live preview always take one; a `screen`
            // attachment takes one of a thin window.
            if pixels?.forced == true || MacScreenPreviewBus.publish != nil { body["pixels"] = .string("always") }
            else if pixels != nil { body["pixels"] = .string("thin") }
            if let requestedApp { body["app"] = .string(requestedApp) }
            result = try await host.dispatch(action: "view", body: body)
        } catch {
            return nil
        }
        let captureFinishedNs = DispatchTime.now().uptimeNanoseconds
        if !result.ok, case .object(let output) = result.output, var remedy = output["remedy"] {
            if case .object(let fields) = remedy, fields["kind"] == .string("inspect") {
                remedy = MacScreenCaptureFailure.operationFailed(result.error ?? "capture_failed",
                    string(output["message"]) ?? "The requested screen capture failed.").remedy(app: requestedApp, part: pixels?.part)
            }
            return MacFourVerbsSupplement(diagnostics: ["error": .string(result.error ?? "capture_failed"),
                "message": output["message"] ?? .string("The requested screen capture failed."), "remedy": remedy])
        }
        guard result.ok, case .object(let output) = result.output,
              let frameID = string(output["frame_id"]) else { return nil }

        let viewId = string(output["view"])
        let marks = array(output["marks"])
        let app = object(output["app"])
        let appName = string(app["name"])
        let bundleIdentifier = string(app["bundle_id"])
        let originObject = object(output["origin"])
        let logicalObject = object(output["logical_size"])
        let imageOriginObject = object(output["image_origin"])
        let imageLogicalObject = object(output["image_logical_size"])
        let pointerObject = object(output["pointer"])
        let pointer: MacPointerPosition? = {
            guard let x = number(pointerObject["x"]), let y = number(pointerObject["y"]) else { return nil }
            return MacPointerPosition(x: x, y: y)
        }()
        let visibleFrame: MacAXFrame? = {
            guard let x = number(originObject["x"]), let y = number(originObject["y"]),
                  let w = number(logicalObject["w"]), let h = number(logicalObject["h"]),
                  w > 0, h > 0 else { return nil }
            return MacAXFrame(x: x, y: y, w: w, h: h)
        }()
        let targetPID = Int32(number(app["pid"]) ?? 0)
        // Every window over this one, whatever the capture shows (a window-only
        // capture has no covering pixels). The probe leaves out her Shotgun and
        // pointer (PersonOnlyWindows); another app's window there would take
        // her hand, while the app's own sheets, menus and panels are its own.
        let covering = targetPID > 0 ? (visibleFrame.map { obstructionProbe.obstructions(over: $0, targetPID: targetPID) } ?? []) : []
        let handObstructions = covering.filter { $0.ownerPID != targetPID }.map(\.frame)
        let structural = structuralSupplement(
            marks: marks,
            menus: array(output["transient_menus"]),
            viewId: viewId,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            visibleFrame: visibleFrame,
            pointer: pointer,
            obstructions: handObstructions
        )

        // The chat's live computer pane. The frame is the one this verb ALREADY
        // captured above — there is no second capture and no timer — and it is
        // decoded only when a surface has bound the bus. Deliberately OUTSIDE
        // the pixel-perception gate below: that gate is about whether OCR earns
        // its latency on this window, and a richly semantic window the agent
        // skips OCR on is exactly the window the user still wants to see.
        if let publish = MacScreenPreviewBus.publish {
            await publishPreview(output: output, appName: appName, publish: publish)
        }

        // The view graded its own AX read (Chromium and incomplete reads are never thin).
        let thinReason = string(output["thin_accessibility_reason"])
        // Independent-window capture contains no covering app pixels to exclude.
        let obstructions = output["capture_isolated_window"] == .bool(true) ? [] : covering
        if let pixels {
            let title = displayText(output["window_title"]) ?? ""
            let windowFrame = visibleFrame.map { "\(Int($0.x)),\(Int($0.y)),\(Int($0.w))x\(Int($0.h))" } ?? ""
            pixels.record(
                frameID: frameID,
                reason: thinReason,
                screenRecording: bool(output["screen_recording_trusted"]) ?? false,
                png: string(output["image"]),
                unavailable: string(output["image_unavailable_reason"]),
                origin: (number(imageOriginObject["x"] ?? originObject["x"]) ?? 0,
                         number(imageOriginObject["y"] ?? originObject["y"]) ?? 0),
                logicalSize: (number(imageLogicalObject["w"] ?? logicalObject["w"]) ?? 0,
                              number(imageLogicalObject["h"] ?? logicalObject["h"]) ?? 0),
                background: output["capture_isolated_window"] == .bool(true),
                window: [bundleIdentifier ?? "", appName ?? "", title, windowFrame].joined(separator: "|"),
                captureDetail: string(output["message"]), captureRemedy: output["remedy"]
            )
            if let mainPicture = frame(output["semantic_focus_frame"]) {
                pixels.focus(name: "the window's main picture area", frame: mainPicture)
            }
        }
        // Pixel perception is the fallback for AX-sparse surfaces; the view
        // decided before its capture whether this window earns it.
        guard output["recognize_pixels"] == .bool(true),
              let encoded = string(output["image"]),
              let data = Data(base64Encoded: encoded),
              let image = VisionImageDecoder.decode(data),
              let originX = number(imageOriginObject["x"] ?? originObject["x"]),
              let originY = number(imageOriginObject["y"] ?? originObject["y"]),
              let logicalW = number(imageLogicalObject["w"] ?? logicalObject["w"]),
              let logicalH = number(imageLogicalObject["h"] ?? logicalObject["h"]),
              logicalW > 0, logicalH > 0 else {
            return structural
        }

        #if canImport(Vision)
        do {
            let visualCompileStartedNs = DispatchTime.now().uptimeNanoseconds
            let appName = string(object(output["app"])["name"])
            let title = displayText(output["window_title"])
            let origin = (x: originX, y: originY)
            let logicalSize = (width: logicalW, height: logicalH)
            let excludedRegions = obstructions.map { obstruction in
                VisionRect(
                    x: (obstruction.frame.x - origin.x) * Double(image.width) / logicalSize.width,
                    y: (obstruction.frame.y - origin.y) * Double(image.height) / logicalSize.height,
                    w: obstruction.frame.w * Double(image.width) / logicalSize.width,
                    h: obstruction.frame.h * Double(image.height) / logicalSize.height
                )
            }
            let percept = try VisionPerceptionCompiler().compile(
                image: image,
                excludedRegions: excludedRegions
            )
            let sceneKey = [bundleIdentifier, appName, title]
                .compactMap { $0 }
                .joined(separator: "|")
            let capturedAt = Self.captureDate(from: output, fallback: Date())
            let sceneSnapshot = await liveScene.identify(
                rows: percept.rows,
                frameSize: percept.frameSize,
                origin: origin,
                logicalSize: logicalSize,
                sceneKey: sceneKey,
                capturedAt: capturedAt
            )
            let vision = percept.fourVerbSupplement(
                origin: origin,
                logicalSize: logicalSize,
                viewId: viewId,
                globalRegionOfInterest: frame(output["semantic_focus_frame"]),
                liveRegionIdentities: sceneSnapshot.identities,
                liveOccludedRegions: sceneSnapshot.temporarilyNotVisible
            )
            let visualCompileFinishedNs = DispatchTime.now().uptimeNanoseconds
            func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Int64 {
                Int64((end &- start) / 1_000_000)
            }
            var visionValues = vision.values
            let visionTargets = vision.targets.compactMap { target -> MacFourVerbsSupplementalTarget? in
                if target.regionOnly {
                    // The surface still exists when a small popup covers part
                    // of it. Carry exact exclusions to the fresh point chooser;
                    // never exempt its motor point from obstruction checks.
                    return MacFourVerbsSupplementalTarget(label: target.label, aliases: target.aliases,
                        kind: target.kind, secret: target.secret, frame: target.frame, observedFrame: target.observedFrame,
                        excludedFrames: obstructions.map(\.frame), provenance: target.provenance,
                        viewId: target.viewId, mark: target.mark, ordinal: target.ordinal,
                        regionOnly: true, physicalOnly: target.physicalOnly,
                        motionUncertain: target.motionUncertain, sourceAXPath: target.sourceAXPath,
                        enabled: target.enabled)
                }
                // Check the final motor frame too: motion lead may move a
                // clear observed object under a foreground window.
                return obstructions.contains { $0.covers(target.frame) } ? nil : target
            }
            if let pixels, let part = pixels.part,
               let region = FourVerbPixelAttachment.region(named: part, in: vision.targets) {
                pixels.focus(name: region.name, frame: region.frame)
            }
            let blockedPhysicalLabels = Set(vision.targets.filter { target in
                target.physicalOnly && obstructions.contains { $0.covers(target.frame) }
            }.compactMap { $0.label?.display })
            let visionContents = vision.contents.map { content in
                MacScreenRender.Content(
                    kind: content.kind, noun: content.noun,
                    rows: content.rows.map { row in
                        guard row.physicalOnly, let label = row.label?.display,
                              blockedPhysicalLabels.contains(label) else { return row }
                        return MacScreenRender.Row(
                            label: row.label, detail: row.detail, provenance: row.provenance,
                            abstain: "projected target covered by foreground window; observe again",
                            sourceAXPath: row.sourceAXPath
                        )
                    },
                    totalRows: content.totalRows, scrollable: content.scrollable, canvas: content.canvas
                )
            }
            for obstruction in obstructions.prefix(3).reversed() {
                let coverage = Int((obstruction.coverage * 100).rounded())
                let coverageText = coverage == 0 ? "<1%" : "\(coverage)%"
                let text = "visual world covered in part by \(obstruction.ownerName) foreground window (\(coverageText) coverage); covered pixels excluded, only clear targets remain available"
                visionValues.insert(MacScreenRender.Value(
                    text: MacScreenText(text, redacted: .string(text)),
                    provenance: .vision(1)
                ), at: 0)
            }
            let obstruction = obstructions.max { $0.coverage < $1.coverage }
            let timings: [String: JSONValue] = [
                "vision_capture_ms": .int(elapsedMilliseconds(from: observationStartedNs, to: captureFinishedNs)),
                "vision_compile_ms": .int(elapsedMilliseconds(from: visualCompileStartedNs, to: visualCompileFinishedNs)),
                "capture_ax_snapshot_ms": output["ax_snapshot_ms"] ?? .null,
                "capture_screen_capture_ms": output["screen_capture_ms"] ?? .null,
                "capture_image_render_ms": output["image_render_ms"] ?? .null,
                "capture_scene_selection_ms": output["scene_selection_ms"] ?? .null,
                "capture_post_render_ms": output["post_render_ms"] ?? .null,
                "capture_view_total_ms": output["view_total_ms"] ?? .null,
            ]
            OwnedProgramRunner.ReadContent.current?.record(.object(timings), content: .object([:]))
            return MacFourVerbsSupplement(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                visibleFrame: visibleFrame,
                pointer: pointer,
                pointerFrame: MacAXFrame(x: origin.x, y: origin.y,
                    w: logicalSize.width, h: logicalSize.height),
                contents: structural.contents + visionContents,
                controls: structural.controls + vision.controls,
                values: structural.values + visionValues,
                targets: structural.targets + visionTargets,
                obstructions: handObstructions,
                diagnostics: ([
                    "vision_isolated_window": output["capture_isolated_window"] ?? .bool(false),
                    "vision_recognized_strings": .int(Int64(percept.recognizedStrings)),
                    "vision_text_tiled": .bool(percept.textTiled),
                    "vision_text_tiling_reason": .string(percept.textTilingReason),
                    "vision_frame_pixels": .object([
                        "w": .double(percept.frameSize.width),
                        "h": .double(percept.frameSize.height),
                    ]),
                    "vision_value_text": .array(vision.values.compactMap { value in
                        value.text.display.map { .string($0) }
                    }),
                    "vision_effect_value_text": vision.diagnostics["vision_effect_value_text"]
                        ?? .array([]),
                    "capture_image_downscale": output["image_downscale"] ?? .null,
                    "capture_image_pixels": output["image_pixel_size"] ?? .null,
                    "visual_world_obstructed": .bool(obstruction != nil),
                    "visual_world_obstruction_count": .int(Int64(obstructions.count)),
                    "visual_world_blocked_targets": .int(Int64(vision.targets.count - visionTargets.count)),
                    "visual_world_obstruction_owner": obstruction.map { .string($0.ownerName) } ?? .null,
                    "visual_world_obstruction_coverage": obstruction.map { .double($0.coverage) } ?? .null,
                ] as [String: JSONValue]).merging(timings) { _, timing in timing }
            )
        } catch {
            return structural
        }
        #else
        return structural
        #endif
    }

    static func captureDate(from output: [String: JSONValue], fallback: Date) -> Date {
        let epoch: Double?
        switch output["captured_at_epoch_seconds"] {
        case .double(let value): epoch = value
        case .int(let value): epoch = Double(value)
        default: epoch = nil
        }
        if let epoch, epoch.isFinite { return Date(timeIntervalSince1970: epoch) }
        guard case .string(let text) = output["captured_at"] else { return fallback }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text) ?? fallback
    }

    private func structuralSupplement(
        marks: [JSONValue],
        menus: [JSONValue],
        viewId: String?,
        appName: String?,
        bundleIdentifier: String?,
        visibleFrame: MacAXFrame?,
        pointer: MacPointerPosition?,
        obstructions: [MacAXFrame]
    ) -> MacFourVerbsSupplement {
        let rowRoles: Set<String> = ["AXRow", "AXCell", "AXOutlineRow", "AXListItem"]
        var rows: [MacScreenRender.Row] = []
        var controls: [MacScreenRender.Control] = []
        var targets: [MacFourVerbsSupplementalTarget] = []
        var values: [MacScreenRender.Value] = []

        // Native popup menus are often siblings of the document window. Their
        // current AX geometry is actionable, but never a window-relative path
        // or mark: the next act re-observes and resolves their names afresh.
        for menuValue in menus.prefix(MacTransientMenus.maxMenus) {
            let menu = object(menuValue)
            let truncated = bool(menu["truncated"]) == true
            let note = truncated ? "Open native menu (item list truncated)" : "Open native menu"
            values.append(MacScreenRender.Value(text: MacScreenText(note), provenance: .ax))
            for itemValue in array(menu["items"]).prefix(MacTransientMenus.maxItems) {
                let item = object(itemValue)
                guard string(item["role"]) == "AXMenuItem", let rect = frame(item["frame"]) else { continue }
                let label = screenText(item["label"]) ?? MacScreenText("")
                let enabled = bool(item["enabled"]) ?? false
                let states = (enabled ? [] : ["disabled"]) + (bool(item["selected"]) == true ? ["selected"] : [])
                controls.append(MacScreenRender.Control(
                    label: label, kind: "menu item", states: states, provenance: .ax
                ))
                targets.append(MacFourVerbsSupplementalTarget(
                    label: label, kind: "menu item", frame: rect, provenance: .ax, enabled: enabled, role: "AXMenuItem",
                    actions: array(item["actions"]).compactMap(string)
                ))
            }
        }

        for markValue in marks {
            let mark = object(markValue)
            guard let role = string(mark["role"]),
                  let frame = frame(mark["frame"]),
                  let number = integer(mark["mark"]) else { continue }
            let kind = MacScreenRender.kindName(role: role)
            let published = screenText(mark["label"])
            // Keep absence as absence. The fused target/render layer assigns
            // one ordinal after matching this mark to the semantic AX lane.
            let label = published ?? MacScreenText("")
            let sourceAXPath: [Int]? = {
                guard case .array(let entries)? = mark["path"] else { return nil }
                var path: [Int] = []
                for entry in entries {
                    guard case .int(let value) = entry, value >= 0,
                          let index = Int(exactly: value) else { return nil }
                    path.append(index)
                }
                return path
            }()
            let enabled = bool(mark["enabled"]) ?? true
            let isRow = rowRoles.contains(role)
            if isRow {
                rows.append(MacScreenRender.Row(
                    label: label,
                    detail: [MacScreenText(kind, redacted: .string(kind))],
                    provenance: .ax,
                    sourceAXPath: sourceAXPath
                ))
            } else {
                controls.append(MacScreenRender.Control(
                    label: label,
                    kind: kind,
                    states: enabled ? (published == nil ? ["unnamed"] : []) : ["disabled"],
                    provenance: .ax,
                    sourceAXPath: sourceAXPath
                ))
            }
            targets.append(MacFourVerbsSupplementalTarget(
                label: label,
                kind: kind,
                secret: bool(mark["secret_field"]) == true,
                frame: frame,
                provenance: .ax,
                viewId: viewId,
                mark: Int(number),
                ordinal: isRow ? rows.count : nil,
                sourceAXPath: sourceAXPath,
                enabled: enabled,
                role: role,
                actions: array(mark["actions"]).compactMap(string),
                settableAttributes: array(mark["settable_attributes"]).compactMap(string)
            ))
        }

        let contents = rows.isEmpty ? [] : [MacScreenRender.Content(
            kind: .list,
            rows: rows,
            totalRows: rows.count,
            scrollable: true
        )]
        return MacFourVerbsSupplement(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            visibleFrame: visibleFrame,
            pointer: pointer,
            contents: contents,
            controls: controls,
            values: values,
            targets: targets,
            obstructions: obstructions
        )
    }

    /// Hands the card the frame this observation already holds, masked and
    /// downscaled. A capture with no image (Screen Recording not granted, a
    /// locked screen, a refused capture) still publishes the words, so the
    /// caption stays honest about the verb in flight while the card keeps
    /// whatever picture it last had.
    private func publishPreview(
        output: [String: JSONValue],
        appName: String?,
        publish: @Sendable (MacScreenPreviewUpdate) async -> Void
    ) async {
        let caption = previewCaption ?? MacScreenPreviewCaption.looking(at: appName)
        guard let encoded = string(output["image"]),
              let data = Data(base64Encoded: encoded),
              let image = VisionImageDecoder.decode(data),
              let preview = MacScreenPreviewFrame.previewImage(from: image) else {
            await publish(MacScreenPreviewUpdate(image: nil, caption: caption, at: Date()))
            return
        }
        await publish(MacScreenPreviewUpdate(image: preview, caption: caption, at: Date()))
    }

    private func object(_ value: JSONValue?) -> [String: JSONValue] {
        guard case .object(let object)? = value else { return [:] }
        return object
    }

    private func array(_ value: JSONValue?) -> [JSONValue] {
        guard case .array(let values)? = value else { return [] }
        return values
    }

    private func string(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    private func bool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let value)? = value else { return nil }
        return value
    }

    private func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let value)?: return Double(value)
        case .double(let value)? where value.isFinite: return value
        default: return nil
        }
    }

    private func integer(_ value: JSONValue?) -> Int64? {
        switch value {
        case .int(let value)?: return value
        case .double(let value)? where value.isFinite && value == value.rounded(): return Int64(exactly: value)
        default: return nil
        }
    }

    private func frame(_ value: JSONValue?) -> MacAXFrame? {
        let object = object(value)
        guard let x = number(object["x"]), let y = number(object["y"]),
              let w = number(object["w"]), let h = number(object["h"]),
              w > 0, h > 0 else { return nil }
        return MacAXFrame(x: x, y: y, w: w, h: h)
    }

    private func displayText(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private func screenText(_ value: JSONValue?) -> MacScreenText? {
        switch value {
        case .string(let clear)?: return MacScreenText(clear, redacted: .string(clear))
        case .object?: return MacScreenText("⟨withheld⟩", redacted: value)
        default: return nil
        }
    }
}

/// Her-screen Phase 6 — PIXELS ONLY WHERE WORDS FAIL. One per `screen` call.
/// The perception source records the frame the look already captured (no
/// second capture) and the thin-AX reason; the dispatcher calls `attach()`
/// after the verb. A background `screen app:` frame is ScreenCaptureKit's
/// desktop-independent window capture, so nothing is raised. Screen
/// Recording is only preflighted, never requested: when missing, it is said.
final class FourVerbPixelAttachment: @unchecked Sendable {
    static let maxLongSide = 1024
    static let maxBytes = 150_000

    let part: String?
    let forced: Bool
    private let lock = NSLock()
    private var recorded = false
    private var frameID = ""
    private var reason: String?
    private var screenRecording = false
    private var png: String?
    private var unavailable: String?
    private var captureDetail: String?
    private var captureRemedy: JSONValue?
    private var origin: (x: Double, y: Double) = (0, 0)
    private var logicalSize: (width: Double, height: Double) = (0, 0)
    private var background = false
    private var window = ""
    private var region: (name: String, frame: MacAXFrame)?

    init(part: String?, forced: Bool) {
        self.part = part
        self.forced = forced
    }

    func record(frameID: String, reason: String?, screenRecording: Bool, png: String?, unavailable: String?,
                origin: (x: Double, y: Double), logicalSize: (width: Double, height: Double),
                background: Bool, window: String, captureDetail: String? = nil, captureRemedy: JSONValue? = nil) {
        lock.lock(); defer { lock.unlock() }
        recorded = true
        self.frameID = frameID
        discarded = false
        self.reason = reason
        self.screenRecording = screenRecording
        self.png = png
        self.unavailable = unavailable
        self.captureDetail = captureDetail
        self.captureRemedy = captureRemedy
        self.origin = origin
        self.logicalSize = logicalSize
        self.background = background
        self.window = window
        region = nil
    }

    func focus(name: String, frame: MacAXFrame) {
        lock.lock(); defer { lock.unlock() }
        region = (name, frame)
    }

    /// The look rejected this capture as not its own window: drop its pixels.
    private var discarded = false
    func discard() {
        lock.lock(); defer { lock.unlock() }
        discarded = true
        png = nil
        region = nil
    }

    /// A numbered pixel region by its rendered name ("visual region 3"),
    /// "region 3", "3", or the OCR label a pixel target carries.
    static func region(named part: String, in targets: [MacFourVerbsSupplementalTarget]) -> (name: String, frame: MacAXFrame)? {
        func normalize(_ text: String) -> String {
            text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "#\"'"))
        }
        let wanted = normalize(part)
        let words = wanted.split(separator: " ")
        let number = words.last.flatMap { Int($0) }
        let prefix = words.dropLast().joined(separator: " ")
        for target in targets where target.sourceAXPath == nil {
            guard let label = target.label?.display else { continue }
            let name = normalize(label)
            if name == wanted || target.aliases.map(normalize).contains(wanted)
                || (number.map { name == "visual region \($0)" } ?? false
                    && ["", "region", "visual region"].contains(prefix)) {
                return (label, target.observedFrame)
            }
        }
        return nil
    }

    /// The delivered image's frame fields (MacImageFrames), once `attach` sent one.
    private(set) var imageFrame: JSONValue?

    /// The one line `screen` adds, or nil when nothing about pixels needs
    /// saying (an AX-rich window she did not ask pixels of).
    func attach() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard recorded, reason != nil || forced else { return nil }
        let why = reason.map { "thin accessibility: \($0)" } ?? "pixels:true"
        guard screenRecording else {
            return "Pixels (\(why)): screen_recording_not_trusted. No image was attached or permission prompt opened. The text read above retains its stated coverage. Request app {action:\"permissions.request\",args:{capability:\"screenRecording\",why:\"Allow NativeAgent to see the screen?\"}}; the owner decides."
        }
        guard !discarded else {
            return "Pixels (\(why)): capture_window_changed. The window changed during capture; no image was attached. The text read above retains its stated coverage. Use mac.look for the affected app to inspect its current state."
        }
        guard let png else {
            let recovery = captureRemedy.flatMap { try? $0.serialize(pretty: false) }
                ?? "Inspect the affected app's menu with mac.menu; correct the capture failure before another image request."
            return "Pixels (\(why)): \(unavailable ?? "capture_failed"). \(captureDetail ?? "No usable image was returned.") No image was attached. The text read above retains its stated coverage. \(recovery)"
        }
        guard LocalToolImage.sink != nil else {
            return "Pixels (\(why)): image_delivery_unavailable. This call cannot carry an image. The text read above retains its stated coverage; request pixels from a model tool turn if an image is needed."
        }
        var scope = "the window"
        if let region { scope = "\(region.name), cropped at higher detail" }
        // Same window, same region, byte-identical source frame → the image
        // already in her context stands. Checked before any decode or encode.
        let key = window + "|" + (region?.name ?? "")
        let fingerprint = SHA256.hash(data: Data(png.utf8)).map { String(format: "%02x", $0) }.joined()
        let turn = forced ? nil : ChatTurnExecution.current
        if let previousID = turn?.attachedPixelFrame(window: key, fingerprint: fingerprint),
           let previous = MacImageFrames.frame(previousID) {
            let frame = MacImageFrames.remember(previous.geometry, id: frameID)
            imageFrame = frame.fields
            turn?.notePixelsAttached(window: key, fingerprint: fingerprint, frameID: frameID)
            return "Pixels (\(why)): \(scope) is unchanged since its image was attached earlier this turn; not sent again. " + frame.words
        }
        guard let data = Data(base64Encoded: png), let image = VisionImageDecoder.decode(data) else {
            return "Pixels (\(why)): the window capture could not be decoded; the words above are all I have."
        }
        var source = (image: image, origin: origin, logicalSize: logicalSize)
        if let region, logicalSize.width > 0, logicalSize.height > 0 {
            let padX = max(24, region.frame.w * 0.25), padY = max(24, region.frame.h * 0.25)
            let crop = VisionImageCropper.crop(
                image,
                to: MacAXFrame(x: region.frame.x - padX, y: region.frame.y - padY,
                               w: region.frame.w + padX * 2, h: region.frame.h + padY * 2),
                origin: origin, logicalSize: logicalSize
            )
            source = (crop.image, crop.origin, crop.logicalSize)
        }
        guard let jpeg = Self.boundedJPEG(source.image) else {
            return "Pixels (\(why)): the image could not be fitted under \(Self.maxBytes / 1000) KB; none was attached."
        }
        // What it shows names it, so a newer look at the same window replaces it.
        let parts = window.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let app = parts.count > 1 && !parts[1].isEmpty ? parts[1] : parts.first ?? "the window"
        let title = parts.count > 2 && !parts[2].isEmpty && parts[2] != app ? " “" + parts[2] + "”" : ""
        let name = LocalToolImage.screenshotName(of: app + title + (region.map { ", " + $0.name } ?? ""), source: key)
        let delivered = LocalToolImage.deliverPNG(jpeg.data, name: name,
            width: jpeg.width, height: jpeg.height, mediaType: "image/jpeg")
        guard case .object(let result) = delivered, result["status"] == .string("ok") else {
            return "Pixels (\(why)): this result already carries its image limit; none was attached."
        }
        let placement = background ? "captured where it sits, nothing raised" : "the front window as shown"
        let attached = "Pixels attached (\(why)): one \(jpeg.width)×\(jpeg.height) JPEG, \(max(1, jpeg.data.count / 1000)) KB, of \(scope) (\(placement)). It follows this result."
        // The final size and the screen rect it covers travel together, so a point in it is a place.
        guard source.logicalSize.width > 0, source.logicalSize.height > 0 else { return attached }
        let frame = MacImageFrames.remember(MacScreenViewGeometry(
            bounds: MacAXFrame(x: source.origin.x, y: source.origin.y, w: source.logicalSize.width, h: source.logicalSize.height),
            pixelWidth: jpeg.width, pixelHeight: jpeg.height), id: frameID)
        imageFrame = frame.fields
        ChatTurnExecution.current?.notePixelsAttached(window: key, fingerprint: fingerprint, frameID: frameID, image: name)
        return attached + " " + frame.words
    }

    /// Long side ≤ 1024 px and ≤ 150 KB: quality steps first, then 3/4 scale.
    static func boundedJPEG(_ image: CGImage) -> (data: Data, width: Int, height: Int)? {
        let longest = max(image.width, image.height)
        guard longest > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var side = min(maxLongSide, longest)
        while side >= 128 {
            let scale = Double(side) / Double(longest)
            let width = max(1, Int((Double(image.width) * scale).rounded()))
            let height = max(1, Int((Double(image.height) * scale).rounded()))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            for quality in [0.8, 0.65, 0.5, 0.4] {
                let encoded = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    encoded, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(destination, scaled,
                    [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(destination), encoded.length > 0, encoded.length <= maxBytes {
                    return (encoded as Data, width, height)
                }
            }
            side = side * 3 / 4
        }
        return nil
    }
}

/// One dispatcher-owned temporal scene. It is deliberately in-memory and
/// rebuildable: stable target identity is perception continuity, not canonical
/// memory or authority. The same tracker instance is shared by every four-verb
/// observation from one chat dispatcher, while app/window keys keep unrelated
/// screens from borrowing identities.
struct VisionLiveSceneSnapshot: Sendable, Equatable {
    let identities: [VisionRect: VisionLiveRegionIdentity]
    let temporarilyNotVisible: [VisionLiveOccludedRegion]
}

actor SwiftToolDispatcherFourVerbLiveScene {
    private struct Track {
        let id: Int
        var frame: MacAXFrame
        var salience: Double
        var contrast: Double
        var colorName: String?
        var shapeName: String?
        var pointConfidence: Double
        var seenCount: Int
        var velocityX: Double
        var velocityY: Double
        // An appearance-only jump is not motion proof. Retain one bounded
        // hypothesis for association only; a third visible frame must confirm
        // its direction and speed before it can influence motor lead.
        var provisionalVelocityX: Double = 0
        var provisionalVelocityY: Double = 0
        var lastCapturedAt: Date
        var lastSeenGeneration: Int
        var lastSeenAt: Date
    }

    private struct Scene {
        var generation = 0
        var nextID = 1
        var tracks: [Track] = []
        var lastUpdated = Date.distantPast
    }

    private var scenes: [String: Scene] = [:]

    func identify(
        rows: [VisionAffordanceRow],
        frameSize: VisionSize,
        origin: (x: Double, y: Double),
        logicalSize: (width: Double, height: Double),
        sceneKey: String,
        capturedAt: Date = Date(),
        now: Date = Date()
    ) -> VisionLiveSceneSnapshot {
        let scaleX = frameSize.width > 0 ? logicalSize.width / frameSize.width : 1
        let scaleY = frameSize.height > 0 ? logicalSize.height / frameSize.height : 1
        func global(_ rect: VisionRect) -> MacAXFrame {
            MacAXFrame(
                x: origin.x + rect.x * scaleX,
                y: origin.y + rect.y * scaleY,
                w: rect.w * scaleX,
                h: rect.h * scaleY
            )
        }

        let key = sceneKey.isEmpty ? "unknown-screen" : sceneKey
        if scenes[key] == nil, scenes.count >= 12,
           let oldest = scenes.min(by: { $0.value.lastUpdated < $1.value.lastUpdated })?.key {
            scenes.removeValue(forKey: oldest)
        }
        var scene = scenes[key] ?? Scene()
        scene.generation += 1
        scene.lastUpdated = now
        var usedTrackIDs: Set<Int> = []
        var identities: [VisionRect: VisionLiveRegionIdentity] = [:]
        let redundantHaloIndexes = VisionPercept.redundantColorlessHaloIndexes(
            in: rows, frameSize: frameSize
        )
        let redundantSameColorIndexes = VisionPercept.redundantSameColorRegionIndexes(
            in: rows, frameSize: frameSize
        )
        let redundantVisualIndexes = redundantHaloIndexes.union(redundantSameColorIndexes)
        let linearIndicatorIndexes = VisionPercept.linearIndicatorIndexes(
            in: rows, frameSize: frameSize
        )
        let candidates = rows.enumerated()
            .filter {
                !redundantVisualIndexes.contains($0.offset)
                    && !linearIndicatorIndexes.contains($0.offset)
                    && VisionPercept.isPhysicalRegionCandidate($0.element, frameSize: frameSize)
            }
            .map(\.element)
            .sorted { lhs, rhs in
                let left = lhs.salience + (lhs.visualContrast ?? 0)
                let right = rhs.salience + (rhs.visualContrast ?? 0)
                return left == right ? lhs.rect.area > rhs.rect.area : left > right
            }

        let colorCounts = candidates.reduce(into: [String: Int]()) { counts, row in
            if let color = row.visualColor { counts[color, default: 0] += 1 }
        }
        for row in candidates {
            let frame = global(row.rect)
            var bestIndex: Int?
            var bestScore = -Double.infinity
            var bestAppearanceOnly = false
            var bestPredictionConsistent = false
            for index in scene.tracks.indices {
                let track = scene.tracks[index]
                guard !usedTrackIDs.contains(track.id),
                      scene.generation - track.lastSeenGeneration <= 6 else { continue }
                if let currentColor = row.visualColor,
                   let trackedColor = track.colorName,
                   currentColor != trackedColor {
                    continue
                }
                if let currentShape = row.visualShape,
                   let trackedShape = track.shapeName,
                   currentShape != trackedShape {
                    continue
                }
                let distance = Self.centerDistance(frame, track.frame)
                let largestDimension = max(max(frame.w, frame.h), max(track.frame.w, track.frame.h))
                let reach = max(48, min(220, largestDimension * 1.5))
                let overlap = Self.intersectionOverUnion(frame, track.frame)
                let appearance = Self.appearanceSimilarity(row: row, frame: frame, track: track)
                let elapsed = capturedAt.timeIntervalSince(track.lastCapturedAt)
                let confirmedSpeed = hypot(track.velocityX, track.velocityY)
                let provisionalSpeed = hypot(track.provisionalVelocityX, track.provisionalVelocityY)
                let usesProvisional = confirmedSpeed < 3 && provisionalSpeed >= 3
                    && track.lastSeenGeneration == scene.generation - 1
                let predictionVelocityX = usesProvisional ? track.provisionalVelocityX : track.velocityX
                let predictionVelocityY = usesProvisional ? track.provisionalVelocityY : track.velocityY
                let speed = hypot(predictionVelocityX, predictionVelocityY)
                let predictedTravel = speed * elapsed
                let predictionConsistent: Bool = {
                    guard track.seenCount >= 2,
                          elapsed >= 0.05,
                          elapsed <= 1.5,
                          speed >= 3,
                          predictedTravel <= max(440, largestDimension * 6) else { return false }
                    let predictedCenterX = track.frame.x + track.frame.w / 2
                        + predictionVelocityX * elapsed
                    let predictedCenterY = track.frame.y + track.frame.h / 2
                        + predictionVelocityY * elapsed
                    let residual = hypot(
                        frame.x + frame.w / 2 - predictedCenterX,
                        frame.y + frame.h / 2 - predictedCenterY
                    )
                    guard residual <= reach else { return false }
                    if usesProvisional {
                        guard elapsed <= 0.75 else { return false }
                        let observedX = (frame.x + frame.w / 2 - track.frame.x - track.frame.w / 2) / elapsed
                        let observedY = (frame.y + frame.h / 2 - track.frame.y - track.frame.h / 2) / elapsed
                        let observedSpeed = hypot(observedX, observedY)
                        guard observedSpeed >= speed * 0.65, observedSpeed <= speed * 1.5 else { return false }
                        let alignment = (observedX * predictionVelocityX + observedY * predictionVelocityY)
                            / (observedSpeed * speed)
                        return alignment >= 0.85
                    }
                    return true
                }()
                // A successful click may make one game object teleport. Its
                // spatial identity is then gone but its visual signature is
                // still the strongest evidence available. Preserve identity
                // only for a close size/salience/contrast match; weaker shapes
                // still require ordinary overlap, bounded motion, or a short
                // continuation of an already measured trajectory.
                guard overlap >= 0.05 || distance <= reach
                    || predictionConsistent || appearance >= 0.86 else { continue }
                let score = overlap * 4
                    + max(0, 1 - distance / reach)
                    + appearance * 1.5
                    + (predictionConsistent ? 2 : 0)
                    - min(0.5, distance / 1_000)
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                    bestPredictionConsistent = predictionConsistent
                    bestAppearanceOnly = overlap < 0.05 && distance > reach
                        && !predictionConsistent
                }
            }

            if let bestIndex {
                let previous = scene.tracks[bestIndex].frame
                let id = scene.tracks[bestIndex].id
                let elapsed = capturedAt.timeIntervalSince(scene.tracks[bestIndex].lastCapturedAt)
                let displacement = Self.centerDistance(frame, previous)
                let largestDimension = max(max(frame.w, frame.h), max(previous.w, previous.h))
                let boundedMotion = !bestAppearanceOnly
                    && elapsed >= 0.05
                    && elapsed <= 5
                    && (displacement <= max(220, largestDimension * 3)
                        || (bestPredictionConsistent
                            && displacement <= max(440, largestDimension * 6)))
                let velocityX = boundedMotion
                    ? ((frame.x + frame.w / 2) - (previous.x + previous.w / 2)) / elapsed
                    : 0
                let velocityY = boundedMotion
                    ? ((frame.y + frame.h / 2) - (previous.y + previous.h / 2)) / elapsed
                    : 0
                let uniqueColor = row.visualColor.map { colorCounts[$0] == 1 } ?? false
                let provisionalMotion = bestAppearanceOnly && uniqueColor
                    && elapsed >= 0.05 && elapsed <= 0.75
                    && displacement <= max(440, largestDimension * 6)
                scene.tracks[bestIndex].provisionalVelocityX = provisionalMotion
                    ? ((frame.x + frame.w / 2) - (previous.x + previous.w / 2)) / elapsed : 0
                scene.tracks[bestIndex].provisionalVelocityY = provisionalMotion
                    ? ((frame.y + frame.h / 2) - (previous.y + previous.h / 2)) / elapsed : 0
                // A slow target can remain on the same sampled pixel for one
                // frame. Do not let that quantization erase an established
                // trajectory used for next-frame association and brief
                // occlusion, but decay it quickly so a genuinely stopped
                // object becomes stationary. Motor lead below still uses only
                // this frame's observed displacement.
                let priorVelocityX = scene.tracks[bestIndex].velocityX
                let priorVelocityY = scene.tracks[bestIndex].velocityY
                let priorSpeed = hypot(priorVelocityX, priorVelocityY)
                let undersampledContinuity = scene.tracks[bestIndex].seenCount >= 2
                    && elapsed > 0
                    && elapsed < 0.05
                    && priorSpeed >= 3
                let retainedVelocityX = undersampledContinuity
                    ? priorVelocityX * 0.85
                    : boundedMotion && displacement < 3 && elapsed <= 0.5
                        ? priorVelocityX * 0.75
                        : velocityX
                let retainedVelocityY = undersampledContinuity
                    ? priorVelocityY * 0.85
                    : boundedMotion && displacement < 3 && elapsed <= 0.5
                        ? priorVelocityY * 0.75
                        : velocityY
                // Lead through the already-spent perception time plus a small
                // dispatch allowance. A first two-frame estimate gets a
                // conservative cap; an independently corroborated fast track
                // may lead up to one measured frame's travel, still bounded by
                // surface scale. A measured reversal gets no lead this
                // frame rather than projecting through its old direction.
                let horizon = min(0.75, max(0, now.timeIntervalSince(capturedAt)) + 0.05)
                let speed = hypot(velocityX, velocityY)
                let corroboratedVelocity = boundedMotion && elapsed <= 0.75
                    && priorSpeed >= 3 && speed >= priorSpeed * 0.65 && speed <= priorSpeed * 1.5
                    && (velocityX * priorVelocityX + velocityY * priorVelocityY) / (speed * priorSpeed) >= 0.9
                // Two positions describe a direction, not yet a stable
                // trajectory. When perception delay can carry the object past
                // its own radius, spend the existing third-frame opportunity
                // instead of ending acquisition on that first estimate.
                let needsMotionConfirmation = boundedMotion
                    && speed * horizon > max(4, min(frame.w, frame.h) / 2)
                    && !corroboratedVelocity
                let reversing = scene.tracks[bestIndex].seenCount >= 2
                    && priorSpeed >= 3
                    && velocityX * priorVelocityX + velocityY * priorVelocityY <= 0
                let rawX = displacement >= 3 && !reversing ? velocityX * horizon : 0
                let rawY = displacement >= 3 && !reversing ? velocityY * horizon : 0
                let rawDistance = hypot(rawX, rawY)
                let leadWidths = scene.tracks[bestIndex].seenCount >= 2 ? 2.0 : 0.75
                let ordinaryMaxLead = max(frame.w, frame.h) * leadWidths
                let corroboratedTravel = bestPredictionConsistent && boundedMotion
                    && elapsed <= 0.75 && !reversing
                    ? min(displacement, hypot(logicalSize.width, logicalSize.height) * 0.12)
                    : 0
                // A fixed object-width cap clipped real latency compensation
                // for small, fast objects. This extension requires the next
                // observed position to corroborate the prior trajectory; an
                // appearance jump alone still gets no extra motor authority.
                let maxLead = max(ordinaryMaxLead, corroboratedTravel)
                let leadScale = rawDistance > maxLead && rawDistance > 0 ? maxLead / rawDistance : 1
                let motionDescription: String? = {
                    if boundedMotion {
                        if let observed = Self.motion(
                            from: previous,
                            to: frame,
                            elapsed: elapsed,
                            logicalSize: logicalSize
                        ) {
                            return observed
                        }
                        if scene.tracks[bestIndex].seenCount >= 2,
                           priorSpeed < 3,
                           displacement < 3 {
                            return "stationary"
                        }
                        return nil
                    }
                    if undersampledContinuity {
                        return Self.motion(
                            velocityX: priorVelocityX,
                            velocityY: priorVelocityY,
                            logicalSize: logicalSize
                        )
                    }
                    let continuityReach = max(48, largestDimension * 1.5)
                    return elapsed >= 0.05 && elapsed <= 5 && displacement > continuityReach
                        ? "repositioned" : nil
                }()
                scene.tracks[bestIndex].frame = frame
                scene.tracks[bestIndex].salience = row.salience
                scene.tracks[bestIndex].contrast = row.visualContrast ?? 0
                scene.tracks[bestIndex].colorName = row.visualColor
                scene.tracks[bestIndex].shapeName = row.visualShape
                scene.tracks[bestIndex].pointConfidence = Self.pointConfidence(row)
                scene.tracks[bestIndex].seenCount += 1
                scene.tracks[bestIndex].velocityX = retainedVelocityX
                scene.tracks[bestIndex].velocityY = retainedVelocityY
                scene.tracks[bestIndex].lastCapturedAt = capturedAt
                scene.tracks[bestIndex].lastSeenGeneration = scene.generation
                scene.tracks[bestIndex].lastSeenAt = now
                usedTrackIDs.insert(id)
                identities[row.rect] = VisionLiveRegionIdentity(
                    id: id,
                    motion: motionDescription,
                    projectedX: rawX * leadScale,
                    projectedY: rawY * leadScale,
                    needsMotionConfirmation: needsMotionConfirmation
                )
            } else {
                let id = scene.nextID
                scene.nextID += 1
                scene.tracks.append(Track(
                    id: id,
                    frame: frame,
                    salience: row.salience,
                    contrast: row.visualContrast ?? 0,
                    colorName: row.visualColor,
                    shapeName: row.visualShape,
                    pointConfidence: Self.pointConfidence(row),
                    seenCount: 1,
                    velocityX: 0,
                    velocityY: 0,
                    lastCapturedAt: capturedAt,
                    lastSeenGeneration: scene.generation,
                    lastSeenAt: now
                ))
                usedTrackIDs.insert(id)
                identities[row.rect] = VisionLiveRegionIdentity(id: id)
            }
        }

        let temporarilyNotVisible = scene.tracks.compactMap { track -> VisionLiveOccludedRegion? in
            let missed = scene.generation - track.lastSeenGeneration
            guard !usedTrackIDs.contains(track.id),
                  missed >= 1,
                  missed <= 2,
                  track.seenCount >= 2,
                  track.pointConfidence >= 0.25,
                  now.timeIntervalSince(track.lastSeenAt) <= 3,
                  logicalSize.width > 0,
                  logicalSize.height > 0 else { return nil }
            let centerX = (track.frame.x + track.frame.w / 2 - origin.x) / logicalSize.width
            let centerY = (track.frame.y + track.frame.h / 2 - origin.y) / logicalSize.height
            let predictionElapsed = capturedAt.timeIntervalSince(track.lastCapturedAt)
            let predicted: (x: Int, y: Int)? = {
                let speed = hypot(track.velocityX, track.velocityY)
                let travel = speed * predictionElapsed
                guard track.seenCount >= 2,
                      predictionElapsed >= 0.05,
                      predictionElapsed <= 1.5,
                      speed >= 3,
                      travel <= max(track.frame.w, track.frame.h) * 3 else { return nil }
                let predictedCenterX = track.frame.x + track.frame.w / 2
                    + track.velocityX * predictionElapsed
                let predictedCenterY = track.frame.y + track.frame.h / 2
                    + track.velocityY * predictionElapsed
                return (
                    min(100, max(0, Int((((predictedCenterX - origin.x) / logicalSize.width) * 100).rounded()))),
                    min(100, max(0, Int((((predictedCenterY - origin.y) / logicalSize.height) * 100).rounded())))
                )
            }()
            return VisionLiveOccludedRegion(
                id: track.id,
                colorName: track.colorName,
                shapeName: track.shapeName,
                lastCenterXPercent: min(100, max(0, Int((centerX * 100).rounded()))),
                lastCenterYPercent: min(100, max(0, Int((centerY * 100).rounded()))),
                expectedCenterXPercent: predicted?.x,
                expectedCenterYPercent: predicted?.y,
                missedFrames: missed,
                confidence: track.pointConfidence * (missed == 1 ? 0.8 : 0.6)
            )
        }.sorted { $0.id < $1.id }
        scene.tracks.removeAll {
            scene.generation - $0.lastSeenGeneration > 8
                || now.timeIntervalSince($0.lastSeenAt) > 20
        }
        scenes[key] = scene
        return VisionLiveSceneSnapshot(
            identities: identities,
            temporarilyNotVisible: Array(temporarilyNotVisible.prefix(4))
        )
    }

    private static func pointConfidence(_ row: VisionAffordanceRow) -> Double {
        min(row.confidence.bounds, max(row.salience, row.visualContrast ?? 0))
    }

    private static func centerDistance(_ lhs: MacAXFrame, _ rhs: MacAXFrame) -> Double {
        let dx = (lhs.x + lhs.w / 2) - (rhs.x + rhs.w / 2)
        let dy = (lhs.y + lhs.h / 2) - (rhs.y + rhs.h / 2)
        return hypot(dx, dy)
    }

    private static func appearanceSimilarity(
        row: VisionAffordanceRow,
        frame: MacAXFrame,
        track: Track
    ) -> Double {
        func ratio(_ lhs: Double, _ rhs: Double) -> Double {
            guard lhs > 0, rhs > 0 else { return 0 }
            return min(lhs, rhs) / max(lhs, rhs)
        }
        let size = (ratio(frame.w, track.frame.w) + ratio(frame.h, track.frame.h)) / 2
        let salience = 1 - min(1, abs(row.salience - track.salience) / 0.25)
        let contrast = 1 - min(1, abs((row.visualContrast ?? 0) - track.contrast) / 0.25)
        let color: Double
        switch (row.visualColor, track.colorName) {
        case let (current?, previous?): color = current == previous ? 1 : 0
        case (nil, nil): color = 0.5
        default: color = 0.25
        }
        return size * 0.45 + salience * 0.20 + contrast * 0.15 + color * 0.20
    }

    private static func intersectionOverUnion(_ lhs: MacAXFrame, _ rhs: MacAXFrame) -> Double {
        let left = max(lhs.x, rhs.x)
        let top = max(lhs.y, rhs.y)
        let right = min(lhs.x + lhs.w, rhs.x + rhs.w)
        let bottom = min(lhs.y + lhs.h, rhs.y + rhs.h)
        let intersection = max(0, right - left) * max(0, bottom - top)
        guard intersection > 0 else { return 0 }
        let union = lhs.w * lhs.h + rhs.w * rhs.h - intersection
        return union > 0 ? intersection / union : 0
    }

    private static func motion(
        from previous: MacAXFrame,
        to current: MacAXFrame,
        elapsed: TimeInterval,
        logicalSize: (width: Double, height: Double)
    ) -> String? {
        let dx = (current.x + current.w / 2) - (previous.x + previous.w / 2)
        let dy = (current.y + current.h / 2) - (previous.y + previous.h / 2)
        guard hypot(dx, dy) >= 3 else { return nil }
        let horizontal = dx > 2 ? "right" : dx < -2 ? "left" : nil
        let vertical = dy > 2 ? "down" : dy < -2 ? "up" : nil
        let direction = [vertical, horizontal].compactMap { $0 }.joined(separator: "-")
        let normalizedSpeed: Double = {
            guard elapsed > 0, logicalSize.width > 0, logicalSize.height > 0 else { return 0 }
            return hypot(dx / logicalSize.width, dy / logicalSize.height) / elapsed
        }()
        let pace = normalizedSpeed >= 0.20 ? " quickly"
            : normalizedSpeed < 0.04 ? " slowly" : ""
        return direction.isEmpty ? "moving\(pace)" : "moving \(direction)\(pace)"
    }

    private static func motion(
        velocityX: Double,
        velocityY: Double,
        logicalSize: (width: Double, height: Double)
    ) -> String? {
        guard hypot(velocityX, velocityY) >= 3 else { return nil }
        let horizontal = velocityX > 3 ? "right" : velocityX < -3 ? "left" : nil
        let vertical = velocityY > 3 ? "down" : velocityY < -3 ? "up" : nil
        let direction = [vertical, horizontal].compactMap { $0 }.joined(separator: "-")
        let normalizedSpeed: Double = {
            guard logicalSize.width > 0, logicalSize.height > 0 else { return 0 }
            return hypot(
                velocityX / logicalSize.width,
                velocityY / logicalSize.height
            )
        }()
        let pace = normalizedSpeed >= 0.20 ? " quickly"
            : normalizedSpeed < 0.04 ? " slowly" : ""
        return direction.isEmpty ? "moving\(pace)" : "moving \(direction)\(pace)"
    }
}
