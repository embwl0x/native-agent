import Foundation
import NativeAgentShared
import Senses
import NativeAgentCore
import PersistenceCore
import TrustCenter
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ApplicationServices)
import ApplicationServices
import UserNotifications
import Experiences
import CryptoKit
import os
import CoreText
import ScreenCaptureKit
#endif
// Blueprint: | `MacFusedObservation.swift` | Fused semantic and marked-image capture |
extension SwiftNativeMacControl {
    /// `view` — ONE frozen scene: the picture and the structure together, with
    /// every actionable element numbered on the image and the same number bound
    /// to its real AX path in the legend.
    ///
    /// The two perceptions are taken as close together as the machine allows
    /// (window rect → capture → AX walk, all in-process) and the residual gap
    /// is REPORTED as `fusion_gap_ms` rather than claimed to be zero. A stale
    /// pairing — marks drawn from one moment onto a picture from another — is
    /// the bug this whole tool exists to avoid, so the honest number matters:
    /// a large gap is a reason to look again, and only the caller can judge it.
    ///
    /// AX-only reads can supply structure without pixels. Releasing pixels
    /// additionally requires Screen Recording and complete AX secret coverage;
    /// a missing grant or incomplete coverage is reported without an image.
    func handleView(_ body: [String: JSONValue]) async -> MacControlResult {
        let read = await screenViewStore.read { await self.captureView(body) }
        let result = read.value
        guard !read.published, case .object(var output) = result.output,
              output["view_current"] == .bool(true) else { return result }
        output["view"] = .null
        output["view_current"] = .bool(false)
        output["view_note"] = .string(result.ok
            ? "This capture was superseded or invalidated while in flight. Its image and legend are diagnostic only; take a fresh view before acting."
            : "This capture failed; no new view was published. Its image and legend are diagnostic only.")
        return MacControlResult(ok: false, action: result.action, output: .object(output),
            error: result.ok ? "view_capture_superseded" : result.error, durationMs: result.durationMs)
    }
    private func captureView(_ body: [String: JSONValue]) async -> (MacControlResult, MacScreenViewSnapshot?) {
        let started = now()
        let viewStartedNs = DispatchTime.now().uptimeNanoseconds
        var anchorPid: Int32?
        let walked = MacSightCaptureBinding.current?.walked
        if walked == nil, let requested = body["app"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requested.isEmpty {
            guard accessibilitySource.isTrusted() else { return (axUntrustedResult(action: "view"), nil) }
            let resolution = MacBackgroundSight.resolve(requested, among: accessibilitySource.runningApps())
            guard case .matched(let app) = resolution else {
                let code = resolution.failureCode ?? "app_not_running"
                return (MacControlResult(ok: false, action: "view", output: .object([
                    "error": .string(code),
                    "message": .string(MacBackgroundSight.words(for: resolution, requested: requested) ?? code),
                ]), error: code, durationMs: 0), nil)
            }
            anchorPid = app.processIdentifier
        }
        func cancelledResult() -> (MacControlResult, MacScreenViewSnapshot?) {
            (MacControlResult(
                ok: false, action: "view",
                output: .object([
                    "view": .null, "view_current": .bool(false), "image": .null,
                    "view_note": .string("This screen request was cancelled; no new view was published."),
                ]),
                error: "view_capture_cancelled",
                durationMs: Int(now().timeIntervalSince(started) * 1000)
            ), nil)
        }
        guard !Task.isCancelled else { return cancelledResult() }
        guard !Task.isCancelled else { return cancelledResult() }
        func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Int64 {
            Int64((end &- start) / 1_000_000)
        }
        // The four-verb semantic screen consumes the same frozen capture as
        // mac_view, but its visual compiler must see the world rather than the
        // human-facing numbered ink we draw on top of it. This is an internal
        // rendering choice only: geometry, AX marks, redaction, permissions,
        // view storage, and the public result contract remain unchanged.
        let semanticRawFrame = body["semantic_raw_frame"] == .bool(true)
        let semanticFocusVisualSurface = body["semantic_focus_visual_surface"] == .bool(true)
        let scope: MacScreenCaptureScope = {
            if case .bool(true)? = body["full_screen"] { return .fullScreen }
            if (body["scope"]?.stringValue ?? "").lowercased() == "full_screen" { return .fullScreen }
            return .focusedWindow
        }()
        let limits = Self.axLimits(from: body)
        let maxMarks = body["max_marks"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacScreenViewBuilder.hardMaxMarks
        let maxImageBytes = min(
            body["max_image_bytes"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacScreenViewBuilder.hardMaxImageBytes,
            MacScreenViewBuilder.hardMaxImageBytes
        )
        let accessibilityTrusted = accessibilitySource.isTrusted()
        let screenTrusted = screenCaptureSource.isScreenRecordingTrusted()
        // 1. Where to look. The window rect comes from AX (the root node's own
        //    frame), so the capture is exactly the window — not a guessed crop.
        let axSnapshotStartedNs = DispatchTime.now().uptimeNanoseconds
        let binding = MacSightCaptureBinding.current
        var windowRect: MacAXFrame?
        var app: MacAXAppInfo?
        var windowTitle: String?
        var snapshot: MacAXTreeSnapshot?
        var redactionRoot: MacAXElementRef?
        var windowIdentity: MacAXWindowIdentity?
        var axSelfRefused = false
        if accessibilityTrusted {
            // A sight's view is the look's own complete walk; any other semantic
            // capture grades the same complete AX mechanism as look. The legacy
            // public view keeps its existing bounded walk.
            switch walked.map({ MacAnchoredRead.read($0.read) })
                ?? anchoredSnapshot(limits: limits, pid: anchorPid, window: nil, complete: semanticRawFrame) {
            case .read(let read):
                snapshot = read.snapshot
                redactionRoot = read.root
                windowIdentity = read.windowIdentity
                app = read.app
                windowTitle = read.rootTitle
                windowRect = read.snapshot.nodes.first?.attributes.frame
            case .selfProcess:
                // The view degrades to pixels-only, like an untrusted AX read:
                // the capture is still honest, only the tree is refused.
                axSelfRefused = true
            case .appGone, .windowGone, .windowDrifted:
                break
            }
        }
        guard anchorPid == nil || (windowRect != nil && windowIdentity != nil && scope == .focusedWindow) else {
            return (MacControlResult(ok: false, action: "view", output: .object([
                "error": .string("named_window_unavailable"),
                "message": .string("The named app has no readable window frame; no desktop image was substituted."),
            ]), error: "named_window_unavailable", durationMs: 0), nil)
        }
        func discardUnboundCapture() async -> (MacControlResult, MacScreenViewSnapshot?) {
            return (MacControlResult(ok: false, action: "view", output: .object([
                "view": .null, "image": .null, "view_current": .bool(false),
                "message": .string("The observed window or look generation changed; the pixel supplement was discarded."),
            ]), error: "observation_changed", durationMs: 0), nil)
        }
        if let binding {
            guard let expected = await lookFrameStore.frame(frameId: binding.frameID),
                  let identity = expected.windowIdentity, identity == windowIdentity,
                  now().timeIntervalSince(expected.capturedAt) <= MacLookFrameStore.ttlSeconds else {
                return await discardUnboundCapture()
            }
        }
        let isolatedWindow = anchorPid != nil || binding != nil
        let transientMenus = isolatedWindow ? [] : app.map {
            MacTransientMenus.read(source: accessibilitySource, pid: $0.processIdentifier)
        } ?? []
        let axSnapshotFinishedNs = DispatchTime.now().uptimeNanoseconds
        guard !Task.isCancelled else { return cancelledResult() }
        let captureRect: MacAXFrame? = (scope == .fullScreen) ? nil
            : MacTransientMenus.captureFrame(window: windowRect, menus: transientMenus)
        // With no picture there is still a frame of reference: the window rect
        // itself, at 1 point per pixel — so the legend is complete and only the
        // drawing is missing.
        let axGeometry: MacScreenViewGeometry? = {
            guard let rect = captureRect ?? windowRect,
                  rect.x.isFinite, rect.y.isFinite, rect.w > 0, rect.h > 0,
                  let width = Int(exactly: rect.w.rounded()), width > 0,
                  let height = Int(exactly: rect.h.rounded()), height > 0 else { return nil }
            return MacScreenViewGeometry(
                bounds: rect,
                pixelWidth: width,
                pixelHeight: height
            )
        }()
        // 2. Number the actionable elements, and read what the window SAYS.
        //
        // Structured controls and prose support action without pixels; always build both.
        var sceneSelectionStartedNs = DispatchTime.now().uptimeNanoseconds
        var sceneSelectionFinishedNs = sceneSelectionStartedNs
        var selection = MacScreenViewBuilder.Selection(marks: [], omitted: 0, offscreen: 0)
        var text = MacScreenViewBuilder.TextSelection(items: [], omitted: 0)
        var marks: [JSONValue] = []
        var texts: [JSONValue] = []
        func select(in geometry: MacScreenViewGeometry?) {
            sceneSelectionStartedNs = DispatchTime.now().uptimeNanoseconds
            defer { sceneSelectionFinishedNs = DispatchTime.now().uptimeNanoseconds }
            guard let snapshot, let geometry else { return }
            selection = MacScreenViewBuilder.select(
                nodes: snapshot.nodes,
                geometry: geometry,
                maxMarks: maxMarks,
                settableAttributes: { node in
                    node.element.map { accessibilitySource.settableAttributes(of: $0) } ?? []
                }
            )
            text = MacScreenViewBuilder.visibleText(
                nodes: snapshot.nodes,
                geometry: geometry,
                limit: body["max_text_items"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacScreenViewBuilder.hardMaxTextItems
            )
            marks = selection.marks.map { $0.toJSON(valueChars: limits.valueChars) }
            texts = text.items.map { $0.toJSON(valueChars: limits.valueChars) }
        }
        // A semantic view numbers its window from the AX read itself, so that
        // read decides once, before any capture, who receives a picture: the
        // caller that always wants one (`pixels: always` — a forced attachment
        // or a bound live preview), a `screen` attachment of a thin window
        // (`pixels: thin`), or on-device recognition of a thin window the AX
        // marks do not already cover. An app read's retained text recognition
        // needs the shot but no picture. A public view always delivers its picture.
        var thinReason: String?
        var recognizesPixels = false
        var semanticFocusFrame: MacAXFrame?
        var pictured = true
        if semanticRawFrame {
            select(in: axGeometry)
            let words = (snapshot?.nodes ?? []).filter { MacPerceptionCompiler.readoutRoles.contains($0.attributes.role) }
                .compactMap { $0.attributes.title ?? $0.attributes.value }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if semanticFocusVisualSurface, let snapshot, let axGeometry {
                semanticFocusFrame = MacScreenViewBuilder.dominantVisualSurface(nodes: snapshot.nodes, geometry: axGeometry)
            }
            // Chromium renderer content belongs to the renderer's AX read,
            // including a pending one; an incomplete read is reported as such.
            // Pixels never quietly replace either.
            let canvas = semanticFocusFrame ?? selection.marks
                .filter { MacScreenViewBuilder.visualSurfaceRoles.contains($0.role) }.map(\.frame)
                .max { $0.w * $0.h < $1.w * $1.h }
            let windowArea = axGeometry.map { $0.bounds.w * $0.bounds.h } ?? 0
            let canvasFraction = canvas.flatMap { windowArea > 0 ? min(1, $0.w * $0.h / windowArea) : nil }
            thinReason = MacChromiumAccessibility.looksChromium(bundleId: app?.bundleIdentifier, pid: app?.processIdentifier, snapshot: nil)
                || snapshot?.truncated == true ? nil : MacScreenViewBuilder.thinAccessibilityReason(
                    accessibilityTrusted: accessibilityTrusted, marks: marks, texts: texts, windowArea: windowArea,
                    canvasFraction: canvasFraction,
                    sourceTextCount: words.count, sourceTextCharacters: words.reduce(0) { $0 + $1.count })
            // Recognition earns its latency only where the marks are few or a
            // visual surface is real; a thin window full of marks is read from them.
            recognizesPixels = thinReason != nil
                && (!accessibilityTrusted || selection.marks.count <= 6 || (canvasFraction ?? 0) >= 0.03)
            pictured = body["pixels"] == .string("always") || recognizesPixels
                || thinReason != nil && body["pixels"] == .string("thin")
        }
        let recognizesText = semanticRawFrame && scope == .focusedWindow && app?.bundleIdentifier != nil
            && SenseAppReadCapture.current != nil
        guard !Task.isCancelled else { return cancelledResult() }
        // Presentation caps never define pixel redaction coverage. Inspect the
        // entire captured window (and open menus) under the shared read deadline.
        // Full-desktop pixels have no complete AX owner here; report that gap.
        var redactionNodes: [MacAXNode] = []
        if pictured {
            let deadline = now().addingTimeInterval(MacAXLimits.readSeconds)
            let covered = MacAXLimits.$readDeadline.withValue(deadline) { () -> Bool in
                guard scope == .focusedWindow, accessibilityTrusted, let redactionRoot else { return false }
                let roots = [redactionRoot] + (isolatedWindow ? [] : app.map {
                    accessibilitySource.transientMenuRoots(pid: $0.processIdentifier)
                } ?? [])
                for root in roots {
                    guard let nodes = try? MacScreenViewTextRedaction.inspectSecretFields(
                        source: accessibilitySource, root: root, deadline: deadline, nonnegativeFrames: false
                    ) else { return false }
                    redactionNodes += nodes
                }
                return now() < deadline
            }
            guard covered else {
                return (MacControlResult(ok: false, action: "view", output: .object([
                    "view": .null, "view_current": .bool(false), "image": .null,
                    "message": .string("Complete secret-field coverage could not be established for these pixels. No image was released; inspect a readable app window with Accessibility enabled.")
                ]), error: "redaction_coverage_unavailable", durationMs: Int(now().timeIntervalSince(started) * 1000)), nil)
            }
        }
        let capturedAt = now()
        let screenCaptureStartedNs = DispatchTime.now().uptimeNanoseconds
        var shot: MacScreenShot?
        var imageFailure: MacScreenCaptureFailure?
        if pictured || recognizesText {
            let capture: Result<MacScreenShot, MacScreenCaptureFailure>
            if isolatedWindow, let windowIdentity {
                capture = await screenCaptureSource.capture(window: windowIdentity)
            } else {
                capture = await screenCaptureSource.capture(rect: captureRect)
            }
            switch capture {
            case .success(let value): shot = value
            case .failure(let failure): imageFailure = failure
            }
        }
        guard !Task.isCancelled else { return cancelledResult() }
        let screenCaptureFinishedNs = DispatchTime.now().uptimeNanoseconds
        let observedPointer = isolatedWindow ? nil : pointerPositionSource.currentPosition()
        let fusionGapMs = Int(abs(now().timeIntervalSince(capturedAt)) * 1000)
        var output: [String: JSONValue] = [
            "accessibility_trusted": .bool(accessibilityTrusted),
            "screen_recording_trusted": .bool(screenTrusted),
            "scope": .string(scope.rawValue),
            "capture_isolated_window": .bool(isolatedWindow),
            "app": app?.toJSON() ?? .null,
            "transient_menus": MacTransientMenus.json(transientMenus),
            "pointer": observedPointer?.json ?? .null,
            // Window titles bypass visibleText's role filter, so apply the legend redactor separately.
            "window_title": windowTitle.map {
                MacScreenViewTextRedaction.redactedLegendString(
                    $0,
                    valueChars: limits.valueChars
                )
            } ?? .null,
            "fusion_gap_ms": .int(Int64(fusionGapMs)),
            "ax_snapshot_ms": .int(elapsedMilliseconds(
                from: axSnapshotStartedNs, to: axSnapshotFinishedNs
            )),
            "screen_capture_ms": .int(elapsedMilliseconds(
                from: screenCaptureStartedNs, to: screenCaptureFinishedNs
            )),
        ]
        output["thin_accessibility_reason"] = thinReason.map(JSONValue.string)
        if recognizesPixels { output["recognize_pixels"] = .bool(true) }
        if !accessibilityTrusted {
            output["accessibility_note"] = .string(MacAccessibilityReader.notTrustedNote)
        }
        if axSelfRefused {
            output["accessibility_note"] = .string(Self.selfInspectionNote)
        }
        if !screenTrusted {
            output["screen_recording_note"] = .string(Self.screenRecordingNote)
        }
        // The geometry the whole fusion hangs on: the picture's own when there
        // is one, else the window rect.
        let geometry = shot.map { MacScreenViewGeometry(shot: $0) } ?? axGeometry
        if !semanticRawFrame { select(in: geometry) }
        guard !Task.isCancelled else { return cancelledResult() }
        // Retain only the recognizer's redacted text/positions from this
        // ephemeral WHOLE window. Do this before canvas cropping, downscaling
        // or action-mark masking can remove a caption that protects its value.
        if recognizesText, let bundle = app?.bundleIdentifier, let retained = SenseAppReadCapture.current {
            do {
                guard let shot else {
                    throw SenseFailure(code: "source_unavailable", message: "The app read has no window capture for redacted text recognition.")
                }
                let recognized = try await MacAppWindowText.readCaptured(shot)
                retained.augment(bundleID: bundle, fields: ["recognized_text": recognized.rows,
                    "recognized_text_body": .string(recognized.text), "window_text_unavailable_reason": .null])
            } catch {
                let reason = (error as? SenseFailure)?.message ?? error.localizedDescription
                retained.augment(bundleID: bundle, fields: ["recognized_text": .null, "recognized_text_body": .null,
                    "window_text_unavailable_reason": .string(reason)])
            }
            guard !Task.isCancelled else { return cancelledResult() }
        }
        // Semantic perception keeps the whole native observation. Only the
        // delivery path may crop or fit it after recognition and selection.
        var imageDownscale: Double?
        var imageBytes: Int?
        let imageRenderStartedNs = DispatchTime.now().uptimeNanoseconds
        if pictured, let shot {
            let renderGeometry = MacScreenViewGeometry(shot: shot)
            guard let secrets = MacScreenViewTextRedaction.secretFrames(
                nodes: redactionNodes, geometry: renderGeometry, deadline: now().addingTimeInterval(MacAXLimits.readSeconds)
            ) else { return await discardUnboundCapture() }
            let placements = semanticRawFrame
                ? []
                : selection.marks.compactMap {
                    renderGeometry.placement(mark: $0.mark, frame: $0.frame)
                }
            let encode: (Double) -> Data? = { rung in
                guard !Task.isCancelled else { return nil }
                return self.screenImageRenderer.renderPNG(shot: shot, placements: placements, secretFrames: secrets, downscale: rung)
            }
            let fitted = semanticRawFrame
                ? encode(1).map { (data: $0, downscale: 1.0) }
                : MacScreenViewBuilder.fitImage(maxBytes: maxImageBytes, encode: encode)
            guard !Task.isCancelled else { return cancelledResult() }
            if let fitted {
                output["image"] = .string(fitted.data.base64EncodedString())
                output["image_format"] = .string("png")
                output["image_annotations"] = .bool(!semanticRawFrame)
                imageDownscale = fitted.downscale
                imageBytes = fitted.data.count
                output["image_origin"] = .object([
                    "x": .double(renderGeometry.bounds.x),
                    "y": .double(renderGeometry.bounds.y),
                ])
                output["image_logical_size"] = .object([
                    "w": .double(renderGeometry.bounds.w),
                    "h": .double(renderGeometry.bounds.h),
                ])
                output["image_pixel_size"] = .object([
                    "w": .int(Int64(renderGeometry.pixelWidth)),
                    "h": .int(Int64(renderGeometry.pixelHeight)),
                ])
                output["semantic_focus_frame"] = semanticFocusFrame.map { frame in
                    .object([
                        "x": .double(frame.x), "y": .double(frame.y),
                        "w": .double(frame.w), "h": .double(frame.h),
                    ])
                } ?? .null
            } else {
                imageFailure = semanticRawFrame ? .encodeFailed : .exceedsByteCap
            }
        }
        let imageRenderFinishedNs = DispatchTime.now().uptimeNanoseconds
        output["image_render_ms"] = .int(elapsedMilliseconds(
            from: imageRenderStartedNs, to: imageRenderFinishedNs
        ))
        if output["image"] == nil {
            output["image"] = .null
            if pictured {
                let failure = imageFailure ?? .captureFailed
                output["image_unavailable_reason"] = .string(failure.rawValue)
                output["message"] = .string(failure.localizedDescription)
                output["remedy"] = failure.remedy(app: scope == .fullScreen ? nil : app?.bundleIdentifier)
            }
        }
        output["image_bytes"] = imageBytes.map { .int(Int64($0)) } ?? .null
        output["image_downscale"] = imageDownscale.map { .double($0) } ?? .null
        output["max_image_bytes"] = .int(Int64(maxImageBytes))
        if let geometry {
            output["logical_size"] = .object([
                "w": .double(geometry.bounds.w),
                "h": .double(geometry.bounds.h),
            ])
            output["origin"] = .object([
                "x": .double(geometry.bounds.x),
                "y": .double(geometry.bounds.y),
            ])
            output["scale"] = .double(geometry.reportedScale)
            if output["image_pixel_size"] == nil {
                output["image_pixel_size"] = .object([
                    "w": .int(Int64(geometry.pixelWidth)),
                    "h": .int(Int64(geometry.pixelHeight)),
                ])
            }
        }
        // 5. Remember it, so `mark` can be resolved — and hand back its id.
        //    The id is the ONLY way to address these numbers later; an older
        //    one is refused rather than silently re-interpreted.
        guard !Task.isCancelled else { return cancelledResult() }
        let viewId = UUID().uuidString
        let capturedView = MacScreenViewSnapshot(
            viewId: viewId,
            capturedAt: capturedAt,
            scope: scope,
            bounds: geometry?.bounds ?? MacAXFrame(x: 0, y: 0, w: 0, h: 0),
            appName: app?.name,
            windowTitle: windowTitle,
            marks: selection.marks,
            windowIdentity: windowIdentity
        )
        if let binding {
            guard await lookFrameStore.latestFrameId() == binding.frameID else {
                return await discardUnboundCapture()
            }
            let frames = lookFrameStore
            let views = screenViewStore
            let clock = now
            binding.confirm { [frameID = binding.frameID] in
                guard await views.snapshot(viewId: viewId) != nil,
                      let frame = await frames.frame(frameId: frameID) else { return false }
                return clock().timeIntervalSince(frame.capturedAt) <= MacLookFrameStore.ttlSeconds
            }
        }
        output["view"] = .string(viewId)
        output["frame_id"] = .string(binding?.frameID ?? viewId)
        output["view_current"] = .bool(true)
        output["captured_at"] = .string(NativeTimestampFormat.plainZulu(capturedAt))
        // Preserve the human-readable timestamp and subsecond precision in the machine observation clock.
        output["captured_at_epoch_seconds"] = .double(capturedAt.timeIntervalSince1970)
        output["view_ttl_seconds"] = .int(Int64(MacLookFrameStore.ttlSeconds))
        output["marks"] = .array(marks)
        output["mark_count"] = .int(Int64(selection.marks.count))
        output["marks_omitted"] = .int(Int64(selection.omitted))
        output["marks_offscreen"] = .int(Int64(selection.offscreen))
        output["max_marks"] = .int(Int64(max(1, min(maxMarks, MacScreenViewBuilder.hardMaxMarks))))
        output["text"] = .array(texts)
        output["text_omitted"] = .int(Int64(text.omitted))
        if let snapshot {
            output["ax_truncated"] = .bool(snapshot.truncated)
            output["ax_truncation_reasons"] = .array(snapshot.truncationReasons.map { .string($0) })
            output["ax_skipped_at_least"] = .int(Int64(snapshot.skippedAtLeast))
        }
        // ONE honest headline: anything the caller did not get to see.
        output["truncated"] = .bool(
            selection.truncated
                || text.omitted > 0
                || (snapshot?.truncated ?? false)
                || pictured && output["image"] == .null
        )
        output["how_to_read"] = .string(
            "`marks` and `text` ARE the view — they describe every control and everything the "
            + "window says, losslessly. Read them first; the image is the spatial backdrop showing "
            + "where each numbered thing sits, not something you need to decode to know what is "
            + "there. A mark with label_source \"nearby_text\" was named by inference from the text "
            + "beside it, and one with label_source \"none\" has no name the app publishes."
        )
        output["how_to_act"] = .string(
            "Act by name with mac.act {verb: \"click\", target: \"<the element's name>\"}; it "
            + "presses the element the app's own way. Coordinates are for the parts of the picture "
            + "with no marks (canvas, game, video). Marks are only valid for THIS view."
        )
        let viewFinishedNs = DispatchTime.now().uptimeNanoseconds
        output["scene_selection_ms"] = .int(elapsedMilliseconds(
            from: sceneSelectionStartedNs, to: sceneSelectionFinishedNs
        ))
        output["post_render_ms"] = .int(elapsedMilliseconds(
            from: imageRenderFinishedNs, to: viewFinishedNs
        ))
        output["view_total_ms"] = .int(elapsedMilliseconds(
            from: viewStartedNs, to: viewFinishedNs
        ))
        let ok = pictured ? output["image"] != .null : accessibilityTrusted
        return (MacControlResult(
            ok: ok,
            action: "view",
            output: .object(output),
            error: ok ? nil : imageFailure?.rawValue ?? "no_perception_available",
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        ), capturedView)
    }
}
