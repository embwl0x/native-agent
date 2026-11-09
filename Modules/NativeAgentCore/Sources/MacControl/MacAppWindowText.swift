import Foundation
import PersistenceCore
import Senses
import NativeAgentCore
#if canImport(Vision) && canImport(ApplicationServices)
import Vision
import ApplicationServices
// Blueprint: | `MacAppWindowText.swift` | `MacAppWindowText`: On-device window OCR; retain only redacted text/positions |
#endif

/// Read only the named window's pixels so background text recognition cannot capture unrelated desktop content or change focus.
public enum MacAppWindowText {
    public static func read(bundleID: String, window: JSONValue?, context: MacOperationContext) async throws -> (rows: JSONValue, text: String) {
        if context.observationMode == .passive, try MacScreenLock.isCovered() {
            throw SenseFailure(code: "source_unavailable", message: MacScreenLock.passiveReply)
        }
        #if canImport(Vision) && canImport(ApplicationServices) && os(macOS)
        let source = defaultMacAXElementSource()
        guard case .matched(let app) = MacBackgroundSight.resolve(bundleID, among: source.runningApps()),
              case .object(let anchor)? = window, case .int(let pid)? = anchor["pid"], pid == Int64(app.processIdentifier),
              case .string(let role)? = anchor["role"], case .object(let rect)? = anchor["frame"],
              let x = number(rect["x"]), let y = number(rect["y"]), let w = number(rect["w"]), let h = number(rect["h"]) else {
            throw SenseFailure(code: "source_unavailable", message: "App text recognition needs an already-running app with a visible window.")
        }
        let frame = MacAXFrame(x: x, y: y, w: w, h: h)
        let identity = MacAXWindowIdentity(pid: app.processIdentifier, index: nil, role: role,
            subrole: string(anchor["subrole"]), title: string(anchor["title"]), frame: frame)
        let candidates = source.windowRoots(pid: app.processIdentifier, context: context)
        guard case .matched(let selected, _) = MacAXWindowIdentity.match(identity, among: candidates.map { (handle: $0, identity: $0.identity) }),
              let node = source.attributes(of: selected.ref, context: context), node.frame == frame, node.title == identity.title else {
            throw SenseFailure(code: "source_unavailable", message: "The AX window changed before its independent text view could be captured.")
        }
        let deadline = Date().addingTimeInterval(MacAXLimits.readSeconds)
        func inspect() throws -> [MacAXNode] {
            let nodes = try MacScreenViewTextRedaction.inspectSecretFields(source: source, root: selected.ref,
                deadline: deadline, context: context)
            guard let root = nodes.first, root.attributes.role == role, MacAXWindowIdentity.rectsMatch(root.attributes.frame, frame) else {
                throw SenseFailure(code: "redaction_coverage_unavailable", message: "The inspected text window changed identity or geometry.")
            }
            return nodes
        }
        let before = try inspect()
        let captureStarted = Date()
        let capture = await defaultMacScreenCaptureSource().capture(window: identity, context: context)
        try Task.checkCancellation()
        let shot: MacScreenShot
        switch capture {
        case .success(let captured): shot = captured
        case .failure(let failure):
            throw SenseFailure(code: failure.rawValue, message: failure.localizedDescription, remedy: failure.remedy(app: bundleID))
        }
        guard MacAXWindowIdentity.rectsMatch(shot.bounds, frame), let provenance = shot.capture,
              provenance.capturedAt >= captureStarted, provenance.capturedAt <= Date(), provenance.windows.count == 1,
              let capturedWindow = provenance.windows.first, capturedWindow.pid == app.processIdentifier,
              MacAXWindowIdentity.rectsMatch(capturedWindow.frame, frame) else {
            throw SenseFailure(code: "source_unavailable", message: "The text capture no longer matches the inspected window frame.")
        }
        let after = try inspect()
        let geometry = MacScreenViewGeometry(shot: shot)
        guard let beforeMasks = MacScreenViewTextRedaction.secretFrames(nodes: before, geometry: geometry, deadline: deadline, context: context),
              let afterMasks = MacScreenViewTextRedaction.secretFrames(nodes: after, geometry: geometry, deadline: deadline, context: context) else {
            throw SenseFailure(code: "redaction_coverage_unavailable", message: "Secret mask compilation exceeded its deadline.")
        }
        let masks = beforeMasks + afterMasks.filter { !beforeMasks.contains($0) }
        let recognized = try await readCaptured(shot, excluding: masks)
        guard source.runningApps().contains(where: { $0.processIdentifier == app.processIdentifier && $0.bundleIdentifier == bundleID }),
              let current = source.attributes(of: selected.ref, context: context), current.frame == frame, current.title == node.title else {
            throw SenseFailure(code: "source_unavailable",
                message: "The app window changed; recognized text was discarded.")
        }
        return recognized
        #else
        throw SenseFailure(code: "source_unavailable", message: "On-device app window text recognition requires macOS Vision.")
        #endif
    }

    /// Whole-window caption redaction precedes mask filtering. Callers supply complete pre/post AX masks for this exact capture.
    public static func readCaptured(_ shot: MacScreenShot, excluding masks: [MacAXFrame]) async throws -> (rows: JSONValue, text: String) {
        #if canImport(Vision) && canImport(ApplicationServices) && os(macOS)
        let bounds = shot.bounds
        guard let image = shot.cgImage, bounds.w > 0, bounds.h > 0,
              shot.pixelWidth > 0, shot.pixelHeight > 0, image.width == shot.pixelWidth, image.height == shot.pixelHeight,
              [bounds.x, bounds.y, bounds.w, bounds.h, bounds.x + bounds.w, bounds.y + bounds.h].allSatisfy(\.isFinite) else {
            throw SenseFailure(code: "source_unavailable", message: "The app capture is incomplete; no live screen was substituted.")
        }
        let geometry = MacScreenViewGeometry(shot: shot)
        guard geometry.scaleX.isFinite, geometry.scaleX > 0, geometry.scaleY.isFinite, geometry.scaleY > 0 else {
            throw SenseFailure(code: "redaction_coverage_unavailable", message: "The capture has no finite AX-to-pixel scale; recognized text was withheld.")
        }
        func finite(_ rect: VisionRect) -> Bool {
            [rect.x, rect.y, rect.w, rect.h, rect.maxX, rect.maxY].allSatisfy(\.isFinite) && rect.w > 0 && rect.h > 0
        }
        // VisionKitTextRecognizer flips normalized bottom-left boxes into top-left image pixels. imageRect maps AX frames into those same pixels.
        let mappedMasks = masks.map(geometry.imageRect)
        guard mappedMasks.allSatisfy(finite) else {
            throw SenseFailure(code: "redaction_coverage_unavailable",
                message: "Secret masks cannot be mapped to this text capture; recognized text was withheld.")
        }
        // Match the renderer's outward rounding to whole image pixels.
        let imageMasks = mappedMasks.map { rect in
            let x = rect.x.rounded(.down), y = rect.y.rounded(.down)
            return VisionRect(x: x, y: y, w: rect.maxX.rounded(.up) - x, h: rect.maxY.rounded(.up) - y)
        }
        let recognized = try await recognize(image: image)
        let visible = try recognized.filter { line in
            guard let rect = line.rect, finite(rect), rect.x >= 0, rect.y >= 0,
                  rect.maxX <= Double(image.width), rect.maxY <= Double(image.height) else {
                throw SenseFailure(code: "redaction_coverage_unavailable",
                    message: "OCR positions cannot be bound to this capture; recognized text was withheld.")
            }
            // A row may contain multiple words: withhold the whole row on any overlap, never select words by its center.
            return !imageMasks.contains { $0.intersection(rect).area > 0 }
        }
        return material(visible, geometry: geometry)
        #else
        throw SenseFailure(code: "source_unavailable", message: "On-device app window text recognition requires macOS Vision.")
        #endif
    }

    private static func material(_ text: [VisionRecognizedText], geometry: MacScreenViewGeometry) -> (rows: JSONValue, text: String) {
        let rows = text.map { line in JSONValue.object([
            "text": line.text.json, "confidence": .double(line.confidence),
            "frame": line.rect.map { geometry.screenRect($0).toJSON() } ?? .null,
            "source": .string("on-device window text recognition")]) }
        return (.array(rows), text.compactMap { $0.text.display }.joined(separator: "\n"))
    }

    #if canImport(Vision) && canImport(ApplicationServices) && os(macOS)
    public static func recognize(image: CGImage) async throws -> [VisionRecognizedText] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        let work = WindowTextRecognition(request: request)
        let boxes = try await withTaskCancellationHandler {
            try VisionKitTextRecognizer().recognizeText(in: image, request: request, select: Self.readingOrder)
        } onCancel: { work.cancel() }
        // Whole-image captions protect values before either output is assembled.
        let redacted = VisionTextRedaction.redact(boxes: boxes,
            imageSize: VisionSize(width: Double(image.width), height: Double(image.height)),
            valueChars: boxes.map { $0.text.count }.max() ?? 120)
        return zip(boxes, redacted).map { box, value in
            VisionRecognizedText(text: value, confidence: box.confidence, rect: box.rect)
        }
    }

    private static func readingOrder(_ observations: [VNRecognizedTextObservation]) -> [VNRecognizedTextObservation] {
        // Anchor lines vertically before sorting within them; pairwise tolerances are not transitive.
        let vertical = observations.enumerated().sorted {
            let left = $0.element.boundingBox, right = $1.element.boundingBox
            if left.midY != right.midY { return left.midY > right.midY }
            return $0.offset < $1.offset
        }
        var linesByPosition: [[(offset: Int, element: VNRecognizedTextObservation)]] = []
        for observation in vertical {
            if let anchor = linesByPosition.last?.first,
               anchor.element.boundingBox.midY - observation.element.boundingBox.midY <= 0.01 {
                let index = linesByPosition.count - 1
                linesByPosition[index].append(observation)
            } else { linesByPosition.append([observation]) }
        }
        return linesByPosition.flatMap { line in
            line.sorted {
                let left = $0.element.boundingBox.minX, right = $1.element.boundingBox.minX
                return left == right ? $0.offset < $1.offset : left < right
            }.map(\.element)
        }
    }
    #endif
    private static func number(_ value: JSONValue?) -> Double? {
        switch value { case .double(let n)? where n.isFinite: return n; case .int(let n)?: return Double(n); default: return nil }
    }
    private static func string(_ value: JSONValue?) -> String? { if case .string(let text)? = value { text } else { nil } }
}

#if canImport(Vision) && canImport(ApplicationServices) && os(macOS)
/// VNRequest explicitly supports cancellation from another thread while its synchronous image handler is running.
private final class WindowTextRecognition: @unchecked Sendable {
    private let request: VNRecognizeTextRequest
    init(request: VNRecognizeTextRequest) { self.request = request }
    func cancel() { request.cancel() }
}
#endif
