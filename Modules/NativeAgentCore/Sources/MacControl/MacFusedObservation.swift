import Foundation
import NativeAgentShared
import Senses
import NativeAgentCore
import PersistenceCore
import TrustCenter
import AppKit
import CoreGraphics
import ApplicationServices
import UserNotifications
import Experiences
import os
import CoreText
import ScreenCaptureKit
// Blueprint: | `MacFusedObservation.swift` | Exact-window fusion with complete pre/post secret masks, identity checks and explicit omissions; `MacViewCapture` carries one view from the anchored read through scene, pixels and masks to publication |
extension SwiftNativeMacControl {
    /// Picture, marks and secret inspections share one window anchor to prevent stale pairings. Acquisition timings expose gaps the caller must judge. Pixels
    /// require Screen Recording and complete AX secret coverage.
    func handleView(_ body: [String: JSONValue], context: MacOperationContext) async -> MacControlResult {
        let read = await screenViewStore.read { await self.captureView(body, context: context) }
        let result = read.value
        guard !read.published, case .object(var output) = result.output,
              output["view_current"] == .bool(true) else { return result }
        // A superseded look answers with what is still true: the text, the picture and the frame it captured stand as of when it was taken.
        // Only its click targets are lost. It stays a success with no view id, so nothing can act on its marks.
        if result.ok, body["semantic_raw_frame"] == .bool(true) {
            output["view"] = .null
            output["marks"] = .array([])
            output["mark_count"] = .int(0)
            output["view_current"] = .bool(false)
            output["view_note"] = .string(output["image_withheld_reason"] != nil
                ? "The picture was not included. The screen changed while it was read, so its controls were dropped; the text read stands."
                : "A newer frame replaced this one while it was read, so its controls no longer apply; the picture and text are as of when it was taken.")
            return MacControlResult(ok: true, action: result.action, output: .object(output),
                error: nil, durationMs: result.durationMs)
        }
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
        if let refused = anchorView(body, walked: walked, anchorPid: &anchorPid, context: context) { return refused }
        let reply = MacViewReply(started: started, now: now)
        guard !Task.isCancelled else { return reply.cancelledResult() }
        guard !Task.isCancelled else { return reply.cancelledResult() }
        let viewing: MacViewCapture
        switch await readViewWindow(body, walked: walked, anchorPid: anchorPid, viewStartedNs: viewStartedNs, context: context) {
        case .next(let read): viewing = read
        case .done(let result): return result
        }
        if let ended = chooseViewCapture(viewing, body: body, reply: reply, context: context) { return ended }
        if let ended = await captureViewPixels(viewing, reply: reply, context: context) { return ended }
        if let ended = await viewOutput(viewing, body: body, reply: reply, context: context) { return ended }
        if let ended = renderViewImage(viewing, reply: reply) { return ended }
        return await publishView(viewing, reply: reply, context: context)
    }
    /// A named app anchors the view to its window, without activating it.
    private func anchorView(
        _ body: [String: JSONValue], walked: (read: MacAXRead, seam: [String: JSONValue])?, anchorPid: inout Int32?, context: MacOperationContext
    ) -> (MacControlResult, MacScreenViewSnapshot?)? {
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
        return nil
    }
    private func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Int64 {
        Int64((end &- start) / 1_000_000)
    }
    private func discardUnboundCapture() async -> (MacControlResult, MacScreenViewSnapshot?) {
        return (MacControlResult(ok: false, action: "view", output: .object([
            "view": .null, "image": .null, "view_current": .bool(false),
            "message": .string("The observed window or look generation changed; the pixel supplement was discarded."),
        ]), error: "observation_changed", durationMs: 0), nil)
    }
    /// Resolve the request's limits and trust, read the anchored window once, check it against the look frame it supplements, and read its open menus.
    private func readViewWindow(
        _ body: [String: JSONValue], walked: (read: MacAXRead, seam: [String: JSONValue])?, anchorPid: Int32?, viewStartedNs: UInt64,
        context: MacOperationContext
    ) async -> MacViewStep<MacViewCapture> {
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
                return .done((MacControlResult(ok: false, action: "view", output: .object([
                    "message": .string(reason), "image": .null,
                ]), error: "renderer_accessibility_unavailable", durationMs: 0), nil))
            }
        }
        guard anchorPid == nil || (windowRect != nil && windowIdentity != nil) else {
            return .done((MacControlResult(ok: false, action: "view", output: .object([
                "error": .string("named_window_unavailable"),
                "message": .string("The named app has no readable window frame; no desktop image was substituted."),
            ]), error: "named_window_unavailable", durationMs: 0), nil))
        }
        if let binding {
            guard let expected = await lookFrameStore.frame(frameId: binding.frameID, context: context),
                  let identity = expected.windowIdentity, identity == windowIdentity,
                  now().timeIntervalSince(expected.capturedAt) <= MacLookFrameStore.ttlSeconds else {
                return .done(await discardUnboundCapture())
            }
        }
        let isolatedWindow = anchorPid != nil || binding != nil
        let transientMenus = isolatedWindow ? [] : app.map {
            MacTransientMenus.read(source: accessibilitySource(context: context), pid: $0.processIdentifier, context: context)
        } ?? []
        let axSnapshotFinishedNs = DispatchTime.now().uptimeNanoseconds
        return .next(MacViewCapture(viewStartedNs: viewStartedNs, semanticRawFrame: semanticRawFrame,
            semanticFocusVisualSurface: semanticFocusVisualSurface, scope: scope, limits: limits, maxMarks: maxMarks, maxImageBytes: maxImageBytes,
            accessibilityTrusted: accessibilityTrusted, screenTrusted: screenTrusted, axSnapshotStartedNs: axSnapshotStartedNs, binding: binding,
            windowRect: windowRect, app: app, windowTitle: windowTitle, snapshot: snapshot, redactionRoot: redactionRoot,
            windowIdentity: windowIdentity, axSelfRefused: axSelfRefused, isolatedWindow: isolatedWindow, transientMenus: transientMenus,
            axSnapshotFinishedNs: axSnapshotFinishedNs))
    }
    /// Select marks and text from the AX read, then decide whether this view needs pixels: thin accessibility, a visual surface, or a request.
    private func chooseViewCapture(
        _ viewing: MacViewCapture, body: [String: JSONValue], reply: MacViewReply, context: MacOperationContext
    ) -> (MacControlResult, MacScreenViewSnapshot?)? {
        let semanticRawFrame = viewing.semanticRawFrame
        let semanticFocusVisualSurface = viewing.semanticFocusVisualSurface
        let accessibilityTrusted = viewing.accessibilityTrusted
        let windowRect = viewing.windowRect
        let app = viewing.app
        let snapshot = viewing.snapshot
        guard !Task.isCancelled else { return reply.cancelledResult() }
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
        viewing.sceneSelectionStartedNs = DispatchTime.now().uptimeNanoseconds
        viewing.sceneSelectionFinishedNs = viewing.sceneSelectionStartedNs
        // Choose capture from the AX read before numbering; thin views need pixels only for uncovered recognition or requested delivery.
        var thinReason: String?
        var recognizesPixels = false
        var semanticFocusFrame: MacAXFrame?
        var pictured = true
        if semanticRawFrame {
            selectScene(viewing, in: axGeometry, body: body, context: context)
            let words = (snapshot?.nodes ?? []).filter { MacPerceptionCompiler.readoutRoles.contains($0.attributes.role) }
                .compactMap { $0.attributes.title ?? $0.attributes.value }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if semanticFocusVisualSurface, let snapshot, let axGeometry {
                semanticFocusFrame = MacScreenViewBuilder.dominantVisualSurface(nodes: snapshot.nodes, geometry: axGeometry)
            }
            // Renderer AX owns Chromium content; pixels cannot conceal an incomplete or pending read.
            let canvas = semanticFocusFrame ?? viewing.selection.marks
                .filter { MacScreenViewBuilder.visualSurfaceRoles.contains($0.role) }.map(\.frame)
                .max { $0.w * $0.h < $1.w * $1.h }
            let windowArea = axGeometry.map { $0.bounds.w * $0.bounds.h } ?? 0
            let canvasFraction = canvas.flatMap { windowArea > 0 ? min(1, $0.w * $0.h / windowArea) : nil }
            let chromium: Bool
            do { chromium = try MacChromiumAccessibility.looksChromium(bundleId: app?.bundleIdentifier, pid: app?.processIdentifier) }
            catch {
                return (MacControlResult(ok: false, action: "view",
                    output: .object(["message": .string(error.localizedDescription), "view_current": .bool(false)]),
                    error: "renderer_classification_unavailable", durationMs: 0), nil)
            }
            thinReason = chromium
                || snapshot?.truncated == true ? nil : MacScreenViewBuilder.thinAccessibilityReason(
                    accessibilityTrusted: accessibilityTrusted, marks: viewing.marks, texts: viewing.texts, windowArea: windowArea,
                    canvasFraction: canvasFraction,
                    sourceTextCount: words.count, sourceTextCharacters: words.reduce(0) { $0 + $1.count })
            // Recognition earns its latency only on sparse marks or real visual surfaces.
            recognizesPixels = thinReason != nil
                && (!accessibilityTrusted || viewing.selection.marks.count <= 6 || (canvasFraction ?? 0) >= 0.03)
            pictured = body["pixels"] == .string("always") || recognizesPixels
                || thinReason != nil && body["pixels"] == .string("thin")
        }
        let recognizesText = semanticRawFrame && app?.bundleIdentifier != nil
            && context.appCapture != nil
        guard !Task.isCancelled else { return reply.cancelledResult() }
        viewing.axGeometry = axGeometry
        viewing.thinReason = thinReason
        viewing.recognizesPixels = recognizesPixels
        viewing.semanticFocusFrame = semanticFocusFrame
        viewing.pictured = pictured
        viewing.recognizesText = recognizesText
        return nil
    }
    /// Number the marks and visible text within one geometry; the scene's selection clock brackets the work.
    private func selectScene(_ viewing: MacViewCapture, in geometry: MacScreenViewGeometry?, body: [String: JSONValue], context: MacOperationContext) {
        let snapshot = viewing.snapshot
        let maxMarks = viewing.maxMarks
        let limits = viewing.limits
        viewing.sceneSelectionStartedNs = DispatchTime.now().uptimeNanoseconds
        defer { viewing.sceneSelectionFinishedNs = DispatchTime.now().uptimeNanoseconds }
        guard let snapshot, let geometry else { return }
        viewing.selection = MacScreenViewBuilder.select(
            nodes: snapshot.nodes,
            geometry: geometry,
            maxMarks: maxMarks,
            settableAttributes: { node in
                node.element.map { accessibilitySource(context: context).settableAttributes(of: $0, context: context) } ?? []
            }
        , context: context)
        viewing.text = MacScreenViewBuilder.visibleText(
            nodes: snapshot.nodes,
            geometry: geometry,
            limit: body["max_text_items"]?.integerValue.flatMap(Int.init(exactly:)) ?? MacScreenViewBuilder.hardMaxTextItems
        )
        viewing.marks = viewing.selection.marks.map { $0.toJSON(valueChars: limits.valueChars) }
        viewing.texts = viewing.text.items.map { $0.toJSON(valueChars: limits.valueChars) }
    }
    /// Inspect the pixel owner's secret fields, capture its window, and inspect again; the capture binds to that window and lifetime or is withheld.
    private func captureViewPixels(_ viewing: MacViewCapture, reply: MacViewReply, context: MacOperationContext) async -> (MacControlResult, MacScreenViewSnapshot?)? {
        let accessibilityTrusted = viewing.accessibilityTrusted
        let app = viewing.app
        let windowIdentity = viewing.windowIdentity
        let redactionRoot = viewing.redactionRoot
        let windowRect = viewing.windowRect
        let pictured = viewing.pictured
        let recognizesText = viewing.recognizesText
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
        // Under Full Mac nothing is masked: an incomplete masking walk costs her marks, never her pixels.
        if pictured || recognizesText {
            do { redactionNodes = try inspectPixelOwner() }
            catch let error where !context.seesAsPerson { coverageFailure = (error as? SenseFailure)?.message ?? error.localizedDescription }
            catch {}
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
        guard !Task.isCancelled else { return reply.cancelledResult() }
        if pictured || recognizesText, coverageFailure == nil, let shot {
            do {
                do { postRedactionNodes = try inspectPixelOwner() }
                catch { guard context.seesAsPerson else { throw error } }
                guard context.seesAsPerson || now() < disclosureDeadline, MacAXWindowIdentity.rectsMatch(shot.bounds, windowRect),
                  let provenance = shot.capture, provenance.capturedAt >= capturedAt,
                  provenance.capturedAt <= now(), provenance.windows.count == 1,
                  let capturedWindow = provenance.windows.first,
                  capturedWindow.pid == app?.processIdentifier,
                  MacAXWindowIdentity.rectsMatch(capturedWindow.frame, windowRect) else {
                    throw SenseFailure(code: "redaction_coverage_unavailable",
                        message: "The capture cannot be bound to the inspected window and lifetime.")
                }
                if pictured { imageTargets = MacImageCapture.pointTargets(nodes: postRedactionNodes,
                    pid: capturedWindow.pid, deadline: disclosureDeadline, source: accessibilityActSource(context: context), context: context) }
            } catch {
                coverageFailure = (error as? SenseFailure)?.message ?? error.localizedDescription
            }
        }
        let screenCaptureFinishedNs = DispatchTime.now().uptimeNanoseconds
        // The deadline keeps masks and pixels one coherent disclosure; under Full Mac there are no masks to keep coherent.
        viewing.disclosureDeadline = context.seesAsPerson ? .distantFuture : disclosureDeadline
        viewing.redactionNodes = redactionNodes
        viewing.postRedactionNodes = postRedactionNodes
        viewing.imageTargets = imageTargets
        viewing.coverageFailure = coverageFailure
        viewing.capturedAt = capturedAt
        viewing.screenCaptureStartedNs = screenCaptureStartedNs
        viewing.shot = shot
        viewing.imageFailure = imageFailure
        viewing.screenCaptureFinishedNs = screenCaptureFinishedNs
        return nil
    }
    /// Open the output with trust, timing and pointer facts; select against the picture's geometry; mask secrets; recognize the window's text.
    private func viewOutput(
        _ viewing: MacViewCapture, body: [String: JSONValue], reply: MacViewReply, context: MacOperationContext
    ) async -> (MacControlResult, MacScreenViewSnapshot?)? {
        let isolatedWindow = viewing.isolatedWindow
        let capturedAt = viewing.capturedAt
        let accessibilityTrusted = viewing.accessibilityTrusted
        let screenTrusted = viewing.screenTrusted
        let scope = viewing.scope
        let app = viewing.app
        let transientMenus = viewing.transientMenus
        let windowTitle = viewing.windowTitle
        let limits = viewing.limits
        let axSnapshotStartedNs = viewing.axSnapshotStartedNs
        let axSnapshotFinishedNs = viewing.axSnapshotFinishedNs
        let screenCaptureStartedNs = viewing.screenCaptureStartedNs
        let screenCaptureFinishedNs = viewing.screenCaptureFinishedNs
        let thinReason = viewing.thinReason
        let recognizesPixels = viewing.recognizesPixels
        let axSelfRefused = viewing.axSelfRefused
        let shot = viewing.shot
        let axGeometry = viewing.axGeometry
        let semanticRawFrame = viewing.semanticRawFrame
        let pictured = viewing.pictured
        let recognizesText = viewing.recognizesText
        let redactionNodes = viewing.redactionNodes
        let postRedactionNodes = viewing.postRedactionNodes
        let disclosureDeadline = viewing.disclosureDeadline
        var coverageFailure = viewing.coverageFailure
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
        if !semanticRawFrame { selectScene(viewing, in: geometry, body: body, context: context) }
        guard !Task.isCancelled else { return reply.cancelledResult() }
        var secrets: [MacAXFrame] = []
        if pictured || recognizesText, coverageFailure == nil, let shot {
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
            guard !Task.isCancelled else { return reply.cancelledResult() }
        }
        viewing.output = output
        viewing.geometry = geometry
        viewing.secrets = secrets
        viewing.coverageFailure = coverageFailure
        viewing.recognizedWindowText = recognizedWindowText
        viewing.windowTextFailure = windowTextFailure
        return nil
    }
    /// Render and fit the picture with its masks (and marks, unless raw), release it only within the disclosure deadline, and state its geometry.
    private func renderViewImage(_ viewing: MacViewCapture, reply: MacViewReply) -> (MacControlResult, MacScreenViewSnapshot?)? {
        let pictured = viewing.pictured
        let shot = viewing.shot
        let semanticRawFrame = viewing.semanticRawFrame
        let selection = viewing.selection
        let secrets = viewing.secrets
        let maxImageBytes = viewing.maxImageBytes
        let disclosureDeadline = viewing.disclosureDeadline
        let redactionNodes = viewing.redactionNodes
        let postRedactionNodes = viewing.postRedactionNodes
        let imageTargets = viewing.imageTargets
        let semanticFocusFrame = viewing.semanticFocusFrame
        let app = viewing.app
        let geometry = viewing.geometry
        var output = viewing.output
        var imageFailure = viewing.imageFailure
        var coverageFailure = viewing.coverageFailure
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
                guard !Task.isCancelled else { return reply.cancelledResult() }
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
        viewing.output = output
        viewing.imageFailure = imageFailure
        viewing.coverageFailure = coverageFailure
        viewing.imageRenderFinishedNs = imageRenderFinishedNs
        return nil
    }
    /// Bind the view to its look frame, withhold pixels whose coverage failed, retain recognized text, and publish the view with its coverage.
    private func publishView(_ viewing: MacViewCapture, reply: MacViewReply, context: MacOperationContext) async -> (MacControlResult, MacScreenViewSnapshot?) {
        let started = reply.started
        let viewStartedNs = viewing.viewStartedNs
        let capturedAt = viewing.capturedAt
        let scope = viewing.scope
        let geometry = viewing.geometry
        let app = viewing.app
        let windowTitle = viewing.windowTitle
        let selection = viewing.selection
        let windowIdentity = viewing.windowIdentity
        let binding = viewing.binding
        let pictured = viewing.pictured
        let shot = viewing.shot
        let disclosureDeadline = viewing.disclosureDeadline
        let recognizesText = viewing.recognizesText
        let recognizedWindowText = viewing.recognizedWindowText
        let windowTextFailure = viewing.windowTextFailure
        let marks = viewing.marks
        let maxMarks = viewing.maxMarks
        let texts = viewing.texts
        let text = viewing.text
        let snapshot = viewing.snapshot
        let transientMenus = viewing.transientMenus
        let sceneSelectionStartedNs = viewing.sceneSelectionStartedNs
        let sceneSelectionFinishedNs = viewing.sceneSelectionFinishedNs
        let imageRenderFinishedNs = viewing.imageRenderFinishedNs
        let accessibilityTrusted = viewing.accessibilityTrusted
        let imageFailure = viewing.imageFailure
        var output = viewing.output
        var coverageFailure = viewing.coverageFailure
        // Marks are bound to this view id; refuse another view’s id rather than reinterpret its numbers.
        guard !Task.isCancelled else { return reply.cancelledResult() }
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

/// A view stage either goes on with what it read or ends the view with its reply.
private enum MacViewStep<Value> {
    case next(Value)
    case done((MacControlResult, MacScreenViewSnapshot?))
}

/// The view's clock: its cancelled reply is timed from when the view began.
private struct MacViewReply {
    let started: Date
    let now: @Sendable () -> Date
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
}

/// One view's capture, from the anchored AX read through the scene, the pixels and their masks to publication. It lives for one call and never
/// crosses isolation.
private final class MacViewCapture {
    let viewStartedNs: UInt64
    let semanticRawFrame: Bool
    let semanticFocusVisualSurface: Bool
    let scope: MacScreenCaptureScope
    let limits: MacAXLimits
    let maxMarks: Int
    let maxImageBytes: Int
    let accessibilityTrusted: Bool
    let screenTrusted: Bool
    let axSnapshotStartedNs: UInt64
    let binding: MacSightCaptureBinding?
    let windowRect: MacAXFrame?
    let app: MacAXAppInfo?
    let windowTitle: String?
    let snapshot: MacAXTreeSnapshot?
    let redactionRoot: MacAXElementRef?
    let windowIdentity: MacAXWindowIdentity?
    let axSelfRefused: Bool
    let isolatedWindow: Bool
    let transientMenus: [MacTransientMenus.Menu]
    let axSnapshotFinishedNs: UInt64
    // The scene: set when the capture is chosen; the selection is renumbered against the picture's geometry.
    var axGeometry: MacScreenViewGeometry?
    var sceneSelectionStartedNs: UInt64 = 0
    var sceneSelectionFinishedNs: UInt64 = 0
    var selection = MacScreenViewBuilder.Selection(marks: [], omitted: 0, offscreen: 0)
    var text = MacScreenViewBuilder.TextSelection(items: [], omitted: 0)
    var marks: [JSONValue] = []
    var texts: [JSONValue] = []
    var thinReason: String?
    var recognizesPixels = false
    var semanticFocusFrame: MacAXFrame?
    var pictured = true
    var recognizesText = false
    // The pixels: set when they are captured under the disclosure deadline.
    var disclosureDeadline = Date.distantPast
    var redactionNodes: [MacAXNode] = []
    var postRedactionNodes: [MacAXNode] = []
    var imageTargets: [MacImageCapture.PointTarget] = []
    var coverageFailure: String?
    var capturedAt = Date.distantPast
    var screenCaptureStartedNs: UInt64 = 0
    var shot: MacScreenShot?
    var imageFailure: MacScreenCaptureFailure?
    var screenCaptureFinishedNs: UInt64 = 0
    // The output: opened after the capture, completed by the image and the publication.
    var output: [String: JSONValue] = [:]
    var geometry: MacScreenViewGeometry?
    var secrets: [MacAXFrame] = []
    var recognizedWindowText: (rows: JSONValue, text: String)?
    var windowTextFailure: String?
    var imageRenderFinishedNs: UInt64 = 0

    init(viewStartedNs: UInt64, semanticRawFrame: Bool, semanticFocusVisualSurface: Bool, scope: MacScreenCaptureScope, limits: MacAXLimits,
         maxMarks: Int, maxImageBytes: Int, accessibilityTrusted: Bool, screenTrusted: Bool, axSnapshotStartedNs: UInt64,
         binding: MacSightCaptureBinding?, windowRect: MacAXFrame?, app: MacAXAppInfo?, windowTitle: String?, snapshot: MacAXTreeSnapshot?,
         redactionRoot: MacAXElementRef?, windowIdentity: MacAXWindowIdentity?, axSelfRefused: Bool, isolatedWindow: Bool,
         transientMenus: [MacTransientMenus.Menu], axSnapshotFinishedNs: UInt64) {
        self.viewStartedNs = viewStartedNs
        self.semanticRawFrame = semanticRawFrame
        self.semanticFocusVisualSurface = semanticFocusVisualSurface
        self.scope = scope
        self.limits = limits
        self.maxMarks = maxMarks
        self.maxImageBytes = maxImageBytes
        self.accessibilityTrusted = accessibilityTrusted
        self.screenTrusted = screenTrusted
        self.axSnapshotStartedNs = axSnapshotStartedNs
        self.binding = binding
        self.windowRect = windowRect
        self.app = app
        self.windowTitle = windowTitle
        self.snapshot = snapshot
        self.redactionRoot = redactionRoot
        self.windowIdentity = windowIdentity
        self.axSelfRefused = axSelfRefused
        self.isolatedWindow = isolatedWindow
        self.transientMenus = transientMenus
        self.axSnapshotFinishedNs = axSnapshotFinishedNs
    }
}
