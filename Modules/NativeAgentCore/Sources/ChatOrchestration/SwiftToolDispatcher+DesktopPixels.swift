import Foundation
import NativeAgentCore
import PersistenceCore
import Dispatcher
import MacControl

extension SwiftToolDispatcher {
    /// Strict provider schemas may spell omitted optional fields as null.
    /// Blank string selectors are also absent, matching the four-verb reader.
    static func desktopPixelsRequested(_ input: [String: JSONValue]) throws -> Bool {
        guard let value = input["pixels"], value != .null else { return false }
        guard case .bool(let requested) = value else {
            throw AutonomyGateError.toolDenied(reason: "screen pixels must be true or false")
        }
        guard requested else { return false }
        for key in ["app", "part"] {
            guard let selector = input[key], selector != .null else { continue }
            if case .string(let text) = selector,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            throw AutonomyGateError.toolDenied(reason: "screen pixels captures the primary desktop; omit app and part to avoid confusing desktop pixels with an isolated window")
        }
        return true
    }

    /// Reached only after the ordinary screen read authority gate. No AX read,
    /// focus change, permission request, persistent file, or action verification.
    static func desktopPixels(
        source: any MacScreenCaptureSource = defaultMacScreenCaptureSource(),
        renderer: any MacScreenImageRenderer = defaultMacScreenImageRenderer()
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
        guard let png = renderer.renderPNG(shot: shot, placements: [], downscale: scale) else {
            return failed("Desktop image encoding failed.")
        }
        let delivered = LocalToolImage.deliverPNG(png, name: "primary-desktop.png",
            width: max(1, Int((Double(shot.pixelWidth) * scale).rounded())),
            height: max(1, Int((Double(shot.pixelHeight) * scale).rounded())))
        guard case .object(var result) = delivered else { return delivered }
        result["capture_scope"] = .string("primary_desktop")
        result["captured_at"] = .string(ISO8601DateFormatter().string(from: Date()))
        result["verification_scope"] = .string("visual_observation_only")
        result["note"] = .string("Actual primary-display pixels, including overlapping windows and desktop, bounded to 1600px. Not an isolated app rendering or an Accessibility read. Inspect the image to assess the outcome; capture success alone does not verify an action. Protected content may be unavailable.")
        return .object(result)
    }
}
