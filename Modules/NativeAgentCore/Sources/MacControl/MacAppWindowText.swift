import Foundation
import PersistenceCore
import Senses
import NativeAgentCore
#if canImport(Vision) && canImport(ApplicationServices)
import Vision
import ApplicationServices
// Blueprint: | `MacAppWindowText.swift` | `MacAppWindowText` enum; one positional-redacting on-device recognizer for current app-window capture and ephemeral whole-window shots before text-only retention |
#endif

/// The independent app view is text recognized on-device from that window's
/// own pixels. This never captures the desktop, launches or activates an app.
public enum MacAppWindowText {
    public static func read(bundleID: String, window: JSONValue?) async throws -> (rows: JSONValue, text: String) {
        if MacObservationMode.current == .passive, MacScreenLock.isCovered() {
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
        let candidates = source.windowRoots(pid: app.processIdentifier)
        guard case .matched(let selected, _) = MacAXWindowIdentity.match(identity, among: candidates.map { (handle: $0, identity: $0.identity) }),
              let node = source.attributes(of: selected.ref), node.frame == frame, node.title == identity.title else {
            throw SenseFailure(code: "source_unavailable", message: "The AX window changed before its independent text view could be captured.")
        }
        let capture = await defaultMacScreenCaptureSource().capture(window: identity)
        try Task.checkCancellation()
        let shot: MacScreenShot
        switch capture {
        case .success(let captured): shot = captured
        case .failure(let failure):
            throw SenseFailure(code: failure.rawValue, message: failure.localizedDescription, remedy: failure.remedy(app: bundleID))
        }
        guard let image = shot.cgImage else {
            throw SenseFailure(code: "image_encode_failed", message: "The captured window has no image for text recognition.", remedy: MacScreenCaptureFailure.encodeFailed.remedy(app: bundleID))
        }
        let recognized = try await recognize(image: image)
        guard source.runningApps().contains(where: { $0.processIdentifier == app.processIdentifier && $0.bundleIdentifier == bundleID }),
              let current = source.attributes(of: selected.ref), current.frame == frame, current.title == node.title else {
            throw SenseFailure(code: "source_unavailable", message: "The app window changed during text recognition; this material was discarded.")
        }
        return material(recognized, geometry: MacScreenViewGeometry(shot: shot))
        #else
        throw SenseFailure(code: "source_unavailable", message: "On-device app window text recognition requires macOS Vision.")
        #endif
    }

    /// Recognize the read's ephemeral capture before retaining any material.
    /// Only redacted text and positions may leave this boundary.
    public static func readCaptured(_ shot: MacScreenShot) async throws -> (rows: JSONValue, text: String) {
        #if canImport(Vision) && canImport(ApplicationServices) && os(macOS)
        let bounds = shot.bounds
        guard let image = shot.cgImage, bounds.w > 0, bounds.h > 0,
              bounds.x.isFinite, bounds.y.isFinite, bounds.w.isFinite, bounds.h.isFinite else {
            throw SenseFailure(code: "source_unavailable", message: "The app capture is incomplete; no live screen was substituted.")
        }
        return material(try await recognize(image: image), geometry: MacScreenViewGeometry(shot: shot))
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
/// VNRequest explicitly supports cancellation from another thread while its
/// synchronous image handler is running.
private final class WindowTextRecognition: @unchecked Sendable {
    private let request: VNRecognizeTextRequest
    init(request: VNRecognizeTextRequest) { self.request = request }
    func cancel() { request.cancel() }
}
#endif
