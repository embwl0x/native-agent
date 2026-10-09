import Foundation
import PersistenceCore
import Senses
import NativeAgentCore
#if canImport(Vision) && canImport(ApplicationServices)
import Vision
import ApplicationServices
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
        guard case .success(let shot) = capture, let image = shot.cgImage else {
            throw SenseFailure(code: "source_unavailable", message: "The app window could not be captured for on-device text recognition; Screen Recording permission and a visible window are required.")
        }
        let recognized = try await recognize(image: image, bounds: shot.bounds)
        guard source.runningApps().contains(where: { $0.processIdentifier == app.processIdentifier && $0.bundleIdentifier == bundleID }),
              let current = source.attributes(of: selected.ref), current.frame == frame, current.title == node.title else {
            throw SenseFailure(code: "source_unavailable", message: "The app window changed during text recognition; this material was discarded.")
        }
        return recognized
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
        return try await recognize(image: image, bounds: bounds)
        #else
        throw SenseFailure(code: "source_unavailable", message: "On-device app window text recognition requires macOS Vision.")
        #endif
    }

    #if canImport(Vision) && canImport(ApplicationServices) && os(macOS)
    private static func recognize(image: CGImage, bounds: MacAXFrame) async throws -> (rows: JSONValue, text: String) {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        let work = WindowTextRecognition(request: request)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: image).perform([request])
        } onCancel: {
            work.cancel()
        }
        try Task.checkCancellation()
        let observations = (request.results ?? []).sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 { return $0.boundingBox.midY > $1.boundingBox.midY }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        let boxes: [VisionTextBox] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return VisionTextBox(text: candidate.string,
                rect: VisionRect(x: box.minX * Double(image.width),
                    y: (1 - box.maxY) * Double(image.height),
                    w: box.width * Double(image.width), h: box.height * Double(image.height)),
                confidence: Double(candidate.confidence))
        }
        // Redact the WHOLE image before assembling either output. A caption
        // in a different observation must protect its value in every sink.
        // Keep this reader's existing full-line output for non-secret text.
        let redacted = VisionTextRedaction.redact(boxes: boxes,
            imageSize: VisionSize(width: Double(image.width), height: Double(image.height)),
            config: VisionRedactionConfig(valueChars: boxes.map { $0.text.count }.max() ?? 120))
        let lines = redacted.compactMap(\.display)
        let rows: [JSONValue] = zip(boxes, redacted).map { box, value in
            return .object(["text": value.json, "confidence": .double(box.confidence),
                "frame": MacAXFrame(x: bounds.x + box.rect.x / Double(image.width) * bounds.w,
                    y: bounds.y + box.rect.y / Double(image.height) * bounds.h,
                    w: box.rect.w / Double(image.width) * bounds.w,
                    h: box.rect.h / Double(image.height) * bounds.h).toJSON(),
                "source": .string("on-device window text recognition")])
        }
        return (.array(rows), lines.joined(separator: "\n"))
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
