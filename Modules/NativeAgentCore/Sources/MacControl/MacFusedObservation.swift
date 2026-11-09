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
// Blueprint: | `MacFusedObservation.swift` | Exact-window fusion with complete pre/post secret masks, identity checks and explicit omissions |
extension SwiftNativeMacControl {
    /// Picture, marks and secret inspections share one window anchor to prevent stale pairings. Acquisition timings expose gaps the caller must judge. Pixels
    /// require Screen Recording and complete AX secret coverage.
    func handleView(_ body: [String: JSONValue], context: MacOperationContext) async -> MacControlResult {
        let read = await screenViewStore.read { await self.captureView(body, context: context) }
        let result = read.value
        guard !read.published, case .object(var output) = result.output,
              output["view_current"] == .bool(true) else { return result }
        output["view"] = .null
        output["frame_id"] = .null
        output["image"] = .null
        output["image_capture"] = .null
        output["pixel_coverage"] = .null
        if result.ok {
            output["marks"] = .array([])
            output["mark_count"] = .int(0)
        }
        output["view_current"] = .bool(false)
        output["view_note"] = .string(result.ok
            ? "This capture was superseded or invalidated while in flight. Its image and action marks were discarded; take a fresh view before acting."
            : "This capture failed; structural rows describe only what was read, with no current view. No image was published.")
        return MacControlResult(ok: false, action: result.action, output: .object(output),
            error: result.ok ? "view_capture_superseded" : result.error, durationMs: result.durationMs)
    }
    private func captureView(_ body: [String: JSONValue], context: MacOperationContext) async -> (MacControlResult, MacScreenViewSnapshot?) {
        let started = now()
        let viewStartedNs = DispatchTime.now().uptimeNanoseconds
        var anchorPid: Int32?
        let walked = context.capture?.walked
        if walked == nil, let requested = body["app"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requested.isEmpty {
            guard accessibilitySource(context: context).isTrusted() else { return (axUntrustedResult(action: "view"), nil) }
            let resolution = MacBackgroundSight.resolve(requested, among: accessibilitySource(context: context).runningApps())
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
        // Visual compilation needs the frozen world pixels before human-facing numbered ink is drawn over them.
        let semanticRawFrame = body["semantic_raw_frame"] == .bool(true)
        let semanticFocusVisualSurface = body["semantic_focus_visual_surface"] == .bool(true)
        let scope = MacScreenCaptureScope.focusedWindow
        let limits = Self.axLimits(from: body)
        let maxMarks = body["max_marks"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacScreenViewBuilder.hardMaxMarks
        let maxImageBytes = min(
            body["max_image_bytes"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacScreenViewBuilder.hardMaxImageBytes,
            MacScreenViewBuilder.hardMaxImageBytes
        )
        let accessibilityTrusted = accessibilitySource(context: context).isTrusted()
        let screenTrusted = screenCaptureSource.isScreenRecordingTrusted()
        // Use the AX root’s window rect so capture cannot become a guessed crop.
        let axSnapshotStartedNs = DispatchTime.now().uptimeNanoseconds
        let binding = context.capture
        var windowRect: MacAXFrame?
        var app: MacAXAppInfo?
        var windowTitle: String?
        var snapshot: MacAXTreeSnapshot?
        var redactionRoot: MacAXElementRef?
        var windowIdentity: MacAXWindowIdentity?
        var axSelfRefused = false
        if accessibilityTrusted {
            // Disclosure requires complete inspection even when presentation uses a bounded walk.
            switch walked.map({ MacAnchoredRead.read($0.read) })
                ?? anchoredSnapshot(limits: limits, pid: anchorPid, window: nil, complete: semanticRawFrame, context: context) {
            case .read(let read):
                snapshot = read.snapshot
                redactionRoot = read.root
                windowIdentity = read.windowIdentity
                app = read.app
                windowTitle = read.rootTitle
                windowRect = read.snapshot.nodes.first?.attributes.frame
            case .selfProcess:
                // Untrusted AX structure must not accompany otherwise valid pixels.
                axSelfRefused = true
            case .appGone, .windowGone, .windowDrifted:
                break
            case .rendererUnavailable(let reason):
                return (MacControlResult(ok: false, action: "view", output: .object([
                    "message": .string(reason), "image": .null,
                ]), error: "renderer_accessibility_unavailable", durationMs: 0), nil)
            }
        }
        guard anchorPid == nil || (windowRect != nil && windowIdentity != nil) else {
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
            guard let expected = await lookFrameStore.frame(frameId: binding.frameID, context: context),
                  let identity = expected.windowIdentity, identity == windowIdentity,
                  now().timeIntervalSince(expected.capturedAt) <= MacLookFrameStore.ttlSeconds else {
                return await discardUnboundCapture()
            }
        }
        let isolatedWindow = anchorPid != nil || binding != nil
        let transientMenus = isolatedWindow ? [] : app.map {
            MacTransientMenus.read(source: accessibilitySource(context: context), pid: $0.processIdentifier, context: context)
        } ?? []
        let axSnapshotFinishedNs = DispatchTime.now().uptimeNanoseconds
        guard !Task.isCancelled else { return cancelledResult() }
        // Keep menus structural: a display-region screenshot could disclose other apps’ pixels.
        let captureRect = windowRect
        // Without pixels, the window rect still anchors a complete legend at one point per pixel.
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
        // Build controls and prose even without pixels so semantic actions remain usable.
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
                    node.element.map { accessibilitySource(context: context).settableAttributes(of: $0, context: context) } ?? []
                }
            , context: context)
            text = MacScreenViewBuilder.visibleText(
                nodes: snapshot.nodes,
                geometry: geometry,
                limit: body["max_text_items"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacScreenViewBuilder.hardMaxTextItems
            )
            marks = selection.marks.map { $0.toJSON(valueChars: limits.valueChars) }
            texts = text.items.map { $0.toJSON(valueChars: limits.valueChars) }
        }
        // Choose capture from the AX read before numbering; thin views need pixels only for uncovered recognition or requested delivery.
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
            // Renderer AX owns Chromium content; pixels cannot conceal an incomplete or pending read.
            let canvas = semanticFocusFrame ?? selection.marks
                .filter { MacScreenViewBuilder.visualSurfaceRoles.contains($0.role) }.map(\.frame)
                .max { $0.w * $0.h < $1.w * $1.h }
            let windowArea = axGeometry.map { $0.bounds.w * $0.bounds.h } ?? 0
            let canvasFraction = canvas.flatMap { windowArea > 0 ? min(1, $0.w * $0.h / windowArea) : nil }
            let chromium: Bool
            do { chromium = try MacChromiumAccessibility.looksChromium(bundleId: app?.bundleIdentifier, pid: app?.processIdentifier, snapshot: nil) }
            catch {
                return (MacControlResult(ok: false, action: "view",
                    output: .object(["message": .string(error.localizedDescription), "view_current": .bool(false)]),
                    error: "renderer_classification_unavailable", durationMs: 0), nil)
            }
            thinReason = chromium
                || snapshot?.truncated == true ? nil : MacScreenViewBuilder.thinAccessibilityReason(
                    accessibilityTrusted: accessibilityTrusted, marks: marks, texts: texts, windowArea: windowArea,
                    canvasFraction: canvasFraction,
                    sourceTextCount: words.count, sourceTextCharacters: words.reduce(0) { $0 + $1.count })
            // Recognition earns its latency only on sparse marks or real visual surfaces.
            recognizesPixels = thinReason != nil
                && (!accessibilityTrusted || selection.marks.count <= 6 || (canvasFraction ?? 0) >= 0.03)
            pictured = body["pixels"] == .string("always") || recognizesPixels
                || thinReason != nil && body["pixels"] == .string("thin")
        }
        let recognizesText = semanticRawFrame && app?.bundleIdentifier != nil
            && context.appCapture != nil
        guard !Task.isCancelled else { return cancelledResult() }
        // Both complete secret inspections and pixel release share one bounded transaction; presentation caps cannot limit disclosure coverage.
        let disclosureDeadline = now().addingTimeInterval(MacAXLimits.readSeconds)
        var redactionNodes: [MacAXNode] = []
        var postRedactionNodes: [MacAXNode] = []
        var imageTargets: [MacImageCapture.PointTarget] = []
        func inspectPixelOwner() throws -> [MacAXNode] {
            try context.holding(\.readDeadline, disclosureDeadline) { context in
                try MacAccessibilityReader.withReadBudget(context: context) { context in
                    guard accessibilityTrusted, let app, let windowIdentity, let redactionRoot,
                          accessibilitySource(context: context).appInfo(pid: app.processIdentifier) == app else {
                        throw SenseFailure(code: "redaction_coverage_unavailable", message: "The pixel owner is unavailable.")
                    }
                    // Reinspect the retained root so unrelated windows cannot supply identity or invalidate this window’s coverage.
                    let nodes = try MacScreenViewTextRedaction.inspectSecretFields(source: accessibilitySource(context: context),
                        root: redactionRoot, deadline: disclosureDeadline, context: context)
                    guard let root = nodes.first, root.attributes.role == windowIdentity.role,
                          MacAXWindowIdentity.rectsMatch(root.attributes.frame, windowRect) else {
                        throw SenseFailure(code: "redaction_coverage_unavailable", message: "The observed window identity or geometry changed.")
                    }
                    return nodes
                }
            }
        }
        var coverageFailure: String?
        if pictured {
            do { redactionNodes = try inspectPixelOwner() }
            catch { coverageFailure = (error as? SenseFailure)?.message ?? error.localizedDescription }
        }
        let capturedAt = now()
        let screenCaptureStartedNs = DispatchTime.now().uptimeNanoseconds
        var shot: MacScreenShot?
        var imageFailure: MacScreenCaptureFailure?
        if pictured || recognizesText, coverageFailure == nil {
            if let windowIdentity {
                let capture = await screenCaptureSource.capture(window: windowIdentity, context: context)
                switch capture {
                case .success(let value): shot = value
                case .failure(let failure): imageFailure = failure
                }
            } else {
                coverageFailure = "No anchored window is available for capture."
            }
        }
        guard !Task.isCancelled else { return cancelledResult() }
        if pictured, coverageFailure == nil, let shot {
            do {
                postRedactionNodes = try inspectPixelOwner()
                guard now() < disclosureDeadline, MacAXWindowIdentity.rectsMatch(shot.bounds, windowRect),
                  let provenance = shot.capture, provenance.capturedAt >= capturedAt,
                  provenance.capturedAt <= now(), provenance.windows.count == 1,
                  let capturedWindow = provenance.windows.first,
                  capturedWindow.pid == app?.processIdentifier,
                  MacAXWindowIdentity.rectsMatch(capturedWindow.frame, windowRect) else {
                    throw SenseFailure(code: "redaction_coverage_unavailable",
                        message: "The capture cannot be bound to the inspected window and lifetime.")
                }
                imageTargets = MacImageCapture.pointTargets(nodes: postRedactionNodes,
                    pid: capturedWindow.pid, deadline: disclosureDeadline, source: accessibilityActSource(context: context), context: context)
            } catch {
                coverageFailure = (error as? SenseFailure)?.message ?? error.localizedDescription
            }
        }
        let screenCaptureFinishedNs = DispatchTime.now().uptimeNanoseconds
        let observedPointer = isolatedWindow ? nil : pointerPositionSource.currentPosition()
        let fusionGapMs = Int(abs(now().timeIntervalSince(capturedAt)) * 1000)
        var output: [String: JSONValue] = [
            "accessibility_trusted": .bool(accessibilityTrusted),
            "screen_recording_trusted": .bool(screenTrusted),
            "scope": .string(scope.rawValue),
            "capture_isolated_window": .bool(true),
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
        // Use picture geometry when present; otherwise the window rect anchors fusion.
        let geometry = shot.map { MacScreenViewGeometry(shot: $0) } ?? axGeometry
        if !semanticRawFrame { select(in: geometry) }
        guard !Task.isCancelled else { return cancelledResult() }
        // A released picture walks the whole window twice; recognized text alone runs on every look, under caption redaction, and never pays for that walk.
        var secrets: [MacAXFrame] = []
        if pictured, coverageFailure == nil, let shot {
            let renderGeometry = MacScreenViewGeometry(shot: shot)
            if let beforeMasks = MacScreenViewTextRedaction.secretFrames(
                nodes: redactionNodes, geometry: renderGeometry, deadline: disclosureDeadline, context: context),
               let afterMasks = MacScreenViewTextRedaction.secretFrames(
                nodes: postRedactionNodes, geometry: renderGeometry, deadline: disclosureDeadline, context: context) {
                secrets = beforeMasks + afterMasks.filter { !beforeMasks.contains($0) }
            } else {
                coverageFailure = "Secret mask compilation exceeded its deadline."
            }
        }
        // Whole-window caption redaction precedes mask filtering; nothing is retained before final coverage and owner checks.
        var recognizedWindowText: (rows: JSONValue, text: String)?
        var windowTextFailure: String?
        if recognizesText {
            do {
                if let coverageFailure {
                    throw SenseFailure(code: "redaction_coverage_unavailable", message: coverageFailure)
                }
                guard let shot else {
                    throw SenseFailure(code: "source_unavailable", message: "The app read has no window capture for redacted text recognition.")
                }
                recognizedWindowText = try await MacAppWindowText.readCaptured(shot, excluding: secrets)
            } catch {
                windowTextFailure = (error as? SenseFailure)?.message ?? error.localizedDescription
            }
            guard !Task.isCancelled else { return cancelledResult() }
        }
        // Perception retains the whole observation; delivery crops or fits only after recognition and selection.
        var imageDownscale: Double?
        var imageBytes: Int?
        let imageRenderStartedNs = DispatchTime.now().uptimeNanoseconds
        if pictured, coverageFailure == nil, let shot {
            do {
                let renderGeometry = MacScreenViewGeometry(shot: shot)
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
                    guard now() < disclosureDeadline else {
                        throw SenseFailure(code: "redaction_coverage_unavailable", message: "The disclosure deadline expired before image release.")
                    }
                    output["pixel_coverage"] = .object([
                        "status": .string("complete"),
                        "before_nodes": .int(Int64(redactionNodes.count)),
                        "after_nodes": .int(Int64(postRedactionNodes.count)),
                        "masked_regions": .int(Int64(secrets.count)),
                    ])
                    output["image"] = .string(fitted.data.base64EncodedString())
                    output["image_capture"] = shot.capture?.recordingTargets(imageTargets).json
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
            } catch {
                coverageFailure = (error as? SenseFailure)?.message ?? error.localizedDescription
            }
        }
        let imageRenderFinishedNs = DispatchTime.now().uptimeNanoseconds
        output["image_render_ms"] = .int(elapsedMilliseconds(
            from: imageRenderStartedNs, to: imageRenderFinishedNs
        ))
        if output["image"] == nil {
            output["image"] = .null
            if pictured, coverageFailure == nil {
                let failure = imageFailure ?? .captureFailed
                output["image_unavailable_reason"] = .string(failure.rawValue)
                output["message"] = .string(failure.localizedDescription)
                output["remedy"] = failure.remedy(app: app?.bundleIdentifier)
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
        // Marks are bound to this view id; refuse another view’s id rather than reinterpret its numbers.
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
            guard await lookFrameStore.latestFrameId(context: context) == binding.frameID else {
                return await discardUnboundCapture()
            }
            let frames = lookFrameStore
            let views = screenViewStore
            let clock = now
            binding.confirm { [frameID = binding.frameID] in
                guard await views.snapshot(viewId: viewId) != nil,
                      let frame = await frames.frame(frameId: frameID, context: context) else { return false }
                return clock().timeIntervalSince(frame.capturedAt) <= MacLookFrameStore.ttlSeconds
            }
        }
        guard let app, accessibilitySource(context: context).appInfo(pid: app.processIdentifier) == app else {
            return await discardUnboundCapture()
        }
        if pictured, coverageFailure == nil, shot != nil, now() >= disclosureDeadline {
            coverageFailure = "The disclosure deadline expired before publication."
        }
        if let coverageFailure {
            output["image"] = .null
            output["image_capture"] = .null
            output["image_bytes"] = .null
            output["image_downscale"] = .null
            output["recognize_pixels"] = .bool(false)
            output["image_unavailable_reason"] = .string("redaction_coverage_unavailable")
            output["image_withheld_reason"] = .string(coverageFailure)
            output["message"] = .string("Pixels withheld: \(coverageFailure) The text observation retains its reported coverage.")
            output["pixel_coverage"] = .object([
                "status": .string("withheld"), "reason": .string(coverageFailure),
            ])
        }
        if recognizesText, let bundle = app.bundleIdentifier, let retained = context.appCapture {
            if coverageFailure == nil, let recognizedWindowText {
                retained.augment(bundleID: bundle, fields: ["recognized_text": recognizedWindowText.rows,
                    "recognized_text_body": .string(recognizedWindowText.text), "window_text_unavailable_reason": .null])
            } else {
                retained.augment(bundleID: bundle, fields: ["recognized_text": .null, "recognized_text_body": .null,
                    "window_text_unavailable_reason": .string(coverageFailure ?? windowTextFailure
                        ?? "The app capture has no proven recognized text.")])
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
        output["ax_coverage"] = .string(snapshot.map { $0.truncated ? "partial" : "within_bounds" } ?? "unavailable")
        if let snapshot {
            output.merge(snapshot.readGapsJSON(including: transientMenus.flatMap(\.observedNodes),
                source: accessibilitySource(context: context))) { _, gap in gap }
            output["ax_truncated"] = .bool(snapshot.truncated)
            output["ax_truncation_reasons"] = .array(snapshot.truncationReasons.map { .string($0) })
            output["ax_read_failures"] = .array(snapshot.readFailures.map(JSONValue.string))
            output["ax_skipped_at_least"] = .int(Int64(snapshot.skippedAtLeast))
        }
        output["truncated"] = .bool(
            selection.truncated
                || text.omitted > 0
                || (snapshot?.truncated ?? false)
                || pictured && output["image"] == .null
        )
        output["partial"] = output["truncated"]
        output["how_to_read"] = .string(
            "`marks` and `text` contain the selected controls and reading-order text. "
            + "Coverage: \(output["truncated"] == .bool(true) ? "partial" : "within the reported bounds"); "
            + "marks_omitted=\(selection.omitted), text_omitted=\(text.omitted), "
            + "ax_skipped_at_least=\(snapshot.map { String($0.skippedAtLeast) } ?? "unknown"). "
            + "Read ax_truncation_reasons for unseen branches; omitted content is unknown. "
            + "The image depicts only the anchored window; open menus are reported structurally. "
            + "A mark with label_source \"none\" has no observed name. "
            + "A label_source of \"unreadable\" means its caption read failed; attribute_gaps names that read. "
            + "attribute_gaps names failed reads: those attributes are unknown, not absent."
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
        let ok = coverageFailure != nil ? snapshot != nil : pictured ? output["image"] != .null : accessibilityTrusted
        return (MacControlResult(
            ok: ok,
            action: "view",
            output: .object(output),
            error: ok ? nil : imageFailure?.rawValue ?? "no_perception_available",
            durationMs: Int(now().timeIntervalSince(started) * 1000)
        ), capturedView)
    }
}
