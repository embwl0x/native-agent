import Foundation
import NativeAgentShared
import CoreGraphics
import AgentWorkspace
import MacControl
import PersistenceCore
import Senses
import ChatTurnContracts
import MemoryV2
import NativeAgentCore
import ProviderRouting
import ToolRegistry
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Dispatcher
import AgentConversations
import StandingBots
// Blueprint: | `WindowObservation.swift` | `SwiftToolDispatcherFourVerbPerceptionSource` struct; native masked window observation, structural and visual recognition, live preview and obstruction exclusion |

/// Fuses MacControl's live capture and Vision recognition into one four-verb supplement.
struct SwiftToolDispatcherFourVerbPerceptionSource: MacFourVerbsSupplementalPerceptionSource {
    let host: any MacControlClient
    let liveScene: SwiftToolDispatcherFourVerbLiveScene
    let obstructionProbe = SystemMacVisualObstructionProbe()
    /// Call-local caption keeps words and frame on the same verb.
    /// Nil names the resolved app, as a bare `screen` does.
    let previewCaption: String?
    /// Screen's captured frame and thin-AX reason, attached by the dispatcher after the verb.
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
                    output["message"]?.stringValue ?? "The requested screen capture failed.").remedy(app: requestedApp, part: pixels?.part)
            }
            return MacFourVerbsSupplement(diagnostics: ["error": .string(result.error ?? "capture_failed"),
                "message": output["message"] ?? .string("The requested screen capture failed."), "remedy": remedy])
        }
        guard result.ok, case .object(let output) = result.output,
              let frameID = output["frame_id"]?.stringValue else { return nil }

        let viewId = output["view"]?.stringValue
        let marks = (output["marks"]?.arrayValue ?? [])
        let app = (output["app"]?.objectValue ?? [:])
        let appName = app["name"]?.stringValue
        let bundleIdentifier = app["bundle_id"]?.stringValue
        let originObject = (output["origin"]?.objectValue ?? [:])
        let logicalObject = (output["logical_size"]?.objectValue ?? [:])
        let imageOriginObject = (output["image_origin"]?.objectValue ?? [:])
        let imageLogicalObject = (output["image_logical_size"]?.objectValue ?? [:])
        let pointerObject = (output["pointer"]?.objectValue ?? [:])
        let pointer: MacPointerPosition? = {
            guard let x = pointerObject["x"]?.numberValue(coercingStrings: false, finiteOnly: true), let y = pointerObject["y"]?.numberValue(coercingStrings: false, finiteOnly: true) else { return nil }
            return MacPointerPosition(x: x, y: y)
        }()
        let visibleFrame: MacAXFrame? = {
            guard let x = originObject["x"]?.numberValue(coercingStrings: false, finiteOnly: true), let y = originObject["y"]?.numberValue(coercingStrings: false, finiteOnly: true),
                  let w = logicalObject["w"]?.numberValue(coercingStrings: false, finiteOnly: true), let h = logicalObject["h"]?.numberValue(coercingStrings: false, finiteOnly: true),
                  w > 0, h > 0 else { return nil }
            return MacAXFrame(x: x, y: y, w: w, h: h)
        }()
        let targetPID = Int32(app["pid"]?.numberValue(coercingStrings: false, finiteOnly: true) ?? 0)
        // Every window over this one, whatever the capture shows (a window-only
        // capture has no covering pixels). The probe leaves out her Shotgun and
        // pointer (PersonOnlyWindows); another app's window there would take
        // her hand, while the app's own sheets, menus and panels are its own.
        let covering = targetPID > 0 ? (visibleFrame.map { obstructionProbe.obstructions(over: $0, targetPID: targetPID) } ?? []) : []
        let handObstructions = covering.filter { $0.ownerPID != targetPID }.map(\.frame)
        let structural = structuralSupplement(
            marks: marks,
            menus: (output["transient_menus"]?.arrayValue ?? []),
            viewId: viewId,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            visibleFrame: visibleFrame,
            pointer: pointer,
            obstructions: handObstructions
        )

        let png = output["image"]?.stringValue
        let image: CGImage? = {
            guard MacScreenPreviewBus.publish != nil || pixels != nil || output["recognize_pixels"] == .bool(true),
                  let png, let data = Data(base64Encoded: png) else { return nil }
            return VisionImageDecoder.decode(data)
        }()
        if let publish = MacScreenPreviewBus.publish {
            await publishPreview(image: image, appName: appName, publish: publish)
        }

        // The view graded its own AX read (Chromium and incomplete reads are never thin).
        let thinReason = output["thin_accessibility_reason"]?.stringValue
        // Independent-window capture contains no covering app pixels to exclude.
        let obstructions = output["capture_isolated_window"] == .bool(true) ? [] : covering
        if let pixels {
            let title = output["window_title"]?.stringValue ?? ""
            let windowFrame = visibleFrame.map { "\(Int($0.x)),\(Int($0.y)),\(Int($0.w))x\(Int($0.h))" } ?? ""
            pixels.record(
                frameID: frameID,
                reason: thinReason,
                screenRecording: output["screen_recording_trusted"]?.boolValue ?? false,
                png: png, image: image,
                unavailable: output["image_unavailable_reason"]?.stringValue,
                origin: ((imageOriginObject["x"] ?? originObject["x"])?.numberValue(coercingStrings: false, finiteOnly: true) ?? 0,
                         (imageOriginObject["y"] ?? originObject["y"])?.numberValue(coercingStrings: false, finiteOnly: true) ?? 0),
                logicalSize: ((imageLogicalObject["w"] ?? logicalObject["w"])?.numberValue(coercingStrings: false, finiteOnly: true) ?? 0,
                              (imageLogicalObject["h"] ?? logicalObject["h"])?.numberValue(coercingStrings: false, finiteOnly: true) ?? 0),
                background: output["capture_isolated_window"] == .bool(true),
                window: [bundleIdentifier ?? "", appName ?? "", title, windowFrame].joined(separator: "|"),
                captureDetail: output["message"]?.stringValue, captureRemedy: output["remedy"]
            )
            if let mainPicture = frame(output["semantic_focus_frame"]) {
                pixels.focus(name: "the window's main picture area", frame: mainPicture)
            }
        }
        // The view decides whether this window needs pixel perception.
        guard output["recognize_pixels"] == .bool(true),
              let image,
              let originX = (imageOriginObject["x"] ?? originObject["x"])?.numberValue(coercingStrings: false, finiteOnly: true),
              let originY = (imageOriginObject["y"] ?? originObject["y"])?.numberValue(coercingStrings: false, finiteOnly: true),
              let logicalW = (imageLogicalObject["w"] ?? logicalObject["w"])?.numberValue(coercingStrings: false, finiteOnly: true),
              let logicalH = (imageLogicalObject["h"] ?? logicalObject["h"])?.numberValue(coercingStrings: false, finiteOnly: true),
              logicalW > 0, logicalH > 0 else {
            return structural
        }

        #if canImport(Vision)
        do {
            let visualCompileStartedNs = DispatchTime.now().uptimeNanoseconds
            let appName = ((output["app"]?.objectValue ?? [:])["name"])?.stringValue
            let title = output["window_title"]?.stringValue
            let origin = (x: originX, y: originY)
            let logicalSize = (width: logicalW, height: logicalH)
            let geometry = MacScreenViewGeometry(bounds: MacAXFrame(x: originX, y: originY, w: logicalW, h: logicalH),
                pixelWidth: image.width, pixelHeight: image.height)
            let excludedRegions = obstructions.map { geometry.imageRect($0.frame) }
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
                geometry: geometry,
                sceneKey: sceneKey,
                capturedAt: capturedAt
            )
            let vision = percept.fourVerbSupplement(
                geometry: geometry,
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
                    kind: content.kind,
                    rows: content.rows.map { row in
                        guard row.physicalOnly, let label = row.label?.display,
                              blockedPhysicalLabels.contains(label) else { return row }
                        return MacScreenRender.Row(
                            label: row.label, detail: row.detail, provenance: row.provenance,
                            abstain: "projected target covered by foreground window; observe again",
                            sourceAXPath: row.sourceAXPath
                        )
                    },
                    canvas: content.canvas
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
        return NativeTimestampFormat.parseISO8601FractionalFirst(text) ?? fallback
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
            let menu = (menuValue.objectValue ?? [:])
            let truncated = menu["truncated"]?.boolValue == true
            let note = truncated ? "Open native menu (item list truncated)" : "Open native menu"
            values.append(MacScreenRender.Value(text: MacScreenText(note), provenance: .ax))
            for itemValue in (menu["items"]?.arrayValue ?? []).prefix(MacTransientMenus.maxItems) {
                let item = (itemValue.objectValue ?? [:])
                guard item["role"]?.stringValue == "AXMenuItem", let rect = frame(item["frame"]) else { continue }
                let label = screenText(item["label"]) ?? MacScreenText("")
                let enabled = item["enabled"]?.boolValue ?? false
                let states = (enabled ? [] : ["disabled"]) + (item["selected"]?.boolValue == true ? ["selected"] : [])
                controls.append(MacScreenRender.Control(
                    label: label, kind: "menu item", states: states, provenance: .ax
                ))
                targets.append(MacFourVerbsSupplementalTarget(
                    label: label, kind: "menu item", frame: rect, provenance: .ax, enabled: enabled, role: "AXMenuItem",
                    actions: (item["actions"]?.arrayValue ?? []).compactMap { $0.stringValue }
                ))
            }
        }

        for markValue in marks {
            let mark = (markValue.objectValue ?? [:])
            guard let role = mark["role"]?.stringValue,
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
            let enabled = mark["enabled"]?.boolValue ?? true
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
                secret: mark["secret_field"]?.boolValue == true,
                frame: frame,
                provenance: .ax,
                viewId: viewId,
                mark: Int(number),
                ordinal: isRow ? rows.count : nil,
                sourceAXPath: sourceAXPath,
                enabled: enabled,
                role: role,
                actions: (mark["actions"]?.arrayValue ?? []).compactMap { $0.stringValue },
                settableAttributes: (mark["settable_attributes"]?.arrayValue ?? []).compactMap { $0.stringValue }
            ))
        }

        let contents = rows.isEmpty ? [] : [MacScreenRender.Content(
            kind: .list,
            rows: rows
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

    /// Publishes the held frame masked and downscaled; missing pixels still update the caption.
    /// The card retains its previous image when capture has none.
    private func publishPreview(
        image: CGImage?,
        appName: String?,
        publish: @Sendable (MacScreenPreviewUpdate) async -> Void
    ) async {
        let caption = previewCaption ?? MacScreenPreviewCaption.looking(at: appName)
        guard let image,
              let preview = MacScreenPreviewFrame.previewImage(from: image) else {
            await publish(MacScreenPreviewUpdate(image: nil, caption: caption, at: Date()))
            return
        }
        await publish(MacScreenPreviewUpdate(image: preview, caption: caption, at: Date()))
    }

    private func integer(_ value: JSONValue?) -> Int64? {
        if case .double(let number)? = value, number != number.rounded() { return nil }
        return value?.integerValue
    }

    private func frame(_ value: JSONValue?) -> MacAXFrame? {
        let object = (value?.objectValue ?? [:])
        guard let x = object["x"]?.numberValue(coercingStrings: false, finiteOnly: true), let y = object["y"]?.numberValue(coercingStrings: false, finiteOnly: true),
              let w = object["w"]?.numberValue(coercingStrings: false, finiteOnly: true), let h = object["h"]?.numberValue(coercingStrings: false, finiteOnly: true),
              w > 0, h > 0 else { return nil }
        return MacAXFrame(x: x, y: y, w: w, h: h)
    }

    private func screenText(_ value: JSONValue?) -> MacScreenText? {
        switch value {
        case .string(let clear)?: return MacScreenText(clear, redacted: .string(clear))
        case .object?: return MacScreenText("⟨withheld⟩", redacted: value)
        default: return nil
        }
    }
}
